# claude-code-island

A live-activity **island in your Mac's notch** for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). It shows what every session is doing — thinking, running a tool, waiting on you, done — across all your terminals at once, and clicking a session jumps you back to the exact tab it's running in.

```bash
npx claude-code-island install
```

> Requires a Mac with a notch (macOS 13+) and Xcode Command Line Tools (`xcode-select --install`).

<!-- TODO: add a screenshot / gif of the pill + dropdown here -->

## What you get

- **A live pill in the notch** — a spinner while Claude works, an amber prompt when it needs your input, a green ✻ when it's done.
- **Every session at a glance** — run Claude in 5 tabs and the pill aggregates the fleet; open the dropdown to see each one, grouped by repo + branch, with its live verb, turn timer, and context-window fill.
- **Click to jump back** — click a session and it focuses the exact terminal tab it lives in (see terminal support below).
- **Works across your terminals** — when you're running Claude in more than one app, each row is tagged with that app's icon so you can tell a Warp session from a Cursor one at a glance.
- **Status taxonomy** — thinking, working, waiting for input, compacting, struggling (repeated tool errors), interrupted/declined (you hit Esc), and API errors — each with its own color and mark.
- **Notch-hover peek** — hover the notch for your token-usage windows (5h / today / week).

## Supported terminals

Detection and app-icon tagging work everywhere; click-to-focus fidelity depends on what each terminal exposes:

| Terminal | Detected | Click focuses… |
|----------|:---:|---|
| Warp | ✅ | the exact tab (deep link) |
| iTerm2 | ✅ | the exact tab (AppleScript) |
| Apple Terminal | ✅ | the exact tab (AppleScript) |
| Ghostty | ✅ | the exact tab (AppleScript, by working dir) |
| Cursor / VS Code | ✅ | the workspace window (`code`/`cursor` CLI) |
| others | ✅ | brings the app frontmost |

## Commands

```bash
npx claude-code-island install     # compile, install, wire up the Claude Code hook
npx claude-code-island test        # cycle through the states so you can see it
npx claude-code-island uninstall   # remove the app, hook, and config
```

## How it works

Claude Code [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) fire on each turn. `claude-code-island` installs a small hook that, on every event, extracts the session's state from the transcript and writes it to `~/.claude-island/sessions/<tab>.json`. A lightweight native menu-bar daemon watches that folder and renders the notch pill.

Because the daemon just renders those session files, the Claude-specific part is only the hook — the surface itself is agent-agnostic by design.

## Requirements

- **macOS 13+** with a notch (MacBook Pro/Air 2021+).
- **Xcode Command Line Tools** — `xcode-select --install`. The installer compiles a ~200KB native app locally (ad-hoc signed, no Apple Developer account needed).
- **Claude Code** installed and configured.

## Uninstall

```bash
npx claude-code-island uninstall
```

Removes the app bundle, the LaunchAgent, and the hook from `~/.claude/settings.json`.

## License

MIT
