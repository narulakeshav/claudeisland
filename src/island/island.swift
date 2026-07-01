import Cocoa
import SwiftUI
import CoreText

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
let kGifPath = kEventDir + "/claude.gif"               // working
let kThinkingGifPath = kEventDir + "/claude-thinking.gif"  // thinking
let kCompactingGifPath = kEventDir + "/claude-compacting.gif"  // compacting
let kUltraThinkGifPath = kEventDir + "/claude-ultra_think.gif"  // ultrathink (front pill, single session)
let kDoneImagePath = kEventDir + "/claude-done.tiff"       // success
let kPausedImagePath = kEventDir + "/claude-paused.tiff"   // idle / resting (legacy)
let kIdleIconPath = kEventDir + "/cc-icon.png"             // idle / resting
let kDarwinName = "com.claude-island.event"

// EXPERIMENT: lead each dropdown row with the session's opening user prompt instead of
// the Warp tab name — the prompt is a far stickier "which convo is this" anchor. Flip to
// false to revert to the tab title. (Falls back to the title when no prompt was captured.)
let kRowTitleUsesPrompt = true

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

// Dropdown ("{n} ⌄") UI geometry, shared by the view and the controller's hit-testing.
let kAgentsPeek: CGFloat = 32     // how far the "{n} ⌄" back pill peeks past the pill's right edge
let kSheetSide: CGFloat = 40      // how much wider (each side) the expanded sheet is than the pill
let kRowHeight: CGFloat = 32      // dropdown row height
let kSubagentFreshS: Double = 8   // a subagent whose transcript moved within this window is "running"
let kHeaderHeight: CGFloat = 22   // dropdown section-header (project label) height
let kDropdownVPad: CGFloat = 6    // vertical padding below the pill row, inside the sheet
let kDropdownBottomPad: CGFloat = 6   // padding below the last row, inside the rounded bottom
let kRowInset: CGFloat = 14       // row horizontal inset from the sheet edge
let kFrontPeek: CGFloat = 22      // how far the front pill grows DOWN on hover to show its title
let kFrontExpandRadius: CGFloat = 28  // bottom corner radius while the front pill is expanded

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
/// only once the window is ≥25% full, and never on the grey idle/stale rows.
func ringVisible(_ card: SessionCard) -> Bool {
    card.context >= 0.25 && card.status != "idle" && card.status != "stale"
}

/// Context-ring fill (and the matching "x% context" text) — warns as the window fills:
/// white < 30%, amber 30–50%, red > 50%.
func contextFillColor(_ pct: Double) -> Color {
    if pct > 0.5  { return Color(red: 0.898, green: 0.282, blue: 0.302) }  // red
    if pct > 0.30 { return Color(red: 1.0, green: 0.745, blue: 0.0) }      // amber
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
    @Published var idleHint: Bool = false    // idle peek, stage 1: icon-only pulsing hint (pre-reveal)
    @Published var idleReveal: Double = 1    // 0→1 bouncy scale/opacity entrance for the idle peek
    @Published var idleWaking: Bool = false  // brief "still alive" wink on click: swaps the
                                              // static resting mark for the live gif, then settles back

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

/// Per-letter rainbow gradient for the "ultrathink" verb — each glyph stepped across a warm→cool
/// hue sweep, mirroring Claude Code's own ultrathink styling. Color only, so the text content and
/// measured width are unchanged (pill geometry doesn't drift).
func rainbowText(_ s: String) -> Text {
    let chars = Array(s)
    guard chars.count > 0 else { return Text("") }
    let n = max(chars.count - 1, 1)
    var out = Text("")
    for (i, ch) in chars.enumerated() {
        let hue = 0.02 + (Double(i) / Double(n)) * 0.82   // red-orange → violet
        out = out + Text(String(ch)).foregroundColor(Color(hue: hue, saturation: 0.75, brightness: 1.0))
    }
    return out
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
}

/// Drives the spinner from a real run-loop timer. SwiftUI's `repeatForever`
/// animations don't reliably run inside a non-activating background panel, so
/// we step the angle ourselves and only run while there's something to spin.
final class Ticker: ObservableObject {
    @Published var angle: Double = 0
    private var timer: Timer?
    static let shared = Ticker()

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.angle = (self.angle + 4).truncatingRemainder(dividingBy: 360)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// Self-stepped clock for the hover-peek marquee. Like `Ticker`, a real run-loop timer is
/// required — SwiftUI's animation clock is frozen in the non-activating panel. `phase` is the
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
    private static let font = NSFont(name: kSansFontName, size: 11) ?? .systemFont(ofSize: 11)
    private static let gap: CGFloat = 48

    var body: some View {
        // Collapse newlines/tabs → spaces so a multi-paragraph preview scrolls as ONE line
        // instead of rendering a tall block that spills above and below the pill.
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
                          .replacingOccurrences(of: "\t", with: " ")
        let textW = textWidth(oneLine, Marquee.font)
        let label = Text(oneLine).font(.custom(kSansFontName, size: 11)).foregroundColor(color).lineLimit(1).fixedSize()
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
        .mask(overflow ? AnyView(Marquee.edgeFade(width)) : AnyView(Rectangle()))
    }

    private static func edgeFade(_ width: CGFloat) -> some View {
        let f = min(0.28, 24 / max(width, 1))   // ~24pt fade on each side
        return LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: f),
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
    private let lineH: CGFloat = 15

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

/// Embeds an animated GIF via AppKit's NSImageView, which animates GIFs on the
/// main run loop (works inside a background panel where SwiftUI animation won't).
struct GIFView: NSViewRepresentable {
    let path: String
    var animates: Bool = true   // false → show the first frame as a still (resting logo)
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.animates = animates
        v.image = NSImage(contentsOfFile: path)
        // Don't let the image's intrinsic 128px size override the SwiftUI .frame.
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) {
        if v.image == nil { v.image = NSImage(contentsOfFile: path) }
    }
}

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
        case "stale":             return Color(white: 0.5)   // done, unattended >15 min
        default:                  return Color(white: 0.55)
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
                .font(.custom(kSansFontName, size: 11))
                .lineLimit(1)
            Spacer(minLength: 8)
            // Context fill of the active session, floated to the header's right edge: a ring +
            // "x% context" in the ring's own color. Only on the active header, ≥25% full.
            if let ctx = headerContext(item), ctx >= 0.25 {
                HStack(spacing: 5) {
                    ContextRing(pct: ctx)
                    Text("\(Int((ctx * 100).rounded()))% context used")
                        .font(.custom(kSansFontName, size: 11))
                        .foregroundColor(contextFillColor(ctx))
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 2)   // a little breathing room between the label and its first row
        .frame(width: sheetWidth - 2 * kRowInset, height: kHeaderHeight, alignment: .bottomLeading)
    }

    // Context fill driving the active header's ring: the hovered row's session, else the
    // selected one; falls back to the group's representative card.
    private func headerContext(_ item: DropdownItem) -> Double? {
        guard headerActive(item) else { return nil }
        let group = String(item.id.dropFirst(4))   // strip "hdr:"
        // Context is PER SESSION, but a header can span several sessions in one repo/branch group —
        // showing one session's % under a multi-session label would misread as an aggregate. So only
        // surface it when the group is a single session (then label ⇔ session, unambiguous).
        let cards = state.roster.filter { $0.groupKey == group }
        guard cards.count == 1 else { return nil }
        return cards.first?.context
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
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(IslandView.compact)
                .frame(width: 8)
        } else if status == "declined" {
            // A dismissed question/permission prompt — an "x" reads as "waved off".
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Color(white: 0.55))
                .frame(width: 8)
        } else if status == "interrupted" {
            // A halted thinking/working turn — a stop square reads as "you stopped it".
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Color(white: 0.55))
                .frame(width: 8)
        } else {
            Circle().fill(ultra ? IslandView.ultraRed : dotColor(status)).frame(width: 8, height: 8)
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
        return HStack(spacing: 10) {
            rowMarker(card.status, ultra: card.ultra && card.status == "thinking")
            if timerOnLeft {
                Text(card.elapsed)
                    .font(.custom(kSansFontName, size: 12))
                    .monospacedDigit()
                    .foregroundColor(card.status == "done" ? IslandView.green : Color.white.opacity(0.55))
                    .lineLimit(1)
                    .fixedSize()
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
                let rowLabel = (isFinished || isEscTerminal || isError) ? (card.preview.isEmpty ? titleText : card.preview)
                    : ((kRowTitleUsesPrompt && !livePrompt.isEmpty) ? livePrompt : titleText)
                let name = Text(rowLabel).foregroundColor(titleColor)
                // Claude Code's own "waiting on background agents" status isn't exposed to
                // hooks — a session parked on live subagents with no fresher tool verb would
                // otherwise show no prefix at all. Fall back to naming it explicitly so the row
                // always reads as "doing something" instead of going blank.
                let workingVerb = card.verb.isEmpty && card.subagentCount > 0 ? "Waiting for subagents…" : card.verb
                if card.status == "working", !workingVerb.isEmpty {
                    verbRun(workingVerb + " ", color: IslandView.coral, ultra: false) + name
                } else if card.status == "thinking" {
                    verbRun(card.ultra ? "Ultrathinking… " : "Thinking… ", color: IslandView.amber, ultra: card.ultra) + name
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
            } else if !card.preview.isEmpty && !isFinished && !isEscTerminal && !isError {
                Text(card.preview)
                    .font(.custom(kSansFontName, size: 12))
                    .foregroundColor(Color.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            // (Context ring moved to the group header — floated right as "ring + x% context".)
            // Active rows keep the timer on the right; finished rows moved it to the left.
            if !card.elapsed.isEmpty && !timerOnLeft {
                Text(card.elapsed)
                    .font(.custom(kSansFontName, size: 12))
                    .monospacedDigit()
                    .foregroundColor(card.status == "done" ? IslandView.green : Color.white.opacity(0.55))
                    .lineLimit(1)
                    .fixedSize()
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
    // spread across >1 project (more useful), else a plain "hover to see" affordance.
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
                                  : .init(text: "hover to see", color: grey))
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
    private var rightW: CGFloat {
        3 + textWidth(rightText, IslandView.sansFont)
    }

    private static let green = Color(red: 0.45, green: 0.82, blue: 0.52)

    // Verb/label color matches the state.
    // The leading verb run for a dropdown row — rainbow per-letter when the turn was an
    // "ultrathink", else a flat status color. Serif + tracking to match the brand verb.
    private func verbRun(_ text: String, color: Color, ultra: Bool) -> Text {
        let base = ultra ? rainbowText(text) : Text(text).foregroundColor(color)
        return base.font(.custom(kSerifFontName, size: 13)).tracking(0.5)
    }

    // The front pill's verb. Rainbow per-letter when a single (non-aggregate) ultrathink turn is
    // live; otherwise the flat status color with the sweeping white shimmer.
    @ViewBuilder private var primaryLabel: some View {
        if state.ultra && !state.aggregate && state.mode == .thinking {
            rainbowText(primary)
                .font(.custom(kSerifFontName, size: 13))
                .tracking(0.5)
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
        // Finished: the agent's reply already lives in the hover peek, so the right side shows the
        // session's AI tab name (its directory until it's earned one) — a calmer "which convo".
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
                if !rightText.isEmpty {
                    rightTextView
                        .font(.custom(kSansFontName, size: 13))
                        .fontWeight(.regular)
                        .monospacedDigit()                  // tabular-nums: stable digit width
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.leading, 3)
            .frame(width: rightW, alignment: .trailing)
        }
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
            // Notch → a static "Happy Clauding". While the agent is actively replying (working)
            // or just finished, the peek shows its live/final response (preview). While thinking
            // (no reply yet) it shows the user's latest message instead. Marquee'd if it overflows.
            let showResponse = !state.preview.isEmpty
                && (state.mode == .working || state.mode == .done)
            // Idle has no message/title worth narrating — hovering the icon (off the literal
            // notch) shows nothing rather than a bare "Claude Code"; hovering the notch itself
            // still shows the usage peek via `state.notchPeek` below.
            let peekText = showResponse ? state.preview
                : (state.mode == .idle ? "" : (state.lastUserMsg.isEmpty ? state.title : state.lastUserMsg))
            if frontPeekH > 0 && (state.notchPeek || !peekText.isEmpty) {
                Group {
                    if state.notchPeek {
                        usagePeekView
                            .font(.custom(kSansFontName, size: 11))
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
        let grey = Color(white: 0.55)
        if !state.rlSession.isEmpty {
            let pct = Int(state.rlSession) ?? 0
            let barColor = pctColor(state.rlSession)
            let textColor = pctTextColor(state.rlSession)
            let reset = fmtReset(state.rlSessionReset)
            HStack(spacing: 6) {
                Text("Session").foregroundColor(grey)
                UsageBar(fraction: Double(pct) / 100, color: barColor)
                Text("\(pct)% context used").foregroundColor(barColor)
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
    private var frontPeekH: CGFloat { (state.frontHovered && !state.dropdownOpen) ? kFrontPeek : 0 }

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

    @ViewBuilder private func icon(_ path: String, fallback: AnyView) -> some View {
        if FileManager.default.fileExists(atPath: path) {
            GIFView(path: path).frame(width: 18, height: 18).clipped()
        } else {
            fallback
        }
    }

    @ViewBuilder private var leading: some View {
        if state.aggregate {
            switch aggKind {
            case .needYou:
                Image(systemName: "exclamationmark").font(.system(size: 13, weight: .bold)).foregroundColor(IslandView.red).frame(width: 14).modifier(WobbleMarker(active: true))
            case .running:
                icon(kGifPath, fallback: AnyView(Spinner(accent: IslandView.coral, mode: .working)))
            case .done:
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(IslandView.green).frame(width: 18)
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
            icon(state.ultra ? kUltraThinkGifPath : kThinkingGifPath, fallback: AnyView(Spinner(accent: accent, mode: .working)))
        case .working:
            icon(kGifPath, fallback: AnyView(Spinner(accent: accent, mode: .working)))
        case .attention:
            Image(systemName: "exclamationmark").font(.system(size: 13, weight: .bold)).foregroundColor(accent).frame(width: 14).modifier(WobbleMarker(active: true))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold)).foregroundColor(accent).frame(width: 16)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(accent).frame(width: 18)
        case .compacting:
            icon(kCompactingGifPath, fallback: AnyView(Circle().fill(accent).frame(width: 9, height: 9).frame(width: 18)))
        case .compacted:
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(accent).frame(width: 18)
        case .idle:
            // Resting "paused" Claude mark; falls back to a neutral glyph if the asset is missing.
            // During the hover-hint stage it breathes (scale + opacity) to confirm the hover;
            // once revealed in full it settles to a steady mark. A click briefly swaps it for
            // the live working gif — a "still alive" wink — before settling back (idleWaking,
            // toggled by handleIslandClick).
            Group {
                if state.idleWaking {
                    icon(kGifPath, fallback: AnyView(Spinner(accent: accent, mode: .working)))
                } else if FileManager.default.fileExists(atPath: kPausedImagePath) {
                    GIFView(path: kPausedImagePath, animates: false).frame(width: 18, height: 18).clipped()
                } else {
                    Image(systemName: "pause.fill").font(.system(size: 11, weight: .semibold)).foregroundColor(accent).frame(width: 16)
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

/// Self-driving clock for the wobble. Like Ticker, we step time ourselves on a Timer:
/// SwiftUI's own animation clock (TimelineView/withAnimation) doesn't tick reliably in
/// this non-activating panel, and the global Ticker is STOPPED in attention mode — the
/// one state the wobble needs — so the marker can't borrow its redraws. Each attention
/// marker owns one; it only exists while that marker is on screen.
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

struct Spinner: View {
    let accent: Color
    let mode: IslandState.Mode
    @ObservedObject private var ticker = Ticker.shared

    var body: some View {
        Group {
            switch mode {
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(accent)
            case .attention:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(accent)
                    .modifier(WobbleMarker(active: true))
            default:
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(ticker.angle))
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// Context-window fill gauge. Grey track (matching the preview text), with the filled
/// arc swept clockwise from 12 o'clock — white when low, amber past a third, red past half.
struct ContextRing: View {
    let pct: Double
    private var fillColor: Color { contextFillColor(pct) }
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
    private var livenessTick = 0    // skip-counter so the liveness scan backs off while hidden
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
        // user canceled (Esc), then refresh the deck. The process/transcript IO runs
        // off the main thread so it never freezes the bar.
        let g = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            self?.refreshLiveness()
        }
        RunLoop.main.add(g, forMode: .common)
        gcTimer = g

        // Fast live poll: reads CC's own busy/idle status files and tails each transcript so the
        // verb/preview/active-state track real activity at sub-second latency between hook events.
        // Started on demand by rebuild() ONLY while a turn is active (working/thinking) — idle
        // sessions have nothing to poll, so this no longer wakes the CPU ~2×/sec around the clock.
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
                    let overNotch = !s.dropdownOpen && pointInNotchRegion(p)
                    if s.notchPeek != overNotch {
                        s.notchPeek = overNotch
                        if overNotch { refreshUsage() }   // freshen the usage rollup on demand
                    }
                    if s.frontHovered != overNotch { setFrontHover(overNotch) }   // stats strip on notch hover only
                    if !s.dropdownOpen {
                        if pointInFrontPill(p) && !overNotch { openDropdown() }
                    } else if !overIsland {
                        closeDropdown()
                    }
                    updateRowHover(p: p, f: panel.frame)
                    if !inZone && !overIsland && !s.dropdownOpen { hideIdlePeek() }
                    return
                }
                // No idle sessions either — the bare "Idle" pill. Still peek the token-usage
                // stats on the literal notch, same as every other state.
                let overNotch = pointInNotchRegion(p)
                if s.notchPeek != overNotch {
                    s.notchPeek = overNotch
                    if overNotch { refreshUsage() }
                }
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
        let overNotch = !s.dropdownOpen && pointInNotchRegion(p)
        if s.notchPeek != overNotch {
            s.notchPeek = overNotch
            if overNotch { refreshUsage() }   // freshen the token-usage peek on demand (60s-throttled)
        }

        // Front-pill peek: the notch peek, or a single (non-aggregate) session's title on
        // hover. The aggregate never title-peeks — every count routes to the dropdown instead.
        let front = !s.dropdownOpen && (overNotch || (!s.aggregate && pointInFrontPill(p)))
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
                    } else if s.mode == .idle && s.neutralNotIdle && pointInFrontPill(p) && !overNotch {
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
        if s.frontHovered && !s.dropdownOpen { bottom -= kFrontPeek }  // title-peek strip stays clickable
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
        // …then spring open on the next tick, so the .animation(value:) catches the 0→1 change
        // and plays the bouncy entrance.
        DispatchQueue.main.async { IslandState.shared.idleReveal = 1 }
        idleHoverTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
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

    /// True over the literal notch — its own width, centered on the screen (the physical
    /// notch sits at the panel's horizontal center regardless of the pill's offset). Drives
    /// the "Happy Clauding" peek; extends down with the peek strip so the hover holds.
    private func pointInNotchRegion(_ p: NSPoint) -> Bool {
        let s = IslandState.shared
        let f = panel.frame
        let islandH = max(s.notchHeight, 30)
        let halfW = max(s.notchWidth, 120) / 2
        let bottom = f.maxY - islandH - (s.frontHovered ? kFrontPeek : 0)
        return abs(p.x - f.midX) <= halfW && p.y >= bottom && p.y <= f.maxY
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
    // ("in N dirs" / "hover to see") carries the headline bucket, so the whole single-bucket
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
            parts.append((d > 1 ? "in \(d) dirs" : "hover to see", head))
        }
        return parts
    }
    /// The status bucket under the cursor on the aggregate pill, or nil. Left cluster
    /// (icon + headline) → headline bucket; each right count → its own bucket.
    private func hoveredAggBucket(_ p: NSPoint) -> String? {
        let s = IslandState.shared
        guard s.aggregate else { return nil }
        let f = panel.frame
        let islandH = max(s.notchHeight, 30)
        let bottom = f.maxY - islandH - (s.frontHovered ? kFrontPeek : 0)
        guard p.y >= bottom, p.y <= f.maxY else { return nil }
        let center = f.midX + curIslandOffset
        let left  = center - curPillWidth / 2
        let right = center + curPillWidth / 2
        let serif = NSFont(name: kSerifFontName, size: 13) ?? .systemFont(ofSize: 13)
        let sans  = NSFont(name: kSansFontName, size: 13) ?? .systemFont(ofSize: 13)

        // Left cluster: [left+18, left+18+leftW]; leftW = leadingSlot + headline width.
        let head = aggHeadlineBucket()
        let iconW: CGFloat = head == "attention" ? 14 : (head == "error" ? 16 : 18)
        let primary = aggHeadlineText()
        let leftW = iconW + (primary.isEmpty ? 0 : 8) + textWidth(primary, serif, tracking: 0.5)
        if p.x >= left + 18, p.x <= left + 18 + leftW { return head }

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
                // The ring sits LEFT of the (variable-width) timer: trailing pad (12), then
                // the timer, then a 10px gap, then the 12px ring. Locate that band.
                let overRing: Bool = item.card.map { card in
                    guard ringVisible(card) else { return false }
                    let timerW = card.elapsed.isEmpty ? 0 : textWidth(card.elapsed, kTimerFont)
                    let ringRight = listRight - 12 - (timerW > 0 ? timerW + 10 : 0)
                    return p.x >= ringRight - 12 - 6 && p.x <= ringRight + 6
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

    /// Run the expensive process scan + transcript checks on a background queue,
    /// then apply the results (prune dead/canceled sessions, rebuild) on main.
    private func refreshLiveness(force: Bool = false) {
        // While hidden (nothing live), the expensive process/sqlite/transcript scan backs off to
        // ~20s — there's no UI to keep fresh. A brand-new session file kicks an immediate scan
        // (force=true, from reload) so the tab still appears with ~no latency.
        livenessTick &+= 1
        if !force && hiddenIdle && livenessTick % 5 != 0 { return }
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
            let live = self.computeLiveTabs()
            let warpTab = hidden ? nil : self.warpActiveTab()   // skip Warp's sqlite read when hidden (no UI)
            var interrupted = Set<String>()
            var declinedPreview: [String: String] = [:]
            for (uuid, _, tx) in active where !tx.isEmpty {
                if self.transcriptInterrupted(tx) {
                    interrupted.insert(uuid)
                    // The agent's response so far, shown in white on the declined row.
                    if let p = self.transcriptActivity(tx)?.preview, !p.isEmpty { declinedPreview[uuid] = p }
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
                // A tab counts as live if a scan saw it in the last 8s — smooths a single
                // transient `ps` miss (scans are every 4s) so a live tab never flickers
                // out, while a genuinely-closed tab clears in ~8-12s.
                self.liveTabs = Set(self.lastSeenLive.filter { now - $0.value < 8 }.keys)
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
        let h: CGFloat = max(nh, 30) + 2 + max(dropH, kFrontPeek)
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
        if let v = sf.transcript { s.transcript = v }
        if let v = sf.ts { s.ts = v }
        if sf.kind == "prompt" {                  // a new turn the user just started
            s.promptTs = sf.ts ?? s.promptTs
            s.turnStartTs = sf.ts ?? s.turnStartTs
            clickFocus = nil                      // a fresh prompt takes focus
        }
    }

    // MARK: - Rebuild the deck

    // Visible = sessions that have actually run (have a file) and whose tab is still
    // live. Open-but-never-run tabs have no session here, so they never appear.
    private func visibleSessions(suppressing suppress: Set<String>) -> [String: LiveSession] {
        sessions.filter { (k, _) in (liveTabs.contains(k) || k == "local") && !suppress.contains(k) }
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
        IslandState.shared.neutralNotIdle = false   // only the dismissed-front branch below sets this
        let suppress = staleDuplicateTabs()
        let vis = visibleSessions(suppressing: suppress)
        guard !vis.isEmpty else {
            frontUUID = nil
            Ticker.shared.stop(); stopClock()
            // No state-file session is live — but Warp tabs running claude with no file (idle,
            // or file cleared) may still be open. Surface them as "{n} idle sessions" + a hover
            // list, exactly like stale ones, instead of collapsing to a bare "Idle".
            let s = IslandState.shared
            let idleCards = liveTabs
                .filter { $0 != "local" && !suppress.contains($0) }
                .sorted()
                .map { u -> SessionCard in
                    let cwd = liveTabCwd[u] ?? ""
                    let proj = cwd.isEmpty ? "Claude Code" : (cwd as NSString).lastPathComponent
                    let label = liveTabTitle[u] ?? ""
                    return SessionCard(id: u, project: proj, title: label.isEmpty ? proj : label,
                                       status: "idle", focus: "warp://session/\(u)",
                                       context: liveTabContext[u] ?? 0)
                }
            if !s.dropdownOpen {
                s.cards = Array(idleCards.dropFirst().prefix(5))
                s.roster = idleCards
                rebuildDropdownItems()
            }
            enterHiddenIdle(idleCount: s.dropdownOpen ? s.roster.count : idleCards.count)
            return
        }

        // Probe git context (repo/branch/churn) for the visible cwds — drives the dropdown's
        // repo/branch grouping + header churn. No-op unless the dropdown is open (throttled).
        refreshGitInfo(Set(vis.values.map(\.cwd).filter { !$0.isEmpty }))

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
        state.contextPct = statuslineContext(f.transcript) ?? f.context
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
                               context: self.statuslineContext(v.transcript) ?? v.context,
                               preview: v.preview, firstPrompt: v.firstPrompt,
                               qHeader: v.qHeader, qText: v.qText)
            card.lastUserMsg = v.lastUserMsg
            card.ultra = v.ultra
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
            s.focus = "warp://session/\(u)"
            let cwd = liveTabCwd[u] ?? ""
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

        // Spinner follows the front session.
        switch state.mode {
        case .thinking, .working: Ticker.shared.start()
        case .done:
            Ticker.shared.stop()
            state.elapsed = formatElapsed(f)        // frozen total
        case .attention, .error, .compacting, .compacted, .idle: Ticker.shared.stop()
        }
        // The 1s clock runs while ANY visible session is mid-turn, so every active row's
        // timer in the dropdown ticks live — not just the front pill's.
        // Delegating sessions (parent done, subagent still live) count as active too — otherwise
        // the clock/poll stops and the overlay never re-evaluates when the delegate finishes.
        let anyActive = vis.contains { $0.value.mode == "working" || $0.value.mode == "thinking" || delegating.contains($0.key) }
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

        // Nothing live, waiting, or errored (all stale / idle) → hide the island entirely.
        if running + needYou + done + errored == 0 {
            Ticker.shared.stop()
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

    /// Which Warp tabs still have a live, interactive (non-forked) CC process. Used only
    /// to GC sessions whose tab closed. Pure IO, safe off the main thread.
    /// Live (non-forked) Warp tabs running claude, mapped to each tab's working
    /// directory (from the env dump) so a tab with no state file can still be
    /// labelled by its project name.
    private func computeLiveTabs() -> (cwds: [String: String], sids: [String: String]) {
        let pids = shell("/usr/bin/pgrep", ["-U", "\(getuid())", "-f", "claude"])
            .split(separator: "\n").map(String.init)
        var cwds = [String: String](), sids = [String: String](), excluded = Set<String>()
        guard !pids.isEmpty else { return (cwds, sids) }
        // ONE `ps eww` for the whole pid LIST (env dumps inline per row). A pid list isn't
        // truncated the way `ps -axeww` is, so we keep the full env — but spawn ps once, not
        // once per process (was ~15 spawns per 4s scan).
        let dump = shell("/bin/ps", ["eww", "-o", "pid=,command=", "-p", pids.joined(separator: ",")])
        for raw in dump.split(separator: "\n") {
            let line = String(raw)
            guard let u = uuidIn(line) else { continue }
            if cwds[u] == nil { cwds[u] = cwdIn(line) }
            // CC writes ~/.claude/sessions/<pid>.json with this process's sessionId, so the tab
            // can resolve its own transcript (and thus its ai-title) even while idle. The row's
            // leading token is the pid; map it to the tab's uuid.
            let pid = line.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
            if sids[u] == nil, !pid.isEmpty,
               let data = FileManager.default.contents(atPath: kCCSessionsDir + "/" + pid + ".json"),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sid = obj["sessionId"] as? String { sids[u] = sid }
            if line.contains("--fork-session") || line.contains("mcp__computer-use") {
                excluded.insert(u)   // forked / computer-use session — hide it
            }
        }
        for u in excluded { cwds.removeValue(forKey: u); sids.removeValue(forKey: u) }
        return (cwds, sids)
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

    // Pull " PWD=…" out of the env dump (leading space avoids matching OLDPWD=).
    // Stops at the next space, so a path with spaces would clip — acceptable.
    private func cwdIn(_ s: String) -> String {
        guard let r = s.range(of: " PWD=") else { return "" }
        return String(s[r.upperBound...].prefix { $0 != " " })
    }

    /// A canceled turn (Esc) fires no Stop hook, so an active session can get stuck showing
    /// thinking/working. Claude Code writes "Request interrupted by user" (a user-type entry)
    /// when that happens. But ANSWERING an AskUserQuestion can also leave that marker — the
    /// difference is the agent then RESUMES, appending real assistant content after it. So the
    /// turn is abandoned only if the marker is the last meaningful entry: scan newest→oldest and
    /// return true at the marker, false the moment we hit real assistant content first.
    /// File IO, safe off the main thread.
    private func transcriptInterrupted(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        let size = fh.seekToEndOfFile()
        fh.seek(toFileOffset: size > 8192 ? size - 8192 : 0)
        guard let s = String(data: fh.readDataToEndOfFile(), encoding: .utf8) else { return false }
        for line in s.split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "user":
                // The marker lives in a user entry's content (string or text blocks).
                let c = (obj["message"] as? [String: Any])?["content"]
                let text: String
                if let str = c as? String { text = str }
                else if let arr = c as? [[String: Any]] { text = arr.compactMap { $0["text"] as? String }.joined(separator: " ") }
                else { text = "" }
                if text.contains("Request interrupted by user") { return true }
            case "assistant":
                // Any real block (text/tool_use/thinking) after the marker → the turn resumed.
                if let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]],
                   content.contains(where: { b in
                       switch b["type"] as? String {
                       case "tool_use", "thinking": return true
                       case "text": return !(((b["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                       default: return false
                       }
                   }) {
                    return false
                }
            default: break
            }
        }
        return false
    }

    /// A live API / connection error (overloaded 529, 500, rate-limit, auth 401, dropped
    /// connection) lands in the transcript as an assistant entry flagged `isApiErrorMessage`,
    /// with human-readable text. No hook fires for it, so the daemon surfaces it: returns the
    /// message if it's the latest meaningful assistant entry, nil once the agent recovers (a
    /// normal assistant block appears after it). Same newest→oldest scan as transcriptInterrupted.
    private func transcriptApiError(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = fh.seekToEndOfFile()
        fh.seek(toFileOffset: size > 8192 ? size - 8192 : 0)
        guard let s = String(data: fh.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        for line in s.split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any] else { continue }
            let content = msg["content"]
            let text: String
            if let arr = content as? [[String: Any]] { text = arr.compactMap { $0["text"] as? String }.joined(separator: " ") }
            else if let str = content as? String { text = str }
            else { text = "" }
            if (obj["isApiErrorMessage"] as? Bool ?? false) || (msg["isApiErrorMessage"] as? Bool ?? false) {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return String((t.isEmpty ? "API Error" : t).prefix(140))
            }
            // A normal assistant block after/instead of the error → recovered, not erroring.
            if let arr = content as? [[String: Any]],
               arr.contains(where: { b in
                   switch b["type"] as? String {
                   case "tool_use", "thinking": return true
                   case "text": return !(((b["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                   default: return false
                   }
               }) {
                return nil
            }
        }
        return nil
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

    /// Map sessionId → CC's live status ("busy"/"idle"), read from Claude Code's own
    /// per-session state files. CC rewrites these continuously, so this leads our hooks.
    /// Safe off the main thread (small files, plain reads).
    private func ccSessionStatuses() -> [String: String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: kCCSessionsDir) else { return [:] }
        var out: [String: String] = [:]
        for f in files where f.hasSuffix(".json") {
            guard let data = fm.contents(atPath: kCCSessionsDir + "/" + f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["sessionId"] as? String,
                  let st = obj["status"] as? String else { continue }
            out[sid] = st
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

    /// Tail the transcript for the *live* activity: the latest assistant entry's final block
    /// gives the real verb ("Thinking" during an extended-thinking block, else the running
    /// tool), and the most recent non-empty assistant text is the freshest preview. File IO,
    /// run off the main thread. Returns nil if nothing usable was found.
    private func transcriptActivity(_ path: String) -> (preview: String, verb: String, thinking: Bool)? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = fh.seekToEndOfFile()
        fh.seek(toFileOffset: size > 16_384 ? size - 16_384 : 0)
        guard let data = try? fh.readToEnd(), let s = String(data: data, encoding: .utf8) else { return nil }
        var textPreview = "", action = "", verb = "", thinking = false
        var classified = false
        for line in s.split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { continue }
            // The very latest assistant entry decides the verb (what it's doing right now);
            // a running tool also yields a concrete object for the preview.
            if !classified, let last = content.last(where: { ($0["type"] as? String) != nil }) {
                switch last["type"] as? String {
                case "thinking": thinking = true; verb = "Thinking"
                case "tool_use":
                    verb = verbForTool(last["name"] as? String ?? "")
                    let tgt = toolTarget(last["name"] as? String ?? "", last["input"] as? [String: Any] ?? [:])
                    action = (verb + " " + tgt).trimmingCharacters(in: .whitespaces)   // "Reading island.swift"
                case "text":     verb = "Responding"
                default:         break
                }
                classified = true
            }
            // Fallback preview = first line of the most recent non-empty text block (may be an
            // earlier entry than the one that set the verb, e.g. when it's now running a tool).
            if textPreview.isEmpty {
                let texts = content.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                if let t = texts.last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    let first = t.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first ?? ""
                    textPreview = String(first.prefix(120))
                }
            }
            if classified && !textPreview.isEmpty { break }
        }
        if !classified && textPreview.isEmpty { return nil }
        // Tool action (concrete object) wins for the preview; otherwise the latest text.
        return (action.isEmpty ? textPreview : action, verb, thinking)
    }

    /// Fires ~2×/sec. Reconciles each known session against CC's live busy/idle status and
    /// the transcript tail, so the pill reflects real activity without waiting for a hook.
    /// Deliberately conservative: attention/error/compacting/compacted are hook-owned and
    /// never overridden here (avoids re-introducing false "waiting for input").
    @objc private func pollLiveStatus() {
        guard !sessions.isEmpty else { return }
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
            var acts: [String: (preview: String, verb: String, thinking: Bool)] = [:]
            var interrupted = Set<String>()
            var apiErrors: [String: String] = [:]
            for (uuid, _, tx) in snap {
                if let a = self.transcriptActivity(tx) { acts[uuid] = a }
                if self.transcriptInterrupted(tx) { interrupted.insert(uuid) }
                if let e = self.transcriptApiError(tx) { apiErrors[uuid] = e }
            }
            DispatchQueue.main.async {
                var changed = false
                let now = Date().timeIntervalSince1970
                let activeModes: Set<String> = ["working", "thinking", "struggling", "error"]
                for (uuid, sessionId, _) in snap {
                    guard let s = self.sessions[uuid] else { continue }
                    // A live API/connection error is the top-priority signal: show red with the
                    // message while it persists, and let it auto-clear (below) once the agent
                    // recovers. The daemon fully owns this state — no hook fires for it.
                    if let err = apiErrors[uuid] {
                        if s.mode != "error" || s.preview != err {
                            s.mode = "error"; s.detail = "API Error"; s.preview = err; s.ts = now; changed = true
                        }
                        continue
                    }
                    // Hook-owned states we never override here (avoids re-introducing false
                    // "waiting for input"). NOTE: "error" is intentionally NOT protected — it's
                    // daemon-owned now, so when apiErrors no longer reports one, the reconcile
                    // below clears it back to working/done.
                    let protected = (s.mode == "compacting" || s.mode == "compacted" || s.mode == "attention")
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
                            if interrupted.contains(uuid) {
                                s.mode = "interrupted"; s.ts = now; s.qHeader = ""; s.qText = ""
                                if let p = acts[uuid]?.preview, !p.isEmpty { s.preview = p }
                                self.persistTerminal(uuid, mode: "interrupted", preview: acts[uuid]?.preview ?? "")
                            } else {
                                s.mode = "done"; s.ts = now
                            }
                            changed = true
                        }
                    }
                    // Freshest preview while live (cheap; no-op when unchanged). Skip the Esc
                    // terminal states and error — their preview is the frozen question /
                    // response-so-far / error message, which the transcript tail would otherwise
                    // overwrite with a stale action.
                    if s.mode != "declined", s.mode != "interrupted", s.mode != "error",
                       let p = acts[uuid]?.preview, !p.isEmpty, s.preview != p { s.preview = p; changed = true }
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

    private func uuidIn(_ s: String) -> String? {
        guard let r = s.range(of: "WARP_TERMINAL_SESSION_UUID=") else { return nil }
        let u = s[r.upperBound...].prefix { $0.isHexDigit }
        return u.isEmpty ? nil : String(u)
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
    /// the highlight is fresh even between 4s scans).
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
        // A little "still alive" wink on the resting mark: briefly swap it for the live
        // working gif, then settle back. Purely cosmetic — doesn't change what the click does.
        if s.mode == .idle && !s.idleWaking {
            s.idleWaking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { IslandState.shared.idleWaking = false }
        }
        // Persistent "{n} idle sessions" pill: a click just toggles its dropdown — never
        // focuses/dismisses a session (there's no meaningful "front" while everything's idle).
        if hiddenIdle && s.mode == .idle && s.idleSessionCount >= 1 {
            if s.dropdownOpen { closeDropdown() } else { openDropdown() }
            return
        }
        // A "Finished" single-session pill: click just acknowledges it — reset to the neutral
        // icon + count pill instead of jumping to the tab (you already know it's done). Not a
        // tab switch, and not the hidden-idle regime — this stays visible. It un-dismisses on
        // its own the moment that session does anything new (see `merge()`).
        if s.mode == .done && !s.aggregate, let front = frontUUID {
            dismissedDoneIds.insert(front)
            rebuild()
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
        // Idle tabs have no state file; reconstruct the focus URL from the uuid so the
        // click still jumps to the tab. They can't be pinned (never front), so don't.
        openFocus(sessions[id]?.focus ?? "warp://session/\(id)")
        // The click focuses this tab in Warp, but a deep-link focus doesn't update Warp's
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

    private func openFocus(_ url: String) {
        if !url.isEmpty, let u = URL(string: url) { NSWorkspace.shared.open(u) }
        else { activateWarp() }
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
    /// Idle sessions have nothing to poll, so it no longer wakes the CPU ~2×/sec around the clock.
    private func startLivePoll() {
        guard liveTimer == nil else { return }
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in self?.pollLiveStatus() }
        t.tolerance = 0.2
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
    private func computeUsage() -> (session: String, today: String) {
        let fm = FileManager.default
        let base = NSString("~/.claude/projects").expandingTildeInPath
        let now = Date().timeIntervalSince1970
        let weekAgo = now - 7 * 86_400
        guard let projects = try? fm.contentsOfDirectory(atPath: base) else { return ("", "") }
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
        for r in usageFiles.values {
            for (h, tok) in r.hours where h >= h7 {
                t7 += tok
                if h >= hMid { tToday += tok }
                if h >= h5 { t5 += tok }
            }
        }
        guard t7 > 0 else { return ("", "") }   // nothing in a week → peek keeps its fallback
        return (Self.fmtTok(t5), Self.fmtTok(tToday))   // wk (t7) still computed; not shown in the peek
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
        guard IslandState.shared.dropdownOpen, !gitProbing, now - lastGitCompute > 3, !cwds.isEmpty else { return }
        gitProbing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var fresh: [String: GitInfo] = [:]
            for cwd in cwds { if let g = self.probeGit(cwd) { fresh[cwd] = g } }
            DispatchQueue.main.async {
                var changed = false
                for (k, v) in fresh where self.gitCache[k] != v { self.gitCache[k] = v; changed = true }
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
