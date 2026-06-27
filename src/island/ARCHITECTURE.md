# ClaudeIsland — Architecture & Hard-Won Notes

A notch "Dynamic Island"–style live activity for Claude Code (CC) on macOS. Shows
what each CC session is doing in a pill around the MacBook notch, with the other
sessions stacked behind as cards. This doc is for an agent picking this up cold:
the moving parts, the Warp internals we reverse-engineered, the multi-session
syncing model, and — most important — the **non-obvious quirks** that cost hours.

---

## 1. The three processes

```
Claude Code hooks ──> island-hook.sh ──> island-send ──> ~/.claude-island/sessions/<tab>.json
                                                              │  (+ Darwin notification)
                                                              ▼
                                                       island (daemon)  ──> NSPanel at the notch
```

- **`island.swift`** — the daemon. A persistent `LSUIElement` background agent
  (LaunchAgent `com.claude-island.app`, KeepAlive). Owns a borderless,
  non-activating `NSPanel` pinned top-center of the notch screen, rendering a
  SwiftUI `IslandView`. Woken by a Darwin notification; also polls on a 4s timer.
- **`island-hook.sh`** — invoked by CC hooks. Reads the hook JSON on stdin,
  derives the session's state, writes it to that session's file via `island-send`.
- **`island-send.swift`** — tiny helper: reads JSON on stdin, atomically writes it
  to the path given as `argv[1]` (relative to `~/.claude-island`, default
  `event.json`), then posts the Darwin notification `com.claude-island.event`.
- **`bin/cli.js`** — installer: compiles the two binaries into
  `~/Applications/ClaudeIsland.app`, installs the LaunchAgent, wires the hooks
  into `~/.claude/settings.json` (global, so all projects get them).

### IPC
- **Darwin notifications** (`CFNotificationCenterGetDarwinNotifyCenter`) — a
  content-less "something changed" ping. The daemon re-reads files on receipt.
- **Files** in `~/.claude-island/` — the actual state. `sessions/<tabUUID>.json`
  is one file per live session (the source of truth). Atomic writes only.

### Paths (`~/.claude-island/`)
- `sessions/<tabUUID>.json` — per-session state (the multi-session model).
- `event.json` — legacy single-session file; still the `island-send` default but
  the daemon no longer reads it.
- `context-window` — optional integer override for the context-ring denominator.
- `claude.gif`, `claude-thinking.gif` — spinner art (placed manually for now; the
  installer does **not** copy them yet — a known TODO).

---

## 2. Hooks → state machine

Hooks wired in `~/.claude/settings.json` (each runs `island-hook.sh <event>`):

| CC hook            | arg         | meaning                              |
|--------------------|-------------|--------------------------------------|
| `UserPromptSubmit` | `prompt`    | turn started → `thinking`            |
| `PreToolUse`       | `tool`      | working → `working` (+ a verb)       |
| `PostToolUse`      | `post`      | tool finished; emits `error` only if it failed |
| `Notification`     | `attention` | permission / idle prompt → `attention` |
| `Stop`             | `stop`      | turn finished → `done`               |

Modes the daemon renders: `idle` (hidden), `thinking`, `working`, `attention`,
`error`, `done`.

- `thinking` — amber, `claude-thinking.gif`, right side shows the **live turn timer**.
- `working` — coral, `claude.gif`, a random whimsical gerund as the verb, right
  side shows the preview (Claude's latest text if its last block is text, else the
  tool action like "Editing X" / "Running Y").
- `error` — red triangle, "Error", failure text. **Transient**: the next tool/stop
  event overwrites it.
- `attention` — red `!`; `idle_prompt` → "Waiting for input", else "Permission"
  retaining the pending tool action.
- `done` — green ✓, "Finished <Xs>", final message. The final message comes from
  the **Stop payload's `last_assistant_message`**, NOT the transcript (see quirks).

---

## 3. Warp integration (the key unlock)

Warp exports per-tab env vars into every shell. Because CC hooks run as children
of the CC process *inside that tab*, the hook inherits them:

- **`WARP_FOCUS_URL=warp://session/<uuid>`** — a deep link. `open`-ing it (or
  `NSWorkspace.shared.open`) **focuses that exact Warp tab/pane**. This is how
  clicking a card/pill jumps to the right tab. Verified working.
- **`WARP_TERMINAL_SESSION_UUID`** — the same `<uuid>`. This is the **stable
  per-tab key** for the whole multi-session model. It identifies the *tab*, not
  the CC process, so it survives CC restarts in the same tab.
- **`AI_AGENT=claude-code_<version>_harness`** — Warp tags the shell with the
  agent name + version. Confirms "this tab is running CC" and is why Warp's focus
  is so clean (Warp has first-class agent awareness; cf. `WARP_CLI_AGENT_PROTOCOL_VERSION`).

Dead ends we already checked (don't re-investigate):
- No persisted session→tab map on disk — Warp sessions are ephemeral.
- The `warp://` vocabulary is built at runtime; only `session/<uuid>` (focus) is
  reliably usable. No discoverable "rename tab" / "run command" action, so we
  **cannot push status into Warp's own tab bar**.
- `oz` (in `Warp.app/Contents/Resources/bin`) is Warp's **cloud** agent CLI —
  irrelevant to local tab control.
- AppleScript: Warp's dictionary doesn't expose windows/tabs (`count windows` errors).

---

## 4. Multi-session model

### Write side (hook)
The hook derives `TAB_UUID = WARP_TERMINAL_SESSION_UUID` (falls back to the UUID
in `WARP_FOCUS_URL`, then `"local"` for non-Warp shells) and writes
`sessions/<TAB_UUID>.json` with: `mode, detail, preview, project, context, focus,
id, aiTitle, cwd, ts, kind, transcript`.
- `aiTitle` = Claude Code's AI-generated session title, read from the transcript's
  `{"type":"ai-title","aiTitle":...}` entries. Used as the card label.
- `kind` = the hook event type (`prompt` matters for focus — see below).
- `ts` = epoch seconds at emit; drives recency + the turn timer.

### Read side (daemon)
- `reload()` (on Darwin ping) re-reads **every** session file and merges each into
  an in-memory `LiveSession` keyed by uuid. **Files are the source of truth**: a
  session whose file is gone is dropped. Merge is field-wise and keeps fields the
  event omitted (so `emit_keep`, which omits `preview`, retains the last preview).
- `rebuild()` computes the deck:
  - **Front pill** = the focused tab. Selection order: a tab the user **clicked**
    (`clickFocus`) → the most recent **UserPromptSubmit** (`promptTs`) → most recent
    activity (`ts`). Rationale: the tab you last *typed in* or *clicked* is "where
    you are"; a background-working session shouldn't steal the front.
  - **Back cards** = the other visible sessions, most-recent first, capped at 5.
- **Visibility filter** `visibleSessions()`: a session shows iff
  `(liveTabs.contains(uuid) || uuid == "local") && mode != "idle"`.

### Liveness, GC, and forked filtering (`refreshLiveness`, 4s timer)
Runs the expensive IO **on a background queue** (see quirks — doing it on main
froze the bar), then applies on main:
- `computeLiveTabs()` — `pgrep -U <uid> -f claude`, then per-pid `ps eww` to read
  each process's env. A tab is "live" if some CC process carries its
  `WARP_TERMINAL_SESSION_UUID`. **Excluded** if that process's command line
  contains `--fork-session` or `mcp__computer-use` (hides forked / computer-use
  sessions, e.g. Claude Desktop's automation tabs).
- **Debounce**: `lastSeenLive[uuid]` is stamped each scan; `liveTabs` = uuids seen
  within the last 15s. This smooths transient `ps` misses so a live tab never
  flickers out (or gets GC'd) from a single bad scan.
- **GC policy**: we do **not** delete files for dead tabs — they're just hidden by
  the liveTabs filter, and the file lingers harmlessly. Only **canceled** sessions
  delete their file (see cancel detection). This avoids the earlier bug where a
  transient scan miss permanently deleted a live tab's file.

### Cancel detection
Pressing **Esc** to interrupt a turn fires **no Stop hook**, so an active session
would otherwise stay stuck on `working`/`thinking`. CC writes
`Request interrupted by user` as the latest transcript entry — the daemon polls
each active session's transcript tail (last ~4KB) for that marker and, if found,
removes the session + deletes its file. (File IO; runs on the background queue.)

### Clicks
- Front pill click → focus its tab; if it's `done`, also dismiss that card
  (remove file + memory).
- Back card click → focus that tab AND set `clickFocus` so it becomes the front.

---

## 5. QUIRKS & GOTCHAS (read this section)

**Verification / tooling**
- 🔴 **`screencapture` does NOT include the physical notch hardware.** It records
  the framebuffer, where the notch is just a reserved region. Right-side text that
  looks perfectly clear in a screenshot can still be physically clipped by the
  camera housing on the real screen. **You cannot verify notch clipping from
  screenshots — ask the human.** This wasted real time.
- `ps -axeww` (all processes) **truncates** long command lines, so a CC process's
  env (which appears after its huge arg list) gets cut and the UUID is lost. Use
  **per-pid `ps eww -o command= -p <pid>`** instead — it returns full env.
- The screenshot crop used during dev: `screencapture -x out.png` then
  `sips -c <H> <W> --cropOffset <y> <x>`. The display sleeps/locks during long
  sessions; `caffeinate -u -t N &` before capturing helps.

**Transcript behavior**
- 🔴 **The transcript is written in BATCHES at tool-execution time, not streamed.**
  There is no live "thinking" text to tail. This kills any "show live thoughts"
  idea. `UserPromptSubmit → thinking` is the ceiling for thinking detection.
- The Stop payload includes `last_assistant_message` — use it for the done preview.
  Reading the transcript at Stop time races the final flush and gives the
  *previous* message.
- Context fill = `(input_tokens + cache_read_input_tokens + cache_creation_input_tokens)`
  from the latest assistant `usage`, over the window. **The transcript strips the
  model's `[1m]` suffix**, so you can't read the 1M window from the model id —
  honor `~/.claude-island/context-window` (an integer), else infer 1M once usage
  exceeds 200k. (Set to `1000000` for the 1M-context machine.)

**Hooks**
- CC loads hook config **at session start**. A CC session already running before
  the hooks were installed won't fire them until it's restarted. A session only
  appears on the island **after it fires a hook event** (prompt/tool/etc) — an
  idle, freshly-opened tab is invisible until it does something. (This is the
  current event-driven model; a "presence-driven" model that shows all open tabs
  is a deferred design decision.)

**SwiftUI / layout**
- The notch gap is kept centered on the camera by offsetting the whole island by
  `(rightW - leftW)/2`. For this to be exact, **every leading icon needs a fixed
  `.frame(width:)`** — SF Symbols (checkmark/exclamation/triangle) otherwise have
  variable widths that throw the centering off and push the right text under the
  notch. The GIF icons are already `.frame(width: 18)`.
- `IslandShape`'s left/right walls are **inset by the shoulder radius (~12pt)** (the
  concave re-entrant fillet). A back card's peek must therefore exceed ~12pt or the
  visible filled sliver is ~0 and the card looks invisible. `cardPeek = 22` → ~10pt
  visible.
- **Back-card width must be computed, not measured.** Measuring the pill via a
  `GeometryReader`/PreferenceKey returned an unreliable (too-small) value, so cards
  came out narrower than the pill and hid *completely* behind it. Width is now
  `leftW + notchWidth + notchClearance + rightW + 36`, the same parts the
  `fixedSize` pill lays out from — deterministic and exact.
- **Back cards are siblings of the pill in a ZStack, NOT in its `.background`.** A
  background view's hit-testing is clipped to the primary view's bounds, so a
  hovered card that grows left of the pill stopped receiving hover events once the
  cursor left the thin sliver. As siblings, each card's full frame is hit-testable.
- The spinner uses a **run-loop `Timer`** (`Ticker`), not SwiftUI
  `repeatForever` — the latter doesn't run inside a non-activating background panel.
- Frosted-glass cards use `.ultraThinMaterial` + `.environment(\.colorScheme,
  .dark)` (so the material renders dark, not washed-out) + a black→translucent
  vertical gradient + a status-color tint at the bottom.

**Daemon threading**
- 🔴 **The process scan + transcript reads MUST run off the main thread.** Doing
  `pgrep` + per-pid `ps eww` (≈15 subprocess spawns) synchronously in the timer
  callback froze the bar (spinner stalls, stale offset pushes text under the notch,
  cards don't rebuild). `refreshLiveness()` snapshots on main → does IO on a global
  queue → applies results on main.

**Panel geometry**
- Panel height = notch height + 2pt only, so it never covers (and blocks clicks to)
  the terminal tabs just below the menu bar.
- Panel width = 1100pt, wide enough that an expanded hover card doesn't hit the
  panel bound and clip, but not so wide it covers the far-left app menus or
  far-right status items.
- `notchClearance` (currently 80) is the slack added to the notch gap so text
  clears the **physical** notch. Tune this with a human looking at the real screen.

---

## 6. Build / deploy / test

```bash
APP="$HOME/Applications/ClaudeIsland.app/Contents/MacOS"
SRC=".../src/island"
swiftc -O -o "$APP/island"      "$SRC/island.swift"      -framework Cocoa -framework SwiftUI
swiftc -O -o "$APP/island-send" "$SRC/island-send.swift" -framework Foundation
cp "$SRC/island-hook.sh" "$APP/island-hook.sh"; chmod +x "$APP/island-hook.sh"
codesign --force --deep --sign - "$HOME/Applications/ClaudeIsland.app"
launchctl kickstart -k "gui/$(id -u)/com.claude-island.app"   # restart daemon
```

Drive a fake session for testing (bypasses the live pipeline). Use `id:"local"`
to skip the liveTabs filter, or a real live tab's UUID to pass it:
```bash
echo '{"mode":"working","detail":"Crafting…","preview":"Editing x.swift",
"project":"demo","context":0.4,"focus":"warp://session/local","id":"local",
"aiTitle":"Demo","cwd":"/x","ts":'"$(date +%s)"'.0,"kind":"tool","transcript":""}' \
  | "$APP/island-send" "sessions/local.json"
```

Remember: anything you do in *this* tab fires real hooks that overwrite this
session's file mid-test. And screenshots can't confirm physical-notch clipping.

---

## 7. Known TODOs / deferred

- Installer (`cli.js`) does not yet copy the GIF assets into `~/.claude-island/`.
- `PostToolUse` wiring was hand-patched into `settings.json` during dev; confirm
  `cli.js` writes it on a fresh install.
- npm package is still named `claude-notification`; README/screenshots describe the
  old banner version.
- **Presence- vs event-driven** display (show idle open tabs vs only-after-activity)
  is an open product decision.
- Front-focus after a daemon restart falls back to most-recent activity until you
  prompt a tab (promptTs isn't persisted).
