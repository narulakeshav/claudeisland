import Cocoa
import SwiftUI
import CoreText
import CryptoKit

// ─────────────────────────────────────────────────────────────────────────
// ClaudeIsland — a persistent notch "live activity" for Claude Code.
//
// Runs as a background LSUIElement agent. Owns a borderless, non-activating
// NSPanel pinned at the top-center of the notch screen. State is pushed in
// from Claude Code hooks: the `island-send` helper writes a normalized
// payload to ~/.claude-island/event.json and posts a Darwin notification,
// which wakes this process to reload and animate.
// ─────────────────────────────────────────────────────────────────────────

// MARK: - Paths

let kEventDir = NSString("~/.claude-island").expandingTildeInPath
let kEventFile = kEventDir + "/event.json"
let kSessionsDir = kEventDir + "/sessions"     // one <tabUUID>.json per live session
// Claude Code's own per-session state files (one <pid>.json each, keyed by sessionId).
// CC updates `status` (busy/idle) live, independent of our hooks — the freshest signal
// for whether a session is actually computing right now. Reverse-engineered, no API.
let kCCSessionsDir = NSString("~/.claude/sessions").expandingTildeInPath
let kProjectOrderFile = kEventDir + "/project-order"   // persisted dropdown group order (first-seen)
let kDarwinName = "com.claude-island.event"

// EXPERIMENT: lead each dropdown row with the session's opening user prompt instead of
// the Warp tab name — the prompt is a far stickier "which convo is this" anchor. Flip to
// false to revert to the tab title. (Falls back to the title when no prompt was captured.)
let kRowTitleUsesPrompt = true

private func stableKeyHash(_ s: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 {
        hash ^= UInt64(b)
        hash = hash &* 0x100000001b3
    }
    return String(format: "%016llx", hash)
}

private func normalizedFlashText(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
        .split { $0.isWhitespace || $0.isNewline }
        .joined(separator: " ")
}

private func transcriptEventID(_ obj: [String: Any], fallback: String) -> String {
    for key in ["uuid", "id", "timestamp"] {
        if let s = obj[key] as? String, !s.isEmpty { return s }
        if let n = obj[key] as? NSNumber { return n.stringValue }
    }
    return stableKeyHash(fallback)
}

// Custom fonts (registered at launch). Verb uses the serif, project uses the sans.
let kSerifFontPath = NSString("~/Library/Fonts/AnthropicSerif_Roman_Web-s.p.0974051x8mlf0.otf").expandingTildeInPath
let kSansFontPath  = NSString("~/Library/Fonts/AnthropicSans_Roman_Web-s.p.0g0iw7wqvowb5.otf").expandingTildeInPath
let kSerifFontName = "AnthropicSerifWebWeb-TextLight"
let kSansFontName  = "AnthropicSansWebWeb-TextRegular"

func registerFonts() {
    for path in [kSerifFontPath, kSansFontPath] where FileManager.default.fileExists(atPath: path) {
        CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: path) as CFURL, .process, nil)
    }
}

/// Bring Warp to the front (or launch it) when the island is clicked.
func activateWarp() {
    let apps = NSWorkspace.shared.runningApplications
    if let warp = apps.first(where: { ($0.bundleIdentifier ?? "").lowercased().contains("warp") }) {
        warp.activate(options: [.activateAllWindows])
    } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.warp.Warp-Stable") {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}

/// Jump to the exact Warp tab/pane that owns this session via its deep link
/// (warp://session/<uuid>). Falls back to just fronting Warp if we have no link.
func focusSession() {
    let f = IslandState.shared.focusURL
    if !f.isEmpty, let url = URL(string: f) {
        NSWorkspace.shared.open(url)
    } else {
        activateWarp()
    }
}

/// Map a session's focus descriptor (and id, for idle/no-focus cases) to the owning terminal
/// app's bundle id — the key for its icon. nil = an app we can't identify (folds into the
/// anonymous "local" card), so no icon is drawn.
func terminalBundleId(focus: String, id: String) -> String? {
    if focus.hasPrefix("warp://") { return "dev.warp.Warp-Stable" }
    if focus.hasPrefix("app:") { return String(focus.dropFirst(4)) }
    if focus.hasPrefix("editor:") {  // editor:<bundleid>:<cwd>
        return focus.dropFirst("editor:".count).split(separator: ":", maxSplits: 1).first.map(String.init)
    }
    if focus.hasPrefix("term:iterm2:") { return "com.googlecode.iterm2" }
    if focus.hasPrefix("term:apple_terminal:") { return "com.apple.Terminal" }
    // Idle tabs / empty focus: fall back to the id prefix the hook and daemon both key on.
    if id.hasPrefix("iterm-") { return "com.googlecode.iterm2" }
    if id.hasPrefix("aterm-") { return "com.apple.Terminal" }
    if id.hasPrefix("ghostty-") { return "com.mitchellh.ghostty" }
    if id.hasPrefix("cursor-") { return "com.todesktop.230313mzl4w4u92" }
    if id.hasPrefix("vscode-") { return "com.microsoft.VSCode" }
    if id.hasPrefix("cdesk-") { return "com.anthropic.claudefordesktop" }
    // Codex Desktop ships inside ChatGPT.app, whose bundle id really is com.openai.codex.
    if id.hasPrefix("cdex-") { return "com.openai.codex" }
    // A bare hex id with no scheme is a Warp tab (uuid-keyed).
    if !id.isEmpty, id != "local", id.allSatisfy({ $0.isHexDigit }) { return "dev.warp.Warp-Stable" }
    return nil
}

/// The state-file key for a Claude-desktop-hosted session. MUST match the hook's
/// `"cdesk-" + short_hash(session_id or cwd)` (short_hash = SHA-1, first 16 hex chars), so the
/// daemon's process scan and the hook agree on the same card. Desktop CC has no tty to key on.
func claudeDesktopKey(_ idSource: String) -> String {
    let hex = Insecure.SHA1.hash(data: Data(idSource.utf8)).map { String(format: "%02x", $0) }.joined()
    return "cdesk-" + hex.prefix(16)
}

private var _appIconCache: [String: NSImage] = [:]
/// The app icon for a bundle id, cached (rendered per-row, so memoize). Prefers a running
/// instance's icon, else resolves on disk; Warp ships two channels (Stable/Preview) so fall
/// back to any running "warp" app.
/// Codex Desktop's real icon — the one in the Dock — which macOS will not give us.
///
/// Codex ships inside ChatGPT.app, an Electron bundle still named "ChatGPT" whose static
/// CFBundleIconFile is `electron.icns` (the ChatGPT knot). The Codex mark is applied to the Dock
/// at RUNTIME, so `NSRunningApplication.icon` and `icon(forFile:)` both hand back the knot no
/// matter what you see in the Dock. The actual art ships beside it as loose PNGs, so load one.
///
/// Light variant deliberately: it's what the Dock shows in Light appearance, and the island is a
/// permanently dark surface — the dark-mode tile is near-black and would sink into the row.
/// Resolved via the bundle id rather than a hardcoded /Applications path so a relocated app (or
/// a rename away from "ChatGPT.app") still works.
private func codexAppIcon() -> NSImage? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
    else { return nil }
    for name in ["icon-codex-light", "icon-codex-dark-color"] {
        let p = url.appendingPathComponent("Contents/Resources/\(name).png").path
        if let img = NSImage(contentsOfFile: p) { return img }
    }
    return nil   // art moved/renamed — caller falls back to the bundle icon
}

func appIcon(bundleId: String) -> NSImage? {
    if let c = _appIconCache[bundleId] { return c }
    let running = NSWorkspace.shared.runningApplications
    var img: NSImage?
    // Codex first — asking macOS would only ever return ChatGPT.app's static knot (see
    // codexAppIcon). Everything below is the fallback for when that art can't be found.
    if bundleId == "com.openai.codex" { img = codexAppIcon() }
    if img == nil {
        if let a = running.first(where: { $0.bundleIdentifier == bundleId }) { img = a.icon }
        else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            img = NSWorkspace.shared.icon(forFile: url.path)
        } else if bundleId.lowercased().contains("warp"),
                  let a = running.first(where: { ($0.bundleIdentifier ?? "").lowercased().contains("warp") }) {
            img = a.icon
        }
    }
    if let img { _appIconCache[bundleId] = img }
    return img
}

// Text measurement. SwiftUI GeometryReader/PreferenceKey reads come back 0 inside
// this non-activating NSPanel hosting context (verified: L/R/Pill all measured 0),
// so we can't measure laid-out views. Instead we size everything deterministically
// from CoreText: measure each label with its real font and reconstruct the cluster
// widths in code. The pill lays out from the same strings, so the pill geometry and
// the back-card widths/offsets stay perfectly in sync.
func textWidth(_ s: String, _ font: NSFont, tracking: CGFloat = 0) -> CGFloat {
    guard !s.isEmpty else { return 0 }
    var attrs: [NSAttributedString.Key: Any] = [.font: font]
    if tracking != 0 { attrs[.kern] = tracking }
    return ceil((s as NSString).size(withAttributes: attrs).width)
}

// Back-card layout constants. Shared between the SwiftUI view (which draws the cards)
// and AppController (which hit-tests them against the mouse), so the geometry the user
// sees and the geometry the hover logic uses can never drift apart.
let kCardPeek: CGFloat = 22       // how far each stacked card peeks past the one in front
let kCardTuck: CGFloat = 56       // how far a hovered card's right edge tucks under the pill
let kCardTextPad: CGFloat = 22    // title leading inset (clears the concave shoulder)
let kCardTextGap: CGFloat = 8     // gap after the title before the tuck
let kCardSansFont = NSFont(name: kSansFontName, size: 13) ?? .systemFont(ofSize: 13)
let kTimerFont = NSFont(name: kSansFontName, size: 12) ?? .systemFont(ofSize: 12)  // dropdown row timer
let kTooltipFont = NSFont(name: kSansFontName, size: 11) ?? .systemFont(ofSize: 11) // compactTooltip label

// Dropdown ("{n} ⌄") UI geometry, shared by the view and the controller's hit-testing.
let kAgentsPeek: CGFloat = 32     // how far the "{n} ⌄" back pill peeks past the pill's right edge
let kSheetSide: CGFloat = 40      // how much wider (each side) the expanded sheet is than the pill
let kRowHeight: CGFloat = 32      // dropdown row height
let kSubagentFreshS: Double = 8   // a subagent whose transcript moved within this window is "running"
let kHeaderHeight: CGFloat = 22   // dropdown section-header (project label) height
let kFlashHoldS: Double = 7.0      // front-pill commentary flash: how long a PROSE flash holds
                                   // before it slides back to the tab name (matches FinishFlash's
                                   // timer); also its protected window before anything replaces it
let kProseRefreshS: Double = 1.6    // minimum read before newer prose can refresh older prose
let kToolDwellS: Double = 1.2      // shorter protected window for a tool-label flash — long enough
                                   // that a burst of rapid tool calls coalesces instead of flickering
let kLivePollIntervalS: Double = 0.4       // active-turn transcript/status poll; cheap after one-pass tailing
let kLivePollToleranceS: Double = 0.08
let kLivenessInspectIntervalS: Double = 1.0 // dropdown/idle-pill visible: user is actively inspecting
let kLivenessActiveIntervalS: Double = 2.0  // normal visible active/resting island
let kLivenessHiddenIntervalS: Double = 20.0 // fully hidden idle: save CPU
let kLiveTabGraceDefaultS: Double = 8.0     // smooth one missed ps scan in the background
let kLiveTabGraceInspectS: Double = 3.0     // faster disappear while the roster is visible
let kDropdownVPad: CGFloat = 6    // vertical padding below the pill row, inside the sheet
let kDropdownBottomPad: CGFloat = 6   // padding below the last row, inside the rounded bottom
let kRowInset: CGFloat = 14       // row horizontal inset from the sheet edge
let kFrontPeek: CGFloat = 23      // how far the front pill grows DOWN on hover to show its title (+1 over the text's own height so descenders like "g" don't clip)
let kFrontExpandRadius: CGFloat = 28  // bottom corner radius while the front pill is expanded
let kUsagePeekReserve: CGFloat = 95 // always-reserved panel height below the island (kFrontPeek + float room for the hover tooltip), so the usage peek + its floating caption never clip against the window bound
let kActivityDays = 7             // days shown in the notch usage-peek activity strip (oldest→newest, today rightmost),
                                  // flanked by "7 days" / "Today" labels

/// One entry in the dropdown: either a project section header or a session row. Headers
/// appear only when the roster spans more than one project; a single-project list is flat.
struct DropdownItem: Identifiable {
    let id: String
    let header: String?       // non-nil → section header label
    let card: SessionCard?    // non-nil → session row
    var titleInHeader = false // row's tab name already shown by its header → row omits it
    // Git context for a repo/branch header (empty hRepo → render `header` as a plain label).
    var hRepo = ""; var hBranch = ""; var hFiles = 0; var hAdded = 0; var hRemoved = 0
    var isHeader: Bool { header != nil }
}

/// Total pixel height of the dropdown's item stack (headers are shorter than rows).
func dropdownContentHeight(_ items: [DropdownItem]) -> CGFloat {
    items.reduce(0) { $0 + ($1.isHeader ? kHeaderHeight : kRowHeight) }
}

/// The resting idle pill's label: "{n} idle session(s)" when ≥1 tracked tab is idle/stale,
/// else a plain "Idle". Single source of truth for both the view text and the geometry math.
func idleSessionsLabel(_ n: Int) -> String {
    n <= 0 ? "Idle" : "\(n) idle session\(n == 1 ? "" : "s")"
}

/// Same layout as `idleSessionsLabel` but without claiming the sessions are idle — used when
/// the neutral "icon + count" pill is showing because a "Finished" pill was dismissed, not
/// because everything is actually idle.
func neutralSessionsLabel(_ n: Int) -> String {
    n <= 0 ? "Idle" : "\(n) session\(n == 1 ? "" : "s")"
}

/// Whether a row draws a context ring (shared by the view and the controller's hit-test):
/// only once the window is ≥25% full. Shown on every status, including the grey
/// idle/stale rows — those are exactly the tabs you're about to resume typing into,
/// so their fill is worth knowing before you do, arguably more than a busy row's.
func ringVisible(_ card: SessionCard) -> Bool {
    card.context >= 0.25
}

/// Context badge fill — warns as the window fills: white < 30%, amber 30–50%, red ≥ 50%.
func contextFillColor(_ pct: Double) -> Color {
    if pct >= 0.5 { return Color(red: 0.898, green: 0.282, blue: 0.302) }  // red
    if pct > 0.30 { return Color(red: 1.0, green: 0.745, blue: 0.0) }      // amber
    return .white
}

/// Context badge foreground (ring + percent text) — the amber fill is too light for white
/// to stay legible, so that band alone flips to black; red and the white/base fill keep white.
func contextForegroundColor(_ pct: Double) -> Color {
    if pct >= 0.5 { return .white }
    if pct > 0.30 { return .black }
    return .white
}

/// Truncated card label (title or, if empty, project), matching what the view draws.
func cardLabel(_ card: SessionCard) -> String {
    let raw = card.title.isEmpty ? card.project : card.title
    return raw.count > 24 ? String(raw.prefix(24)) + "…" : raw
}

/// Constant on-screen width of a back card — never resizes, only slides. Wide enough to
/// fit its title, but never less than what's needed to still cover the sliver the cursor
/// grabbed (so a hover can't slide the card out from under the pointer).
func cardWidth(_ card: SessionCard, idx: Int) -> CGFloat {
    let titleW = textWidth(cardLabel(card), kCardSansFont)
    return max(titleW + kCardTextPad + kCardTextGap + kCardTuck,
               kCardTuck + CGFloat(idx + 1) * kCardPeek + 30)
}

// MARK: - State

final class IslandState: ObservableObject {
    enum Mode: String { case thinking, working, attention, error, done, compacting, compacted, idle }

    @Published var mode: Mode = .thinking
    @Published var title: String = "Claude Code"
    @Published var lastUserMsg: String = ""  // front session's latest user message (peek marquee)
    @Published var detail: String = ""       // left label: verb while working
    @Published var preview: String = ""      // (currently unused for display)
    @Published var elapsed: String = ""      // right label: live turn timer
    @Published var project: String = ""
    @Published var contextPct: Double = 0    // 0…1 fill of the context window
    @Published var focusURL: String = ""     // warp://session/<uuid> for this tab
    @Published var showTermIcons = false     // roster spans ≥2 terminal apps → tag each row with its app icon
    @Published var firstRunHint = false      // first idle after install: peek shows a "hover to summon me" teach
    @Published var idleHint: Bool = false    // idle peek, stage 1: icon-only pulsing hint (pre-reveal)
    @Published var idleReveal: Double = 1    // 0→1 bouncy scale/opacity entrance for the idle peek
    @Published var idleWaking: Bool = false  // brief "still alive" wink on click: swaps the
                                              // static resting mark for the live gif, then settles back
    // A freshly-finished front session briefly shows its own reply in the right-side slot instead
    // of the tab name — confirmation of what just happened before it hands back off. The
    // controller (rebuild()) only ever sets this on a fresh arrival at "done" / clears it once the
    // front leaves "done" entirely; the actual multi-second animation (marquee in, white → grey,
    // slide out to the tab name) is fully owned and self-timed by `FinishFlash` in the view — see
    // its doc comment for why this can't be a normal SwiftUI `.animation`.
    @Published var justFinishedID: String? = nil     // frontUUID whose flash should be (re)triggered

    // A working front session just said something (genuine commentary, not a tool-label
    // fallback — see `commentary` on SessionCard/LiveSession) briefly shows it in the
    // right-side slot the same way `justFinishedID` does for the done reply, so a glance at
    // the pill answers "is it stuck?" without needing to hover-peek. Set to a fresh, distinct
    // value (see rebuild()'s edge-detection) each time NEW commentary lands; read alongside
    // `preview` (already the current front's text by the time this flips, same reasoning as
    // `justFinishedID`) and cleared by the view once its own hold+slide sequence completes.
    @Published var freshCommentaryID: String? = nil
    // The exact message the current flash should show — captured in rebuild() at trigger time,
    // NOT re-read from `preview` when the flash starts. `preview` moves on (a later tool event,
    // or the turn's done boundary) between the trigger and the view's async `.onChange`, so
    // reading it late showed a message that didn't match what triggered the flash (phantom
    // text). This pins the shown message to the triggering one.
    @Published var commentaryMessage: String = ""

    // ── Multi-session aggregate (≥2 sessions that have actually run) ─────────────
    // Past one session the front pill stops narrating a single tab and shows fleet
    // counts: a left headline (most important live signal) + grey trailing counts.
    // Computed by the controller's rebuild() from the roster; the single-session
    // fields above still mirror the front tab (harmless — the view ignores them while
    // `aggregate` is true).
    @Published var aggregate = false   // render the count pill, not the single-session one
    @Published var runningCount = 0    // working / thinking / compacting / struggling
    @Published var needYouCount = 0    // attention only — sessions you can actually act on
    @Published var doneCount = 0       // done within 15m (stale ones drop out)
    @Published var errorCount = 0      // errored: terminal, NOT actionable — never "need you"
    // When every tracked session is idle/stale, the island hides; a notch hover reveals an
    // "{n} idle sessions" pill that drops the roster list. This holds that count while hidden.
    @Published var idleSessionCount = 0
    // true: `idleSessionCount` is showing because every visible session was dismissed (not
    // because they're actually idle) — the `.idle` mode right text reads "{n} sessions"
    // instead of "{n} idle sessions". Stays visible (never enters the hidden-idle regime).
    @Published var neutralNotIdle = false

    // Notch geometry, set by the controller so the island can match it.
    @Published var notchHeight: CGFloat = 32
    @Published var notchWidth: CGFloat = 200

    // Corner radii (tunable live via the event payload during calibration).
    @Published var topRadius: CGFloat = 12     // re-entrant shoulder fillet
    @Published var bottomRadius: CGFloat = 16  // bottom convex corner

    // Other live sessions, rendered as muted cards stacked behind the front pill,
    // peeking out to the left. Keyed by Warp tab UUID in the real pipeline.
    @Published var cards: [SessionCard] = []

    // Which back card is hovered, driven by AppController's global mouse monitor
    // (SwiftUI's own onHover never fires inside this non-key panel). The view observes
    // this to slide the card out and reveal its title.
    @Published var hoveredCard: String? = nil

    // ── Alternate "dropdown" UI (config: ~/.claude-island/ui-mode = peek | dropdown) ──
    // peek    : back cards stack/peek to the LEFT, hover reveals each title.
    // dropdown: a single "{n} ⌄" back pill peeks to the RIGHT; clicking it drops down a
    //           menu listing every tracked session (dot + name), click a row to focus.
    @Published var uiMode: String = "dropdown"
    @Published var roster: [SessionCard] = []   // every tracked session, for the dropdown
    @Published var dropdownItems: [DropdownItem] = []   // roster grouped by project (+ headers)
    @Published var dropdownOpen = false
    @Published var hoveredRow: String? = nil    // dropdown row under the cursor
    @Published var hoveredGroup: String? = nil  // group (repo/branch) under the cursor — a row OR its header
    @Published var selectedGroup: String? = nil // the selected/active session's group — the resting "expanded" header
    @Published var selectedId: String? = nil    // the selected/active session id — its context drives the header ring
    @Published var hoveredRing: String? = nil   // dropdown row whose context ring is hovered
    // When opened by hovering an aggregate count, the dropdown shows only that status bucket
    // ("attention"/"running"/"done"/"error"); empty = the full list (opened via the {n} ⌄ peek).
    @Published var dropdownFilter = ""
    // Hovering the literal notch shows a playful "Happy Clauding" peek (placeholder until we
    // surface something richer here, e.g. the Claude Code session limit).
    @Published var notchPeek = false
    // Token-usage windows for the notch peek, computed by the controller's usage rollup.
    // Abbreviated values (e.g. "1.1M"); empty until first computed → peek falls back to
    // "Happy Clauding". "Session" = rolling last 5h (Claude's usage-window length).
    @Published var usageSession = ""
    @Published var usageToday = ""
    // Per-day token activity for the notch-peek strip: kActivityDays intensity levels (0=idle,
    // 1…4 brighter), oldest→newest with today rightmost. Shaded relative to the user's own
    // busiest day in the window (there is no per-day plan quota to measure against). Empty until
    // first computed, or when the week is idle → the strip hides.
    @Published var usageDays: [Int] = []
    // Raw input+output tokens for each of those days (same oldest→newest order), for the
    // per-day hover caption ("312k tokens · Jun 19").
    @Published var usageDayTokens: [Int] = []
    // Which strip cell the cursor is over (0…kActivityDays-1, -1 = none). Hit-tested in the
    // mouse monitor since SwiftUI's onHover never fires in this non-key panel.
    @Published var hoveredDay = -1
    // The notch usage-peek shows ONE of two faces at a time, toggled by clicking the peek:
    // false = the usage text line (session/today), true = the 7-day activity heatmap. Persists
    // across hovers so it stays on whichever face the user last picked.
    @Published var usageShowActivity = false
    // Real plan rate-limit % (from Claude Code's statusline `rate_limits`, captured by
    // island-statusline.py). "47" etc., or "" when unavailable (non-Max, or pre-first-response).
    // The 5h window is what Claude's plans call your "Session"; seven_day is the weekly cap.
    @Published var rlSession = ""   // five_hour used_percentage
    @Published var rlWeek = ""      // seven_day used_percentage
    @Published var rlSessionReset = 0.0   // five_hour resets_at (epoch secs; 0 = none)
    @Published var rlWeekReset = 0.0      // seven_day resets_at
    // Front session's "ultrathink" flag — paints the single-session pill's verb in a rainbow.
    @Published var ultra = false

    // Front-pill hover: while true the primary island grows DOWN by kFrontPeek and shows
    // the front session's title at the bottom-center — a quick "which session is this?"
    // peek. Driven by the controller's mouse monitor (onHover never fires in this panel).
    @Published var frontHovered = false

    static let shared = IslandState()
}

/// Drives the "ultrathink" rainbow's continuous color cycle — shared (not per-instance) so the
/// verb text and its matching glyph marker, separate views, animate in exact sync (including
/// across multiple simultaneously-visible ultrathink rows). Started lazily on first use and left
/// running for the app's remaining lifetime; ultrathink is rare enough that the always-on 60Hz
/// timer costs nothing meaningful.
final class RainbowClock: ObservableObject {
    @Published var t: Double = 0
    static let swapInterval: Double = 0.4   // seconds between each discrete color swap
    static let shared = RainbowClock()
    private var timer: Timer?
    private init() {
        let tm = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.t += 1.0 / 60.0
        }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }
}

/// The "ultrathink" rainbow's fixed discrete palette — specific brand colors (not derived from
/// any other status color, and not reused for the plain red/amber/green states) that each
/// letter jumps between, so the effect reads as letters individually SWAPPING color rather
/// than a gradient sliding across the text.
let kRainbowPalette: [Color] = [
    Color(red: 0xFA / 255, green: 0x51 / 255, blue: 0x4F / 255),   // red
    Color(red: 0xFF / 255, green: 0x7D / 255, blue: 0x40 / 255),   // orange
    Color(red: 0xFF / 255, green: 0xC0 / 255, blue: 0x48 / 255),   // yellow
    Color(red: 0x82 / 255, green: 0xCA / 255, blue: 0x7A / 255),   // green
    Color(red: 0x76 / 255, green: 0xA9 / 255, blue: 0xDF / 255),   // blue
    Color(red: 0xA0 / 255, green: 0x81 / 255, blue: 0xCD / 255),   // purple
    Color(red: 0xD4 / 255, green: 0x7E / 255, blue: 0xB7 / 255),   // pink
]

/// Character `i`'s palette slot at discrete swap-step `step` — subtracting `step` from `i`
/// before wrapping means a given color moves to a HIGHER index as `step` increases, i.e. it
/// visibly hands off from an earlier character to the next one (see RainbowClock).
private func rainbowSlot(_ i: Int, step: Int) -> Int {
    let n = kRainbowPalette.count
    return ((i - step) % n + n) % n
}

/// Per-letter rainbow gradient for the "ultrathink" verb — mirrors Claude Code's own ultrathink
/// styling. `step` (whole swaps, see RainbowClock) picks each character's slot in the fixed
/// palette; incrementing it swaps every letter to its neighbor's previous color all at once,
/// instead of continuously blending hues. Color only, so the text content and measured width
/// are unchanged (pill geometry doesn't drift).
func rainbowText(_ s: String, step: Int = 0) -> Text {
    let chars = Array(s)
    guard chars.count > 0 else { return Text("") }
    var out = Text("")
    for (i, ch) in chars.enumerated() {
        out = out + Text(String(ch)).foregroundColor(kRainbowPalette[rainbowSlot(i, step: step)])
    }
    return out
}

/// The animated form of `rainbowText`, isolated in its own tiny view so the re-render from
/// RainbowClock stays scoped to just this text run instead of the whole dropdown/pill.
/// `trailing` lets a dropdown row concatenate the (flat-colored) title onto the same `Text` —
/// keeping verb+title as one continuous run so line-wrap/truncation still behaves as a unit.
struct RainbowVerb: View {
    let text: String
    var trailing: Text? = nil
    @ObservedObject private var clock = RainbowClock.shared

    var body: some View {
        let step = Int(clock.t / RainbowClock.swapInterval)
        let verb = rainbowText(text, step: step)
            .font(.custom(kSerifFontName, size: 13)).tracking(0.5)
        if let trailing { return verb + trailing }
        return verb
    }
}

/// A background session in the stack (one per other active Warp tab).
struct SessionCard: Identifiable {
    let id: String          // Warp tab UUID
    var project: String = ""
    var title: String = ""  // ai-title, shown on hover
    var status: String = "" // mode string, drives the dot/bg color
    var verb: String = ""   // live action verb while working (e.g. "Editing"), from detail
    var focus: String = ""  // warp://session/<uuid>
    var isSelected: Bool = false  // highlighted row: the Warp-active tab, else the front session
    var elapsed: String = "" // turn timer text; live while active, frozen when done
    var context: Double = 0  // 0…1 context-window fill, for the per-row ring
    var preview: String = "" // latest action / message, shown grey after the title
    var flashPri: Int = 0    // how much `preview` should flash: 2 prose / 1 notable action / 0 routine
    var flashKey: String = "" // transcript-stable identity for `preview`; text itself is display-only
    var firstPrompt: String = "" // session's opening user message (row-title experiment)
    var lastUserMsg: String = "" // session's most recent user message, for the dropdown row title
    var qHeader: String = ""  // pending AskUserQuestion: short topic label (attention rows)
    var qText: String = ""    // pending AskUserQuestion: full question text (attention rows)
    var subagentCount: Int = 0  // live subagents (Task tool), shown as "{n} agents" left of the timer
    var ultra = false  // "ultrathink" turn → paint the verb in a rainbow gradient
    // Git context (local probe by cwd). Dropdown groups sessions by repo + branch so each
    // worktree is its own labelled section; the header carries the working-tree churn.
    var repo: String = ""     // repo name (shared across a repo's worktrees), e.g. "claude-notification"
    var branch: String = ""   // current branch, e.g. "main" / "test-worktree"
    var files: Int = 0        // uncommitted files changed (vs HEAD)
    var added: Int = 0        // + lines
    var removed: Int = 0      // − lines
    // Group key: repo/branch when known, else the bare project dir (pre-git-probe / non-repo).
    var groupKey: String {
        if !branch.isEmpty { return (repo.isEmpty ? project : repo) + "/" + branch }
        if !repo.isEmpty { return repo }
        return project.isEmpty ? "Claude Code" : project
    }
}

struct EventPayload: Decodable {
    let mode: String?
    let title: String?
    let detail: String?
    let preview: String?
    let project: String?
    let context: Double?
    let focus: String?
    let topRadius: Double?
    let bottomRadius: Double?
    let cards: [CardPayload]?
}

struct CardPayload: Decodable {
    let id: String?
    let project: String?
    let title: String?
    let status: String?
    let focus: String?
}

/// One session's latest event, written by the hook to sessions/<tabUUID>.json.
struct SessionFile: Decodable {
    let mode: String?
    let detail: String?
    let preview: String?
    let project: String?
    let context: Double?
    let focus: String?
    let id: String?
    let aiTitle: String?
    let cwd: String?
    let ts: Double?
    let kind: String?   // hook event type: prompt | tool | post | attention | stop
    let transcript: String?
    let firstPrompt: String?   // session's opening user message, for the dropdown row title
    let lastPrompt: String?    // session's most recent user message, for the hover peek marquee
    let qHeader: String?       // pending AskUserQuestion: short topic label (e.g. "Card tilt")
    let qText: String?         // pending AskUserQuestion: the full question text
    let ultra: Bool?           // turn invoked with "ultrathink" → rainbow verb
    let flashPri: Int?         // how much `preview` should flash: 2 prose / 1 notable action / 0 routine
    let flashKey: String?      // stable identity for the working preview flash
    let finishKey: String?     // stable identity for the terminal done flash
}

/// Self-stepped clock for the hover-peek marquee. SwiftUI's `repeatForever` animations
/// don't reliably run inside this non-activating background panel, so we step it
/// ourselves via a real run-loop timer. `phase` is the
/// scroll offset in points; the view wraps it modulo the text's period.
final class MarqueeClock: ObservableObject {
    @Published var phase: CGFloat = 0
    private var timer: Timer?
    static let shared = MarqueeClock()
    static let speed: CGFloat = 0.55   // points per tick (~33 pt/s at 60fps)

    func start() {
        guard timer == nil else { return }
        phase = 0
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += MarqueeClock.speed
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        phase = 0
    }
}

/// A news-ticker label: if the text overflows `width` it scrolls left continuously (two
/// copies separated by a gap, wrapped on `clock.phase`); otherwise it sits static. Clipped to
/// `width` so it never spills past the peek strip.
struct Marquee: View {
    let text: String
    let color: Color
    let width: CGFloat
    @ObservedObject var clock: MarqueeClock
    // False for content that's freshly shown (its true beginning, not a continuous loop the
    // viewer only ever catches mid-scroll) — e.g. `FinishFlashView`'s reply. The peek's own
    // continuously-cycling feed wants the default `true`: both edges perpetually have text
    // scrolling in/out, so fading the leading edge there hides the seam. But for content that
    // STARTS static (see `FinishFlashView`'s pre-scroll pause) before any scrolling begins, that
    // same leading fade dims the message's own opening words toward invisible from frame one —
    // there's nothing "scrolling in" yet to justify it.
    var fadeLeadingEdge: Bool = true
    private static let font = NSFont(name: kSansFontName, size: 13) ?? .systemFont(ofSize: 13)
    private static let gap: CGFloat = 48

    var body: some View {
        // Collapse newlines/tabs → spaces so a multi-paragraph preview scrolls as ONE line
        // instead of rendering a tall block that spills above and below the pill.
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
                          .replacingOccurrences(of: "\t", with: " ")
        let textW = textWidth(oneLine, Marquee.font)
        let label = Text(oneLine).font(.custom(kSansFontName, size: 13)).foregroundColor(color).lineLimit(1).fixedSize()
        let overflow = textW > width
        return Group {
            if !overflow {
                label.frame(width: width, alignment: .center)
            } else {
                let period = textW + Marquee.gap
                let off = -clock.phase.truncatingRemainder(dividingBy: period)
                ZStack(alignment: .leading) {
                    label.offset(x: off)
                    label.offset(x: off + period)   // trailing copy fills the gap as the first exits
                }
                .frame(width: width, alignment: .leading)
                .clipped()
            }
        }
        // Soft fade at both edges so the text dissolves in/out rather than hard-clipping —
        // only while it scrolls (static text sits clear of the edges, so no fade needed).
        .mask(overflow ? AnyView(Marquee.edgeFade(width, leading: fadeLeadingEdge)) : AnyView(Rectangle()))
    }

    private static func edgeFade(_ width: CGFloat, leading: Bool = true) -> some View {
        let f = min(0.28, 24 / max(width, 1))   // ~24pt fade on each side
        return LinearGradient(stops: [
            .init(color: leading ? .clear : .black, location: 0),
            .init(color: .black, location: leading ? f : 0),
            .init(color: .black, location: 1 - f),
            .init(color: .clear, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }
}

/// Paces the peek's message feed so every line is readable. Previews arrive at the hook's
/// PreToolUse cadence — wildly uneven (a fast Read flashes a commentary line for ms; a slow Bash
/// holds one for seconds). `submit()` enqueues each distinct line; a self-stepped pacer advances
/// the displayed line only after a minimum dwell, so nothing flickers past unread. The dwell
/// shrinks as the backlog grows (the queue self-drains, so it never lags far behind reality).
/// Two more self-stepped ramps drive the look: `slide` (0→1, the vertical push on each swap) and
/// `tint` (0→1, a freshly-shown line enters white and settles to the peek grey over ~3s). All
/// timer-driven because SwiftUI's animation clock is frozen in this non-activating panel.
final class PeekFeed: ObservableObject {
    @Published var cur = ""
    @Published var prev = ""
    @Published var slide: CGFloat = 1     // 1 = settled, 0 = mid-swap
    @Published var tint: CGFloat = 1      // 0 = white (just shown), 1 = settled to peek grey

    private var queue: [String] = []
    private var shownAt: CFTimeInterval = 0
    private var pacer: Timer?
    private var slideTimer: Timer?
    private var tintTimer: Timer?

    func submit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // First line on (re)appear: show at once, already settled (not "new"), no white flash.
        if cur.isEmpty && queue.isEmpty {
            cur = t; shownAt = CACurrentMediaTime(); slide = 1; tint = 1
            return
        }
        if t == cur || t == queue.last { return }    // dedupe the carry / repeat emits
        queue.append(t)
        if queue.count > 5 { queue.removeFirst(queue.count - 5) }   // bound lag: keep the latest few
        ensurePacer()
    }

    func stop() {
        pacer?.invalidate(); pacer = nil
        slideTimer?.invalidate(); slideTimer = nil
        tintTimer?.invalidate(); tintTimer = nil
    }

    private func ensurePacer() {
        guard pacer == nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        pacer = t
    }

    private func tick() {
        if slide < 1 { return }                       // let the current swap finish first
        guard !queue.isEmpty else { pacer?.invalidate(); pacer = nil; return }
        if CACurrentMediaTime() - shownAt >= dwell(queue.count) { advance() }
    }

    // More backlog → shorter dwell, so a burst of fast tools drains instead of piling up.
    private func dwell(_ n: Int) -> CFTimeInterval {
        switch n {
        case 0, 1: return 2.2
        case 2:    return 1.6
        case 3:    return 1.1
        default:   return 0.7
        }
    }

    private func advance() {
        prev = cur
        cur = queue.removeFirst()
        shownAt = CACurrentMediaTime()
        startSlide()
        startTint()
    }

    private func startSlide() {
        slideTimer?.invalidate(); slide = 0
        let start = CACurrentMediaTime(); let dur: CFTimeInterval = 0.34
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let e = min(1, (CACurrentMediaTime() - start) / dur)
            self.slide = 1 - pow(1 - CGFloat(e), 2.2)            // ease-out
            if e >= 1 { self.slideTimer?.invalidate(); self.slideTimer = nil }
        }
        RunLoop.main.add(t, forMode: .common); slideTimer = t
    }

    private func startTint() {
        tintTimer?.invalidate(); tint = 0
        let start = CACurrentMediaTime(); let dur: CFTimeInterval = 3.0
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let e = min(1, (CACurrentMediaTime() - start) / dur)
            self.tint = CGFloat(e * e * (3 - 2 * e))            // smoothstep: holds white, eases to grey
            if e >= 1 { self.tintTimer?.invalidate(); self.tintTimer = nil }
        }
        RunLoop.main.add(t, forMode: .common); tintTimer = t
    }
}

/// The peek's message line, advanced like a paced rolling queue (see `PeekFeed`): the old line
/// rises + fades out the top while the new line rises in from the bottom + fades in. A newly-shown
/// line enters white and settles to the peek grey over ~3s. Each line is still a `Marquee` (a long
/// message scrolls horizontally once settled). Vertical motion is clipped to one line.
struct QueuePeek: View {
    let text: String
    let baseWhite: Double          // settled peek grey (e.g. 0.66); a new line starts at white 1.0
    let width: CGFloat
    @ObservedObject var clock: MarqueeClock
    @StateObject private var feed = PeekFeed()
    private let lineH: CGFloat = 17   // > the 13pt font's natural line height so descenders (g, y, p) don't clip

    var body: some View {
        ZStack {
            if !feed.prev.isEmpty && feed.slide < 1 {
                Marquee(text: feed.prev, color: Color(white: baseWhite), width: width, clock: clock)
                    .offset(y: -lineH * feed.slide)
                    .opacity(Double(max(0, 1 - feed.slide * 1.5)))
            }
            Marquee(text: feed.cur, color: curColor, width: width, clock: clock)
                .offset(y: lineH * (1 - feed.slide))
                .opacity(Double(min(1, feed.slide * 1.5)))
        }
        .frame(width: width, height: lineH)
        .clipped()
        .onAppear { feed.submit(text) }
        .onDisappear { feed.stop() }
        .onChange(of: text) { feed.submit($0) }
    }

    // White at tint=0, settling to the peek grey at tint=1.
    private var curColor: Color { Color(white: 1.0 - (1.0 - baseWhite) * feed.tint) }
}

/// Drives the front pill's "just finished" moment (see `showingFinishFlash`): the agent's own
/// reply marquees in white, eases to grey over ~3s (same curve/duration as `PeekFeed.tint`), holds,
/// then hands off — sliding up and out — to the tab name rising in from below (same curve as
/// `PeekFeed.slide`). This stays in SwiftUI because its text layout exactly matches the rest of
/// the pill; a layer-backed AppKit rewrite looked smoother in theory but produced baseline and
/// clipping mismatches in the notch.
final class FinishFlash: ObservableObject {
    @Published var message: String = ""
    @Published var tint: CGFloat = 0     // 0 = white (just shown) → 1 = settled grey, over ~3s
    @Published var slide: CGFloat = 0    // 0 = showing the message → 1 = fully handed off to the tab name

    private var tintTimer: Timer?
    private var slideTimer: Timer?
    private var holdTimer: Timer?

    /// (Re)starts the sequence for a freshly-finished session. `onHandoff` fires once the slide
    /// to the tab name completes — the caller uses it to stop rendering this view entirely
    /// (see `IslandState.justFinishedID`) rather than leaving a redundant fixed-width box around
    /// forever once it's just displaying the same tab name the plain path would anyway.
    /// The tab name itself is NOT captured here — `FinishFlashView` reads it live (`state.title`
    /// can update mid-hold, e.g. once the AI title finishes generating a moment after the turn
    /// ends; capturing a stale copy at start() would make it visibly change size right at the
    /// handoff, reading as an extra jump on top of the slide itself).
    func start(message: String, onHandoff: @escaping () -> Void) {
        stop()
        self.message = message
        slide = 0
        startTint()
        let hold = Timer(timeInterval: kFlashHoldS, repeats: false) { [weak self] _ in
            self?.startSlide(onHandoff: onHandoff)
        }
        RunLoop.main.add(hold, forMode: .common)
        holdTimer = hold
    }

    func stop() {
        tintTimer?.invalidate(); tintTimer = nil
        slideTimer?.invalidate(); slideTimer = nil
        holdTimer?.invalidate(); holdTimer = nil
    }

    private func startTint() {
        tintTimer?.invalidate(); tint = 0
        let start = CACurrentMediaTime(); let dur: CFTimeInterval = 3.0
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let e = min(1, (CACurrentMediaTime() - start) / dur)
            self.tint = CGFloat(e * e * (3 - 2 * e))    // smoothstep: holds white, eases to grey
            if e >= 1 { self.tintTimer?.invalidate(); self.tintTimer = nil }
        }
        RunLoop.main.add(t, forMode: .common); tintTimer = t
    }

    private func startSlide(onHandoff: @escaping () -> Void) {
        slideTimer?.invalidate()
        let start = CACurrentMediaTime(); let dur: CFTimeInterval = 0.34
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let e = min(1, (CACurrentMediaTime() - start) / dur)
            self.slide = 1 - pow(1 - CGFloat(e), 2.2)    // ease-out
            if e >= 1 {
                self.slideTimer?.invalidate(); self.slideTimer = nil
                onHandoff()
            }
        }
        RunLoop.main.add(t, forMode: .common); slideTimer = t
    }
}

/// Renders `FinishFlash`'s sequence: the agent's reply, marqueed within a fixed box if it
/// overflows (own private `MarqueeClock` — independent of the shared one, which only runs on
/// pill hover), tinted white → grey; then a `QueuePeek`-style vertical handoff to the tab name.
struct FinishFlashView: View {
    @ObservedObject var flash: FinishFlash
    let width: CGFloat
    // Passed fresh on every render (NOT captured into `FinishFlash` at .start() time) — the tab
    // name/title can legitimately change mid-hold (e.g. AI title generation landing a moment
    // after the turn ends), and a stale copy would visibly resize right at the handoff instead
    // of matching whatever the plain tab-name view is about to show.
    let tabName: String
    @StateObject private var marqueeClock = MarqueeClock()
    @State private var marqueeStartTimer: Timer?
    private let lineH: CGFloat = 17

    var body: some View {
        // `.trailing`: the ZStack's default `.center` would center `tabName` (a bare,
        // `.fixedSize()` Text with no frame of its own) inside the fixed `width` box — fine
        // while it's still narrower than a full flash message, but it doesn't match how the SAME
        // text sits once handed off to the plain (natural-width, trailing-aligned) tab name view,
        // producing a few-pixel sideways pop right at the handoff. `.trailing` here makes it flush
        // against the same right edge both before and after — Marquee's own internal `.frame`
        // already fills `width` exactly, so this alignment change doesn't affect it.
        ZStack(alignment: .trailing) {
            Marquee(text: flash.message, color: msgColor, width: width, clock: marqueeClock, fadeLeadingEdge: false)
                .offset(y: -lineH * flash.slide)
                .opacity(Double(max(0, 1 - flash.slide * 1.5)))
            Text(tabName)
                .font(.custom(kSansFontName, size: 13))
                .foregroundColor(Color(white: 0.62))
                .lineLimit(1)
                .fixedSize()
                .offset(y: lineH * (1 - flash.slide))
                .opacity(Double(min(1, flash.slide * 1.5)))
        }
        .frame(width: width, height: lineH)
        .clipped()
        .onAppear {
            // A beat of stillness before it starts scrolling — reads as "here's the reply",
            // THEN motion, rather than immediately looking busy the instant it appears.
            let t = Timer(timeInterval: 1.0, repeats: false) { _ in marqueeClock.start() }
            RunLoop.main.add(t, forMode: .common)
            marqueeStartTimer = t
        }
        .onDisappear {
            marqueeStartTimer?.invalidate(); marqueeStartTimer = nil
            marqueeClock.stop()
        }
    }

    private var msgColor: Color { Color(white: 1.0 - (1.0 - 0.62) * Double(flash.tint)) }
}

/// Small fill bar for the notch usage peek: a dim track with a colored fill proportional to
/// `fraction` (0...1), in the same color the percent label uses.
struct UsageBar: View {
    let fraction: Double
    let color: Color
    private static let w: CGFloat = 56
    private static let h: CGFloat = 5

    var body: some View {
        let f = min(max(fraction, 0), 1)
        let fillW = max(Self.h, Self.w * CGFloat(f))
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Self.h / 2)
                .fill(Color.white.opacity(0.16))
            RoundedRectangle(cornerRadius: Self.h / 2)
                .fill(LinearGradient(colors: [color.opacity(0.45), color],
                                      startPoint: .leading, endPoint: .trailing))
                .frame(width: fillW)
            // Soft glow at the fill's leading tip, like a charging indicator.
            if f > 0.02 && f < 1 {
                Circle()
                    .fill(color)
                    .frame(width: Self.h, height: Self.h)
                    .blur(radius: 1.2)
                    .offset(x: fillW - Self.h / 2)
            }
        }
        .frame(width: Self.w, height: Self.h)
        .shadow(color: color.opacity(0.25), radius: 1.2, x: 0, y: 0)
    }
}

// MARK: - Geometry

func notchScreen() -> NSScreen {
    if let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) { return s }
    return NSScreen.main ?? NSScreen.screens[0]
}

/// Physical notch width in points, or a sensible fallback on notch-less Macs.
func notchWidth(_ screen: NSScreen) -> CGFloat {
    if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
        let w = screen.frame.width - left.width - right.width
        if w > 0 { return w }
    }
    return 180
}

// MARK: - Darwin notification bridge

private func darwinCallback(_ center: CFNotificationCenter?,
                            _ observer: UnsafeMutableRawPointer?,
                            _ name: CFNotificationName?,
                            _ object: UnsafeRawPointer?,
                            _ userInfo: CFDictionary?) {
    DispatchQueue.main.async { AppController.shared?.reload() }
}

// MARK: - SwiftUI

/// Dynamic-Island silhouette. The top edge spans the full width ("ears"); the
/// body walls are inset by the shoulder radius. Each top shoulder is a concave,
/// re-entrant fillet — a quad whose control point sits at the intersection of the
/// horizontal (top edge) and vertical (wall) tangents, giving a tangent-continuous
/// inward-and-down sweep like the shoulders around an iPhone notch. The bottom
/// corners are ordinary convex rounds.
struct IslandShape: Shape {
    var topRadius: CGFloat = 16     // shoulder (re-entrant) fillet radius
    var bottomRadius: CGFloat = 16  // bottom convex corner radius

    // Let the corner radii interpolate frame-by-frame so the bottom corners round out
    // smoothly as the pill expands (otherwise the radius would snap to its new value).
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = max(0, min(topRadius, w / 2, h))
        let br = max(0, min(bottomRadius, (w - 2 * r) / 2, h - r))
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))                                                  // top-left ear
        p.addLine(to: CGPoint(x: w, y: 0))                                               // top edge (full width)
        p.addQuadCurve(to: CGPoint(x: w - r, y: r), control: CGPoint(x: w - r, y: 0))    // right shoulder (concave)
        p.addLine(to: CGPoint(x: w - r, y: h - br))                                      // right wall (inset)
        p.addQuadCurve(to: CGPoint(x: w - r - br, y: h), control: CGPoint(x: w - r, y: h)) // bottom-right convex
        p.addLine(to: CGPoint(x: r + br, y: h))                                          // bottom edge
        p.addQuadCurve(to: CGPoint(x: r, y: h - br), control: CGPoint(x: r, y: h))       // bottom-left convex
        p.addLine(to: CGPoint(x: r, y: r))                                               // left wall (inset)
        p.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: r, y: 0))            // left shoulder (concave)
        p.closeSubpath()
        return p
    }
}

// Real macOS "glass": an NSVisualEffectView with .behindWindow blending, which
// samples and blurs whatever is physically behind the panel (desktop + other app
// windows). SwiftUI's own Material only blurs within-window content, so in this
// transparent borderless panel it can't produce the frosted-glass look — this can.
// Forced dark so the vibrancy reads against the island's dark chrome.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .vibrantDark)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

struct IslandView: View {
    @ObservedObject var state = IslandState.shared
    @StateObject private var finishFlash = FinishFlash()
    // Same class, second instance: periodic "Claude just said something" flash while working
    // (see `freshCommentaryID`) — independent hold/slide timers from the done-flash above.
    @StateObject private var commentaryFlash = FinishFlash()

    private static let coral = Color(red: 232 / 255, green: 112 / 255, blue: 78 / 255) // #E8704E

    private static let amber = Color(red: 1.0, green: 0.745, blue: 0.0) // #FFBE00 (reserved: thinking)

    private static let ultraRed = Color(red: 250 / 255, green: 65 / 255, blue: 47 / 255) // #FA412F (ultrathink — matches the rainbow's first letter)

    private static let orange = Color(red: 1.0, green: 0.584, blue: 0.0) // #FF9500 (attention: input needed)

    private static let red = Color(red: 0.898, green: 0.282, blue: 0.302) // #E5484D

    private static let compact = Color(red: 142 / 255, green: 165 / 255, blue: 255 / 255) // #8EA5FF

    private static let idleGrey = Color(white: 0.62) // resting / "Idle"

    private var accent: Color {
        switch state.mode {
        case .thinking:  return IslandView.amber
        case .working:   return IslandView.coral
        case .attention: return IslandView.coral
        case .error:     return IslandView.red
        case .done:      return IslandView.green
        case .compacting, .compacted: return IslandView.compact
        case .idle:      return IslandView.idleGrey
        }
    }

    // The island matches the notch's height and hangs from the very top edge,
    // wider than the notch, with content wrapping around the camera.
    private var islandHeight: CGFloat { max(state.notchHeight, 30) }

    // Clearance added to the notch gap so text never touches the camera.
    private let notchClearance: CGFloat = 80

    // Real fonts, used to measure label widths deterministically (see textWidth).
    private static let serifFont = NSFont(name: kSerifFontName, size: 13) ?? .systemFont(ofSize: 13)
    private static let sansFont  = NSFont(name: kSansFontName, size: 13) ?? .systemFont(ofSize: 13)

    // Front-pill width, computed deterministically from the parts the pill lays out from
    // (the pill is rendered at EXACTLY this width). Back cards anchor to it, and the
    // controller's hover hit-test reads the same value — so view, cards, and hit-testing
    // never drift. (GeometryReader returns 0 in this panel, so we can't measure instead.)
    private var pillWidth: CGFloat {
        leftW + state.notchWidth + notchClearance + rightW + 36
    }

    // How far the centered island is shifted to keep the notch gap on the camera.
    private var islandOffset: CGFloat { (rightW - leftW) / 2 }

    var body: some View {
        ZStack(alignment: .top) {
            if state.uiMode == "dropdown" {
                // Closed: a "{n} ⌄" back pill peeks RIGHT of the front pill. Open: the
                // island grows into an expanded sheet (wider + taller) holding the list.
                if state.dropdownOpen { expandedSheet }
                // The resting idle pill ("{n} idle sessions") is its own hover-to-open target,
                // so it skips the "{n} ⌄" back-pill affordance (which would double the count).
                if state.roster.count >= 1 && state.mode != .idle { agentsBackPill }
                island
                if state.dropdownOpen { dropdownList }
                if state.roster.count >= 1 && state.mode != .idle { agentsLabel }
            } else {
                // Back cards are SIBLINGS of the island (not its background) so each
                // card's full frame is hit-testable.
                ForEach(Array(state.cards.enumerated()), id: \.element.id) { idx, card in
                    backCard(idx: idx, card: card)
                }
                island
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.mode)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.hoveredCard)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: state.dropdownOpen)
        .animation(.spring(response: 0.5, dampingFraction: 0.64), value: state.frontHovered)
        .animation(.easeOut(duration: 0.12), value: state.hoveredRow)
        .animation(.easeOut(duration: 0.12), value: state.hoveredGroup)
        .animation(.easeOut(duration: 0.12), value: state.selectedGroup)
        // Grow/shrink the bar smoothly when its width changes (verb/preview text updates)
        // instead of snapping to the new size.
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: pillWidth)
        // Report the live geometry to the controller, which hit-tests the mouse against
        // it (SwiftUI's onHover/GeometryReader don't work in this non-key panel).
        .onChange(of: pillWidth) { AppController.shared?.updateGeom(pillWidth: $0, islandOffset: islandOffset) }
        .onChange(of: islandOffset) { AppController.shared?.updateGeom(pillWidth: pillWidth, islandOffset: $0) }
        .onAppear { AppController.shared?.updateGeom(pillWidth: pillWidth, islandOffset: islandOffset) }
    }

    // A row is "inactive" when its dot is grey — idle tabs and stale (long-finished)
    // sessions, plus any unrecognized status. Mirror this in dotColor's grey cases.
    private func isInactiveStatus(_ status: String) -> Bool {
        !["thinking", "working", "attention", "error", "done", "compacting", "compacted", "declined", "interrupted", "struggling"].contains(status)
    }

    // Status-dot color for a background session.
    private func dotColor(_ status: String) -> Color {
        switch status {
        case "thinking":          return IslandView.amber
        case "working":           return IslandView.coral
        case "attention", "error": return IslandView.red
        case "done":              return IslandView.green
        case "compacting", "compacted": return IslandView.compact
        case "struggling":        return IslandView.amber  // stuck in a run of tool errors
        case "declined", "interrupted": return Color(white: 0.6)  // Esc'd — resolved/halted
        case "stale":             return Color.white.opacity(0.5)   // done, unattended >15 min — same as idle
        default:                  return Color.white.opacity(0.5)  // idle
        }
    }

    // Other sessions: dark-glass cards tinted by their status color, anchored to the
    // pill's leading edge and nudged left so each peeks a thin sliver. The controller's
    // mouse monitor sets state.hoveredCard; the hovered card slides left to reveal its
    // title (constant width — it only translates, never resizes). Clicking focuses it.
    @ViewBuilder
    private func backCard(idx: Int, card: SessionCard) -> some View {
        let hovered = state.hoveredCard == card.id
        let label = cardLabel(card)
        let w = cardWidth(card, idx: idx)
        let pillLeft = islandOffset - pillWidth / 2
        // Collapsed: left edge a sliver-stack left of the pill (right part tucked under
        // it). Hovered: slide left so the right edge tucks `kCardTuck` under the pill and
        // the title is revealed to the left. Only `off` changes — w is constant.
        let off: CGFloat = hovered
            ? pillLeft + kCardTuck - w / 2
            : pillLeft - CGFloat(idx + 1) * kCardPeek + w / 2

        let shape = IslandShape(topRadius: state.topRadius, bottomRadius: state.bottomRadius)
        let tint = dotColor(card.status)
        ZStack {
            // Frosted glass, solid black for the top half fading to translucent toward
            // the bottom, with a uniform status tint over the whole card.
            shape.fill(.ultraThinMaterial)                       // frosted glass
            shape.fill(LinearGradient(                           // solid-black top → translucent bottom
                stops: [
                    .init(color: Color.black, location: 0.0),
                    .init(color: Color.black, location: 0.5),
                    .init(color: Color.black.opacity(0.5), location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom))
            shape.fill(tint.opacity(0.26))                       // status tint
        }
        .environment(\.colorScheme, .dark)                       // dark frost, not washed-out
        .frame(width: w, height: islandHeight)
        .overlay(alignment: .leading) {
            Text(label)
                .font(.custom(kSansFontName, size: 13))
                .foregroundColor(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, kCardTextPad)
                .opacity(hovered ? 1 : 0)
        }
        .opacity(hovered ? 1 : 0.97 - Double(idx) * 0.06)
        .offset(x: off)
        // Collapsed cards stack under the pill (negative z, nearer = higher). A hovered
        // card rises above the other cards but stays BELOW the pill, so its tuck hides
        // under the pill while its revealed title (left of the pill) shows.
        .zIndex(hovered ? -0.5 : Double(-(idx + 1)))
        .contentShape(Rectangle())
        .onTapGesture { AppController.shared?.focusCardTab(card.id) }
    }

    // MARK: - Dropdown mode ("{n} ⌄" back pill + menu)

    // A single dark-glass pill behind the front pill, shifted RIGHT so it peeks a
    // sliver past the pill's right edge, showing the agent count + a chevron. Clicking
    // it toggles the dropdown menu. (Mirror of the left peek cards, but one, on the right.)
    private var agentsBackPill: some View {
        let open = state.dropdownOpen
        let shape = IslandShape(topRadius: state.topRadius, bottomRadius: state.bottomRadius)
        return ZStack {
            // Closed: a soft, mostly-transparent glass card peeks right. Open: NO
            // background — the expanded sheet is the backdrop, and a translucent card
            // here would wash out the (solid-black) notch ticker it overlaps.
            if !open {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.28))
            }
        }
        .environment(\.colorScheme, .dark)
        .frame(width: pillWidth, height: islandHeight)
        // Same width as the pill, shifted right so it peeks `kAgentsPeek` on the right.
        .offset(x: islandOffset + kAgentsPeek)
        .zIndex(-1)
        .contentShape(Rectangle())
        .onTapGesture { AppController.shared?.openDropdown() }
    }

    // The "{n} ⌄" label, rendered as a direct ZStack child positioned at the peek
    // centre (verified against a marker — placing it inside the back card's overlay
    // composed the offset wrong). Purely an indicator; the whole pill is the button.
    private var agentsLabel: some View {
        HStack(spacing: 4) {
            Text("\(state.roster.count)")
                .font(.custom(kSansFontName, size: 13))
                .foregroundColor(.white)
            Image(systemName: state.dropdownOpen ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color(white: 0.7))
        }
        .fixedSize()
        // Box is islandHeight tall so the label centres VERTICALLY with the verb (the
        // ZStack is .top-aligned, which was pinning it to the top). Nudged left of the
        // geometric peek centre so it sits in the solid peek, clear of the right shoulder.
        // The box is the click target too — tapping the indicator opens/closes the menu.
        .frame(width: kAgentsPeek + 14, height: islandHeight)
        .contentShape(Rectangle())
        .offset(x: islandOffset + pillWidth / 2 + kAgentsPeek / 2 - 11)
        .zIndex(1)
        .onTapGesture { AppController.shared?.openDropdown() }
    }

    // Sheet width / total height when expanded (shared with the controller hit-test).
    // The sheet's LEFT edge stays flush with the pill (aligned with the verb); it only
    // grows to the RIGHT (by kSheetSide, to encompass the "{n}" back card) and downward.
    // The sheet only reserves the back-pill slot when the back pill is actually shown. In the
    // idle "{n} idle sessions" state there's no back pill, so the sheet stays flush with the pill
    // (no rightward bulge into the empty chevron slot).
    private var sheetSide: CGFloat { state.mode == .idle ? 0 : kSheetSide }
    private var sheetWidth: CGFloat { pillWidth + sheetSide }
    private var sheetOffset: CGFloat { islandOffset + sheetSide / 2 }  // keeps left edge at pillLeft
    private var sheetListHeight: CGFloat { dropdownContentHeight(state.dropdownItems) + kDropdownVPad + kDropdownBottomPad }

    // The expanded "Dynamic Island" sheet: the SAME silhouette as the pill, grown to the
    // right + downward, hanging from the notch. The notch row stays solid black (it
    // overlaps the physical notch / ticker), and the body below is real macOS glass —
    // a behind-window blur of the desktop, with a light dark tint for legibility — so it
    // no longer just composites the raw desktop text through it. Pill content sits on the
    // top row; the session list fills the body below.
    private var expandedSheet: some View {
        let shape = IslandShape(topRadius: state.topRadius, bottomRadius: 22)
        let total = islandHeight + sheetListHeight
        let notchFrac = min(0.92, islandHeight / total)   // the whole notch row stays solid black
        return ZStack {
            // Frosted glass backdrop: blurs whatever is behind the panel. `.hudWindow` is
            // the only DARK material — the lighter ones (.popover/.sidebar) add a grey-white
            // haze that reads as "milky frost"; this keeps a clean dark vibrant blur.
            VisualEffectBlur(material: .hudWindow)
                .clipShape(shape)
            // Solid black across the notch row, then a light dark tint over the glass for
            // the body — enough contrast for white text without hiding the blur.
            shape.fill(LinearGradient(
                stops: [
                    .init(color: Color.black, location: 0.0),
                    // Hold solid black a bit past the notch row, then fade slowly all the
                    // way to the bottom so the glass eases in (no hard band).
                    .init(color: Color.black, location: min(0.92, notchFrac + 0.16)),
                    .init(color: Color.black.opacity(0.1), location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom))
        }
        .frame(width: sheetWidth, height: total)
        .offset(x: sheetOffset)
        .zIndex(-2)
    }

    // The session rows (grouped by project, with headers when >1 project), stacked in the
    // sheet body just below the pill row.
    private var dropdownList: some View {
        VStack(spacing: 0) {
            ForEach(state.dropdownItems) { item in
                if item.isHeader { dropdownHeader(item) }
                else if let c = item.card { dropdownRow(c, titleInHeader: item.titleInHeader) }
            }
        }
        .frame(width: sheetWidth - 2 * kRowInset)
        .offset(x: sheetOffset, y: islandHeight + kDropdownVPad)
        .zIndex(-1)
    }

    // A repo/branch section header: "repo" (dim) + "/branch" (white) + "· N files +X −Y" churn,
    // above its group of rows. Non-git groups (e.g. the attention view's tab-name header) render
    // their plain label.
    private func dropdownHeader(_ item: DropdownItem) -> some View {
        HStack(spacing: 0) {
            headerLabel(item, active: headerActive(item))
                .font(.custom(kSansFontName, size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            // Context fill now lives per-row (right edge), tiered by urgency — the header
            // stays a pure repo/branch group label.
        }
        .shadow(color: Color.black.opacity(0.55), radius: 1.4)
        .padding(.horizontal, 16)
        .padding(.bottom, 2)   // a little breathing room between the label and its first row
        .frame(width: sheetWidth - 2 * kRowInset, height: kHeaderHeight, alignment: .bottomLeading)
    }

    // Exactly ONE header is "active": the group under the cursor, or — when nothing's hovered —
    // the selected/active session's group. Only that header expands to show churn, in white.
    private func headerActive(_ item: DropdownItem) -> Bool {
        guard let g = state.hoveredGroup ?? state.selectedGroup else { return false }
        return item.id == "hdr:\(g)"
    }

    // Resting: a dim "dirname · branch". Active: only the branch/worktree whitens, and the churn
    // detail "· N files · +x −y" grows in (dirname stays grey throughout; +green/−red for churn).
    private func headerLabel(_ item: DropdownItem, active: Bool) -> Text {
        let grey = Color.white.opacity(0.5)
        guard !item.hRepo.isEmpty else { return Text(item.header ?? "").foregroundColor(grey) }
        let sep = Text("  ·  ").foregroundColor(grey)
        var t = Text(item.hRepo).foregroundColor(grey)   // dirname: always grey
        if !item.hBranch.isEmpty { t = t + sep + Text(item.hBranch).foregroundColor(active ? .white : grey) }
        if active, item.hFiles > 0 {
            t = t + sep + Text("\(item.hFiles) file\(item.hFiles == 1 ? "" : "s")").foregroundColor(grey)
            if item.hAdded > 0 || item.hRemoved > 0 {
                t = t + sep
                if item.hAdded > 0 { t = t + Text("+\(item.hAdded)").foregroundColor(IslandView.green) }
                if item.hRemoved > 0 {
                    if item.hAdded > 0 { t = t + Text(" ") }
                    t = t + Text("−\(item.hRemoved)").foregroundColor(IslandView.red)
                }
            }
        }
        return t
    }


    // Leading marker for a row: an attention session (permission / waiting on the user)
    // shows a red exclamation to flag it needs action; everything else is a status dot.
    // Both occupy the same 8-pt slot so the title stays aligned across rows.
    @ViewBuilder
    private func rowMarker(_ status: String, ultra: Bool = false) -> some View {
        if status == "attention" {
            Image(systemName: "exclamationmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(IslandView.red)
                .frame(width: 8)
                .modifier(WobbleMarker(active: true))
        } else if status == "compacted" {
            // Same static busy-glyph mark as "done", tinted the compact-blue instead of green.
            Text("✻")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(IslandView.compact)
                .frame(width: 11, height: 11)
        } else if status == "declined" {
            // A dismissed question/permission prompt — an "x" reads as "waved off".
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Color(white: 0.55))
                .frame(width: 8, height: 8)
                .frame(width: 11, height: 11)
        } else if status == "interrupted" {
            // A halted thinking/working turn — a stop square reads as "you stopped it".
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Color(white: 0.55))
                .frame(width: 8, height: 8)
                .frame(width: 11, height: 11)
        } else if status == "working" {
            BusyGlyph(color: IslandView.coral, interval: 0.20)
        } else if status == "compacting" {
            BusyGlyph(color: IslandView.compact, interval: 0.20)
        } else if status == "thinking" {
            if ultra {
                UltraGlyph(interval: 0.3)
            } else {
                BusyGlyph(color: IslandView.amber, interval: 0.3)
            }
        } else if status == "done" {
            // A finished turn reads as a static busy-glyph mark rather than a plain dot —
            // grey/idle stays a dot (see the fallback below).
            Text("✻")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(IslandView.green)
                .frame(width: 11, height: 11)   // matches BusyGlyph's max(size, 8) frame at size 11
        } else if status == "idle" {
            Circle().fill(Color.white.opacity(0.5)).frame(width: 7, height: 7).frame(width: 11, height: 11)
        } else {
            // Outer 11x11 box matches the glyph markers' footprint (BusyGlyph/done/UltraGlyph
            // all frame at max(size, 8) = 11 by default) so the gap to the title stays
            // consistent across every row, not just the dot's own 8pt size.
            Circle().fill(dotColor(status)).frame(width: 8, height: 8).frame(width: 11, height: 11)
        }
    }

    private func dropdownRow(_ card: SessionCard, titleInHeader: Bool = false) -> some View {
        let hl = state.hoveredRow == card.id
        // The selected session (Warp-active tab, else front) reads as "selected": a soft
        // persistent tint, lighter than the hover highlight. Hovering bumps to full alpha.
        let rowBG: Color = hl ? Color.white.opacity(0.13)
            : (card.isSelected ? Color.white.opacity(0.10) : Color.clear)
        // Inactive rows (grey dot — idle / stale) get a grey title too, so the whole row
        // recedes and the active sessions read first.
        let titleColor: Color = isInactiveStatus(card.status)
            ? Color.white.opacity(0.45)
            : (card.isSelected ? .white : Color.white.opacity(0.9))
        // Finished rows lead with the agent's response (the grey preview gets promoted to
        // the title); running rows lead with the opening prompt + keep the live preview.
        let isFinished = (card.status == "done" || card.status == "stale") && !card.preview.isEmpty
        // An Esc'd row — "declined" (a question) or "interrupted" (a halted turn) — reads like a
        // finished one: it leads with the agent's response so far, behind a muted prefix.
        let isEscTerminal = card.status == "declined" || card.status == "interrupted"
        // An API/connection error leads with its message (promoted to the title) behind a red prefix.
        let isError = card.status == "error"
        // Finished rows lead with the (frozen, green) turn timer — "[dot] [12s] [response]" —
        // instead of trailing it on the right, where it duplicated what the peek already shows.
        let timerOnLeft = (card.status == "done" || card.status == "stale") && !card.elapsed.isEmpty
        // Context-window fill, per session. Tiered by urgency: below 30% it's inert and stays
        // hidden; 30–50% is mild (amber) and only surfaces while the row is hovered, so quiet
        // rows read clean; ≥50% is high enough to pin on always, in red. Shown on every status
        // (see ringVisible), including the grey idle/stale rows — except "compacting": the
        // session's last-known context is still the PRE-compaction fill until the new state
        // lands, so the badge would otherwise sit there showing a number that's already stale
        // and about to drop.
        let showContext = card.status != "compacting" && card.context >= 0.30 && (card.context >= 0.50 || hl)
        // The title Group's halo (below) is tinted to match whichever colored prefix leads
        // that row, darkened rather than plain black — a black shadow directly behind a
        // saturated coral/amber/red/blue prefix reads as a muddy smudge; a darkened version
        // of the SAME hue reads as a natural recede instead.
        let prefixShadowColor: Color = {
            if card.status == "working" { return Color(red: 0.41, green: 0.20, blue: 0.14) }       // dark coral
            if card.status == "thinking" { return card.ultra ? .black : Color(red: 0.45, green: 0.335, blue: 0.0) } // dark amber
            if card.status == "compacting" || card.status == "compacted" { return Color(red: 0.25, green: 0.29, blue: 0.45) } // dark compact-blue
            if card.status == "attention" || isError { return Color(red: 0.40, green: 0.13, blue: 0.14) } // dark red
            if card.status == "struggling" { return Color(red: 0.45, green: 0.335, blue: 0.0) }     // dark amber
            return .black   // plain title / muted esc-terminal prefix — no strong hue to match
        }()
        return HStack(spacing: 10) {
            // When the roster spans ≥2 terminal apps, each row leads with its app's icon so you
            // can tell a Warp session from a Cursor one at a glance. Fixed-width slot (drawn empty
            // for apps we can't identify) keeps the status dots vertically aligned across rows.
            if state.showTermIcons {
                if let bid = terminalBundleId(focus: card.focus, id: card.id), let ic = appIcon(bundleId: bid) {
                    Image(nsImage: ic).resizable().interpolation(.high)
                        .frame(width: 14, height: 14)
                        .opacity(isInactiveStatus(card.status) ? 0.5 : 0.95)
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
            }
            rowMarker(card.status, ultra: card.ultra && card.status == "thinking")
            if timerOnLeft {
                Text(card.elapsed)
                    .font(.custom(kSansFontName, size: 12))
                    .monospacedDigit()
                    .foregroundColor(card.status == "done" ? IslandView.green : Color.white.opacity(0.55))
                    .lineLimit(1)
                    .fixedSize()
                    .shadow(color: Color.black.opacity(0.55), radius: 1.4)
            }
            Group {
                // Each row leads with a colored state word ahead of the tab's title, so the
                // list reads as "what is it doing" at a glance: the live verb while working
                // ("Editing"), "Thinking…", "Compacting…", "Compacted", or "Input Needed".
                // The verb tracks the session's `detail` and so updates live as it works.
                let titleText = card.title.isEmpty ? card.project : card.title
                // In-progress rows track the LATEST prompt (falls back to the opening one,
                // then the tab title) so a follow-up message updates the row immediately
                // instead of sticking to what kicked the session off.
                let livePrompt = card.lastUserMsg.isEmpty ? card.firstPrompt : card.lastUserMsg
                // "Compacted" rows lead with CC's own away-summary recap once transcriptSignals
                // sees it; until then they fall back to the same live-prompt text
                // as an in-progress row.
                let rowLabel = (isFinished || isEscTerminal || isError) ? (card.preview.isEmpty ? titleText : card.preview)
                    : (card.status == "compacted" && !card.preview.isEmpty) ? card.preview
                    : ((kRowTitleUsesPrompt && !livePrompt.isEmpty) ? livePrompt : titleText)
                let name = Text(rowLabel).foregroundColor(titleColor)
                // Claude Code's own "waiting on background agents" status isn't exposed to
                // hooks — a session parked on live subagents with no fresher tool verb would
                // otherwise show no prefix at all. Fall back to naming it explicitly so the row
                // always reads as "doing something" instead of going blank.
                let workingVerb = card.verb.isEmpty && card.subagentCount > 0 ? "Waiting for subagents…" : card.verb
                if card.status == "working", !workingVerb.isEmpty {
                    verbRun(workingVerb + " ", color: IslandView.coral) + name
                } else if card.status == "thinking" {
                    if card.ultra {
                        RainbowVerb(text: "Ultrathinking… ", trailing: name)
                    } else {
                        verbRun("Thinking… ", color: IslandView.amber) + name
                    }
                } else if card.status == "compacting" {
                    Text("Compacting… ").font(.custom(kSerifFontName, size: 13)).tracking(0.5).foregroundColor(IslandView.compact) + name
                } else if card.status == "compacted" {
                    Text("Compacted ").font(.custom(kSerifFontName, size: 13)).tracking(0.5).foregroundColor(IslandView.compact) + name
                } else if card.status == "attention" {
                    // Red prefix in the front-island red: the question's own title
                    // (qHeader, e.g. "Accent") when we have one, else the generic
                    // "Input Needed" (permission prompts carry no question). When a
                    // tab-name header already names the session (titleInHeader) the
                    // prefix stands alone; otherwise the tab title trails it. The full
                    // question text lives in the preview slot.
                    let prefix = card.qHeader.isEmpty ? "Input Needed" : card.qHeader
                    if titleInHeader {
                        Text(prefix).font(.custom(kSerifFontName, size: 13)).tracking(0.5).foregroundColor(IslandView.red)
                    } else {
                        Text(prefix + " ").font(.custom(kSerifFontName, size: 13)).tracking(0.5).foregroundColor(IslandView.red) + Text(titleText).foregroundColor(titleColor)
                    }
                } else if isEscTerminal {
                    // Muted prefix — "Declined" for a waved-off question, "Interrupted" for a
                    // halted turn; the agent's response so far (promoted into rowLabel) trails
                    // it in white.
                    let prefix = card.status == "declined" ? "Declined " : "Interrupted "
                    Text(prefix).font(.custom(kSerifFontName, size: 13)).tracking(0.5).foregroundColor(Color(white: 0.55)) + name
                } else if card.status == "struggling" {
                    // A run of consecutive tool failures — amber, same family as the live verbs.
                    Text("Struggling… ").font(.custom(kSerifFontName, size: 13)).tracking(0.5).foregroundColor(IslandView.amber) + name
                } else if isError {
                    // A live API / connection error: red prefix, the message (promoted into
                    // rowLabel) trails it. Clears itself once the agent recovers.
                    Text("API Error ").font(.custom(kSerifFontName, size: 13)).tracking(0.5).foregroundColor(IslandView.red) + name
                } else {
                    name
                }
            }
            .font(.custom(kSansFontName, size: 13))
            .lineLimit(1)
            .layoutPriority(1)            // title keeps its width; preview yields first
            // A soft dark halo behind the title/verb text — same trick as the volume HUD /
            // Now Playing overlay, where text floats over unpredictable vibrancy. Guarantees
            // contrast against a bright backdrop bleeding through the glass. Tinted to match
            // the row's own colored prefix (see prefixShadowColor) rather than plain black —
            // black behind a saturated coral/amber/red prefix read as a muddy smudge. NOT
            // applied to the context badge below — that's a solid opaque pill, not blended
            // text, so a shadow on it just looks like a ring around a shape instead of helping.
            .shadow(color: prefixShadowColor.opacity(0.65), radius: 1.4)
            // Latest action / message in grey, filling the gap and truncating with an
            // ellipsis. Its expanding frame also right-pins the ring + timer. For an
            // attention row the question takes this slot instead: its header in red, the
            // question text in white — so the row reads "<tab> · <topic> <question>".
            if card.status == "attention", !card.qText.isEmpty {
                Text(card.qText)
                    .font(.custom(kSansFontName, size: 12))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shadow(color: Color.black.opacity(0.55), radius: 1.4)
            } else if !card.preview.isEmpty && !isFinished && !isEscTerminal && !isError {
                Text(card.preview)
                    .font(.custom(kSansFontName, size: 12))
                    .foregroundColor(Color.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shadow(color: Color.black.opacity(0.55), radius: 1.4)
            } else {
                Spacer(minLength: 8)
            }
            // Live subagent count, just left of the ring/timer — the whole sub-deck boiled
            // down to "this session has N delegates running right now". A coral chip (the
            // brand "active" color) with a filled dot so it reads as a distinct live badge,
            // not just more grey text. Read from the transcript tree (hooks never see
            // subagents); 0 → nothing shown.
            if card.subagentCount > 0 {
                HStack(spacing: 4) {
                    Circle().fill(IslandView.coral).frame(width: 5, height: 5)
                    Text(card.subagentCount == 1 ? "1 subagent" : "\(card.subagentCount) subagents")
                        .font(.custom(kSansFontName, size: 11)).tracking(0.2)
                        .foregroundColor(IslandView.coral)
                        .lineLimit(1)
                }
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule(style: .continuous).fill(IslandView.coral.opacity(0.16)))
                .padding(.trailing, 3)
            }
            // Context ring + timer, floated at the row's trailing edge. Bundled into ONE
            // HStack (not separate siblings of the outer row) — as siblings, the outer row's
            // own 10pt inter-item spacing stacked with this cluster's internal gaps and read
            // as a blown-out void around the "·" separator.
            if showContext || (!card.elapsed.isEmpty && !timerOnLeft) {
                HStack(spacing: 4) {
                    if showContext {
                        // A solid badge, not blended text — its legibility never depends on
                        // whatever's behind the panel (bright IDE, dark terminal, anything),
                        // since it's an opaque filled shape rather than anti-aliased glyph
                        // strokes sitting on a translucent gradient. Ring + percent both go
                        // white on top of it.
                        HStack(spacing: 4) {
                            ContextRing(pct: card.context, colorOverride: contextForegroundColor(card.context))
                            Text("\(Int((card.context * 100).rounded()))% context")
                                .font(.custom(kSansFontName, size: 12))
                                .foregroundColor(contextForegroundColor(card.context))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(contextFillColor(card.context)))
                        // Hovering the badge once it's red (≥50%) surfaces a nudge to compact —
                        // the amber 30–50% band stays quiet since it's not yet actionable.
                        // Floats to the LEFT of the badge: overlay(.leading) starts the tooltip
                        // at the badge's own left edge, then a manual offset (by its own
                        // measured width + an 8pt gap) shifts it fully clear of the badge — the
                        // badge sits at the row's trailing end, so a left-floating tooltip has
                        // room to grow without pushing past the sheet's edge.
                        .overlay(alignment: .leading) {
                            if state.hoveredRing == card.id, card.context >= 0.5 {
                                let tooltipW = textWidth("Consider Compacting", kTooltipFont) + 14
                                compactTooltip
                                    .offset(x: -(tooltipW + 8))
                            }
                        }
                    }
                    if showContext, !card.elapsed.isEmpty, !timerOnLeft {
                        Text("·")
                            .font(.custom(kSansFontName, size: 12))
                            .foregroundColor(Color.white.opacity(0.55))
                            .shadow(color: Color.black.opacity(0.55), radius: 1.4)
                    }
                    if !card.elapsed.isEmpty, !timerOnLeft {
                        Text(card.elapsed)
                            .font(.custom(kSansFontName, size: 12))
                            .monospacedDigit()
                            .foregroundColor(card.status == "done" ? IslandView.green : Color.white.opacity(0.55))
                            .lineLimit(1)
                            .fixedSize()
                            .shadow(color: Color.black.opacity(0.55), radius: 1.4)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(width: sheetWidth - 2 * kRowInset, height: kRowHeight)
        // Highlight sits inside the row with a sliver of padding all round, fully rounded
        // (capsule) so it never pokes past the sheet's rounded bottom corners.
        .background(
            RoundedRectangle(cornerRadius: (kRowHeight - 4) / 2)
                .fill(rowBG)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { AppController.shared?.focusCardTab(card.id) }
    }

    // Tooltip nudge shown while hovering a red (≥50%) context badge — floats to its left.
    private var compactTooltip: some View {
        Text("Consider Compacting")
            .font(.custom(kSansFontName, size: 11))
            .foregroundColor(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(Color(white: 0.15)))
            .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
            .transition(.opacity)
            .zIndex(10)
    }

    // Width reserved for the leading icon (gif / image / glyph) + spacing.
    private var leadingSlot: CGFloat {
        let iconW: CGFloat
        if state.aggregate {
            switch aggKind {
            case .needYou: iconW = 14   // "!"
            case .error:   iconW = 16   // triangle
            default:       iconW = 18   // gif / "✓"
            }
        } else {
            iconW = state.mode == .attention ? 14 : (state.mode == .error ? 16 : 18)
        }
        return iconW + (primary.isEmpty ? 0 : 8)
    }

    // ── Fleet aggregate (≥2 sessions) ───────────────────────────────────────────
    // The left headline is the single most important live signal: need-you (attention,
    // the only actionable state) wins, then running, then done, then error. Error is
    // terminal and NOT actionable — it shows (red, so a failure is visible) but is never
    // labelled "need you". Whatever isn't the headline trails on the right in grey.
    private enum AggKind { case needYou, running, done, error }
    private var aggKind: AggKind {
        if state.needYouCount > 0 { return .needYou }
        if state.runningCount > 0 { return .running }
        if state.doneCount    > 0 { return .done }
        return .error
    }
    private var aggHeadline: String {
        switch aggKind {
        case .needYou: return state.needYouCount == 1 ? "1 agent needs input"
                                                       : "\(state.needYouCount) agents need input"
        case .running: return "\(state.runningCount) running…"
        case .done:    return "\(state.doneCount) done"
        case .error:   return "\(state.errorCount) error"
        }
    }
    // Trailing grey counts: whatever isn't the headline. Each part carries its own color
    // so "done" reads green and "error" red even when they trail (matching the headline
    // palette); the rest is grey. When nothing actionable trails (all sessions running),
    // we fill the otherwise-blank right side with a hint — the fleet's dir-spread if it's
    // spread across >1 project (more useful), else a plain "Hover to See" affordance.
    private struct AggPart { let text: String; let color: Color }
    private var aggParts: [AggPart] {
        let grey = Color(white: 0.62)
        var parts: [AggPart] = []
        if aggKind != .running, state.runningCount > 0 { parts.append(.init(text: "\(state.runningCount) running", color: grey)) }
        if aggKind != .done,    state.doneCount    > 0 { parts.append(.init(text: "\(state.doneCount) done", color: IslandView.green)) }
        if aggKind != .error,   state.errorCount   > 0 { parts.append(.init(text: "\(state.errorCount) error", color: IslandView.red)) }
        if parts.isEmpty {
            let dirs = distinctProjectCount
            parts.append(dirs > 1 ? .init(text: "in \(dirs) dirs", color: grey)
                                  : .init(text: "Hover to See", color: grey))
        }
        return parts
    }
    private var aggRight: String { aggParts.map { $0.text }.joined(separator: " · ") }
    // Same parts as `aggRight`, rendered as one concatenated Text so each segment keeps its
    // own color (separators stay grey). Font/weight are applied on the outer view.
    private var aggRightText: Text {
        let grey = Color(white: 0.62)
        var out = Text("")
        for (i, p) in aggParts.enumerated() {
            if i > 0 { out = out + Text(" · ").foregroundColor(grey) }
            out = out + Text(p.text).foregroundColor(p.color)
        }
        return out
    }
    // Distinct non-empty projects across the tracked fleet — drives the "in N dirs" hint.
    private var distinctProjectCount: Int {
        Set(state.roster.map { $0.project }.filter { !$0.isEmpty }).count
    }
    private var leftW: CGFloat {
        leadingSlot + textWidth(primary, IslandView.serifFont, tracking: 0.5)
    }
    // Right cluster: leading pad (3) + message text. The context ring now lives per-row in
    // the dropdown, so the front pill no longer draws it (would be redundant).
    static let finishFlashLeadPad: CGFloat = 14
    // Same leading pad whether or not a flash is CURRENTLY active, as long as we're in "done"
    // or "working" — those are exactly the two modes that can show a FinishFlashView (done's
    // own reply, or working's periodic commentary flash), and holding the pad constant across
    // the whole mode (not just its flash sub-state) is what keeps `rightW` from jumping the
    // instant a flash starts or ends (see `doneBoxWidth`'s note below).
    private var rightLeadPad: CGFloat {
        (state.mode == .done || state.mode == .working) ? IslandView.finishFlashLeadPad : 3
    }
    // The finish-flash marquees within a box sized to the TAB NAME it'll settle into — not a
    // separate fixed width — specifically so `rightW` (and therefore `pillWidth`/`islandOffset`,
    // the whole pill's position) is the SAME value for the entire "done" state: while the message
    // is marqueeing, while it's mid-slide, and once it's settled to the plain tab name. A fixed
    // marquee-comfortable width (the previous approach) necessarily differs from the tab name's
    // real width, and that residual delta — not padding, not alignment, not animation timing —
    // was the pixel jump: however carefully the swap itself is handled, two different box widths
    // on either side of it will always show *some* gap. Same width throughout removes the gap
    // instead of trying to hide it. Reused as-is for the working-commentary flash: `rightText`
    // in `.working` is already `clip(state.title)`, so this is the same value either way.
    private var doneBoxWidth: CGFloat { textWidth(clip(state.title), IslandView.sansFont) }
    private var rightW: CGFloat {
        if state.mode == .done && !state.aggregate { return rightLeadPad + doneBoxWidth }
        return rightLeadPad + textWidth(rightText, IslandView.sansFont)
    }

    private static let green = Color(red: 0.45, green: 0.82, blue: 0.52)

    // Verb/label color matches the state. Serif + tracking to match the brand verb. (The
    // "ultrathink" rainbow case is handled separately by RainbowVerb, which animates.)
    private func verbRun(_ text: String, color: Color) -> Text {
        Text(text).foregroundColor(color).font(.custom(kSerifFontName, size: 13)).tracking(0.5)
    }

    // The front pill's verb. Rainbow per-letter when a single (non-aggregate) ultrathink turn is
    // live; otherwise the flat status color with the sweeping white shimmer.
    @ViewBuilder private var primaryLabel: some View {
        if state.ultra && !state.aggregate && state.mode == .thinking {
            RainbowVerb(text: primary)
                .lineLimit(1)
                .fixedSize()
                // Same white sweep as the flat verb — rides over the rainbow letters.
                .modifier(ShimmerText(active: verbShimmers,
                                      width: textWidth(primary, IslandView.serifFont, tracking: 0.5)))
        } else {
            Text(primary)
                .font(.custom(kSerifFontName, size: 13))
                .tracking(0.5)
                .foregroundColor(primaryColor)
                .lineLimit(1)
                .fixedSize()
                .modifier(ShimmerText(active: verbShimmers,
                                      width: textWidth(primary, IslandView.serifFont, tracking: 0.5)))
        }
    }

    private var primaryColor: Color {
        if state.aggregate {
            switch aggKind {
            case .needYou: return IslandView.red
            case .running: return IslandView.coral
            case .done:    return IslandView.green
            case .error:   return IslandView.red
            }
        }
        switch state.mode {
        case .thinking: return IslandView.amber
        case .done:     return IslandView.green
        case .error:    return IslandView.red
        case .compacting, .compacted: return IslandView.compact
        case .idle:     return IslandView.coral   // "Claude Code" reads in our brand coral-orange while resting
        default:        return IslandView.coral
        }
    }

    private static let clipLen = 18
    private func clip(_ s: String) -> String {
        let m = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return "" }
        guard m.count > IslandView.clipLen else { return m }
        return String(m.prefix(IslandView.clipLen)).trimmingCharacters(in: .whitespaces) + "…"
    }
    // True while the front pill should show its just-finished flash (see `FinishFlash`) instead
    // of the plain tab name. `justFinishedID` is set/cleared by the controller (rebuild()); the
    // multi-second animation itself lives entirely in the view (see `island`/`FinishFlashView`).
    private var showingFinishFlash: Bool {
        state.mode == .done && !state.aggregate && state.justFinishedID != nil
            && !state.preview.isEmpty && finishFlash.message == state.preview
    }
    // Same idea while a session is actively working: briefly shows Claude's latest genuine
    // commentary instead of the tab name (see `freshCommentaryID`), then hands back off.
    private var showingCommentaryFlash: Bool {
        state.mode == .working && !state.aggregate && state.freshCommentaryID != nil
            && !state.commentaryMessage.isEmpty && commentaryFlash.message == state.commentaryMessage
    }

    // DEBUG: a compact signature of whatever the right slot is CURRENTLY showing, so an
    // `.onChange` on it can log every visible change with timing (see logFlicker). Gated by a
    // sentinel file, so this is inert unless flicker-logging is turned on.
    private var rightSignature: String {
        if showingFinishFlash { return "FINISH|\(finishFlash.message)" }
        if showingCommentaryFlash { return "FLASH|\(commentaryFlash.message)" }
        return "plain|\(rightText)"
    }

    // Right side: live timer while thinking; a clip of Claude's message/action
    // while working, on done, and for permission prompts.
    private var rightText: String {
        if state.aggregate { return aggRight }
        switch state.mode {
        case .thinking:                  return state.elapsed
        // Working: the agent's live reply now lives in the hover peek, so the right side shows the
        // session's AI tab name (its directory until it's earned one) — a calmer "which convo",
        // matching the finished state below.
        case .working:                   return clip(state.title)
        // Finished: the agent's reply plays once via `FinishFlashView` (see `showingFinishFlash`);
        // this plain-text fallback is only what shows before/after that flash.
        case .done:                      return clip(state.title)
        case .attention, .error:         return clip(state.preview)
        case .compacting, .compacted:    return ""
        case .idle:                      return state.neutralNotIdle
            ? neutralSessionsLabel(state.idleSessionCount) : idleSessionsLabel(state.idleSessionCount)
        }
    }
    // Colored variant of `rightText`: the aggregate composes per-segment colors (green
    // "done", red "error"); single-session stays uniform grey.
    private var rightTextView: Text {
        if state.aggregate { return aggRightText }
        return Text(rightText).foregroundColor(Color(white: 0.62))
    }

    private var island: some View {
        // Each cluster is laid out at EXACTLY its CoreText-measured width, so the pill's
        // total rendered width is deterministically `pillWidth` (left + gap + right +
        // padding). That's what lets the back cards anchor to the real pill edge — they
        // peek off the same `pillWidth` the pill is actually drawn at, never an estimate
        // that drifts. (`fixedSize` on the text means a sub-pixel measurement difference
        // overflows invisibly into the gap rather than clipping the text.)
        HStack(spacing: 0) {
            // Left: gif/icon + verb.
            HStack(spacing: 8) {
                leading
                if !primary.isEmpty {
                    primaryLabel
                }
            }
            .frame(width: leftW, alignment: .leading)

            // Centered notch gap (+ clearance so text never touches the camera).
            Color.clear.frame(width: state.notchWidth + notchClearance)

            // Right: message/timer (context ring moved to the dropdown rows).
            HStack(spacing: 7) {
                // `.transition(.identity)` on both branches: the ambient `.animation(value:
                // pillWidth)` further down (pillWidth itself changes here, fixed flash width ⇄
                // natural text width) would otherwise make SwiftUI's DEFAULT opacity crossfade
                // kick in for this if/else's mount/unmount — a second, unwanted fade stacked on
                // top of FinishFlashView's own already-completed slide, reading as a flash/blink
                // right at the handoff. `.identity` means "swap instantly, no transition" —
                // correct here since the view's own internal animation already did the work.
                if showingFinishFlash {
                    FinishFlashView(flash: finishFlash, width: doneBoxWidth, tabName: clip(state.title))
                        .padding(.leading, IslandView.finishFlashLeadPad)
                        .transition(.identity)
                } else if showingCommentaryFlash {
                    FinishFlashView(flash: commentaryFlash, width: doneBoxWidth, tabName: clip(state.title))
                        .padding(.leading, IslandView.finishFlashLeadPad)
                        .transition(.identity)
                } else if !rightText.isEmpty {
                    rightTextView
                        .font(.custom(kSansFontName, size: 13))
                        .fontWeight(.regular)
                        .monospacedDigit()                  // tabular-nums: stable digit width
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, rightLeadPad)
                        .transition(.identity)
                }
            }
            .frame(width: rightW, alignment: .trailing)
        }
        // Fires exactly once per fresh "done" arrival (see rebuild()'s edge-detection) — (re)starts
        // the self-timed flash sequence. Reading state.preview/state.title here (not passed
        // through justFinishedID) is safe: rebuild() sets them for the SAME session in the SAME
        // pass right before flipping this.
        .onChange(of: state.justFinishedID) { newValue in
            guard newValue != nil else {
                finishFlash.stop()   // controller cleared it (front moved on) — don't let a
                return               // pending hold/slide timer fire pointlessly after the fact
            }
            finishFlash.start(message: state.preview) {
                if IslandState.shared.justFinishedID != nil {
                    IslandState.shared.justFinishedID = nil
                }
            }
        }
        // Same pattern as justFinishedID above, for the periodic working-commentary flash.
        // Fires once per fresh commentary key (see rebuild()'s edge-detection) — restarts the
        // hold+slide sequence even if a previous flash is still mid-hold, so newer commentary
        // always wins over older.
        .onChange(of: state.freshCommentaryID) { newValue in
            guard newValue != nil else {
                commentaryFlash.stop()
                return
            }
            commentaryFlash.start(message: state.commentaryMessage) {
                if IslandState.shared.freshCommentaryID != nil {
                    IslandState.shared.freshCommentaryID = nil
                }
            }
        }
        // DEBUG: log every visible change of the right slot with high-res timing (gated by a
        // sentinel file — inert otherwise). Lets us quantify the flicker cadence.
        .onChange(of: rightSignature) { sig in AppController.shared?.logFlicker(sig) }
        .padding(.horizontal, 18)
        .frame(width: pillWidth, height: islandHeight)   // top row stays pinned to the notch
        // Background grows DOWN by the peek on hover; the row above stays put, and the
        // session title fades in at the bottom-center of the revealed strip.
        .frame(width: pillWidth, height: islandHeight + frontPeekH, alignment: .top)
        .background(
            // When the dropdown is open, the expanded sheet draws the background; the
            // pill's own shape would otherwise leave a seam mid-sheet. While expanded the
            // bottom corners round out more (animated via IslandShape.animatableData) so
            // the grown pill reads as a soft lozenge rather than a stretched rectangle.
            IslandShape(topRadius: state.topRadius,
                        bottomRadius: frontPeekH > 0 ? kFrontExpandRadius : state.bottomRadius)
                .fill(state.dropdownOpen ? Color.clear : Color.black)
        )
        .overlay(alignment: .bottom) {
            // The peek and the right pill stay COMPLEMENTARY: whichever of {tab name, live
            // step/response} is on the right, the peek shows the other — never both the same
            // thing. So while a flash is putting the response/commentary on the right (the done
            // reply, or the working commentary flash), the peek shows the tab name; once the
            // flash hands back to the tab name on the right, the peek shows the live step/
            // commentary (the usual). Thinking (no reply yet) still falls back to the user's
            // latest message; idle shows nothing (hovering the notch itself still gives the
            // usage peek via `state.notchPeek`). Marquee'd if it overflows.
            let flashOnRight = showingFinishFlash || showingCommentaryFlash
            let hasResponse = !state.preview.isEmpty
                && (state.mode == .working || state.mode == .done)
            let tabNamePeek = state.title.isEmpty ? state.project : state.title
            let peekText: String = {
                if state.mode == .idle { return "" }
                if flashOnRight { return tabNamePeek }           // response is on the right → tab name here
                if hasResponse { return state.preview }          // tab name on the right → live step here
                return state.lastUserMsg.isEmpty ? state.title : state.lastUserMsg
            }()
            if frontPeekH > 0 && (state.notchPeek || !peekText.isEmpty) {
                Group {
                    if state.notchPeek {
                        usagePeekView
                            .font(.custom(kSansFontName, size: 13))
                            .lineLimit(1)
                            .frame(maxWidth: pillWidth - 28)
                    } else {
                        QueuePeek(text: peekText, baseWhite: 0.66,
                                  width: pillWidth - 28, clock: MarqueeClock.shared)
                    }
                }
                .padding(.bottom, 5)
                // Fade + rise into place so it doesn't just blink on.
                .opacity(state.frontHovered ? 1 : 0)
                .offset(y: state.frontHovered ? 0 : 5)
                .environment(\.colorScheme, .dark)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { AppController.shared?.handleIslandClick() }
        // Idle peek: a bouncy scale + fade entrance (spring overshoot, ~0.55s so it reads as
        // springy, not snappy). Anchored to the top so it grows down out of the notch.
        .scaleEffect(state.mode == .idle ? (0.72 + 0.28 * state.idleReveal) : 1, anchor: .top)
        .opacity(state.mode == .idle ? state.idleReveal : 1)
        .animation(.spring(response: 0.55, dampingFraction: 0.55), value: state.idleReveal)
        // Shift so the notch gap stays centered on the camera even when the two
        // sides differ in width — neither side can slide behind the notch.
        .offset(x: islandOffset)
    }

    // Notch-hover peek: "Session [▓▓▓░░░] 16% context · resets in 57m" — a fill bar + percent
    // in the same color, reset time in white. Falls back to the locally-tallied absolute token
    // windows, then to the playful resting text, when the real plan limit isn't available yet.
    // "This Week" (7d) is still computed (`rlWeek`) but hidden here — may resurface later.
    @ViewBuilder
    private var usagePeekView: some View {
        // The teach copy stands alone. Otherwise the peek shows ONE face at a time — the usage
        // text line, or (when toggled and a week of data exists to shade) the activity heatmap —
        // and a click swaps between them (handleIslandClick). Keeping them mutually exclusive
        // instead of stacked keeps the peek from piling up two rows of stats.
        if state.firstRunHint {
            Text("👋 Hover the notch anytime to summon me").foregroundColor(.white)
        } else if state.usageShowActivity && !state.usageDays.isEmpty {
            ActivityStrip(levels: state.usageDays, tokens: state.usageDayTokens,
                          hovered: state.hoveredDay)
                .padding(.bottom, 3)
        } else {
            usagePeekLine
                .padding(.bottom, 3)
        }
    }

    @ViewBuilder
    private var usagePeekLine: some View {
        let grey = Color(white: 0.55)
        if !state.rlSession.isEmpty {
            let pct = Int(state.rlSession) ?? 0
            let barColor = pctColor(state.rlSession)
            let textColor = pctTextColor(state.rlSession)
            let reset = fmtReset(state.rlSessionReset)
            HStack(spacing: 6) {
                ContextRing(pct: Double(pct) / 100, colorOverride: barColor)
                Text("\(pct)% session limit used").foregroundColor(barColor)
                if !reset.isEmpty {
                    Text("·").foregroundColor(textColor)
                    Text("resets in \(reset)").foregroundColor(pctResetColor(state.rlSession))
                }
            }
        } else if !(state.usageSession.isEmpty && state.usageToday.isEmpty) {
            let sess = Text("Session: ").foregroundColor(grey)
                + Text(state.usageSession + " tokens").foregroundColor(.white)
            let today = Text("Today: ").foregroundColor(grey)
                + Text(state.usageToday + " tokens").foregroundColor(.white)
            sess + Text("  ·  ").foregroundColor(grey) + today
        } else {
            Text("Happy Clauding").foregroundColor(.white)
        }
    }

    // GitHub-contributions-style row of per-day cells: brighter = a heavier day for you
    // (relative to your own busiest day in the window). On the black notch, "more activity"
    // reads as "whiter", so intensity maps to white opacity; an idle day is a faint grid cell.
    private struct ActivityStrip: View {
        let levels: [Int]   // oldest→newest, today rightmost
        let tokens: [Int]   // raw per-day tokens, same order (may be empty)
        let hovered: Int    // hit-tested cell index, -1 = none
        static let cell: CGFloat = 11, gap: CGFloat = 2.5
        var body: some View {
            let label = Color(white: 0.5)
            // The busiest day sets the brightness peak; every other day is shaded by a gamma
            // curve of its share of that peak (see opacity()).
            let peak = tokens.max() ?? 0
            // Inline flanks: "7 days" · cells · "Today". Fixed-width labels keep the cell row
            // exactly centered under the pill so the hover hit-test lines up.
            HStack(spacing: 6) {
                Text("7 days").font(.custom(kSansFontName, size: 11)).foregroundColor(label)
                    .frame(width: 44, alignment: .trailing)   // hug the cells; padding falls outside
                HStack(spacing: Self.gap) {
                    ForEach(Array(levels.enumerated()), id: \.offset) { i, _ in
                        let op = Self.opacity(i < tokens.count ? tokens[i] : 0, peak: peak)
                        // Faint outline only on near-black (idle) cells so they stay visible;
                        // bright cells read on their own. Hovered cell always gets a full ring.
                        let border: Color = i == hovered ? .white
                            : (op < 0.20 ? Color.white.opacity(0.18) : .clear)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(op))
                            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(border, lineWidth: 1))
                            .frame(width: Self.cell, height: Self.cell)
                    }
                }
                Text("Today").font(.custom(kSansFontName, size: 11)).foregroundColor(label)
                    .frame(width: 44, alignment: .leading)   // hug the cells; padding falls outside
            }
            // Floating tooltip: a self-contained chip below the cells, drawn only on hover so it
            // costs no layout height. Matches the dropdown's compactTooltip (capsule, size 11).
            .overlay(alignment: .bottom) {
                if hovered >= 0, hovered < tokens.count {
                    Text(caption)
                        .font(.custom(kSansFontName, size: 11)).foregroundColor(.white)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Capsule(style: .continuous).fill(Color(white: 0.15)))
                        .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
                        .offset(y: 24)
                }
            }
        }
        private var caption: String {
            guard hovered >= 0, hovered < tokens.count else { return " " }
            let daysAgo = tokens.count - 1 - hovered
            let cal = Calendar.current
            let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: Date())) ?? Date()
            let df = DateFormatter(); df.dateFormat = "MMM d"
            let t = tokens[hovered]
            let amt = t >= 1_000_000 ? String(format: "%.1fM", Double(t) / 1_000_000)
                    : t >= 1_000 ? "\(t / 1000)k" : "\(t)"
            return "\(amt) tokens · \(df.string(from: day))"
        }
        // Brightness = gamma curve of the day's share of the busiest day's tokens. The √ (gamma
        // 0.5) maps token magnitude to PERCEIVED brightness: the peak day → 1.0, a normal day
        // stays clearly mid-bright, light days lift off the 0.10 idle cell — while a true 4×
        // spike still reads ~1.6× brighter (linear crushes normal days near idle; log flattens
        // the top so the spike stops standing out — this is the middle ground).
        private static func opacity(_ t: Int, peak: Int) -> Double {
            guard t > 0, peak > 0 else { return 0.10 }   // idle — faint so the grid still reads
            return 0.28 + 0.72 * pow(Double(t) / Double(peak), 0.5)
        }
    }

    // Bar fill: white below 60% → yellow 60-85% → red past 85%, so a tight context window
    // reads at a glance.
    private func pctColor(_ s: String) -> Color {
        let v = Int(s) ?? 0
        if v >= 85 { return IslandView.red }
        if v >= 60 { return IslandView.amber }
        return .white
    }

    // Labels (percent + reset time): quiet grey below 60%, only picking up the warning color
    // once usage is actually worth flagging.
    private func pctTextColor(_ s: String) -> Color {
        let v = Int(s) ?? 0
        if v >= 85 { return IslandView.red }
        if v >= 60 { return IslandView.amber }
        return Color(white: 0.55)
    }

    // "resets in [time]": grey while the bar is still white (nothing to worry about), white
    // once the bar has gone yellow/red (the reset becomes the thing worth noticing).
    private func pctResetColor(_ s: String) -> Color {
        pctColor(s) == .white ? Color(white: 0.55) : .white
    }

    // Time until a rate-limit window resets, from its epoch `resets_at`: "3d 2h" / "2h 14m" / "57m".
    // "" when there's no reset or it's already past (the next render picks up the fresh window).
    private func fmtReset(_ epoch: Double) -> String {
        guard epoch > 0 else { return "" }
        let secs = Int(epoch - Date().timeIntervalSince1970)
        guard secs > 0 else { return "" }
        let d = secs / 86_400, h = (secs % 86_400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(1, m))m"
    }

    // Extra height the front pill takes on hover (0 normally). Suppressed while the
    // dropdown is open — the expanded sheet already names every session there.
    private var frontPeekH: CGFloat {
        guard state.frontHovered && !state.dropdownOpen else { return 0 }
        return kFrontPeek
    }

    // Which states get the sweeping white shimmer on their left verb: the "in progress"
    // ones (thinking / working gerunds / compacting) and, in the multi-session aggregate,
    // the "{n} running…" headline. The resting "Claude Code" (idle) does NOT shimmer.
    private var verbShimmers: Bool {
        if state.aggregate { return aggKind == .running }
        return [.thinking, .working, .compacting].contains(state.mode)
    }

    private var primary: String {
        if state.aggregate { return aggHeadline }
        switch state.mode {
        case .error: return "Error"
        case .compacting: return "Compacting…"
        case .compacted:  return "Compacted"
        case .done:  return state.elapsed.isEmpty ? "Finished" : "Finished " + state.elapsed
        // working: a short verb. A malformed/partial working event can carry no verb — fall
        // back to a generic "Working…" (NOT the preview: the agent's message is long prose and
        // would blow out the left side past any sane width). The right side shows the message.
        case .working: return state.detail.isEmpty ? "Working…" : state.detail
        case .thinking: return state.ultra ? "Ultrathinking…" : (state.detail.isEmpty ? "Thinking…" : state.detail)
        case .idle:    return ""              // idle shows just the icon (+ "Idle" on the right)
        default:     return state.detail
        }
    }

    @ViewBuilder private var leading: some View {
        if state.aggregate {
            switch aggKind {
            case .needYou:
                Image(systemName: "exclamationmark").font(.system(size: 13, weight: .bold)).foregroundColor(IslandView.red).frame(width: 14).modifier(WobbleMarker(active: true))
            case .running:
                BusyGlyph(color: IslandView.coral, interval: 0.2, size: 17)
            case .done:
                // Same "✻" static busy-glyph mark as the dropdown's rowMarker for "done" —
                // not a checkmark, so a finished session reads consistently across both.
                Text("✻").font(.system(size: 12, weight: .bold)).foregroundColor(IslandView.green).frame(width: 18)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold)).foregroundColor(IslandView.red).frame(width: 16)
            }
        } else {
            leadingSingle
        }
    }

    @ViewBuilder private var leadingSingle: some View {
        switch state.mode {
        case .thinking:
            if state.ultra {
                UltraGlyph(interval: 0.3, size: 17, pulse: true)
            } else {
                BusyGlyph(color: accent, interval: 0.3, size: 17, pulse: true)
            }
        case .working:
            BusyGlyph(color: accent, interval: 0.2, size: 17)
        case .attention:
            Image(systemName: "exclamationmark").font(.system(size: 13, weight: .bold)).foregroundColor(accent).frame(width: 14).modifier(WobbleMarker(active: true))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold)).foregroundColor(accent).frame(width: 16)
        case .done:
            // Same "✻" static busy-glyph mark as the dropdown's rowMarker — not a checkmark,
            // so a finished session reads consistently in both the front pill and dropdown.
            Text("✻").font(.system(size: 12, weight: .bold)).foregroundColor(accent).frame(width: 18)
        case .compacting:
            BusyGlyph(color: accent, interval: 0.25, size: 17)
        case .compacted:
            Text("✻").font(.system(size: 12, weight: .bold)).foregroundColor(accent).frame(width: 18)
        case .idle:
            // Resting "paused" Claude mark: the static busy glyph. During the hover-hint stage
            // it breathes (scale + opacity) to confirm the hover; once revealed in full it
            // settles to a steady mark. A click plays one pass through the busy glyphs — a
            // "still alive" wink — before settling back (idleWaking, toggled by
            // handleIslandClick; purely cosmetic, doesn't focus/open anything).
            Group {
                if state.idleWaking {
                    IdleWakeGlyph(color: IslandView.coral, interval: 0.2, size: 17)
                } else {
                    Text("✻")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(IslandView.coral)
                        .frame(width: 17, height: 17)
                }
            }
        }
    }
}

/// A white highlight band that sweeps left→right across text, masked to the glyphs (a
/// "shimmer"). Sized from a known width since GeometryReader reads 0 in this panel. When
/// `active` is false it's a no-op passthrough.
struct ShimmerText: ViewModifier {
    let active: Bool
    let width: CGFloat

    func body(content: Content) -> some View {
        if active, width > 0 {
            // TimelineView drives the sweep off the system animation clock — onAppear +
            // withAnimation(repeatForever) is unreliable in this non-key panel.
            content.overlay(
                TimelineView(.animation) { tl in
                    let sweep = 1.6, pause = 0.5            // sweep, then rest off-screen
                    let cycle = sweep + pause
                    let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
                    let phase = min(t / sweep, 1.0)         // 0…1 during sweep, parked at 1 during the pause
                    let x = -0.75 * width + phase * (1.5 * width)   // fully off-text (right) while parked
                    LinearGradient(gradient: Gradient(colors: [.clear, Color.white.opacity(0.8), .clear]),
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: width * 0.5)
                        .offset(x: x)
                        .mask(content)            // confine the shine to the letterforms
                }
            )
        } else {
            content
        }
    }
}

/// Self-driving clock for the wobble: SwiftUI's own animation clock
/// (TimelineView/withAnimation) doesn't tick reliably in this non-activating panel, so
/// we step time ourselves on a Timer. Each attention marker owns one; it only exists
/// while that marker is on screen.
final class WobbleClock: ObservableObject {
    @Published var t: Double = 0
    private var timer: Timer?
    init() {
        let tm = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.t += 1.0 / 60.0
        }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }
    deinit { timer?.invalidate() }
}

/// A periodic attention nudge for the `!` marker: a quick rotational shake (a few
/// oscillations that decay to rest), then a long pause. Punctuated motion with rest
/// gaps reads as "act on me" — the opposite of the continuous shimmer, which reads as
/// ambient progress and habituates in peripheral vision.
struct WobbleMarker: ViewModifier {
    let active: Bool
    @StateObject private var clock = WobbleClock()

    func body(content: Content) -> some View {
        guard active else { return AnyView(content) }
        let cycle = 3.0, shake = 0.6               // shake burst, then rest
        let t = clock.t.truncatingRemainder(dividingBy: cycle)
        let angle: Double = t < shake
            ? 11 * (1 - t / shake) * sin((t / shake) * .pi * 6)   // 3 oscillations, decaying to settle
            : 0
        return AnyView(content.rotationEffect(.degrees(angle), anchor: .bottom))
    }
}

/// Cycles a "working"/"thinking" row's marker through Claude Code's own busy
/// glyphs (✳✽✶✢✻) instead of a static dot. Own timer per instance so a
/// background row stuck on "working" animates independently of whatever the
/// front session is doing (e.g. attention).
final class GlyphClock: ObservableObject {
    @Published var t: Double = 0   // continuously running elapsed time, in seconds
    private var timer: Timer?
    init() {
        let tm = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.t += 1.0 / 60.0
        }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }
    deinit { timer?.invalidate() }
}

/// Replaces the plain status dot for a "working"/"thinking" row with Claude
/// Code's own busy-spinner glyphs, cycling in place. `interval` sets the
/// cadence — faster for "working" reads as busier, slower for "thinking"
/// reads more contemplative. `pulse` additionally breathes the opacity
/// between 100% and 85% each cycle, in sync with the glyph swap — reserved
/// for the front-pill "thinking" mark, where the extra motion reads as
/// deliberate rather than busy.
struct BusyGlyph: View {
    static let glyphs = ["✳", "✽", "✶", "✢", "✻", "·"]
    let color: Color
    let interval: Double
    let size: CGFloat
    let pulse: Bool
    @StateObject private var clock = GlyphClock()

    init(color: Color, interval: Double, size: CGFloat = 11, pulse: Bool = false) {
        self.color = color
        self.interval = interval
        self.size = size
        self.pulse = pulse
    }

    private var frame: Int { Int(clock.t / interval) % Self.glyphs.count }
    private var pulseOpacity: Double { 0.925 + 0.075 * cos(2 * Double.pi * clock.t / interval) }

    var body: some View {
        Text(Self.glyphs[frame])
            .font(.system(size: size, weight: .bold))
            .foregroundColor(color)
            .opacity(pulse ? pulseOpacity : 1.0)
            .frame(width: max(size, 8), height: max(size, 8))
    }
}

/// The idle "wake" wink: plays exactly one pass through the busy glyphs, then holds on the
/// last one (clamped, not modulo — unlike `BusyGlyph` this never loops) so it reads as a
/// single "still alive" blink instead of spinning for as long as `idleWaking` happens to
/// stay true.
struct IdleWakeGlyph: View {
    let color: Color
    let interval: Double
    let size: CGFloat
    @StateObject private var clock = GlyphClock()

    private var frame: Int { min(Int(clock.t / interval), BusyGlyph.glyphs.count - 1) }

    var body: some View {
        Text(BusyGlyph.glyphs[frame])
            .font(.system(size: size, weight: .bold))
            .foregroundColor(color)
            .frame(width: max(size, 8), height: max(size, 8))
    }
}

/// The marker for an "ultrathink" turn: the same cycling busy glyphs as `BusyGlyph`, but
/// colored to continuously track the rainbow verb's leading (character 0) hue instead of a
/// fixed color — kept in exact sync via the shared `RainbowClock`, since the verb text and
/// this glyph are separate views that both need to move together. A dedicated small view
/// (rather than adding this to `BusyGlyph` itself) so the extra 60Hz re-render this needs
/// stays scoped to actual ultrathink markers, not every plain working/thinking dot.
struct UltraGlyph: View {
    let interval: Double
    let size: CGFloat
    let pulse: Bool
    @StateObject private var clock = GlyphClock()
    @ObservedObject private var rainbowClock = RainbowClock.shared

    init(interval: Double, size: CGFloat = 11, pulse: Bool = false) {
        self.interval = interval
        self.size = size
        self.pulse = pulse
    }

    private var frame: Int { Int(clock.t / interval) % BusyGlyph.glyphs.count }
    private var pulseOpacity: Double { 0.925 + 0.075 * cos(2 * Double.pi * clock.t / interval) }
    private var color: Color {
        // Character 0's current slot — matches the leading letter of the rainbow verb.
        let step = Int(rainbowClock.t / RainbowClock.swapInterval)
        return kRainbowPalette[rainbowSlot(0, step: step)]
    }

    var body: some View {
        Text(BusyGlyph.glyphs[frame])
            .font(.system(size: size, weight: .bold))
            .foregroundColor(color)
            .opacity(pulse ? pulseOpacity : 1.0)
            .frame(width: max(size, 8), height: max(size, 8))
    }
}

/// Context-window fill gauge. Grey track (matching the preview text), with the filled
/// arc swept clockwise from 12 o'clock — white when low, amber past a third, red past half.
struct ContextRing: View {
    let pct: Double
    var colorOverride: Color? = nil
    private var fillColor: Color { colorOverride ?? contextFillColor(pct) }
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(white: 0.62).opacity(0.55), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, pct)))
                .stroke(fillColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 9, height: 9)
        .animation(.easeOut(duration: 0.3), value: pct)
    }
}

// MARK: - Panel

/// Hosting view that accepts clicks even though the panel is non-activating and never
/// becomes key — otherwise the first click on the island/chevron is swallowed by the
/// window server instead of reaching SwiftUI's tap gestures.
final class ClickableHostingView<Content: View>: NSHostingView<Content> {
    var onMove: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The panel is non-activating and never key, so mouse-MOVED events are never delivered to it
    // — the controller's NSEvent monitors only see moves OUTSIDE our window, so hover froze the
    // moment the cursor entered the open sheet. A tracking area is the one mechanism that fires
    // mouseMoved INSIDE a non-key window, so we forward those to the controller's hover update.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) { onMove?(); super.mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { onMove?(); super.mouseExited(with: event) }
}

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Start transparent to clicks; the controller flips this to false (per mouse-move)
        // only while the cursor is actually over the island, so the rest of this wide panel
        // never steals clicks from the menu bar / status items beneath it. (Returning nil
        // from the view's hitTest does NOT forward clicks to other apps' windows — verified
        // — so ignoresMouseEvents is the only reliable passthrough.)
        ignoresMouseEvents = true
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

/// Resolved, in-memory state for one Warp-tab session, merged across its events.
/// A session exists only once it has fired at least one hook (i.e. actually run);
/// open-but-never-run tabs are intentionally NOT shown.
final class LiveSession {
    var mode = "thinking"
    var detail = ""
    var preview = ""
    var firstPrompt = ""
    var lastUserMsg = ""  // most recent typed user message, for the hover peek marquee
    var qHeader = ""      // pending AskUserQuestion: short topic label
    var qText = ""        // pending AskUserQuestion: full question text
    var ultra = false     // "ultrathink" turn → rainbow verb
    var flashPri = 0      // how much `preview` should flash: 2 prose / 1 notable action / 0 routine
    var flashKey = ""     // stable identity for the current preview; preview text can vary by producer
    var finishKey = ""    // stable identity for the current terminal reply flash
    var project = ""
    var aiTitle = ""
    var context = 0.0
    var focus = ""
    var cwd = ""
    var ts = 0.0          // last event time (epoch)
    var promptTs = 0.0    // last UserPromptSubmit — the "you're focused here" signal
    var turnStartTs = 0.0 // start of the current turn, for the elapsed timer
    var transcript = ""   // transcript path, polled to detect user-cancel (Esc)
}

final class AppController: NSObject, NSApplicationDelegate {
    static var shared: AppController?

    private var panel: NotchPanel!
    private var clockTimer: Timer?
    private var gcTimer: Timer?
    private var liveTimer: Timer?   // fast poll of CC's live status; runs ONLY mid-turn
    private var lastLivenessScanTs = 0.0
    private var livenessScanning = false
    private var pendingLivenessForce = false
    private var knownSessionIds: Set<String> = []   // session files seen last reload (detect new tabs)
    private var dropdownTimer: Timer?   // 1s refresh while the dropdown is open (subagent rows
                                        // don't fire hooks, so nothing else re-reads them)
    private var hiddenIdle = false      // true while the island is hidden (nothing live/recent)
    private var idlePeekShown = false   // true while the resting idle pill is revealed on hover
    private var idleHoverTimer: Timer?  // dwell timer: hover the notch ~2s to reveal idle

    private var sessions: [String: LiveSession] = [:]
    private var liveTabs: Set<String> = []      // interactive (non-forked) tab UUIDs
    private var lastSeenLive: [String: Double] = [:]   // uuid → last scan that saw it (debounce)
    private var liveTabCwd: [String: String] = [:]     // uuid → cwd, for idle (no-file) tab labels
    private var liveTabTitle: [String: String] = [:]   // uuid → last-known label, kept after a file is gone
    private var liveTabContext: [String: Double] = [:]  // uuid → last-known context fill, for idle rings
    private var liveTabFocus: [String: String] = [:]    // tab key → focus descriptor, so idle (no-file) tabs stay clickable
    private var projectOrder: [String] = []             // dropdown group order, by first-seen (never reshuffled)
    private var activeWarpTab: String?                  // uuid of the tab focused in Warp (drives row highlight)
    private var lastDbActiveTab: String?                // last active tab Warp's DB reported (to detect real switches)
    private var clickFocus: String?             // a tab the user clicked → pin to front
    private var clickFocusTs: Double = 0        // newest activity ts at click time; the pin
                                                // releases once any tab posts something newer
    private var dropdownFrozenOrder: [String]?  // row id order locked while the menu is open,
                                                // so rows don't reshuffle under the cursor
    private var frontUUID: String?              // current front-pill session
    private var lastSingleFocus: String?        // the tab that last held the front as the lone
                                                // running session; lets its completion keep the
                                                // single "Finished" pill instead of an aggregate count
    private let appStartTs = Date().timeIntervalSince1970
    private var shownFlashKeys: Set<String> = []
    private var shownFinishKeys: Set<String> = []
    // Edge-detects fresh commentary for the front pill's periodic flash (see `freshCommentaryID`):
    // a transcript-stable activity key for whatever was last acted on. Preview text is display
    // only; hook/poll can disagree on string length without making the same event flash twice.
    private var lastCommentaryKey: String = ""
    private var lastFlashStartTs: Double = 0   // when the current front-pill flash began (epoch),
                                               // for the kCommentaryHoldS protected window
    private var lastFlashPriority: Int = 0     // its priority (2 prose / 1 notable action), so a
                                               // higher-priority item can preempt it mid-hold
    // DEBUG flicker logger (gated by ~/.claude-island/flicker.on): last log time + on/off cache.
    private var lastFlickerT: Double = 0
    private var dismissedDoneIds: Set<String> = []  // clicked-away "Finished" pills — excluded
                                                // from front-selection until they do something new

    // Live pill geometry, reported by the view (which computes it deterministically).
    // The mouse monitor hit-tests the cursor against this — both use the same numbers,
    // so what's drawn and what's hoverable can't drift. Set/read on the main thread.
    private var curPillWidth: CGFloat = 0
    private var curIslandOffset: CGFloat = 0
    // Mirrors IslandView.sheetSide so the hit-tests track the drawn sheet: 0 in the idle state
    // (no back pill to encompass), else kSheetSide.
    private var sheetSide: CGFloat { IslandState.shared.mode == .idle ? 0 : kSheetSide }
    private var mouseMonitors: [Any] = []

    // MARK: - Menu bar item (Pause / Quit)

    private var statusItem: NSStatusItem?
    private var pauseMenuItem: NSMenuItem?
    private var showCodexItem: NSMenuItem?
    private var paused = false
    // Whether Codex Desktop cards (cdex-*) show in the roster. A display toggle only — the watcher
    // keeps writing the files; this just filters them out of visibleSessions. Persisted, defaults
    // on (the point of Codex support is to see it), so an unset install shows Codex from the start.
    private var showCodex = UserDefaults.standard.object(forKey: "showCodex") as? Bool ?? true

    /// A menu bar presence — the conventional home for quitting a background utility (a plain
    /// Quit would just be relaunched by the KeepAlive agent) and a persistent "it's installed"
    /// anchor. The glyph is a mini-notch: the island's own concave shoulder fillets.
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = notchGlyph()
        item.button?.toolTip = "Claude Island"
        let menu = NSMenu()
        let pause = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        menu.addItem(.separator())
        // A checkable "Show Codex" — visible whether or not Codex is installed, so it also
        // signals that the island can surface Codex at all. Its ✓ reflects the persisted pref.
        let codex = NSMenuItem(title: "Show Codex", action: #selector(toggleShowCodex), keyEquivalent: "")
        codex.target = self
        codex.state = showCodex ? .on : .off
        menu.addItem(codex)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Claude Island", action: #selector(quitIsland), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        pauseMenuItem = pause
        showCodexItem = codex
    }

    /// The notch silhouette as a menu bar template image — the same concave re-entrant shoulder
    /// fillets as `IslandShape`, so the glyph reads as "the notch thing." Template → macOS tints
    /// it for the light/dark menu bar automatically.
    private func notchGlyph() -> NSImage {
        // The island silhouette itself — concave re-entrant shoulder fillets on top, convex
        // bottom corners (same geometry as `IslandShape`). A tad shorter than the original so it
        // reads as a wide notch. Template → macOS tints it for the light/dark menu bar.
        let w: CGFloat = 22, h: CGFloat = 10.5, r: CGFloat = 5, br: CGFloat = 3
        let img = NSImage(size: NSSize(width: w, height: h), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let p = CGMutablePath()   // flipped:true → top-left origin, y down, matching IslandShape
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: w, y: 0))
            p.addQuadCurve(to: CGPoint(x: w - r, y: r), control: CGPoint(x: w - r, y: 0))       // right shoulder (concave)
            p.addLine(to: CGPoint(x: w - r, y: h - br))
            p.addQuadCurve(to: CGPoint(x: w - r - br, y: h), control: CGPoint(x: w - r, y: h))  // bottom-right convex
            p.addLine(to: CGPoint(x: r + br, y: h))
            p.addQuadCurve(to: CGPoint(x: r, y: h - br), control: CGPoint(x: r, y: h))          // bottom-left convex
            p.addLine(to: CGPoint(x: r, y: r))
            p.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: r, y: 0))               // left shoulder (concave)
            p.closeSubpath()
            ctx.addPath(p); NSColor.black.setFill(); ctx.fillPath()
            return true
        }
        img.isTemplate = true
        return img
    }

    @objc private func togglePause() {
        paused.toggle()
        pauseMenuItem?.title = paused ? "Resume" : "Pause"
        if paused { panel.orderOut(nil) } else { rebuild() }
    }

    @objc private func toggleShowCodex() {
        showCodex.toggle()
        UserDefaults.standard.set(showCodex, forKey: "showCodex")
        showCodexItem?.state = showCodex ? .on : .off
        rebuild()   // visibleSessions re-filters cdex-* in/out on the next roster build
    }

    @objc private func quitIsland() {
        // KeepAlive=true would relaunch a plain terminate, so bootout the LaunchAgent — it stays
        // quit until next login (or a reinstall / manual `launchctl bootstrap`).
        _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/com.claude-island.app"])
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        AppController.shared = self
        registerFonts()

        // UI mode: "peek" (left peek cards) or "dropdown" ({n}⌄ back pill → menu).
        if let m = try? String(contentsOfFile: kEventDir + "/ui-mode", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
            IslandState.shared.uiMode = m
        }

        // Persisted dropdown group order (first-seen project names, one per line) so the
        // dir headers keep their "when first opened" order across daemon restarts.
        if let raw = try? String(contentsOfFile: kProjectOrderFile, encoding: .utf8) {
            projectOrder = raw.split(separator: "\n").map(String.init)
        }

        let hosting = ClickableHostingView(rootView: IslandView())
        hosting.frame = NSRect(x: 0, y: 0, width: 1100, height: 160)
        hosting.autoresizingMask = [.width, .height]
        hosting.onMove = { [weak self] in self?.updateHover() }   // track hover INSIDE the panel

        panel = NotchPanel()
        panel.contentView = hosting
        position()
        setupStatusItem()

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center,
                                        Unmanaged.passUnretained(self).toOpaque(),
                                        darwinCallback,
                                        kDarwinName as CFString,
                                        nil,
                                        .deliverImmediately)

        // Reposition if displays change (external monitor, resolution).
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(position),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)

        // Periodic liveness scan: prune sessions whose tab closed or whose turn the
        // user canceled (Esc), then refresh the deck. This timer ticks cheaply once/sec;
        // refreshLiveness decides whether a real background scan is due for the current state.
        let g = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshLiveness()
        }
        RunLoop.main.add(g, forMode: .common)
        gcTimer = g

        // Fast live poll: reads CC's own busy/idle status files and tails each transcript so the
        // verb/preview/active-state track real activity at sub-second latency between hook events.
        // Started on demand by rebuild() ONLY while a turn is active (working/thinking) — idle
        // sessions have nothing to poll, so this no longer wakes the CPU around the clock.
        // All IO runs off the main thread.

        // Drive back-card hover ourselves. SwiftUI's onHover relies on a tracking area
        // that only fires in the key window, and this non-activating panel can never
        // become key — so onHover never fires (verified). Instead we watch mouse moves
        // globally (when another app is active, the normal case for us) and locally, and
        // hit-test the cursor against the deterministic pill geometry.
        panel.acceptsMouseMovedEvents = true
        let gm = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            self?.updateHover()
        })
        let lm = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] e in
            self?.updateHover(); return e
        })
        // Click-outside dismiss: while the dropdown is open, a mouse-down anywhere outside
        // the expanded sheet closes it. Global catches clicks in other apps; local catches
        // clicks on our own panel's transparent areas. Neither consumes the event.
        let gd = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.dismissDropdownIfOutside(NSEvent.mouseLocation)
        })
        let ld = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            self?.dismissDropdownIfOutside(NSEvent.mouseLocation); return e
        })
        mouseMonitors = [gm, lm, gd, ld].compactMap { $0 }

        refreshLiveness()
        reload()
        refreshUsage()   // warm the token-usage peek so the first notch hover has data
    }

    /// Called by the view whenever the pill's drawn geometry changes, so the hover
    /// hit-test below stays in lockstep with what's on screen.
    func updateGeom(pillWidth: CGFloat, islandOffset: CGFloat) {
        curPillWidth = pillWidth
        curIslandOffset = islandOffset
        // Re-hit-test against the cursor's current spot: the front pill shifting (its
        // own text changing) moves the cards, so a card shouldn't stay revealed under a
        // cursor it's no longer beneath, even if the mouse itself hasn't moved.
        updateHover()
    }

    /// Hit-test the mouse against the back-card slivers and update the hovered card.
    /// Runs on the main thread (NSEvent monitors fire there).
    private func updateHover() {
        if paused { return }                          // no hover reveals while paused
        let p = NSEvent.mouseLocation                 // screen coords, origin bottom-left
        let f = panel.frame
        let s = IslandState.shared

        // Hidden-idle regime: nothing is live, so the panel is normally off-screen. Hovering
        // the notch for ~2s reveals a resting "Idle" pill; moving away hides it again.
        if hiddenIdle {
            let inZone = pointInNotchZone(p)
            if idlePeekShown {
                let overIsland = pointInIslandHitArea(p)
                panel.ignoresMouseEvents = !overIsland
                if s.idleSessionCount >= 1 {
                    // Revealed "{n} idle sessions" pill. Hovering the literal notch peeks the
                    // token-usage stats; hovering the count text drops the roster list. Idle is a
                    // hidden regime, so once the cursor leaves the notch + pill (dropdown closed)
                    // the pill tucks back away — it isn't a persistent fixture.
                    let overNotch = !s.dropdownOpen && (pointInNotchRegion(p) || (s.notchPeek && pointInUsagePeekArea(p)))
                    if s.notchPeek != overNotch {
                        s.notchPeek = overNotch
                        if overNotch { refreshUsage() }   // freshen the usage rollup on demand
                    }
                    updateHoveredDay(p)
                    if s.frontHovered != overNotch { setFrontHover(overNotch) }   // stats strip on notch hover only
                    if !s.dropdownOpen {
                        if pointInFrontPillRight(p) && !overNotch { openDropdown() }
                    } else if !overIsland {
                        closeDropdown()
                    }
                    updateRowHover(p: p, f: panel.frame)
                    if !inZone && !overIsland && !s.dropdownOpen { hideIdlePeek() }
                    return
                }
                // No idle sessions either — the bare "Idle" pill. Still peek the token-usage
                // stats on the literal notch, same as every other state.
                let overNotch = pointInNotchRegion(p) || (s.notchPeek && pointInUsagePeekArea(p))
                if s.notchPeek != overNotch {
                    s.notchPeek = overNotch
                    if overNotch { refreshUsage() }
                }
                updateHoveredDay(p)
                if s.frontHovered != overNotch { setFrontHover(overNotch) }
                // No idle sessions: the transient "Idle" peek hides once you leave it.
                let keep = inZone || overIsland
                if !keep && !s.dropdownOpen { hideIdlePeek() }
            } else if inZone {
                showIdleHint()   // immediate pulsing hint; expands to full after the dwell
            }
            return
        }
        cancelIdleDwell()   // left the idle regime — drop any pending dwell

        // Capture clicks only while the cursor is over the island; otherwise stay
        // transparent so the menu bar / status items underneath remain clickable.
        let overIsland = pointInIslandHitArea(p)
        panel.ignoresMouseEvents = !overIsland

        // On the aggregate pill, each count is its own hover target: hovering a count opens the
        // dropdown filtered to that bucket (hover "1 done" → just the done sessions; the left
        // headline → its bucket, e.g. needs-input → the attention list, at any count). The list
        // re-filters live as the cursor moves between counts.
        let bucket = hoveredAggBucket(p)

        // Hovering the literal notch (center) peeks "Happy Clauding" — takes priority over the
        // single-session title peek (which lives on the text to either side of the notch).
        // Hysteresis: the literal notch OPENS the peek; once open, staying anywhere in the
        // expanded strip HOLDS it so the cursor can reach the day cells (and their captions).
        let overNotch = !s.dropdownOpen && (pointInNotchRegion(p) || (s.notchPeek && pointInUsagePeekArea(p)))
        if s.notchPeek != overNotch {
            s.notchPeek = overNotch
            if overNotch { refreshUsage() }   // freshen the token-usage peek on demand (60s-throttled)
        }
        updateHoveredDay(p)

        // Front-pill peek: the notch peek, or a single (non-aggregate) session's title on
        // hover. The aggregate never title-peeks — every count routes to the dropdown instead.
        // Idle never title-peeks either — there's no title/preview to show (peekText is forced
        // empty), so hovering the resting icon must not expand a strip with nothing in it; only
        // the notch itself still peeks (the usage stats), same as every other mode.
        // A single session's "Input Needed" cluster is a dropdown target too (`bucket`), so it
        // must not peek on the way there — otherwise the strip flashes open for the one frame
        // before the dropdown replaces it.
        let front = !s.dropdownOpen
            && (overNotch || (!s.aggregate && s.mode != .idle && bucket == nil && pointInFrontPill(p)))
        if s.frontHovered != front { setFrontHover(front) }
        // Run the marquee clock only while the session-message peek is up (not the static
        // notch peek) — it's a real run-loop timer, so don't leave it spinning idle.
        if front && !overNotch { MarqueeClock.shared.start() } else { MarqueeClock.shared.stop() }

        // Dropdown mode: hover-driven open/close. The "{n} ⌄" peek opens the full list; an
        // aggregate count opens the list filtered to its bucket. Moving the cursor off the
        // expanded sheet closes it. (SwiftUI's onHover never fires in this non-key panel, so
        // we drive it from the monitor.) Once open, `overIsland` covers the whole sheet.
        if s.uiMode == "dropdown" {
            if s.roster.count >= 1 {
                if !s.dropdownOpen {
                    if pointInBackPillPeek(p) {
                        s.dropdownFilter = ""
                        openDropdown()
                    } else if let b = bucket {
                        s.dropdownFilter = b
                        openDropdown()
                    } else if s.mode == .idle && s.neutralNotIdle && pointInFrontPillRight(p) && !overNotch {
                        // The dismissed-neutral "{n} sessions" pill has no "{n} ⌄" back-peek
                        // (suppressed for .idle mode, same as the hidden-idle pill) — hovering
                        // the pill itself opens the dropdown directly instead.
                        s.dropdownFilter = ""
                        openDropdown()
                    }
                } else if !overIsland {
                    closeDropdown()
                } else if pointInBackPillPeek(p) {
                    // Already open: hovering the "{n} ⌄" peek switches back to the full list.
                    if !s.dropdownFilter.isEmpty { s.dropdownFilter = ""; refilterOpenDropdown() }
                } else if let b = hoveredAggBucket(p), b != s.dropdownFilter {
                    // Already open: sliding onto a different count re-filters the list in place
                    // (the live reactivity — no close/reopen). Over the rows, bucket is nil, so
                    // the current filter holds while you interact with them.
                    s.dropdownFilter = b
                    refilterOpenDropdown()
                }
            }
            updateRowHover(p: p, f: f)
            return
        }

        let cards = s.cards
        let cur = s.hoveredCard
        // Only when the cursor is within the island's strip; otherwise no hover.
        guard p.x >= f.minX, p.x <= f.maxX, p.y >= f.minY, p.y <= f.maxY, !cards.isEmpty else {
            if cur != nil { setHover(nil) }
            return
        }
        // The hosting view fills the panel and the ZStack is centered, so the pill's
        // center sits at the panel's horizontal center + islandOffset.
        let pillLeft = f.midX + curIslandOffset - curPillWidth / 2
        // Keep the current card hovered while the cursor is within its EXPANDED rect, so
        // moving onto the revealed title doesn't drop the hover.
        if let cur, let i = cards.firstIndex(where: { $0.id == cur }) {
            let w = cardWidth(cards[i], idx: i)
            if p.x >= pillLeft + kCardTuck - w, p.x <= pillLeft + kCardTuck { return }
        }
        // Otherwise pick the collapsed sliver the cursor is over (each is kCardPeek wide
        // and they abut, so there's no overlap to flicker between).
        for (idx, card) in cards.enumerated() {
            let sLeft = pillLeft - CGFloat(idx + 1) * kCardPeek
            let sRight = pillLeft - CGFloat(idx) * kCardPeek
            if p.x >= sLeft, p.x < sRight {
                if cur != card.id { setHover(card.id) }
                return
            }
        }
        if cur != nil { setHover(nil) }
    }

    /// True if a screen point falls within the island's clickable region (the pill, its
    /// "{n} ⌄" right peek, and the expanded sheet when open). Used by the hosting view to
    /// pass every other click through to the menu bar. A few px of margin so edge taps land.
    func pointInIslandHitArea(_ p: NSPoint) -> Bool {
        let s = IslandState.shared
        let f = panel.frame
        let islandH = max(s.notchHeight, 30)
        let center = f.midX + curIslandOffset          // pill center on screen
        let m: CGFloat = 4
        let left = center - curPillWidth / 2
        var right = center + curPillWidth / 2
        var bottom = f.maxY - islandH
        let top = f.maxY
        if s.roster.count >= 1 && s.mode != .idle { right += kAgentsPeek }  // "{n} ⌄" back pill peeks right
        if s.frontHovered && !s.dropdownOpen { bottom -= kFrontPeek }  // peek strip stays clickable
        if s.dropdownOpen {
            right = left + curPillWidth + sheetSide     // sheet grows right…
            bottom = f.maxY - (islandH + dropdownContentHeight(s.dropdownItems) + kDropdownVPad + kDropdownBottomPad)  // …and down
        }
        return p.x >= left - m && p.x <= right + m && p.y >= bottom - m && p.y <= top
    }

    // MARK: - Idle peek (hover the hidden notch ~2s to reveal a resting pill)

    /// The hover target while the island is hidden: the notch itself plus a little margin,
    /// in screen coords. Independent of the panel frame so it works while ordered out.
    private func pointInNotchZone(_ p: NSPoint) -> Bool {
        let screen = notchScreen()
        let s = IslandState.shared
        let nw = max(s.notchWidth, 140)
        let margin: CGFloat = 40
        let cx = screen.frame.midX
        let top = screen.frame.maxY
        let bottom = top - max(s.notchHeight, 24)
        return p.x >= cx - nw / 2 - margin && p.x <= cx + nw / 2 + margin && p.y >= bottom && p.y <= top
    }

    /// Deterministic idle-pill geometry for the given left/right labels — mirrors the view's
    /// own width math so hit-testing is correct the instant we reveal (before the view's
    /// onChange reports back). Returns (pillWidth, islandOffset).
    private func idleGeom(primary: String, right: String) -> (CGFloat, CGFloat) {
        let serif = NSFont(name: kSerifFontName, size: 13) ?? .systemFont(ofSize: 13)
        let sans  = NSFont(name: kSansFontName, size: 13) ?? .systemFont(ofSize: 13)
        let leadingSlot: CGFloat = 18 + (primary.isEmpty ? 0 : 8)
        let leftW  = leadingSlot + textWidth(primary, serif, tracking: 0.5)
        let rightW = 3 + textWidth(right, sans)
        let pill = leftW + IslandState.shared.notchWidth + 80 + rightW + 36
        return (pill, (rightW - leftW) / 2)
    }

    /// Enter the idle regime. Two flavors:
    ///  • ≥2 idle/stale sessions → a PERSISTENT "{n} idle sessions" pill that stays in the
    ///    notch at rest (the count is always visible); hovering it drops the roster list.
    ///  • 0–1 sessions → nothing worth a resting pill, so order the panel out; a notch hover
    ///    still peeks a plain "Idle". Either way we shape the view into its .idle form first
    ///    (final width, no stale frame) so any later reveal/grow is clean.
    private func enterHiddenIdle(idleCount: Int) {
        hiddenIdle = true
        stopLivePoll()   // nothing to poll while dark
        let s = IslandState.shared
        s.idleSessionCount = idleCount
        s.aggregate = false
        s.detail = ""
        s.preview = ""
        s.title = "Claude Code"
        s.lastUserMsg = ""        // drop the prior session's message so the peek strip never shows it
        s.idleHint = false
        s.mode = .idle

        // Idle is a HIDDEN regime: the island leaves the notch entirely regardless of how many
        // tabs remain idle/stale — no persistent pill. A notch hover (1s dwell) re-reveals a
        // resting pill: plain "Idle", or the "{n} idle sessions" list when tabs remain. Keep the
        // roster in that case so the reveal can drop the list; only the no-session peek wipes it.
        if idleCount == 0 { s.cards = []; s.roster = [] }

        // Don't yank a peek the user is actively hovering: if the resting pill is already
        // revealed, hold it up (just refresh width/count) — a routine rebuild mustn't tear it
        // down out from under the cursor. It hides on its own once the cursor leaves.
        if idlePeekShown {
            (curPillWidth, curIslandOffset) = idleGeom(primary: "", right: idleRightLabel())
            return
        }
        s.idleReveal = 0          // collapsed; springs to 1 on the hover-reveal
        (curPillWidth, curIslandOffset) = idleGeom(primary: "", right: idleRightLabel())
        panel.orderOut(nil)
        maybeShowFirstRunHint()   // first idle after install → teach the hover, once
    }

    private var firstRunHintChecked = false
    /// The first time the island goes idle after install, briefly reveal the resting pill with a
    /// "hover to summon me" note in the peek strip — so the hover affordance is discoverable
    /// instead of the notch just going dark. Shown once, then a flag file suppresses it forever.
    private func maybeShowFirstRunHint() {
        guard !firstRunHintChecked else { return }
        firstRunHintChecked = true
        let flag = kEventDir + "/.onboarded"
        if FileManager.default.fileExists(atPath: flag) { return }
        let s = IslandState.shared
        s.firstRunHint = true
        showIdleHint()            // orders the pill front + reveals it
        cancelIdleDwell()         // skip the hint→settle dwell; go straight to the full pill
        s.idleHint = false
        s.notchPeek = true        // select the usage-peek slot (firstRunHint swaps in the teach copy)
        setFrontHover(true)       // grow the peek strip so the copy has room
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self else { return }
            let s = IslandState.shared
            s.firstRunHint = false   // clear BEFORE hiding so the hideIdlePeek guard lets it tear down
            s.notchPeek = false
            self.setFrontHover(false)
            self.hideIdlePeek()
            try? "1\n".write(toFile: flag, atomically: true, encoding: .utf8)
        }
    }

    /// The idle pill's right-side label — mirrors IslandView's `.idle` rightText case.
    private func idleRightLabel() -> String { idleSessionsLabel(IslandState.shared.idleSessionCount) }

    /// Stage 1: the moment the cursor lands on the hidden notch, pop a small pulsing
    /// paused-icon pill (immediate "I see you" feedback), then expand to the full resting
    /// pill after a short dwell.
    private func showIdleHint() {
        idlePeekShown = true
        let s = IslandState.shared
        s.aggregate = false
        s.dropdownOpen = false
        s.frontHovered = false
        // Keep the roster (+ rows) when there's a "{n} idle sessions" list to drop on hover
        // (incl. a single idle tab → "1 idle session"); only wipe in the no-list resting "Idle".
        if s.idleSessionCount == 0 {
            s.cards = []
            s.roster = []
        }
        s.detail = ""
        s.preview = ""
        s.title = "Claude Code"
        s.lastUserMsg = ""
        s.idleHint = true
        s.idleReveal = 0        // start collapsed…
        s.mode = .idle
        // Width is CONSTANT (labels never change) — no width jank, no text flash.
        (curPillWidth, curIslandOffset) = idleGeom(primary: "", right: idleRightLabel())
        position()
        panel.orderFrontRegardless()
        refreshLiveness(force: true)   // refresh idle/exited tabs while the user is looking
        // …then spring open on the next tick, so the .animation(value:) catches the 0→1 change
        // and plays the bouncy entrance.
        DispatchQueue.main.async { IslandState.shared.idleReveal = 1 }
        idleHoverTimer?.invalidate()
        let t = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.expandIdlePeek()
        }
        RunLoop.main.add(t, forMode: .common)
        idleHoverTimer = t
    }

    /// Stage 2: after the 1s dwell, settle the breathing icon to a steady mark (only if still
    /// hovered). No geometry change — same width as the hint.
    private func expandIdlePeek() {
        idleHoverTimer = nil
        guard hiddenIdle, idlePeekShown else { return }
        let m = NSEvent.mouseLocation
        guard pointInNotchZone(m) || pointInIslandHitArea(m) else { hideIdlePeek(); return }
        IslandState.shared.idleHint = false
    }

    private func cancelIdleDwell() {
        idleHoverTimer?.invalidate()
        idleHoverTimer = nil
    }

    private func hideIdlePeek() {
        // The first-run teaching peek holds itself up for its full window regardless of the
        // cursor; it clears firstRunHint before hiding, so this guard only blocks mid-show.
        if IslandState.shared.firstRunHint { return }
        idlePeekShown = false
        cancelIdleDwell()
        IslandState.shared.idleHint = false
        IslandState.shared.idleReveal = 0
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
    }

    /// True if a screen point falls within the "{n} ⌄" peek band — the strip just right
    /// of the front pill where the back-pill indicator sits. This is the hover-open
    /// trigger (deliberately the peek only, so hovering the front ticker never opens the
    /// menu). Geometry mirrors the right edge used by `pointInIslandHitArea`.
    private func pointInBackPillPeek(_ p: NSPoint) -> Bool {
        let s = IslandState.shared
        guard s.roster.count >= 1 else { return false }
        let f = panel.frame
        let islandH = max(s.notchHeight, 30)
        let pillRight = f.midX + curIslandOffset + curPillWidth / 2
        let m: CGFloat = 4
        return p.x >= pillRight - m && p.x <= pillRight + kAgentsPeek + m
            && p.y >= f.maxY - islandH && p.y <= f.maxY
    }

    /// True if a screen point falls within the front pill — the trigger for the title
    /// peek. Once the peek is showing, the live region extends down by kFrontPeek so the
    /// cursor moving onto the revealed title strip holds it open (hysteresis, no flicker).
    private func pointInFrontPill(_ p: NSPoint) -> Bool {
        let s = IslandState.shared
        let f = panel.frame
        let islandH = max(s.notchHeight, 30)
        let center = f.midX + curIslandOffset
        let left = center - curPillWidth / 2
        let right = center + curPillWidth / 2
        let bottom = f.maxY - islandH - (s.frontHovered ? kFrontPeek : 0)
        return p.x >= left && p.x <= right && p.y >= bottom && p.y <= f.maxY
    }

    /// The idle pill's right side ONLY — the actual "{n} sessions" / "{n} idle sessions" text,
    /// nothing before it. Hovering that text opens the dropdown; hovering the icon, or the
    /// physical notch cutout + its clearance sitting between the icon and the text, must not
    /// (both are just resting/peek territory). `island`'s HStack has an outer
    /// `.padding(.horizontal, 18)` before the icon even starts, THEN the 18pt icon slot
    /// (`leadingSlot`, no verb text next to it in .idle), THEN the notch gap itself
    /// (`notchWidth + notchClearance`, per `pillWidth`/`islandOffset`) before the text run
    /// begins — all three have to be skipped, not just the first two (that was the bug: the
    /// dropdown was opening just from hovering the notch to reveal the pill, since skipping
    /// only the icon still landed inside the notch gap, not yet at the text).
    private func pointInFrontPillRight(_ p: NSPoint) -> Bool {
        let s = IslandState.shared
        let f = panel.frame
        let islandH = max(s.notchHeight, 30)
        let center = f.midX + curIslandOffset
        let outerPadding: CGFloat = 18
        let leadingSlot: CGFloat = 18
        let notchGap: CGFloat = s.notchWidth + 80   // notchClearance, mirrors IslandView.pillWidth
        let left = center - curPillWidth / 2 + outerPadding + leadingSlot + notchGap
        let right = center + curPillWidth / 2
        let bottom = f.maxY - islandH - (s.frontHovered ? kFrontPeek : 0)
        return p.x >= left && p.x <= right && p.y >= bottom && p.y <= f.maxY
    }

    /// True over the literal notch — its own width, centered on the screen (the physical
    /// notch sits at the panel's horizontal center regardless of the pill's offset). Drives
    /// the "Happy Clauding" peek; extends down with the peek strip so the hover holds.
    private func pointInNotchRegion(_ p: NSPoint) -> Bool {
        let s = IslandState.shared
        let f = panel.frame
        // The literal notch strip only — its original (un-expanded) height, even while the
        // peek below it is showing. Otherwise hovering anywhere in the expanded peek area,
        // including its bottom edge, would count as "on the notch" and swap the title/preview
        // peek for the session-limit one.
        let islandH = max(s.notchHeight, 30)
        let halfW = max(s.notchWidth, 120) / 2
        let bottom = f.maxY - islandH
        return abs(p.x - f.midX) <= halfW && p.y >= bottom && p.y <= f.maxY
    }

    /// The expanded usage-peek strip below the notch (the text + activity strip + caption).
    /// Used only to HOLD an already-open notch peek while the cursor drops onto it, so the
    /// user can reach the day cells — it never opens the peek (that's the literal notch only).
    private func pointInUsagePeekArea(_ p: NSPoint) -> Bool {
        let s = IslandState.shared
        let f = panel.frame
        let islandH = max(s.notchHeight, 30)
        let center = f.midX + curIslandOffset
        let top = f.maxY - islandH
        let bottom = top - kFrontPeek
        return abs(p.x - center) <= curPillWidth / 2 && p.y >= bottom && p.y <= top
    }

    /// Hit-test the cursor's x against the centered activity-strip cells and publish the
    /// hovered day (-1 when off the cells). The cell row is centered under the pill, so its
    /// geometry mirrors ActivityStrip's fixed cell/gap sizes.
    private func updateHoveredDay(_ p: NSPoint) {
        let s = IslandState.shared
        guard s.notchPeek, !s.usageDays.isEmpty, pointInUsagePeekArea(p) else {
            if s.hoveredDay != -1 { s.hoveredDay = -1 }
            return
        }
        let f = panel.frame
        let center = f.midX + curIslandOffset
        let n = s.usageDays.count
        let cell: CGFloat = 11, pitch: CGFloat = 11 + 2.5
        let stripW = CGFloat(n) * cell + CGFloat(n - 1) * (pitch - cell)
        let rel = p.x - (center - stripW / 2)
        let idx = Int(rel / pitch)
        let hd = (rel >= 0 && idx >= 0 && idx < n) ? idx : -1
        if s.hoveredDay != hd { s.hoveredDay = hd }
    }

    // ── Aggregate hit-testing: which count the cursor is over ─────────────────────
    // Mirrors IslandView's pill layout (same fonts, strings, widths) so the hover regions
    // line up with the drawn text. KEEP IN SYNC with IslandView's aggKind / aggHeadline /
    // aggParts / leadingSlot if those change.
    private func distinctProjects() -> Int {
        Set(IslandState.shared.roster.map { $0.project }.filter { !$0.isEmpty }).count
    }
    private func aggHeadlineBucket() -> String {
        let s = IslandState.shared
        if s.needYouCount > 0 { return "attention" }
        if s.runningCount > 0 { return "running" }
        if s.doneCount    > 0 { return "done" }
        return "error"
    }
    private func aggHeadlineText() -> String {
        let s = IslandState.shared
        switch aggHeadlineBucket() {
        case "attention": return s.needYouCount == 1 ? "1 agent needs input" : "\(s.needYouCount) agents need input"
        case "running":   return "\(s.runningCount) running…"
        case "done":      return "\(s.doneCount) done"
        default:          return "\(s.errorCount) error"
        }
    }
    // Trailing counts as (text, bucket), in the order IslandView draws them. The hint
    // ("in N dirs" / "Hover to See") carries the headline bucket, so the whole single-bucket
    // pill resolves to that one bucket.
    private func aggRightParts() -> [(text: String, bucket: String)] {
        let s = IslandState.shared
        let head = aggHeadlineBucket()
        var parts: [(String, String)] = []
        if head != "running", s.runningCount > 0 { parts.append(("\(s.runningCount) running", "running")) }
        if head != "done",    s.doneCount    > 0 { parts.append(("\(s.doneCount) done", "done")) }
        if head != "error",   s.errorCount   > 0 { parts.append(("\(s.errorCount) error", "error")) }
        if parts.isEmpty {
            let d = distinctProjects()
            parts.append((d > 1 ? "in \(d) dirs" : "Hover to See", head))
        }
        return parts
    }
    /// The status bucket under the cursor on the pill's status text, or nil. On the aggregate
    /// pill: left cluster (icon + headline) → headline bucket; each right count → its own
    /// bucket. On the SINGLE-session pill only an "input needed" left cluster is a target — it
    /// opens the same input-needed dropdown the fleet headline does, so one waiting agent shows
    /// its question exactly like five do; every other single mode keeps the left cluster as a
    /// plain title-peek.
    private func hoveredAggBucket(_ p: NSPoint) -> String? {
        let s = IslandState.shared
        guard s.aggregate || s.mode == .attention else { return nil }
        let f = panel.frame
        let islandH = max(s.notchHeight, 30)
        let bottom = f.maxY - islandH - (s.frontHovered ? kFrontPeek : 0)
        guard p.y >= bottom, p.y <= f.maxY else { return nil }
        let center = f.midX + curIslandOffset
        let left  = center - curPillWidth / 2
        let right = center + curPillWidth / 2
        let serif = NSFont(name: kSerifFontName, size: 13) ?? .systemFont(ofSize: 13)
        let sans  = NSFont(name: kSansFontName, size: 13) ?? .systemFont(ofSize: 13)

        // Left cluster: [left+18, left+18+leftW]; leftW = leadingSlot + headline width. The
        // single pill's verb is `detail` ("Input Needed"), drawn in the same 14pt "!" slot.
        let head = s.aggregate ? aggHeadlineBucket() : "attention"
        let iconW: CGFloat = head == "attention" ? 14 : (head == "error" ? 16 : 18)
        let primary = s.aggregate ? aggHeadlineText() : s.detail
        let leftW = iconW + (primary.isEmpty ? 0 : 8) + textWidth(primary, serif, tracking: 0.5)
        if p.x >= left + 18, p.x <= left + 18 + leftW { return head }
        // Single pill: only that left cluster routes to the dropdown — its right side is the
        // question preview, not a count, so it stays a peek target.
        guard s.aggregate else { return nil }

        // Right cluster: text is trailing-aligned, ending 18 in from the pill's right edge.
        let parts = aggRightParts()
        let rightText = parts.map { $0.text }.joined(separator: " · ")
        let textStart = (right - 18) - textWidth(rightText, sans)
        guard p.x >= textStart, p.x <= right - 18 else { return nil }
        let sepW = textWidth(" · ", sans)
        var x = textStart
        for (i, part) in parts.enumerated() {
            let segEnd = x + textWidth(part.text, sans) + (i < parts.count - 1 ? sepW : 0)
            if p.x <= segEnd { return part.bucket }
            x = segEnd
        }
        return parts.last?.bucket
    }

    private static func bucketModes(_ bucket: String) -> Set<String> {
        switch bucket {
        case "running":   return ["working", "thinking", "compacting", "struggling"]
        case "attention": return ["attention"]
        case "done":      return ["done", "declined", "interrupted", "compacted"]
        case "error":     return ["error"]
        default:          return []
        }
    }
    /// The dropdown roster narrowed to the active filter bucket (empty filter = the full list).
    private func filteredRoster() -> [SessionCard] {
        let s = IslandState.shared
        guard !s.dropdownFilter.isEmpty else { return s.roster }
        let modes = Self.bucketModes(s.dropdownFilter)
        return s.roster.filter { modes.contains($0.status) }
    }
    private func rebuildDropdownItems() {
        let s = IslandState.shared
        let roster = filteredRoster()
        // Input-needed view: each waiting session leads with its TAB NAME as the header (even
        // for a single one), then a row carrying the ask ("Input Needed" + the question). The
        // tab name lives in the header, so the row omits it (titleInHeader).
        if s.dropdownFilter == "attention" {
            var items: [DropdownItem] = []
            for c in roster {
                let name = c.title.isEmpty ? c.project : c.title
                items.append(DropdownItem(id: "hdr:\(c.id)", header: name, card: nil))
                items.append(DropdownItem(id: c.id, header: nil, card: c, titleInHeader: true))
            }
            s.dropdownItems = items
            return
        }
        s.dropdownItems = Self.groupRoster(roster, order: projectOrder)
    }
    /// Re-filter an already-open dropdown when the cursor moves to a different count, so the
    /// list reacts live (no close/reopen). Repopulates the rows and resizes the sheet.
    private func refilterOpenDropdown() {
        rebuildDropdownItems()
        position()
    }

    /// Close the open dropdown when a click lands outside the expanded sheet's bounds.
    private func dismissDropdownIfOutside(_ p: NSPoint) {
        let s = IslandState.shared
        guard s.dropdownOpen else { return }
        let f = panel.frame
        let islandH = max(s.notchHeight, 30)
        // Same silhouette the sheet is drawn at: flush-left with the pill, extending
        // kSheetSide right and the row stack + paddings down from the notch top.
        let leftEdge = f.midX + curIslandOffset - curPillWidth / 2
        let rightEdge = leftEdge + curPillWidth + sheetSide
        let sheetH = islandH + dropdownContentHeight(s.dropdownItems) + kDropdownVPad + kDropdownBottomPad
        let inside = p.x >= leftEdge && p.x <= rightEdge && p.y <= f.maxY && p.y >= f.maxY - sheetH
        if !inside { closeDropdown() }
    }

    /// Hit-test the cursor against the open dropdown's rows (walking the item stack, since
    /// project headers are shorter than rows and only a row should register a hover).
    private func updateRowHover(p: NSPoint, f: NSRect) {
        let s = IslandState.shared
        let items = s.dropdownItems
        guard s.dropdownOpen, !items.isEmpty else {
            if s.hoveredRow != nil { s.hoveredRow = nil }
            if s.hoveredGroup != nil { s.hoveredGroup = nil }
            if s.hoveredRing != nil { s.hoveredRing = nil }
            return
        }
        let islandH = max(s.notchHeight, 30)
        // Rows fill the sheet, whose left edge is flush with the pill and which extends
        // kSheetSide to the right. Screen coords have origin bottom-left, so items go DOWN.
        let leftEdge = f.midX + curIslandOffset - curPillWidth / 2
        let rightEdge = leftEdge + curPillWidth + sheetSide
        let listRight = rightEdge - kRowInset       // rows are inset kRowInset inside the sheet
        let contentTop = f.maxY - islandH - kDropdownVPad
        guard p.x >= leftEdge, p.x <= rightEdge, p.y <= contentTop, p.y >= contentTop - dropdownContentHeight(items) else {
            if s.hoveredRow != nil { setRow(nil) }
            if s.hoveredGroup != nil { s.hoveredGroup = nil }
            if s.hoveredRing != nil { s.hoveredRing = nil }
            return
        }
        var y = contentTop
        for item in items {
            let h = item.isHeader ? kHeaderHeight : kRowHeight
            if p.y <= y, p.y > y - h {
                let id = item.card?.id            // nil over a header → clears the ROW hover
                if s.hoveredRow != id { setRow(id) }
                // Group hover lights the matching header's branch — set whether the cursor is on
                // a row OR its header, so the highlight is robust to row/header hit-test drift.
                let grp = item.isHeader ? String(item.id.dropFirst(4)) : item.card?.groupKey   // "hdr:" == 4
                if s.hoveredGroup != grp { s.hoveredGroup = grp }
                // Mirror dropdownRow's trailing HStack (spacing 4) right-to-left: trailing pad
                // (12), [timer], [4, "·"], 4, then the pill (6px pad, percent text, 4px gap,
                // 12px ring, 6px pad) — to locate the badge's actual band (it sits well left of
                // the timer, not flush against it).
                let overRing: Bool = item.card.map { card in
                    guard ringVisible(card) else { return false }
                    // This row is under the cursor, so it's the hovered row — the same `hl`
                    // that gates the 30–50% (amber) tier into view in dropdownRow. Compacting
                    // rows never draw the badge (see showContext), so never hit-test one either.
                    guard card.status != "compacting", card.context >= 0.30 else { return false }
                    let timerOnLeft = (card.status == "done" || card.status == "stale") && !card.elapsed.isEmpty
                    let timerW = (!card.elapsed.isEmpty && !timerOnLeft) ? textWidth(card.elapsed, kTimerFont) : 0
                    let dotW = (!card.elapsed.isEmpty && !timerOnLeft) ? textWidth("·", kTimerFont) : 0
                    let percentStr = "\(Int((card.context * 100).rounded()))% context"
                    let percentW = textWidth(percentStr, kTimerFont)
                    let pillPad: CGFloat = 6
                    var pillRight = listRight - 12
                    if timerW > 0 { pillRight -= timerW + 4 }
                    if dotW > 0 { pillRight -= dotW + 4 }
                    let pillLeft = pillRight - pillPad - percentW - 4 - 12 - pillPad
                    return p.x >= pillLeft && p.x <= pillRight
                } ?? false
                let ringID = overRing ? id : nil
                if s.hoveredRing != ringID { s.hoveredRing = ringID }
                return
            }
            y -= h
        }
        if s.hoveredRow != nil { setRow(nil) }
        if s.hoveredGroup != nil { s.hoveredGroup = nil }
        if s.hoveredRing != nil { s.hoveredRing = nil }
    }

    private func setRow(_ id: String?) {
        withAnimation(.easeOut(duration: 0.1)) { IslandState.shared.hoveredRow = id }
    }

    private func setHover(_ id: String?) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            IslandState.shared.hoveredCard = id
        }
    }

    private func setFrontHover(_ on: Bool) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.64)) {
            IslandState.shared.frontHovered = on
        }
    }

    private func livenessInterval() -> Double {
        let s = IslandState.shared
        if s.dropdownOpen || idlePeekShown { return kLivenessInspectIntervalS }
        if hiddenIdle { return kLivenessHiddenIntervalS }
        return kLivenessActiveIntervalS
    }

    private func liveTabGrace() -> Double {
        (IslandState.shared.dropdownOpen || idlePeekShown) ? kLiveTabGraceInspectS : kLiveTabGraceDefaultS
    }

    /// Run the expensive process scan + transcript checks on a background queue,
    /// then apply the results (prune dead/canceled sessions, rebuild) on main.
    private func refreshLiveness(force: Bool = false) {
        // The timer ticks once/sec, but the real scan cadence is state-aware: snappy while a
        // roster is visible, moderate while the island is visible, slow when fully hidden. Forced
        // scans (new file, dropdown open, idle reveal) skip the cadence gate.
        let now = Date().timeIntervalSince1970
        if livenessScanning {
            if force { pendingLivenessForce = true }
            return
        }
        if !force && now - lastLivenessScanTs < livenessInterval() { return }
        livenessScanning = true
        lastLivenessScanTs = now
        let hidden = hiddenIdle
        // Any mid-turn session (thinking/working) or a pending question (attention) can be
        // Esc'd — an interrupt fires no Stop hook, so the transcript's "Request interrupted by
        // user" marker is the only signal the turn was abandoned. We carry the session's mode
        // so the apply step can verify it hasn't changed since (a fresh prompt landing right
        // after the Esc must win over a stale declined flip).
        let active = sessions
            .filter { $0.value.mode == "thinking" || $0.value.mode == "working" || $0.value.mode == "attention" }
            .map { ($0.key, $0.value.mode, $0.value.transcript) }
        let scanMode = Dictionary(active.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        // Every session's transcript, so a /rename (which fires no hook) is picked up here
        // within a scan cycle instead of waiting for that tab's next activity.
        let titleScan = sessions.compactMap { $0.value.transcript.isEmpty ? nil : ($0.key, $0.value.transcript) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let cc = self.ccSessionInfos()
            let live = self.computeLiveTabs(cc)
            let warpTab = hidden ? nil : self.warpActiveTab()   // skip Warp's sqlite read when hidden (no UI)
            // CC's own busy/idle read — unlike pollLiveStatus (which only ever flips to
            // "interrupted" once CC itself reports idle), this scan otherwise trusts the
            // transcript tail alone. A mid-turn interrupt-and-resume (Esc, or answering a
            // question) writes the "Request interrupted by user" marker before the resumed
            // real content streams back in, so a thinking/working session can transiently
            // read as abandoned while CC is still actively computing the resume. Cross-check
            // busy status here too so this periodic backstop can't flip an actually-busy
            // session — the sub-second poll already owns that transition correctly.
            let statuses = self.ccSessionStatuses(cc)
            var interrupted = Set<String>()
            var declinedPreview: [String: String] = [:]
            for (uuid, mode, tx) in active where !tx.isEmpty {
                if mode != "attention" {
                    let sessionId = ((tx as NSString).lastPathComponent as NSString).deletingPathExtension
                    if statuses[sessionId] == "busy" { continue }
                }
                let signals = self.transcriptSignals(tx)
                if signals.interrupted {
                    interrupted.insert(uuid)
                    // The agent's response so far, shown in white on the declined row.
                    if let p = signals.activity?.preview, !p.isEmpty { declinedPreview[uuid] = p }
                }
            }
            var titles: [String: String] = [:]
            for (uuid, tx) in titleScan {
                if let t = self.transcriptTitle(tx), !t.isEmpty { titles[uuid] = t }
            }
            // Idle tabs have no island state file, so they aren't in `titleScan`. Resolve
            // their ai-title straight from the transcript (via the tab's sessionId) so the
            // row shows the session's name instead of falling back to the bare dirname.
            for (uuid, sid) in live.sids where titles[uuid] == nil {
                if let tx = self.transcriptForSession(sid), let t = self.transcriptTitle(tx), !t.isEmpty {
                    titles[uuid] = t
                }
            }
            DispatchQueue.main.async {
                defer {
                    self.livenessScanning = false
                    if self.pendingLivenessForce {
                        self.pendingLivenessForce = false
                        self.refreshLiveness(force: true)
                    }
                }
                let now = Date().timeIntervalSince1970
                self.applyDBActiveTab(warpTab)
                // Apply any renamed titles (manual /rename wins over the auto ai-title).
                for (u, t) in titles where self.sessions[u]?.aiTitle != t {
                    self.sessions[u]?.aiTitle = t
                    self.liveTabTitle[u] = t
                }
                for (u, c) in live.cwds {
                    self.lastSeenLive[u] = now
                    if !c.isEmpty { self.liveTabCwd[u] = c }
                }
                for (u, f) in live.focuses { self.liveTabFocus[u] = f }
                // A tab counts as live if a recent scan saw it — long enough in the background
                // to smooth a transient ps miss, shorter while the roster is visible so exited
                // sessions disappear quickly.
                let grace = self.liveTabGrace()
                self.liveTabs = Set(self.lastSeenLive.filter { now - $0.value < grace }.keys)
                self.liveTabs.insert("local")
                // Only canceled turns delete a file; dead tabs are just hidden by the
                // liveTabs filter (their file lingers harmlessly until they reappear).
                for k in interrupted {
                    guard let s = self.sessions[k] else { continue }
                    // Skip if a new turn landed since the scan (mode changed) — that fresh
                    // prompt's thinking/working state must win over a stale terminal flip.
                    guard s.mode == scanMode[k] else { continue }
                    // An Esc'd turn isn't a dead card to hide — it's a decision the user made.
                    // A waved-off question reads as "declined"; a halted thinking/working turn
                    // as "interrupted". Either keeps the agent's response so far. Persist so the
                    // next reload() (which re-reads the file) doesn't resurrect the stale mode.
                    let terminal = scanMode[k] == "attention" ? "declined" : "interrupted"
                    // A declined row shows the question the user waved off (its text, else the
                    // short header); an interrupted row shows the agent's response so far.
                    let text = terminal == "declined"
                        ? (!s.qText.isEmpty ? s.qText : (!s.qHeader.isEmpty ? s.qHeader : (declinedPreview[k] ?? "")))
                        : (declinedPreview[k] ?? "")
                    s.mode = terminal
                    s.ts = now
                    s.qHeader = ""
                    s.qText = ""
                    if !text.isEmpty { s.preview = text }
                    self.persistTerminal(k, mode: terminal, preview: text)
                }
                self.rebuild()
            }
        }
    }

    /// Size and pin the panel to the top-center of the notch screen.
    @objc func position() {
        let screen = notchScreen()
        let nh = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top
                                               : (NSApp.mainMenu?.menuBarHeight ?? 32)
        IslandState.shared.notchHeight = nh
        IslandState.shared.notchWidth = notchWidth(screen)

        // Only as tall as the menu-bar strip (never blocks clicks below it), and
        // wide enough that an expanded card never hits the panel bound and clips,
        // but not so wide it covers the app menus / status items. When the dropdown is
        // open the panel grows down to make room for the menu (transparent elsewhere, so
        // clicks outside the menu still pass through to the apps below).
        let w: CGFloat = 1100
        let s = IslandState.shared
        let dropH = s.dropdownOpen ? dropdownContentHeight(s.dropdownItems) + kDropdownVPad + kDropdownBottomPad : 0
        // Always reserve room for the front-pill hover peek so its expand/collapse animates
        // smoothly inside a transparent panel (no resize-on-hover that would clip the spring).
        // The reserve covers the taller usage peek + its floating day tooltip; the extra height
        // is transparent and click-through, so it costs nothing when idle.
        let h: CGFloat = max(nh, 30) + 2 + max(dropH, kUsagePeekReserve)
        let x = screen.frame.midX - w / 2
        let y = screen.frame.maxY - h
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    /// Open the dropdown menu (idempotent) and resize the panel to fit it. Driven by
    /// hovering the "{n} ⌄" peek; a tap on the peek also calls this as a fallback. It
    /// never closes — closing is purely hover-leave (or a click outside the sheet) — so a
    /// tap while the cursor still rests on the peek can't toggle it shut and reopen.
    func openDropdown() {
        let s = IslandState.shared
        guard !s.dropdownOpen else { return }
        s.dropdownOpen = true
        refreshActiveTab()   // freshest active-tab highlight on open
        // Lock the current row order on open so timers/activity can't reshuffle rows under
        // the cursor; release it on close so the list re-sorts by recency again.
        dropdownFrozenOrder = s.roster.map { $0.id }
        rebuild()            // populate subagent rows immediately on open
        refreshLiveness(force: true)   // opening is explicit inspection; don't wait for timer/backoff
        position()
        // Subagents don't fire hooks, so neither the file-watch nor the mid-turn clock
        // refreshes them. Drive a 1s tick of our own while the menu is open.
        dropdownTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshElapsed() }
        RunLoop.main.add(t, forMode: .common)
        dropdownTimer = t
    }
    func closeDropdown() {
        guard IslandState.shared.dropdownOpen else { return }
        IslandState.shared.dropdownOpen = false
        IslandState.shared.dropdownFilter = ""   // back to the full list next open
        dropdownFrozenOrder = nil
        dropdownTimer?.invalidate()
        dropdownTimer = nil
        position()
    }

    // MARK: - Session ingest

    /// Re-read every session file (a Darwin ping means one just changed) and rebuild.
    /// The files are the source of truth: a session whose file is gone is dropped,
    /// even if its tab is still live.
    func reload() {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: kSessionsDir)) ?? []).filter { $0.hasSuffix(".json") }
        let existing = Set(files.map { ($0 as NSString).deletingPathExtension })
        let freshIds = existing.subtracting(knownSessionIds)   // brand-new session files this reload
        knownSessionIds = existing
        for k in sessions.keys where !existing.contains(k) { sessions.removeValue(forKey: k) }
        for f in files {
            guard let data = fm.contents(atPath: kSessionsDir + "/" + f),
                  let sf = try? JSONDecoder().decode(SessionFile.self, from: data) else { continue }
            merge(sf, fallbackID: (f as NSString).deletingPathExtension)
        }
        rebuild()
        // A brand-new tab's first event lands before the (possibly backed-off) liveness scan has
        // it in liveTabs, so it'd be filtered from the deck. Kick one immediate scan so it shows
        // at once — fires only when a genuinely new file appears, not on every event.
        if !freshIds.isEmpty { refreshLiveness(force: true) }
    }

    /// Merge one event into a session, retaining fields the event omitted.
    private func merge(_ sf: SessionFile, fallbackID: String) {
        let id = sf.id ?? fallbackID
        let s = sessions[id] ?? LiveSession()
        sessions[id] = s
        if let v = sf.mode {
            s.mode = v
            // A dismissed "Finished" pill un-dismisses the moment this session does anything
            // new (a fresh turn, a permission ask, etc.) — the click only silenced that one
            // completion, not this session forever.
            if !["done", "declined", "interrupted", "compacted"].contains(v) { dismissedDoneIds.remove(id) }
        }
        if let v = sf.detail { s.detail = v }
        if let v = sf.preview { s.preview = v }   // omitted by emit_keep → retained
        if let v = sf.flashPri { s.flashPri = v }
        if let v = sf.flashKey { s.flashKey = v }
        if let v = sf.finishKey { s.finishKey = v }
        if let v = sf.firstPrompt, !v.isEmpty { s.firstPrompt = v }
        if let v = sf.lastPrompt, !v.isEmpty { s.lastUserMsg = v }
        // Question carried by an AskUserQuestion pause. Present (incl. "") on every full emit
        // so a normal turn clears it; omitted by emit_keep so a follow-up Notification retains.
        if let v = sf.qHeader { s.qHeader = v }
        if let v = sf.qText { s.qText = v }
        if let v = sf.ultra { s.ultra = v }
        if let v = sf.project { s.project = v }
        if let v = sf.aiTitle, !v.isEmpty { s.aiTitle = v }
        // Remember the label (title, else project) so a later idle entry for this tab —
        // after its file is deleted/interrupted — shows the title, not just the dir.
        let label = s.aiTitle.isEmpty ? s.project : s.aiTitle
        if !label.isEmpty { liveTabTitle[id] = label }
        if let v = sf.context { s.context = v; if v > 0 { liveTabContext[id] = v } }
        // Compaction shrank the window: drop the remembered fill so a later idle entry
        // for this tab doesn't resurrect the stale pre-compaction ring.
        if s.mode == "compacted" { liveTabContext[id] = 0 }
        if let v = sf.focus { s.focus = v }
        if let v = sf.cwd { s.cwd = v }
        // Ghostty sessions written before AppleScript focus existed (or with cwd unknown at the
        // time) carry the generic app: descriptor. We know the cwd here, so upgrade to a
        // working-directory match — click then focuses the exact tab without needing a re-emit.
        if s.focus == "app:com.mitchellh.ghostty", !s.cwd.isEmpty { s.focus = "ghostty:\(s.cwd)" }
        // Same for VS Code / Cursor sessions written before CLI window-focus existed.
        if s.focus.hasPrefix("app:"), !s.cwd.isEmpty, (id.hasPrefix("cursor-") || id.hasPrefix("vscode-")) {
            s.focus = "editor:\(s.focus.dropFirst(4)):\(s.cwd)"
        }
        if let v = sf.transcript { s.transcript = v }
        if let v = sf.ts { s.ts = v }
        if s.mode == "done" {
            if s.finishKey.isEmpty { s.finishKey = fallbackFinishKey(id, s) }
            if s.ts > 0, s.ts < appStartTs { shownFinishKeys.insert(s.finishKey) }
        }
        if sf.kind == "prompt" {                  // a new turn the user just started
            s.promptTs = sf.ts ?? s.promptTs
            s.turnStartTs = sf.ts ?? s.turnStartTs
            clickFocus = nil                      // a fresh prompt takes focus
        }
    }

    private func fallbackActivityKey(_ session: LiveSession, preview: String, priority: Int) -> String {
        let norm = normalizedFlashText(preview)
        let scope = session.transcript.isEmpty ? "" : session.transcript + "\n"
        return "fallback:\(priority):\(stableKeyHash(scope + norm))"
    }

    private func activityFlashKey(_ session: LiveSession, preview: String, priority: Int) -> String {
        if !session.flashKey.isEmpty { return session.flashKey }
        return fallbackActivityKey(session, preview: preview, priority: priority)
    }

    private func fallbackFinishKey(_ id: String, _ session: LiveSession) -> String {
        if !session.flashKey.isEmpty, session.flashKey.hasPrefix("text:") {
            return "finish:\(session.flashKey)"
        }
        let scope = session.transcript.isEmpty ? id : session.transcript
        return "finish:\(stableKeyHash(scope + "\n" + normalizedFlashText(session.preview)))"
    }

    private func finishFlashKey(_ id: String, _ session: LiveSession) -> String {
        if !session.finishKey.isEmpty { return session.finishKey }
        return fallbackFinishKey(id, session)
    }

    // MARK: - Rebuild the deck

    // Visible = sessions that have actually run (have a file) and whose tab is still
    // live. Open-but-never-run tabs have no session here, so they never appear.
    private func visibleSessions(suppressing suppress: Set<String>) -> [String: LiveSession] {
        // liveTabs comes from a pgrep for `claude`, so it can only ever vouch for Claude Code.
        // Codex Desktop runs every chat inside one shared `codex app-server` process, so there's
        // no per-session process to find — codex-watch.py decides liveness from rollout mtime
        // instead and owns these files' whole lifecycle (it deletes them when a chat goes cold,
        // and the daemon prunes any session whose file vanished). So trust the file's existence.
        sessions.filter { (k, _) in
            let codexShown = showCodex && k.hasPrefix("cdex-")   // gated by the menu-bar toggle
            return (liveTabs.contains(k) || k == "local" || codexShown) && !suppress.contains(k)
        }
    }

    /// Tab UUIDs to hide as duplicates: the same Claude conversation (identical transcript)
    /// can be surfaced under more than one Warp tab UUID — e.g. the tab/pane was recreated, or
    /// the session was resumed elsewhere — leaving a stale state file behind. Keep only the
    /// freshest (highest ts) per transcript; suppress the rest from the deck and front pill.
    private func staleDuplicateTabs() -> Set<String> {
        var best: [String: (key: String, ts: Double)] = [:]   // transcript → freshest tab
        for (k, v) in sessions where !v.transcript.isEmpty {
            if let cur = best[v.transcript], cur.ts >= v.ts { continue }
            best[v.transcript] = (k, v.ts)
        }
        let keep = Set(best.values.map { $0.key })
        return Set(sessions.filter { !$0.value.transcript.isEmpty && !keep.contains($0.key) }.map { $0.key })
    }

    private func rebuild() {
        if paused { panel.orderOut(nil); return }   // Pause: stay dark until resumed
        IslandState.shared.neutralNotIdle = false   // only the dismissed-front branch below sets this
        let suppress = staleDuplicateTabs()
        let vis = visibleSessions(suppressing: suppress)
        guard !vis.isEmpty else {
            frontUUID = nil
            stopClock()
            // No state-file session is live — but Warp tabs running claude with no file (idle,
            // or file cleared) may still be open. Surface them as "{n} idle sessions" + a hover
            // list, exactly like stale ones, instead of collapsing to a bare "Idle".
            let s = IslandState.shared
            let idleTabIds = liveTabs.filter { $0 != "local" && !suppress.contains($0) }
            let idleCwds = Set(idleTabIds.compactMap { liveTabCwd[$0] }.filter { !$0.isEmpty })
            refreshGitInfo(idleCwds)
            let idleCards = idleTabIds
                .sorted()
                .map { u -> SessionCard in
                    let cwd = liveTabCwd[u] ?? ""
                    let proj = cwd.isEmpty ? "Claude Code" : (cwd as NSString).lastPathComponent
                    let label = liveTabTitle[u] ?? ""
                    let g = self.gitGroup(cwd, proj)
                    var card = SessionCard(id: u, project: proj, title: label.isEmpty ? proj : label,
                                           status: "idle", focus: liveTabFocus[u] ?? "warp://session/\(u)",
                                           context: liveTabContext[u] ?? 0)
                    card.repo = g.repo; card.branch = g.branch
                    card.files = g.files; card.added = g.added; card.removed = g.removed
                    return card
                }
            if s.dropdownOpen {
                let rank = Dictionary(s.roster.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
                s.roster = idleCards.sorted {
                    let ra = rank[$0.id] ?? Int.max, rb = rank[$1.id] ?? Int.max
                    return ra != rb ? ra < rb : $0.id < $1.id
                }
                rebuildDropdownItems()
            } else {
                s.cards = Array(idleCards.dropFirst().prefix(5))
                s.roster = idleCards
                rebuildDropdownItems()
            }
            enterHiddenIdle(idleCount: s.roster.count)
            return
        }

        // Probe git context (repo/branch/churn) for the visible cwds — drives the dropdown's
        // repo/branch grouping + header churn. No-op unless the dropdown is open (throttled).
        var gitCwds = Set(vis.values.map(\.cwd).filter { !$0.isEmpty })
        gitCwds.formUnion(liveTabCwd.values.filter { !$0.isEmpty })
        refreshGitInfo(gitCwds)

        // Front pill: a clicked tab wins (pinned until the next prompt), else the most
        // recently prompted, else the most recent activity. All candidates have really
        // run, so the front pill is always a genuine activity state — never a bare tab.
        // A click pins the front, but only until a DIFFERENT tab posts newer activity than
        // existed at click time — then the genuinely-live tab reclaims the front (otherwise
        // a stale pinned session, e.g. one stuck "Waiting for input", hides the active one).
        // Exactly one running session and nothing waiting on you → that running tab becomes
        // the front, so the pill shows its full live activity (verb / preview / live timer)
        // even if a different tab finished more recently. Watching the one thing that's
        // working beats narrating counts. The live timer follows frontUUID, so making it the
        // front is what keeps that timer ticking on the running tab.
        // A done-family session whose background delegate (a Task/subagent it spun up) is still
        // live keeps reading as "working": the parent's Stop fired, but the subagent outlives the
        // turn and fires no hooks of its own. Checked only for finished sessions (cheap, few of
        // them) and NOT written back into the stored model — so when the delegate's transcript
        // ages out past kSubagentFreshS this self-heals to the real "done" with its final message.
        let doneFamily: Set<String> = ["done", "declined", "interrupted", "compacted"]
        let delegating = Set(vis.filter { doneFamily.contains($0.value.mode) && liveSubagentCount($0.value) > 0 }.map(\.key))
        let runModes: Set<String> = ["working", "thinking", "compacting", "struggling"]
        func effMode(_ k: String, _ v: LiveSession) -> String { delegating.contains(k) ? "working" : v.mode }
        func isRunning(_ k: String, _ v: LiveSession) -> Bool { runModes.contains(effMode(k, v)) }

        // Dismissed "Finished" pills (clicked away) are ineligible to be re-fronted — fall
        // back to the full `vis` for the selection math ONLY when every candidate has been
        // dismissed (`allFrontsDismissed`), purely so the calls below have something to pick
        // from; the actual displayed mode gets overridden to the neutral pill further down.
        let frontVis = vis.filter { !dismissedDoneIds.contains($0.key) }
        let allFrontsDismissed = frontVis.isEmpty
        let selectionVis = allFrontsDismissed ? vis : frontVis

        let runningKeys = selectionVis.filter { isRunning($0.key, $0.value) }.map(\.key)
        let needYouLive = selectionVis.contains { $0.value.mode == "attention" }
        let focusedRunning = runningKeys.count == 1 && !needYouLive

        let now = Date().timeIntervalSince1970
        let newestTs = vis.values.map { $0.ts }.max() ?? 0
        if let c = clickFocus, selectionVis[c] == nil || newestTs > clickFocusTs {
            clickFocus = nil
        }
        // Remember the lone running tab so its completion can keep the single pill.
        if focusedRunning { lastSingleFocus = runningKeys[0] }
        // The lone session we were watching just finished and nothing else is running or waiting
        // → keep IT fronted as a single "Finished" pill (the most recent thing that happened),
        // instead of flipping to a "{n} done" aggregate. Releases once another tab runs, a newer
        // completion lands elsewhere, or this one goes stale (>15 min).
        let focusedDone: Bool = {
            guard !focusedRunning, !needYouLive, runningKeys.isEmpty,
                  let k = lastSingleFocus, let v = selectionVis[k],
                  doneFamily.contains(v.mode), now - v.ts <= 900 else { return false }
            return v.ts >= newestTs
        }()

        let front: String
        if focusedRunning {
            front = runningKeys[0]
        } else if focusedDone {
            front = lastSingleFocus!
        } else if let c = clickFocus, selectionVis[c] != nil {
            front = c
        } else {
            // Headline-matched front: the count pill announces a single bucket (need-you >
            // running > done > error). Front the freshest tab in that same bucket, so the
            // hover-peek names — and a click focuses — a tab the headline is actually about,
            // not whatever merely posted activity most recently. With several running and
            // nothing waiting, that's the most recently active running tab (the dropdown
            // still lists them all).
            let buckets: [(String, LiveSession) -> Bool] = [
                { _, v in v.mode == "attention" },
                { k, v in isRunning(k, v) },
                { k, v in doneFamily.contains(effMode(k, v)) },
                { _, v in v.mode == "error" },
            ]
            func freshest(_ pred: (String, LiveSession) -> Bool) -> String? {
                selectionVis.filter { pred($0.key, $0.value) }
                   .max(by: { ($0.value.promptTs, $0.value.ts) < ($1.value.promptTs, $1.value.ts) })?.key
            }
            front = buckets.lazy.compactMap(freshest).first
                ?? selectionVis.max(by: { ($0.value.promptTs, $0.value.ts) < ($1.value.promptTs, $1.value.ts) })?.key
                ?? selectionVis.keys.sorted().first!
        }
        // Captured before frontUUID/state.mode below are overwritten — lets the finish-flash
        // trigger further down tell "just arrived at done" apart from "still sitting at done".
        let prevFrontUUID = frontUUID
        let prevMode = IslandState.shared.mode

        frontUUID = front
        let f = vis[front]!
        // A delegating front shows live "Delegating…" rather than its parked done state.
        let frontMode = effMode(front, f)
        let frontDetail = delegating.contains(front) && f.detail.isEmpty ? "Delegating…" : f.detail

        let state = IslandState.shared
        // declined has no Mode case (it's a dropdown-only flavor of "finished"); the front
        // single pill treats it like done.
        state.mode = IslandState.Mode(rawValue: frontMode) ?? (["declined", "interrupted"].contains(frontMode) ? .done : .working)
        state.detail = frontDetail
        state.ultra = f.ultra
        state.preview = f.preview
        state.project = f.project
        // The front session's AI title (its directory name if it hasn't earned one yet),
        // surfaced by the on-hover front-pill peek.
        state.title = f.aiTitle.isEmpty ? f.project : f.aiTitle
        state.lastUserMsg = f.lastUserMsg
        state.contextPct = sessionContext(f)
        state.focusURL = f.focus

        // Every visible session has had its "Finished" pill dismissed (clicked away) and
        // nothing else is running/waiting — reset to a neutral "icon + count" pill instead of
        // re-fronting the same dismissed session. This stays visible (unlike the hidden-idle
        // regime); the roster/dropdown built below still lists every session normally.
        if allFrontsDismissed {
            state.mode = .idle
            state.neutralNotIdle = true
            state.idleSessionCount = vis.count
            state.detail = ""
            state.preview = ""
            state.lastUserMsg = ""
            state.title = "Claude Code"
        }

        // Back cards: the other live sessions, most-recent first. The uuid breaks ties
        // deterministically so equal-timestamp cards keep a STABLE order — otherwise the
        // dictionary's random iteration order reshuffles them every rebuild (the
        // "carousel" rotation). A done card stays green for 15 min, then greys (stale).
        // Highlighted dropdown row = the tab currently focused in Warp (from Warp's DB),
        // falling back to the front session when unknown. Highlight only — never re-fronts.
        let selected = (activeWarpTab.flatMap { liveTabs.contains($0) ? $0 : nil }) ?? front
        // The selected session's group is the resting "expanded" header (full churn, white) when
        // nothing is hovered — so exactly one header always carries the detail.
        let selKey = vis[selected] != nil ? selected : front
        if let sv = vis[selKey] {
            let g = gitGroup(sv.cwd, sv.project)
            state.selectedGroup = g.branch.isEmpty ? g.repo : g.repo + "/" + g.branch
            state.selectedId = selKey
        } else { state.selectedGroup = nil; state.selectedId = nil }
        func makeCard(_ k: String, _ v: LiveSession) -> SessionCard {
            // Effective mode: a finished session with a still-live delegate reads as "working".
            let em = effMode(k, v)
            // A finished session (done/declined/interrupted/compacted) greys to "stale" after 15 min.
            let status = (doneFamily.contains(em) && now - v.ts > 900) ? "stale" : em
            // Show a turn timer for active (working/thinking) and finished (done/stale)
            // sessions; formatElapsed ticks live for active and freezes at ts for done.
            let showTimer = ["working", "thinking", "done", "struggling"].contains(em) || status == "stale"
            let verb = delegating.contains(k) && v.detail.isEmpty ? "Delegating…" : v.detail
            var card = SessionCard(id: k, project: v.project,
                               title: v.aiTitle.isEmpty ? v.project : v.aiTitle,
                               status: status, verb: verb, focus: v.focus, isSelected: k == selected,
                               elapsed: showTimer ? formatElapsed(v) : "",
                               context: self.sessionContext(v),
                               preview: v.preview, firstPrompt: v.firstPrompt,
                               qHeader: v.qHeader, qText: v.qText)
            card.lastUserMsg = v.lastUserMsg
            card.ultra = v.ultra
            card.flashPri = v.flashPri
            // Git context for repo/branch grouping + header churn (cache lookup; bg-probed).
            let g = self.gitGroup(v.cwd, v.project)
            card.repo = g.repo; card.branch = g.branch
            card.files = g.files; card.added = g.added; card.removed = g.removed
            // Only count the subagents/ tree while the dropdown is open (keeps the disk reads
            // off the hot path otherwise). Not gated on the parent's mode: background/async
            // delegates can outlive the parent's turn, so count any that are still live.
            if state.dropdownOpen { card.subagentCount = self.liveSubagentCount(v) }
            return card
        }
        // Idle live tabs: a Warp tab running claude that hasn't written a state file
        // (never emitted, or its file was cleared). Surface a neutral entry so the deck
        // and the "{n} ⌄" counter reflect ALL live tabs — but never the front pill
        // (front is chosen from `vis` only). ts stays 0 so they sort to the bottom.
        var idle: [String: LiveSession] = [:]
        for u in liveTabs where u != "local" && vis[u] == nil && !suppress.contains(u) {
            let s = LiveSession()
            s.mode = "idle"
            s.focus = liveTabFocus[u] ?? "warp://session/\(u)"
            let cwd = liveTabCwd[u] ?? ""
            s.cwd = cwd
            s.project = cwd.isEmpty ? "Claude Code" : (cwd as NSString).lastPathComponent
            // Prefer the tab's last-known session title over its directory name.
            s.aiTitle = liveTabTitle[u] ?? ""
            s.context = liveTabContext[u] ?? 0   // last-known fill, so the ring persists
            idle[u] = s
        }
        let all = vis.merging(idle) { a, _ in a }

        var ordered = all.sorted { ($0.value.ts, $0.key) > ($1.value.ts, $1.key) }
        // While the dropdown is open, hold the row order it had on open (new sessions append
        // by recency) so ticking timers / new activity never slide a row under the cursor.
        if state.dropdownOpen, let frozen = dropdownFrozenOrder {
            let rank = Dictionary(frozen.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            ordered.sort { a, b in
                let ra = rank[a.key] ?? Int.max, rb = rank[b.key] ?? Int.max
                return ra != rb ? ra < rb : (a.value.ts, a.key) > (b.value.ts, b.key)
            }
        }
        state.cards = ordered.filter { $0.key != front }.prefix(5).map { makeCard($0.key, $0.value) }
        // dropdown roster: every live tab (front + others + idle), most-recent first.
        state.roster = ordered.map { makeCard($0.key, $0.value) }
        // Tag rows with their terminal-app icon only when the roster actually spans ≥2 apps —
        // otherwise the icon is redundant (everything's in the same terminal) and just noise.
        state.showTermIcons = Set(state.roster.compactMap { terminalBundleId(focus: $0.focus, id: $0.id) }).count >= 2

        // Dropdown group order = the order projects were FIRST SEEN by the daemon, persisted
        // to disk so it reflects when each tab was first opened and survives restarts. A new
        // project is appended (oldest stays on top, new tabs land at the bottom) and never
        // reshuffles afterward. A batch first seen together is tie-broken by ascending ts.
        let projFirstTs = Dictionary(grouping: all.values, by: { sess -> String in
            let g = self.gitGroup(sess.cwd, sess.project)
            return g.branch.isEmpty ? g.repo : g.repo + "/" + g.branch
        }).mapValues { $0.map(\.ts).min() ?? 0 }
        var orderGrew = false
        for proj in projFirstTs.keys.sorted(by: { (projFirstTs[$0]!, $0) < (projFirstTs[$1]!, $1) })
        where !projectOrder.contains(proj) { projectOrder.append(proj); orderGrew = true }
        if orderGrew { try? projectOrder.joined(separator: "\n").write(toFile: kProjectOrderFile, atomically: true, encoding: .utf8) }
        rebuildDropdownItems()

        if state.mode == .done {
            state.elapsed = formatElapsed(f)        // frozen total
        }
        // The 1s clock runs while ANY visible session is mid-turn, so every active row's
        // timer in the dropdown ticks live — not just the front pill's.
        // Delegating sessions (parent done, subagent still live) count as active too — otherwise
        // the clock/poll stops and the overlay never re-evaluates when the delegate finishes.
        // A freshly-compacted session also counts, but only for a short grace window: CC's own
        // "away summary" recap (read by transcriptSignals) lands a little after the compact
        // finishes, not synchronously with it, so the poll needs to keep checking for a bit —
        // but NOT forever, or an old untouched "Compacted" row would wake the CPU repeatedly
        // indefinitely just waiting for a recap that already came (or is never coming).
        let anyActive = vis.contains {
            $0.value.mode == "working" || $0.value.mode == "thinking" || delegating.contains($0.key)
                || ($0.value.mode == "compacted" && now - $0.value.ts < 300)
        }
        // The 1s timer and the sub-second live poll both run ONLY while a turn is active.
        if anyActive { startClock(); startLivePoll() } else { stopClock(); stopLivePoll() }

        // Fleet reducer: tally the roster into the buckets the front pill and (later) the
        // dropdown headers both read. The roster's `status` already bakes in the 15-min
        // done→stale rule, so `done` here is "finished within 15 min"; stale/idle count
        // toward nothing. "Need you" is ATTENTION ONLY — a session waiting on your input,
        // the one thing you can act on. An errored turn is terminal and not actionable, so
        // it gets its own bucket and never reads as "need you". Aggregate kicks in once ≥2
        // sessions have actually run.
        let running = state.roster.filter { ["working", "thinking", "compacting", "struggling"].contains($0.status) }.count
        let needYou = state.roster.filter { $0.status == "attention" }.count
        let done = state.roster.filter { ["done", "declined", "interrupted", "compacted"].contains($0.status) }.count
        let errored = state.roster.filter { $0.status == "error" }.count
        state.runningCount = running
        state.needYouCount = needYou
        state.doneCount = done
        state.errorCount = errored
        // ≥2 sessions that have run → count aggregate, UNLESS a single running tab has claimed
        // the front for its full live activity (then show that, not the counts).
        state.aggregate = !allFrontsDismissed && !focusedRunning && !focusedDone && (running + needYou + done + errored) >= 2
        if state.aggregate {
            for (id, session) in vis where doneFamily.contains(effMode(id, session)) && !session.preview.isEmpty {
                shownFinishKeys.insert(finishFlashKey(id, session))
            }
        }

        // A single front session just landed at "done" (not merely still sitting there from a
        // prior rebuild) → tell the view to (re)start its finish-flash (see `FinishFlash`) by
        // setting this to a fresh value; the view's `.onChange` does the rest and nils it back
        // out itself once the flash hands off to the tab name. Cleared here the instant it no
        // longer applies (front moved on, or this session started a new turn) so the NEXT fresh
        // "done" for the very same session — same uuid string — still reads as a value change.
        // NOTE: don't wrap these in withTransaction(animation: nil) — this runs synchronously
        // inside openDropdown() (dropdownOpen=true; rebuild()), and forcing a "no animation"
        // transaction here suppressed the dropdown's OWN open animation too (both land in the
        // same update pass), making the whole island snap open instead of springing.
        let finishIdentity = finishFlashKey(front, f)
        if state.mode == .done, !state.preview.isEmpty {
            if state.aggregate {
                shownFinishKeys.insert(finishIdentity)
                state.justFinishedID = nil
            } else if !shownFinishKeys.contains(finishIdentity),
                      (front != prevFrontUUID || prevMode != .done) {
                shownFinishKeys.insert(finishIdentity)
                state.justFinishedID = finishIdentity
            }
        } else if state.mode != .done || state.aggregate {
            state.justFinishedID = nil
        }

        // A working front session's latest preview is "flash-worthy" when flashPri ≥ 1 — either
        // Claude's own prose (2) or a notable action like Write/Edit/Bash/Fetch/Task (1); routine
        // reads/greps (0) never flash. Flash it in the right slot the same way justFinishedID
        // flashes the done reply, with a priority-aware DWELL so it reads instead of flickering:
        //   • the item on screen is protected for its dwell — a full kFlashHoldS (~7s, time to
        //     read) before a lower-priority tool label can replace prose, a short kToolDwellS
        //     (~1.2s) for a tool label so a burst of rapid tool calls coalesces into one instead
        //     of stuttering;
        //   • newer prose can refresh older prose after kProseRefreshS, so the island does not
        //     feel stuck narrating stale commentary while still blocking the old 1ms tool stomp;
        //   • a strictly-higher-priority item cuts in immediately — a comment (2) still wins over
        //     a showing tool label (1) at once ("commentary wins"); past the dwell, anything newer
        //     takes over. Because each rebuild re-evaluates the CURRENT preview, a suppressed
        //     burst still converges to the latest value once the dwell passes (never "2 behind").
        // The message shown is captured HERE (commentaryMessage), not re-read when the flash
        // starts — see that field for why. The identity is the transcript activity key, not
        // the display string, so hook/poll preview-length differences cannot re-flash it.
        let flashPri = f.flashPri
        let flashIdentity = activityFlashKey(f, preview: state.preview, priority: flashPri)
        let commentaryKey = flashIdentity
        let alreadyShown = shownFlashKeys.contains(flashIdentity)
        let held = now - lastFlashStartTs
        let dwell = lastFlashPriority >= 2 ? kFlashHoldS : kToolDwellS
        let proseRefresh = flashPri >= 2 && lastFlashPriority >= 2 && held >= kProseRefreshS
        let replaceAfter = (flashPri >= 2 && lastFlashPriority >= 2) ? kProseRefreshS : dwell
        let canReplace = flashPri > lastFlashPriority || proseRefresh || held >= dwell
        if state.mode == .working, !state.aggregate, flashPri >= 1, !state.preview.isEmpty,
           commentaryKey != lastCommentaryKey, !alreadyShown, canReplace {
            logDecision("TRIGGER pri=\(flashPri) lastPri=\(lastFlashPriority) held=\(String(format: "%.2f", held)) key=\(flashIdentity.prefix(32)) front=\(front.prefix(6)) '\(state.preview.prefix(28))'")
            shownFlashKeys.insert(flashIdentity)
            lastCommentaryKey = commentaryKey
            lastFlashStartTs = now
            lastFlashPriority = flashPri
            state.commentaryMessage = state.preview
            state.freshCommentaryID = commentaryKey
        } else if state.mode != .working || state.aggregate {
            if state.freshCommentaryID != nil || lastFlashPriority != 0 {
                logDecision("RESET mode=\(state.mode) agg=\(state.aggregate) front=\(front.prefix(6))")
            }
            state.freshCommentaryID = nil
            lastCommentaryKey = ""   // left "working" entirely — next spell starts fresh, even
            lastFlashPriority = 0    // if its first flash text/priority happens to repeat
            lastFlashStartTs = 0
        } else if state.mode == .working, flashPri >= 1, !state.preview.isEmpty,
                  commentaryKey != lastCommentaryKey, !alreadyShown {
            // Flash-worthy & fresh, but the current item's dwell hasn't passed — log why held back.
            logDecision("SUPPRESS pri=\(flashPri) lastPri=\(lastFlashPriority) held=\(String(format: "%.2f", held))/\(String(format: "%.1f", replaceAfter)) key=\(flashIdentity.prefix(32)) front=\(front.prefix(6)) '\(state.preview.prefix(28))'")
        }

        // Nothing live, waiting, or errored (all stale / idle) → hide the island entirely.
        if running + needYou + done + errored == 0 {
            // Genuinely nothing left (even the dismissed session has gone stale) — this is the
            // real idle regime, not the dismissed-neutral one, so it always reads "idle
            // sessions" regardless of the override above.
            state.neutralNotIdle = false
            if state.dropdownOpen {
                // The idle pill's dropdown is open: hold the "{n} idle sessions" presentation
                // (don't flip to a stale front pill or tear the panel down) and refresh the
                // roster/count in place. hiddenIdle stays true — we never left the regime.
                state.mode = .idle
                state.aggregate = false
                state.idleSessionCount = state.roster.count
                hiddenIdle = true
                position()
                return
            }
            enterHiddenIdle(idleCount: state.roster.count)
            return
        }

        // Real content takes over: leave the hidden-idle regime and drop any idle peek.
        hiddenIdle = false
        idlePeekShown = false
        state.idleHint = false
        state.idleReveal = 1
        cancelIdleDwell()
        position()
        panel.orderFrontRegardless()
    }

    // MARK: - Process scan (liveness + forked filter) — runs on a background queue

    private struct CCSessionInfo {
        var sessionId = ""
        var cwd = ""
        var status = ""
    }

    /// Which Warp tabs still have a live, interactive (non-forked) CC process. Used only
    /// to GC sessions whose tab closed. Pure IO, safe off the main thread.
    /// Live (non-forked) terminal tabs running claude, mapped to each tab's working directory
    /// from Claude's session file (env dump only as fallback) so idle tabs can still be labelled
    /// by project name.
    private func computeLiveTabs(_ ccInfos: [String: CCSessionInfo]? = nil) -> (cwds: [String: String], sids: [String: String], focuses: [String: String]) {
        // Anchored so "claude" must be a whole path/word component (start/end or flanked by
        // "/" or a space) — a bare substring match would also catch unrelated long-running
        // processes like a "claudeisland-slack-bot" dev server, permanently pinning whatever
        // terminal tab launched it as "live" and resurrecting its last-known session as a
        // stale card that never ages out.
        let pids = shell("/usr/bin/pgrep", ["-U", "\(getuid())", "-f", "(^|[/ ])claude([/ ]|$)"])
            .split(separator: "\n").map(String.init)
        var cwds = [String: String](), sids = [String: String](), focuses = [String: String]()
        var excluded = Set<String>()
        guard !pids.isEmpty else { return (cwds, sids, focuses) }
        let cc = ccInfos ?? ccSessionInfos()
        // ONE `ps eww` for the whole pid LIST (env dumps inline per row). A pid list isn't
        // truncated the way `ps -axeww` is, so we keep the full env — but use it ONLY for terminal
        // identity. Claude's own ~/.claude/sessions/<pid>.json is the source of truth for cwd /
        // sessionId/status, which avoids brittle env parsing (especially paths with spaces).
        let dump = shell("/bin/ps", ["eww", "-o", "pid=,tty=,command=", "-p", pids.joined(separator: ",")])
        for raw in dump.split(separator: "\n") {
            let line = String(raw)
            // Layout: "<pid> <tty> <command…> <ENV…>". Take pid + tty off the front; the rest
            // (command + inlined env) is searched as a substring, so we hand tabIdentity the whole line.
            let head = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard head.count >= 2 else { continue }
            let pid = String(head[0]); let tty = String(head[1])
            let info = cc[pid]
            let cwdFromSession = info?.cwd ?? ""
            let cwd = cwdFromSession.isEmpty ? envCwdIn(line) : cwdFromSession
            guard let ident = tabIdentity(line, tty: tty, cwd: cwd, sessionId: info?.sessionId ?? "") else { continue }
            let u = ident.key
            if cwds[u] == nil { cwds[u] = cwd }
            if focuses[u] == nil { focuses[u] = ident.focus }
            if sids[u] == nil, let sid = info?.sessionId, !sid.isEmpty { sids[u] = sid }
            // Forked sub-sessions and dedicated computer-use sessions are hidden. But the desktop
            // app grants mcp__computer-use in --allowedTools to EVERY chat, so that string alone
            // over-excludes real desktop sessions — skip the computer-use test for them (a genuine
            // forked desktop sub-session still carries --fork-session and stays hidden).
            let isDesktop = line.contains("CLAUDE_CODE_ENTRYPOINT=claude-desktop")
            if line.contains("--fork-session") || (line.contains("mcp__computer-use") && !isDesktop) {
                excluded.insert(u)   // forked / computer-use session — hide it
            }
        }
        for u in excluded { cwds.removeValue(forKey: u); sids.removeValue(forKey: u); focuses.removeValue(forKey: u) }
        return (cwds, sids, focuses)
    }

    /// Transcript path for a CC sessionId, found by globbing the per-project dirs (the dir
    /// name encodes the cwd, but the sessionId is globally unique so we don't need to
    /// reconstruct that encoding). Lets an idle tab recover its ai-title. Safe off-main.
    private func transcriptForSession(_ sid: String) -> String? {
        let base = NSString("~/.claude/projects").expandingTildeInPath
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        for d in dirs {
            let p = base + "/" + d + "/" + sid + ".jsonl"
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    // Fallback only: pull " PWD=…" out of the env dump (leading space avoids matching OLDPWD=).
    // Stops at the next space, so paths with spaces clip; computeLiveTabs prefers CC's own cwd.
    private func envCwdIn(_ s: String) -> String {
        guard let r = s.range(of: " PWD=") else { return "" }
        return String(s[r.upperBound...].prefix { $0 != " " })
    }

    private struct TranscriptSignals {
        var activity: (preview: String, verb: String, thinking: Bool, flashPri: Int, flashKey: String)?
        var interrupted = false
        var apiError: String?
        var awaySummary: String?
    }

    private func contentText(_ content: Any?) -> String {
        if let str = content as? String { return str }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: " ")
        }
        return ""
    }

    private func realUserText(_ content: Any?) -> String {
        let text = contentText(content).split { $0.isWhitespace || $0.isNewline }.joined(separator: " ")
        guard !text.isEmpty else { return "" }
        let skipPrefixes = ["<command-", "<local-command", "<system-reminder", "<task-notification",
                            "Caveat:", "[Request interrupted"]
        if skipPrefixes.contains(where: { text.hasPrefix($0) }) { return "" }
        let skipContains = ["</tool-use-id>", "<tool-use-id>", "<output-file>", "<task-id>", "<task-notification"]
        if skipContains.contains(where: { text.contains($0) }) { return "" }
        return text
    }

    private func hasRealAssistantContent(_ content: [[String: Any]]) -> Bool {
        content.contains { b in
            switch b["type"] as? String {
            case "tool_use", "thinking": return true
            case "text": return !(((b["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            default: return false
            }
        }
    }

    /// One transcript-tail pass for all live signals. This keeps the sub-second poll cheap and
    /// makes interruption/API-error/activity decisions agree on the same recent transcript view.
    /// File IO, safe off the main thread.
    private func transcriptSignals(_ path: String) -> TranscriptSignals {
        var signals = TranscriptSignals()
        guard let fh = FileHandle(forReadingAtPath: path) else { return signals }
        defer { try? fh.close() }
        let size = fh.seekToEndOfFile()
        fh.seek(toFileOffset: size > 32_768 ? size - 32_768 : 0)
        guard let data = try? fh.readToEnd(), let s = String(data: data, encoding: .utf8) else { return signals }

        var textPreview = "", textFlashKey = "", action = "", actionFlashKey = "", verb = "", thinking = false
        var actionFlashPri = 0
        var classified = false
        var interruptResolved = false
        var apiResolved = false

        scanTail: for line in s.split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }

            switch obj["type"] as? String {
            case "system":
                if signals.awaySummary == nil,
                   obj["subtype"] as? String == "away_summary",
                   let content = obj["content"] as? String, !content.isEmpty {
                    signals.awaySummary = content
                }

            case "user":
                let c = (obj["message"] as? [String: Any])?["content"]
                if !interruptResolved {
                    if contentText(c).contains("Request interrupted by user") {
                        signals.interrupted = true
                        interruptResolved = true
                    }
                }
                // Activity/prose previews belong only to the current typed turn. Tool results
                // are transcript "user" rows too, but they are meta or carry tool-use tags; only
                // real typed text is a turn boundary. Without this guard, a fresh turn with only
                // tools so far can walk backward into the prior turn and resurrect old prose.
                if !(obj["isMeta"] as? Bool ?? false), !realUserText(c).isEmpty {
                    break scanTail
                }

            case "assistant":
                guard let msg = obj["message"] as? [String: Any] else { continue }
                let contentAny = msg["content"]
                let content = contentAny as? [[String: Any]]
                let realAssistant = content.map(hasRealAssistantContent) ?? false

                if !apiResolved {
                    if (obj["isApiErrorMessage"] as? Bool ?? false) || (msg["isApiErrorMessage"] as? Bool ?? false) {
                        let t = contentText(contentAny).trimmingCharacters(in: .whitespacesAndNewlines)
                        signals.apiError = String((t.isEmpty ? "API Error" : t).prefix(140))
                        apiResolved = true
                    } else if realAssistant {
                        apiResolved = true
                    }
                }

                if !interruptResolved, realAssistant {
                    interruptResolved = true
                }

                guard let content else { continue }
                let eventID = transcriptEventID(obj, fallback: String(line))

                // The latest assistant entry decides the verb (what it's doing right now);
                // a running tool also yields a concrete action fallback. The preview itself
                // is chosen after the scan: current-turn prose wins, matching island-hook.py.
                if !classified, !content.isEmpty {
                    for idx in stride(from: content.count - 1, through: 0, by: -1) {
                        let last = content[idx]
                        guard let type = last["type"] as? String else { continue }
                        switch type {
                        case "thinking":
                            thinking = true
                            verb = "Thinking"
                        case "tool_use":
                            let toolName = last["name"] as? String ?? ""
                            verb = verbForTool(toolName)
                            actionFlashPri = flashPriorityForTool(toolName)
                            let tgt = toolTarget(toolName, last["input"] as? [String: Any] ?? [:])
                            action = (verb + " " + tgt).trimmingCharacters(in: .whitespaces)
                            actionFlashKey = "tool:\(eventID):\(toolName):\(idx)"
                        case "text":
                            verb = "Responding"
                        default:
                            break
                        }
                        classified = true
                        break
                    }
                }

                // Prose preview = first line of the most recent non-empty text block in the
                // current typed turn (may be earlier than the latest tool entry).
                if textPreview.isEmpty, !content.isEmpty {
                    for idx in stride(from: content.count - 1, through: 0, by: -1) {
                        guard (content[idx]["type"] as? String) == "text",
                              let t = content[idx]["text"] as? String,
                              !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        let first = t.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first ?? ""
                        textPreview = String(first.prefix(120))
                        textFlashKey = "text:\(eventID):\(idx)"
                        break
                    }
                }

            default:
                break
            }
        }

        if classified || !textPreview.isEmpty {
            let preview = textPreview.isEmpty ? action : textPreview
            let flashPri = textPreview.isEmpty ? actionFlashPri : 2
            let flashKey = textPreview.isEmpty ? actionFlashKey : textFlashKey
            signals.activity = (preview: preview, verb: verb, thinking: thinking, flashPri: flashPri, flashKey: flashKey)
        }
        return signals
    }

    /// Rewrite a session file to a terminal Esc state: "declined" (an Esc'd question/permission
    /// prompt) or "interrupted" (a halted thinking/working turn), clearing any dead question and
    /// parking the agent's response so far as the preview. Persisting it means reload()/merge()
    /// keep the terminal mode instead of re-reading the stale one. File IO, called on main.
    private func persistTerminal(_ uuid: String, mode: String, preview: String) {
        let path = kSessionsDir + "/" + uuid + ".json"
        guard let data = FileManager.default.contents(atPath: path),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        obj["mode"] = mode
        obj["detail"] = mode == "declined" ? "Declined" : "Interrupted"
        obj["qHeader"] = ""
        obj["qText"] = ""
        if !preview.isEmpty { obj["preview"] = preview }
        obj["ts"] = Date().timeIntervalSince1970
        if let out = try? JSONSerialization.data(withJSONObject: obj) {
            try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    // MARK: - Live status poll (freshest activity, between hook events)

    /// Map pid → CC's live session metadata, read from Claude Code's own per-session state
    /// files. CC rewrites these continuously, so this is less brittle than scraping env dumps.
    /// Safe off the main thread (small files, plain reads).
    private func ccSessionInfos() -> [String: CCSessionInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: kCCSessionsDir) else { return [:] }
        var out: [String: CCSessionInfo] = [:]
        for f in files where f.hasSuffix(".json") {
            guard let data = fm.contents(atPath: kCCSessionsDir + "/" + f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let pid = (f as NSString).deletingPathExtension
            out[pid] = CCSessionInfo(
                sessionId: obj["sessionId"] as? String ?? "",
                cwd: obj["cwd"] as? String ?? "",
                status: obj["status"] as? String ?? ""
            )
        }
        return out
    }

    /// Map sessionId → CC's live status ("busy"/"idle").
    private func ccSessionStatuses(_ ccInfos: [String: CCSessionInfo]? = nil) -> [String: String] {
        var out: [String: String] = [:]
        for info in (ccInfos ?? ccSessionInfos()).values where !info.sessionId.isEmpty && !info.status.isEmpty {
            out[info.sessionId] = info.status
        }
        return out
    }

    private func verbForTool(_ name: String) -> String {
        switch name {
        case "Read":                              return "Reading"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "Editing"
        case "Grep", "Glob":                      return "Searching"
        case "Bash", "BashOutput", "KillShell":   return "Running"
        case "WebFetch":                          return "Fetching"
        case "WebSearch":                         return "Searching the web"
        case "Task", "Agent":                     return "Delegating"
        case "TodoWrite":                         return "Planning"
        default:                                  return "Working"   // incl. mcp__* tools
        }
    }

    private func flashPriorityForTool(_ name: String) -> Int {
        switch name {
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "Bash", "WebFetch", "Task":
            return 1
        default:
            return 0
        }
    }

    /// Concrete object a tool is acting on (file basename / command / pattern), mirroring
    /// the hook so the pill's right side stays specific ("Reading | island.swift").
    private func toolTarget(_ tool: String, _ input: [String: Any]) -> String {
        func base(_ p: String) -> String { (p as NSString).lastPathComponent }
        switch tool {
        case "Read", "Edit", "MultiEdit", "Write": return base(input["file_path"] as? String ?? "")
        case "NotebookEdit":                       return base(input["notebook_path"] as? String ?? "")
        case "Bash": return (input["command"] as? String ?? "").split(separator: " ").first.map(String.init) ?? ""
        case "Grep", "Glob":                       return input["pattern"] as? String ?? ""
        default:                                   return ""
        }
    }

    /// Fires sub-second while a turn is active. Reconciles each known session against CC's live busy/idle status and
    /// the transcript tail, so the pill reflects real activity without waiting for a hook.
    /// Deliberately conservative: attention/error/compacting/compacted are hook-owned and
    /// never overridden here (avoids re-introducing false "waiting for input").
    @objc private func pollLiveStatus() {
        guard !sessions.isEmpty else { return }
        // Everything below (CC status + transcript scan) is computed off-thread and applied
        // a beat later. A hook (e.g. UserPromptSubmit) can land on `s` in between — most
        // visibly, sending a message while idle sets mode="thinking" via merge() right as a
        // poll cycle that STARTED just before is still mid-flight with pre-prompt data. That
        // stale data can read CC as still "idle" and the (now superseded) transcript tail as
        // ending on an old "Request interrupted by user" marker, stomping the fresh
        // thinking/working state with a false "interrupted" the instant the message is sent.
        // Snapshotting `now` here and skipping any session merge() has touched since lets the
        // next cycle (whose data postdates that hook) apply the correction instead.
        let snapStart = Date().timeIntervalSince1970
        // Snapshot (tabUUID, sessionId, transcript) for sessions that have a transcript.
        let snap: [(String, String, String)] = sessions.compactMap { (k, v) in
            guard !v.transcript.isEmpty else { return nil }
            let sessionId = ((v.transcript as NSString).lastPathComponent as NSString).deletingPathExtension
            return (k, sessionId, v.transcript)
        }
        guard !snap.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let statuses = self.ccSessionStatuses()
            var transcriptSignals: [String: TranscriptSignals] = [:]
            for (uuid, _, tx) in snap {
                transcriptSignals[uuid] = self.transcriptSignals(tx)
            }
            DispatchQueue.main.async {
                var changed = false
                let now = Date().timeIntervalSince1970
                let activeModes: Set<String> = ["working", "thinking", "struggling", "error"]
                for (uuid, sessionId, _) in snap {
                    guard let s = self.sessions[uuid] else { continue }
                    let signals = transcriptSignals[uuid] ?? TranscriptSignals()
                    // A hook already moved this session on since we started scanning — our
                    // snapshot predates that update, so don't let it clobber the fresher state.
                    // (See the staleness note above pollLiveStatus.)
                    if s.ts > snapStart { continue }
                    // A live API/connection error is the top-priority signal: show red with the
                    // message while it persists, and let it auto-clear (below) once the agent
                    // recovers. The daemon fully owns this state — no hook fires for it.
                    if let err = signals.apiError {
                        if s.mode != "error" || s.preview != err {
                            s.mode = "error"; s.detail = "API Error"; s.preview = err; s.ts = now; changed = true
                        }
                        continue
                    }
                    // Hook-owned states we never override here (avoids re-introducing false
                    // "waiting for input"). Also covers the done-family terminal states: CC's own
                    // busy/idle status file can still read "busy" for a tick or two after the Stop
                    // hook already froze `done`'s ts/turnStartTs — without this guard, that stale
                    // read flips the session back to "working" (resetting turnStartTs to "now"),
                    // then the next tick flips it back to "done" with a fresh ts, so the timer
                    // freezes at ~one poll interval — a bogus "Finished 0s" that clobbers the
                    // hook's real duration. NOTE: "error" is intentionally NOT protected — it's
                    // daemon-owned now, so when apiErrors no longer reports one, the reconcile
                    // below clears it back to working/done.
                    let protected = (s.mode == "compacting" || s.mode == "compacted" || s.mode == "attention"
                                      || s.mode == "done" || s.mode == "declined" || s.mode == "interrupted")
                    if !protected, let st = statuses[sessionId] {
                        if st == "busy" {
                            // Actively computing. Leave thinking/working/struggling (and their
                            // verb) to the hooks; only un-stick a stale terminal/error state.
                            if !["working", "thinking", "struggling"].contains(s.mode) {
                                s.mode = "working"; s.turnStartTs = now; changed = true
                            }
                        } else if activeModes.contains(s.mode) {
                            // CC went idle but we're still showing active → the turn ended and we
                            // haven't seen the Stop hook yet. If the transcript shows the user
                            // Esc'd it (no Stop ever fires), settle to "interrupted" — keeping the
                            // response so far — instead of a false "done". (attention is protected
                            // above, so a halted turn here is never a question — that's caught as
                            // "declined" in refreshLiveness.)
                            if signals.interrupted {
                                s.mode = "interrupted"; s.ts = now; s.qHeader = ""; s.qText = ""
                                if let p = signals.activity?.preview, !p.isEmpty { s.preview = p }
                                self.persistTerminal(uuid, mode: "interrupted", preview: signals.activity?.preview ?? "")
                            } else {
                                s.mode = "done"; s.ts = now
                                if s.finishKey.isEmpty { s.finishKey = self.finishFlashKey(uuid, s) }
                            }
                            changed = true
                        }
                    }
                    // A "compacted" row has no preview of its own until CC's own "away summary"
                    // recap lands (read by transcriptSignals) — swap it in over the pre-compact
                    // prompt fallback once it shows up.
                    if s.mode == "compacted", let away = signals.awaySummary, !away.isEmpty, s.preview != away {
                        s.preview = away; changed = true
                    }
                    // Freshest preview while live (cheap; no-op when unchanged). Skip the Esc
                    // terminal states, error, and compacted — their preview is the frozen question /
                    // response-so-far / error message / away-summary, which the transcript tail
                    // would otherwise overwrite with a stale pre-compact action.
                    if s.mode != "declined", s.mode != "interrupted", s.mode != "error", s.mode != "compacted",
                       let activity = signals.activity, !activity.preview.isEmpty {
                        if s.preview != activity.preview { s.preview = activity.preview; changed = true }
                        if s.flashPri != activity.flashPri { s.flashPri = activity.flashPri; changed = true }
                        if s.flashKey != activity.flashKey { s.flashKey = activity.flashKey; changed = true }
                    }
                }
                if changed { self.rebuild() }
            }
        }
    }

    /// Latest session title from the transcript: a manual /rename (`custom-title`) wins over
    /// Claude's auto `ai-title`. Reads a tail (a just-made rename is near the end) so the
    /// periodic scan stays cheap. File IO, safe off the main thread.
    private func transcriptTitle(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = fh.seekToEndOfFile()
        let span: UInt64 = 262_144
        fh.seek(toFileOffset: size > span ? size - span : 0)
        guard let data = try? fh.readToEnd(), let s = String(data: data, encoding: .utf8) else { return nil }
        var ai: String? = nil
        for line in s.split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "custom-title":
                if let c = obj["customTitle"] as? String, !c.isEmpty { return c }  // rename wins outright
            case "ai-title":
                if ai == nil, let a = obj["aiTitle"] as? String, !a.isEmpty { ai = a }
            default: break
            }
        }
        return ai
    }

    /// Identify the terminal tab that owns a Claude Code process from its `ps eww` line (the env
    /// dump is inlined). Returns the state-file key — which MUST match what the hook writes, so
    /// it's built from the same per-tab env var the hook keys on — plus a scheme-tagged focus
    /// descriptor. `tty` is the process's tty column (may be "??"; only used to focus idle tabs
    /// that have no state file). `cwd` comes from CC's session JSON when available, with env as
    /// a fallback. nil → a terminal we don't track per-tab (folds into "local").
    private func tabIdentity(_ s: String, tty: String, cwd: String, sessionId: String = "") -> (key: String, focus: String)? {
        // ORDER IS LOAD-BEARING and mirrors island-hook.py's detect_terminal: every terminal is
        // tried first, claude-desktop only as the last resort. Both sides must pick the SAME
        // branch for the same process or the keys diverge and the card never gets its file — so
        // when a process carries both a terminal env and the desktop entrypoint, both sides have
        // to agree the terminal wins (it does more for us: a real per-tab focus target).
        if let r = s.range(of: "WARP_TERMINAL_SESSION_UUID=") {
            let u = s[r.upperBound...].prefix { $0.isHexDigit }
            return u.isEmpty ? nil : (String(u), "warp://session/\(u)")
        }
        // A real tty (from the interactive shell, not the detached CC process) lets us build an
        // AppleScript focus target for idle tabs; without one we can only bring the app frontmost.
        let dev = (tty.isEmpty || tty == "??") ? "" : "/dev/" + (tty as NSString).lastPathComponent
        func envVal(_ key: String) -> String? {
            guard let r = s.range(of: key) else { return nil }
            let v = s[r.upperBound...].prefix { $0 != " " }
            return v.isEmpty ? nil : String(v)
        }
        if s.contains("TERM_PROGRAM=iTerm.app"), let sid = envVal("ITERM_SESSION_ID=") {
            let focus = dev.isEmpty ? "app:com.googlecode.iterm2" : "term:iterm2:\(dev)"
            return ("iterm-" + sid.replacingOccurrences(of: ":", with: "-"), focus)
        }
        if s.contains("TERM_PROGRAM=Apple_Terminal"), let sid = envVal("TERM_SESSION_ID=") {
            let focus = dev.isEmpty ? "app:com.apple.Terminal" : "term:apple_terminal:\(dev)"
            return ("aterm-" + sid.replacingOccurrences(of: ":", with: "-"), focus)
        }
        if s.contains("TERM_PROGRAM=ghostty"), !dev.isEmpty {
            // Ghostty is AppleScript-focusable — match its tab by working directory.
            let focus = cwd.isEmpty ? "app:com.mitchellh.ghostty" : "ghostty:\(cwd)"
            return ("ghostty-" + (dev as NSString).lastPathComponent, focus)
        }
        if s.contains("TERM_PROGRAM=vscode"), !dev.isEmpty {
            // VS Code / Cursor integrated terminal — same detection the hook uses, so the key
            // matches. `__CFBundleIdentifier` (inherited from the launching editor) both tells
            // Cursor from VS Code and gives the exact bundle for the app-activate focus + icon.
            let base = (dev as NSString).lastPathComponent
            let cf = envVal("__CFBundleIdentifier=") ?? ""
            let isCursor = cf.lowercased().contains("cursor") || cf.lowercased().contains("todesktop")
                || (envVal("VSCODE_GIT_ASKPASS_NODE=") ?? "").contains("Cursor")
            let bundle = cf.isEmpty ? (isCursor ? "com.todesktop.230313mzl4w4u92" : "com.microsoft.VSCode") : cf
            // The `code`/`cursor` CLI focuses the window holding this cwd's workspace (no side
            // effects) — a real upgrade over app-activate when several editor windows are open.
            let focus = cwd.isEmpty ? "app:\(bundle)" : "editor:\(bundle):\(cwd)"
            return ("\(isCursor ? "cursor" : "vscode")-\(base)", focus)
        }
        // Claude Code hosted inside the desktop app — no tty or terminal env to key on, so key on
        // the session (matching the hook) and focus by just bringing Claude frontmost; no per-chat
        // deep link exists. Both signals mirror the hook's: CC sets CLAUDE_CODE_ENTRYPOINT itself,
        // and __CFBundleIdentifier (set by the launching app) is the fallback. Nothing above
        // matched, so there's no terminal identity to prefer over this.
        if s.contains("CLAUDE_CODE_ENTRYPOINT=claude-desktop")
            || s.contains("__CFBundleIdentifier=com.anthropic.claudefordesktop") {
            // Require a real CC session id (from ~/.claude/sessions/<pid>.json) — the desktop app's
            // `disclaimer` launch wrapper carries the same entrypoint env but has no session file,
            // and keying it off cwd would synthesize a phantom titleless card. The hook always has
            // session_id, so this matches its `cdesk-<hash(session_id)>` key.
            guard !sessionId.isEmpty else { return nil }
            return (claudeDesktopKey(sessionId), "app:com.anthropic.claudefordesktop")
        }
        return nil
    }

    private func shell(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.launchPath = path; p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    // MARK: - Warp active tab (read from Warp's own SQLite — no Accessibility prompt)

    /// Path to Warp's SQLite store, in our own Group Container (readable without any TCC
    /// grant). Channel dir varies (Warp-Stable / -Preview), so glob for dev.warp.Warp*.
    private func warpDBPath() -> String? {
        let base = NSString("~/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support")
            .expandingTildeInPath
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        for d in dirs where d.hasPrefix("dev.warp.Warp") {
            let p = base + "/" + d + "/warp.sqlite"
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    /// UUID of the tab currently focused in Warp. Resolves app.active_window_id →
    /// windows.active_tab_index (0-based, tabs in id order) → the tab's focused leaf →
    /// terminal_panes.uuid. Read-only over a `mode=ro` URI so it sees Warp's live WAL
    /// writes. Returns nil if Warp/db is absent or the row is ambiguous. Safe off-main.
    private func warpActiveTab() -> String? {
        guard let db = warpDBPath() else { return nil }
        // Percent-encode the path (it has spaces) for the file: URI; keep slashes.
        let enc = db.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? db
        let q = """
        WITH aw AS (SELECT active_window_id AS wid FROM app LIMIT 1),
        atab AS (SELECT id AS tab_id FROM tabs WHERE window_id=(SELECT wid FROM aw)
                 ORDER BY id LIMIT 1 OFFSET (SELECT active_tab_index FROM windows WHERE id=(SELECT wid FROM aw)))
        SELECT lower(hex(tp.uuid)) FROM pane_nodes pn JOIN terminal_panes tp ON tp.id=pn.id
        LEFT JOIN pane_leaves pl ON pl.pane_node_id=pn.id
        WHERE pn.tab_id=(SELECT tab_id FROM atab) AND pn.is_leaf=1
        ORDER BY (CASE WHEN pl.is_focused=1 THEN 0 ELSE 1 END), pn.id LIMIT 1;
        """
        let out = shell("/usr/bin/sqlite3", ["file:\(enc)?mode=ro", q])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.count == 32 ? out : nil
    }

    /// DEBUG: append one line per visible right-slot change to ~/.claude-island/flicker.log —
    /// wall-clock time, delta since the previous change, and the new content signature — so the
    /// flicker cadence can be read off precisely. Inert unless the sentinel ~/.claude-island/
    /// flicker.on exists (touch it to enable, rm to disable — no rebuild needed).
    func logFlicker(_ sig: String) {
        let dir = NSHomeDirectory() + "/.claude-island"
        guard FileManager.default.fileExists(atPath: dir + "/flicker.on") else { return }
        let t = CACurrentMediaTime()
        let dt = lastFlickerT == 0 ? 0 : (t - lastFlickerT)
        lastFlickerT = t
        let wall = ISO8601DateFormatter().string(from: Date())
        let line = String(format: "%@  +%6.3fs  %@\n", wall, dt, sig)
        let path = dir + "/flicker.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }

    /// DEBUG: same log file as logFlicker, but for rebuild()'s flash decisions (TRIGGER/
    /// SUPPRESS/RESET) — shows WHY the right slot changed, alongside the visible-change lines.
    func logDecision(_ msg: String) {
        let dir = NSHomeDirectory() + "/.claude-island"
        guard FileManager.default.fileExists(atPath: dir + "/flicker.on") else { return }
        let t = CACurrentMediaTime()
        let dt = lastFlickerT == 0 ? 0 : (t - lastFlickerT)
        lastFlickerT = t
        let wall = ISO8601DateFormatter().string(from: Date())
        let line = String(format: "%@  +%6.3fs  · %@\n", wall, dt, msg)
        let path = dir + "/flicker.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }

    /// Apply a DB-reported active tab. Warp only updates active_tab_index on *manual* tab
    /// switches — a deep-link focus (our row click) doesn't persist there. So we adopt the
    /// DB value only when it actually CHANGES (a real switch); otherwise we keep whatever
    /// activeWarpTab a click set optimistically. A nil read (Warp closed / transient) is
    /// ignored so the highlight doesn't flicker.
    private func applyDBActiveTab(_ dbTab: String?) {
        guard let dbTab else { return }
        if dbTab != lastDbActiveTab { activeWarpTab = dbTab }
        lastDbActiveTab = dbTab
    }

    /// Re-read the Warp-active tab off-main and rebuild (called when the dropdown opens, so
    /// the highlight is fresh even between liveness scans).
    func refreshActiveTab() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let tab = self.warpActiveTab()
            DispatchQueue.main.async { self.applyDBActiveTab(tab); self.rebuild() }
        }
    }

    // MARK: - Clicks

    /// Front-pill click: focus its Warp tab; if it's done, dismiss that card.
    func handleIslandClick() {
        let s = IslandState.shared
        // Clicking the notch usage-peek swaps its two faces (usage text ⇄ 7-day heatmap) rather
        // than focusing a tab — the cursor is over the notch, not a session pill. Only when there
        // is a heatmap to swap to (a week of data, past the first-run teach copy).
        if s.notchPeek && !s.usageDays.isEmpty && !s.firstRunHint {
            s.usageShowActivity.toggle()
            return
        }
        // A little "still alive" wink on the resting mark: play one pass through the busy
        // glyphs, then settle back. Purely cosmetic, and idle has nothing actionable to jump
        // to, so this is also the ENTIRE click behavior while idle — never focuses/opens a
        // Warp/terminal tab (unlike every other mode below).
        if s.mode == .idle {
            if !s.idleWaking {
                s.idleWaking = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { IslandState.shared.idleWaking = false }
            }
            // Persistent "{n} idle sessions" pill: a click still toggles its dropdown — never
            // focuses/dismisses a session (there's no meaningful "front" while everything's idle).
            if hiddenIdle && s.idleSessionCount >= 1 {
                if s.dropdownOpen { closeDropdown() } else { openDropdown() }
            }
            return
        }
        // On the aggregate pill, clicking while hovering the "{n} done" count (dropdownFilter
        // already tracks whichever bucket is under the cursor, set by the hover monitor) clears
        // it the same way the single-session "Finished" pill does — dismiss every done/declined/
        // interrupted/compacted session so the count (and, once nothing else is running, the
        // whole aggregate) drops away instead of jumping to some arbitrary tab.
        if s.aggregate, s.dropdownFilter == "done" {
            let doneFamily: Set<String> = ["done", "declined", "interrupted", "compacted"]
            for card in s.roster where doneFamily.contains(card.status) { dismissedDoneIds.insert(card.id) }
            s.dropdownFilter = ""
            if s.dropdownOpen { refilterOpenDropdown() }
            rebuild()
            return
        }
        // A "Finished" single-session pill: click BOTH focuses its tab AND acknowledges it —
        // reset to the neutral icon + count pill so it doesn't keep sitting there once you've
        // seen it, same as any other front-pill click, just also dismissed. It un-dismisses on
        // its own the moment that session does anything new (see `merge()`).
        if s.mode == .done && !s.aggregate, let front = frontUUID {
            dismissedDoneIds.insert(front)
            rebuild()
            if let f = sessions[front] { openFocus(f.focus) } else { activateWarp() }
            return
        }
        // The front ticker focuses its own tab. The dropdown is opened ONLY by the
        // "{n} ⌄" back-pill peek (which has its own tap target) — never by the front pill.
        closeDropdown()
        guard let front = frontUUID, let f = sessions[front] else { activateWarp(); return }
        openFocus(f.focus)
        // Just focus — never delete the state file. A finished front session's tab is always
        // still live (front is chosen from live tabs), so dropping its file would only make it
        // reappear as an "idle" entry on the next scan. Let it stay "done" (→ stale after 15m,
        // gone only when the tab actually closes).
    }

    /// Back-card / dropdown-row click: focus that tab and promote it to the front pill.
    func focusCardTab(_ id: String) {
        // Idle tabs have no state file; reconstruct the focus descriptor from the live-tab map
        // (or the Warp uuid) so the click still jumps to the tab. They can't be pinned, so don't.
        openFocus(sessions[id]?.focus ?? liveTabFocus[id] ?? "warp://session/\(id)")
        // The click focuses this tab, but a deep-link/AppleScript focus doesn't update Warp's
        // active_tab_index — so highlight it optimistically; the DB will only override this
        // once the user manually switches tabs (applyDBActiveTab detects the change).
        activeWarpTab = id
        if sessions[id] != nil {
            clickFocus = id
            // Remember how recent activity was when pinned; any newer event releases it.
            clickFocusTs = sessions.values.map { $0.ts }.max() ?? 0
        } else {
            clickFocus = nil
        }
        closeDropdown()
        IslandState.shared.hoveredRow = nil
        rebuild()
    }

    /// Jump to the tab a session lives in. The descriptor is scheme-tagged by the hook/liveness
    /// probe so one call site handles every terminal:
    ///   term:<kind>:<tty>       AppleScript-focus the tab owning <tty> (Terminal / iTerm2)
    ///   app:<bundleid>          just bring the app frontmost (Ghostty & other no-scripting terms)
    ///   warp://… (or any URL)   hand to NSWorkspace (Warp's deep link)
    private func openFocus(_ url: String) {
        if url.hasPrefix("term:") {
            let rest = String(url.dropFirst("term:".count))
            let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 { focusTerminalTTY(kind: parts[0], tty: parts[1]); return }
        }
        if url.hasPrefix("ghostty:") { focusGhostty(cwd: String(url.dropFirst("ghostty:".count))); return }
        if url.hasPrefix("editor:") {
            // editor:<bundleid>:<cwd>
            let rest = String(url.dropFirst("editor:".count))
            let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 { focusEditor(bundleId: parts[0], cwd: parts[1]); return }
        }
        if url.hasPrefix("app:") { activateBundle(String(url.dropFirst("app:".count))); return }
        if !url.isEmpty, let u = URL(string: url) { NSWorkspace.shared.open(u) }
        else { activateWarp() }
    }

    /// Focus the exact Ghostty tab whose terminal is in `cwd` (Ghostty ships an AppleScript
    /// dictionary but exposes no tty/pid, so working directory is the match key). Falls back to
    /// activating the app if nothing matches. Off-main — osascript is synchronous.
    private func focusGhostty(cwd: String) {
        guard !cwd.isEmpty else { activateBundle("com.mitchellh.ghostty"); return }
        let q = cwd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Ghostty"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              if (working directory of (focused terminal of t)) is "\(q)" then
                activate window w
                select tab t
                focus (focused terminal of t)
                return
              end if
            end repeat
          end repeat
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.shell("/usr/bin/osascript", ["-e", script])
        }
    }

    /// Focus the VS Code / Cursor WINDOW that has `cwd`'s workspace open, via that editor's CLI
    /// (`code`/`cursor -r <cwd>`) — it targets the right window with no side effects, no extra
    /// permission. Falls back to app-activate if the CLI can't be found. Off-main (CLI is ~1s).
    private func focusEditor(bundleId: String, cwd: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            activateBundle(bundleId); return
        }
        // Cursor ships its CLI as `bin/cursor`, VS Code as `bin/code`; the bin dir holds one CLI.
        let binDir = appURL.appendingPathComponent("Contents/Resources/app/bin")
        let candidates = ["cursor", "code", "codium", "code-insiders"].map { binDir.appendingPathComponent($0).path }
        guard let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            activateBundle(bundleId); return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.shell(cli, ["-r", cwd])
            // The CLI focuses the window but doesn't always steal app focus reliably; nudge it.
            DispatchQueue.main.async { self?.activateBundle(bundleId) }
        }
    }

    /// Bring an app frontmost by bundle id (launch it if it isn't running). The Ghostty/VS Code
    /// tier — no per-tab scripting, so this is as precise as we can get.
    private func activateBundle(_ bundleId: String) {
        if let a = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            a.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    /// Focus the exact Terminal/iTerm tab that owns `tty` via AppleScript (the terminal exposes
    /// `tty` per tab/session; the deep-link equivalent Warp gives us for free). Runs off-main —
    /// osascript is synchronous and would otherwise stall the click.
    private func focusTerminalTTY(kind: String, tty: String) {
        let script: String
        switch kind {
        case "apple_terminal":
            script = """
            tell application "Terminal"
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set frontmost of w to true
                    set selected of t to true
                    return
                  end if
                end repeat
              end repeat
            end tell
            """
        case "iterm2":
            script = """
            tell application "iTerm2"
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      select w
                      select t
                      select s
                      return
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """
        default:
            activateWarp(); return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.shell("/usr/bin/osascript", ["-e", script])
        }
    }

    // MARK: - Elapsed timer (front session)

    private func startClock() {
        refreshElapsed()
        guard clockTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshElapsed() }
        RunLoop.main.add(t, forMode: .common)
        clockTimer = t
    }

    /// The sub-second live poll runs ONLY while a turn is active (started/stopped from rebuild).
    /// Idle sessions have nothing to poll, so it no longer wakes the CPU around the clock.
    private func startLivePoll() {
        guard liveTimer == nil else { return }
        pollLiveStatus()
        let t = Timer(timeInterval: kLivePollIntervalS, repeats: true) { [weak self] _ in self?.pollLiveStatus() }
        t.tolerance = kLivePollToleranceS
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
    }
    private func stopLivePoll() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    // MARK: - Usage rollup (token-window peek)

    /// Per-transcript token tally, resumed incrementally: transcripts are append-only JSONL, so
    /// we only read the bytes added since last scan — an active file is never fully reparsed.
    private final class FileRollup {
        var mtime: Double = 0
        var size: UInt64 = 0
        var offset: UInt64 = 0        // bytes already parsed
        var hours: [Int: Int] = [:]   // hour-bucket (epoch/3600) → input+output tokens
    }
    private var usageFiles: [String: FileRollup] = [:]   // transcript path → its rollup
    private var lastUsageCompute = 0.0
    private var usageComputing = false

    private static let usageISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let usageISOPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    /// Recompute the notch-peek's token windows (5h / today / 7d). Throttled to once a minute and
    /// driven on demand (launch + notch hover), so there's no always-on background cost. Off-main.
    private func refreshUsage() {
        let now = Date().timeIntervalSince1970
        guard !usageComputing, now - lastUsageCompute > 60 else { return }
        usageComputing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let u = self.computeUsage()
            let rl = self.readRateLimits()
            DispatchQueue.main.async {
                IslandState.shared.usageSession = u.session
                IslandState.shared.usageToday = u.today
                IslandState.shared.usageDays = u.days
                IslandState.shared.usageDayTokens = u.dayTokens
                IslandState.shared.rlSession = rl.session
                IslandState.shared.rlWeek = rl.week
                IslandState.shared.rlSessionReset = rl.sessionReset
                IslandState.shared.rlWeekReset = rl.weekReset
                self.lastUsageCompute = Date().timeIntervalSince1970
                self.usageComputing = false
            }
        }
    }

    /// Read the real plan rate-limit % that island-statusline.py captured from Claude Code's
    /// statusline JSON. Returns ("","") when the file is missing or stale (older than the 5h
    /// window, so a since-reset value isn't shown as current). Each window is independent.
    private func readRateLimits() -> (session: String, week: String, sessionReset: Double, weekReset: Double) {
        let path = NSString("~/.claude-island/rate-limits.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ("", "", 0, 0) }
        let now = Date().timeIntervalSince1970
        if let ts = obj["ts"] as? Double, now - ts > 6 * 3600 { return ("", "", 0, 0) }   // stale
        func win(_ key: String) -> (String, Double) {
            guard let w = obj[key] as? [String: Any],
                  let p = (w["used_percentage"] as? NSNumber)?.doubleValue else { return ("", 0) }
            return ("\(Int(p.rounded()))", (w["resets_at"] as? NSNumber)?.doubleValue ?? 0)
        }
        let f = win("five_hour"), s = win("seven_day")
        return (f.0, s.0, f.1, s.1)
    }

    /// CC's real context-window fill (0…1) for a session, captured per-session by
    /// island-statusline.py and keyed by session_id (the transcript's basename). This is
    /// computed against the session's ACTUAL window — model- and 1M-beta-aware — so it's used in
    /// preference to the daemon's 200k/1M token-count heuristic. nil when not yet captured.
    /// A session's context-window fill (0…1) for the ring. Prefers CC's per-session statusline %
    /// (its REAL window — model/1M-beta aware) over the daemon's token-count guess — EXCEPT right
    /// after a compaction. There the statusline % is stale-HIGH: its most recent sample was the
    /// summarization call, which ingested the FULL pre-compaction context, and CC re-runs the
    /// statusline post-compaction so the ctx file is freshly written yet still high (a timestamp
    /// check wouldn't catch it). The hook forces v.context=0 for exactly this "compacted" window
    /// (island-hook.py, sessionstart/source=compact), so honor that authoritative signal until
    /// the next real turn refreshes both. v.mode stays "compacted" until that turn, so this also
    /// covers a compacted session that goes stale before the user returns to it.
    private func sessionContext(_ v: LiveSession) -> Double {
        if v.mode == "compacted" { return v.context }
        return statuslineContext(v.transcript) ?? v.context
    }

    private func statuslineContext(_ transcript: String) -> Double? {
        guard transcript.hasSuffix(".jsonl") else { return nil }
        let sid = String((transcript as NSString).lastPathComponent.dropLast(6))   // ".jsonl"
        guard !sid.isEmpty else { return nil }
        let path = ("~/.claude-island/ctx/\(sid).json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pct = (obj["pct"] as? NSNumber)?.doubleValue else { return nil }
        return max(0, min(1, pct / 100.0))
    }

    /// Scan transcripts touched in the last 7d, summing input+output tokens per hour-bucket, then
    /// reduce to the three windows. Returns "" when the week is empty (peek keeps its fallback).
    /// Only ever runs on the single in-flight background task (guarded by usageComputing), so the
    /// usageFiles cache it mutates is never touched concurrently.
    private func computeUsage() -> (session: String, today: String, days: [Int], dayTokens: [Int]) {
        let fm = FileManager.default
        let base = NSString("~/.claude/projects").expandingTildeInPath
        let now = Date().timeIntervalSince1970
        // Scan far enough back to fill the activity strip (a few days of slack over kActivityDays),
        // not just the 7d peek windows. Older buckets still land in the per-day strip below.
        let weekAgo = now - Double(kActivityDays + 1) * 86_400
        guard let projects = try? fm.contentsOfDirectory(atPath: base) else { return ("", "", [], []) }
        var seen = Set<String>()
        for proj in projects {
            let dir = base + "/" + proj
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".jsonl") {
                let path = dir + "/" + f
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mt = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                      mt >= weekAgo else { continue }
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                seen.insert(path)
                let r = usageFiles[path] ?? FileRollup()
                usageFiles[path] = r
                if r.size == size && r.mtime == mt { continue }    // unchanged → reuse
                if size < r.size { r.offset = 0; r.hours = [:] }    // rewritten/compacted → reparse
                parseUsage(path, from: r.offset, into: r)
                r.mtime = mt; r.size = size; r.offset = size
            }
        }
        for k in Array(usageFiles.keys) where !seen.contains(k) { usageFiles.removeValue(forKey: k) }

        let hourNow = Int(now / 3600)
        let h5 = hourNow - 5
        let h7 = hourNow - 24 * 7
        let hMid = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 / 3600)
        var t5 = 0, tToday = 0, t7 = 0
        // Per-day totals for the activity strip: index 0 = oldest day shown, last = today.
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        var dayTok = [Int](repeating: 0, count: kActivityDays)
        for r in usageFiles.values {
            for (h, tok) in r.hours {
                if h >= h7 {
                    t7 += tok
                    if h >= hMid { tToday += tok }
                    if h >= h5 { t5 += tok }
                }
                // Bucket the hour into its local calendar day; drop anything outside the window.
                let when = Date(timeIntervalSince1970: Double(h) * 3600)
                let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: when), to: todayStart).day ?? Int.max
                let idx = kActivityDays - 1 - daysAgo
                if idx >= 0 && idx < kActivityDays { dayTok[idx] += tok }
            }
        }
        guard t7 > 0 else { return ("", "", [], []) }   // nothing in a week → peek keeps its fallback
        // Shade each day relative to the busiest day in the window (no per-day plan quota exists):
        // idle→0, then quartiles of the max → 1…4. All-idle windows send [] so the strip hides.
        let maxDay = dayTok.max() ?? 0
        let days: [Int] = maxDay == 0 ? [] : dayTok.map { t in
            if t == 0 { return 0 }
            let r = Double(t) / Double(maxDay)
            if r > 0.75 { return 4 }
            if r > 0.50 { return 3 }
            if r > 0.25 { return 2 }
            return 1
        }
        let dayTokens = maxDay == 0 ? [] : dayTok
        return (Self.fmtTok(t5), Self.fmtTok(tToday), days, dayTokens)   // wk (t7) still computed; not shown in the peek
    }

    /// Parse the bytes [offset…] of one transcript, adding input+output tokens to per-hour buckets.
    private func parseUsage(_ path: String, from offset: UInt64, into r: FileRollup) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        fh.seek(toFileOffset: offset)
        guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any],
                  let tsStr = obj["timestamp"] as? String else { continue }
            let tok = ((usage["input_tokens"] as? Int) ?? 0) + ((usage["output_tokens"] as? Int) ?? 0)
            guard tok > 0, let ep = Self.usageEpoch(tsStr) else { continue }
            r.hours[Int(ep / 3600), default: 0] += tok
        }
    }

    private static func usageEpoch(_ iso: String) -> Double? {
        (usageISO.date(from: iso) ?? usageISOPlain.date(from: iso))?.timeIntervalSince1970
    }

    private static func fmtTok(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1000)k" }
        return "\(n)"
    }

    /// Re-tick the front pill's timer and every live row timer in the dropdown roster.
    private func refreshElapsed() {
        let s = IslandState.shared
        if let f = frontUUID.flatMap({ sessions[$0] }) { s.elapsed = formatElapsed(f) }
        guard !s.roster.isEmpty else { return }
        s.roster = s.roster.map { card in
            guard let v = sessions[card.id] else { return card }
            var c = card
            let show = ["working", "thinking", "done"].contains(v.mode) || card.status == "stale"
            c.elapsed = show ? formatElapsed(v) : ""
            // Keep the live subagent count fresh on the 1s tick while the dropdown is open;
            // zero it out otherwise so closed-state stays cheap.
            if s.dropdownOpen {
                c.subagentCount = liveSubagentCount(v)
            } else if c.subagentCount != 0 {
                c.subagentCount = 0
            }
            return c
        }
        rebuildDropdownItems()   // keep grouped view's timers in sync (respecting any active filter)
    }

    // MARK: - Git context (local probe, per session cwd; dropdown groups by repo/branch)

    struct GitInfo: Equatable { var repo = ""; var branch = ""; var files = 0; var added = 0; var removed = 0 }
    private var gitCache: [String: GitInfo] = [:]   // cwd → its repo/branch/churn
    private var gitProbeSeen = Set<String>()        // includes non-git dirs, so missing dirs probe once immediately
    private var lastGitCompute = 0.0
    private var gitProbing = false

    /// Cache-backed git context for a session's cwd, falling back to the bare dir name pre-probe
    /// (or for a non-git dir) so grouping still works. Pure lookup — the probe runs in the bg.
    private func gitGroup(_ cwd: String, _ project: String) -> GitInfo {
        if var g = gitCache[cwd] {
            if g.repo.isEmpty { g.repo = project.isEmpty ? "Claude Code" : project }
            return g
        }
        return GitInfo(repo: project.isEmpty ? "Claude Code" : project)
    }

    /// One `git` probe for a cwd: repo name (shared across a repo's worktrees, via the common
    /// git dir so a linked worktree maps to the same repo prefix), current branch, and the
    /// uncommitted churn vs HEAD. Returns nil for a non-git dir. Runs off the main thread.
    private func probeGit(_ cwd: String) -> GitInfo? {
        guard !cwd.isEmpty else { return nil }
        let common = shell("/usr/bin/git", ["-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard common.hasPrefix("/") else { return nil }   // empty/relative/error → not a repo
        // common is "<repoRoot>/.git" (or a worktrees subpath under it); the repo name is the
        // parent dir of the shared .git, identical for the main tree and every linked worktree.
        let repo = ((common as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let branch = shell("/usr/bin/git", ["-C", cwd, "branch", "--show-current"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var files = 0, added = 0, removed = 0
        // Tracked changes vs HEAD (staged + unstaged).
        for line in shell("/usr/bin/git", ["-C", cwd, "diff", "HEAD", "--numstat"]).split(separator: "\n") {
            let c = line.split(separator: "\t")
            guard c.count >= 2 else { continue }
            files += 1
            added += Int(c[0]) ?? 0       // "-" (binary) → 0
            removed += Int(c[1]) ?? 0
        }
        // Untracked (new, non-ignored) files count as additions too — `git diff HEAD` omits them,
        // which made the island undercount vs Warp / `git status`. Each new file = its line count.
        let others = shell("/usr/bin/git", ["-C", cwd, "ls-files", "--others", "--exclude-standard", "-z"])
        for name in others.split(separator: "\0") where !name.isEmpty {
            guard files < 500,
                  let data = FileManager.default.contents(atPath: cwd + "/" + name),
                  data.count <= 1_000_000 else { continue }   // skip huge files
            var nl = 0, binary = false
            for b in data { if b == 0 { binary = true; break }; if b == 0x0A { nl += 1 } }
            if binary { continue }        // don't count binary blobs (images, etc.)
            files += 1
            added += nl
        }
        return GitInfo(repo: repo, branch: branch.isEmpty ? "detached" : branch,
                       files: files, added: added, removed: removed)
    }

    /// Refresh git context for the visible sessions' cwds. Gated on the dropdown being open
    /// (the repo/branch headers only render there) and throttled, like the subagent count, to
    /// keep `git` off the hot path. On a real change it triggers one rebuild to repaint.
    private func refreshGitInfo(_ cwds: Set<String>) {
        let now = Date().timeIntervalSince1970
        let hasUnseenCwd = cwds.contains { !gitProbeSeen.contains($0) }
        guard IslandState.shared.dropdownOpen, !gitProbing, !cwds.isEmpty,
              hasUnseenCwd || now - lastGitCompute > 3 else { return }
        gitProbing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var fresh: [String: GitInfo] = [:]
            for cwd in cwds { if let g = self.probeGit(cwd) { fresh[cwd] = g } }
            DispatchQueue.main.async {
                var changed = false
                for (k, v) in fresh where self.gitCache[k] != v { self.gitCache[k] = v; changed = true }
                self.gitProbeSeen.formUnion(cwds)
                self.lastGitCompute = Date().timeIntervalSince1970
                self.gitProbing = false
                if changed { self.rebuild() }
            }
        }
    }

    // MARK: - Subagents (counted straight from the transcript tree; hooks never see them)

    /// How many subagents a session has running right now. Claude Code fires no hooks for a
    /// subagent's own tool calls, so this is read from the transcript tree: the parent path
    /// <…>/<sessionId>.jsonl maps to <…>/<sessionId>/subagents/, and each agent-<id>.jsonl
    /// whose file moved within kSubagentFreshS is a live delegate. Cheap: a dir listing + an
    /// mtime stat per agent (no transcript parsing — we only need the count).
    private func liveSubagentCount(_ v: LiveSession) -> Int {
        guard v.transcript.hasSuffix(".jsonl") else { return 0 }
        let dir = String(v.transcript.dropLast(6)) + "/subagents"   // ".jsonl" == 6 chars
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return 0 }
        let now = Date().timeIntervalSince1970
        var count = 0
        for name in entries where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
            guard let attrs = try? fm.attributesOfItem(atPath: dir + "/" + name),
                  let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                  now - mtime <= kSubagentFreshS else { continue }   // not running → skip
            count += 1
        }
        return count
    }

    /// Group the roster by project for the dropdown. Group order follows the caller's
    /// persistent first-seen order (oldest-opened dir on top); rows keep ts order within a
    /// group. Headers are emitted only when more than one project is present.
    static func groupRoster(_ roster: [SessionCard], order persistentOrder: [String]) -> [DropdownItem] {
        var groups: [String: [SessionCard]] = [:]
        for c in roster { groups[c.groupKey, default: []].append(c) }
        // Cluster by repo (dirname) so all of a repo's branches/worktrees stay CONTIGUOUS —
        // otherwise a different dir, first-seen between two of this repo's branches, would split
        // them apart. Repos order by first-seen; branches within a repo order by first-seen.
        func repoOf(_ k: String) -> String { k.firstIndex(of: "/").map { String(k[..<$0]) } ?? k }
        let rank = Dictionary(persistentOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        // Repo first-seen = earliest rank among THIS repo's CURRENT group keys only, so stale
        // plain-name entries left in the persisted order (from before grouping existed) can't drag
        // a repo's position around.
        var repoRank: [String: Int] = [:]
        for k in groups.keys {
            repoRank[repoOf(k)] = min(repoRank[repoOf(k)] ?? Int.max, rank[k] ?? Int.max)
        }
        let order = groups.keys.sorted { a, b in
            let ra = repoRank[repoOf(a)] ?? Int.max, rb = repoRank[repoOf(b)] ?? Int.max
            if ra != rb { return ra < rb }                       // repo, by first-seen
            let ka = rank[a] ?? Int.max, kb = rank[b] ?? Int.max
            return ka != kb ? ka < kb : a < b                    // branch within repo, by first-seen
        }
        // Always show the repo/branch header — it's the primary "which session is this" anchor now
        // (even a lone session gets its "dirname · branch · churn" label).
        let showHeaders = true
        var items: [DropdownItem] = []
        for key in order {
            let cards = groups[key]!
            if showHeaders, let head = cards.first {
                items.append(DropdownItem(id: "hdr:\(key)", header: key, card: nil,
                    hRepo: head.repo.isEmpty ? head.project : head.repo, hBranch: head.branch,
                    hFiles: head.files, hAdded: head.added, hRemoved: head.removed))
            }
            for c in cards { items.append(DropdownItem(id: c.id, header: nil, card: c)) }
        }
        return items
    }

    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    private func formatElapsed(_ s: LiveSession) -> String {
        guard s.turnStartTs > 0 else { return "" }
        let end = s.mode == "done" ? s.ts : Date().timeIntervalSince1970
        let sec = max(0, Int(end - s.turnStartTs))
        return sec < 60 ? "\(sec)s" : "\(sec / 60)m \(sec % 60)s"
    }
}

// MARK: - Boot

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.delegate = controller
app.run()
