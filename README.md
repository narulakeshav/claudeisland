# claude-code-island

A live-activity **island in your Mac's notch** for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). See what every session is doing — across all your terminals — and jump back to the exact tab with one click.

```bash
npx claude-code-island install
```

> Requires a Mac with a notch (macOS 13+) and Xcode Command Line Tools (`xcode-select --install`).

<!-- TODO: replace with a real screenshot / gif of the pill + dropdown -->
![claude-code-island in the notch](docs/screenshot.png)

## Every session at a glance

Run Claude Code in five tabs and the notch pill becomes a fleet dashboard — it tallies how many sessions are working, waiting on you, or done. Open the dropdown and each one is its own row, grouped by repo and branch, with its live verb, turn timer, and context-window fill.

## Live status, not just a "done" ping

The pill shows a spinner while Claude thinks or runs a tool, turns amber the moment a session needs your input, and settles to a green ✻ when it finishes. The full taxonomy is color-coded in real time: thinking, working, waiting for input, compacting, struggling (a run of tool errors), interrupted/declined (you hit Esc), and API errors.

## Click to jump back to the exact tab

Clicking a session focuses the precise terminal tab it's running in — not just the app. Warp uses its deep link, iTerm2 / Apple Terminal / Ghostty use AppleScript, and Cursor / VS Code use their CLI to focus the right workspace window. No hunting through tabs to find the one that's waiting on you.

## Works across every terminal you use

Warp, iTerm2, Apple Terminal, Ghostty, Cursor, and VS Code are all detected automatically. When you're running Claude in more than one app at once, each dropdown row is tagged with that app's icon, so a Warp session reads differently from a Cursor one at a glance.

## Token and context awareness

Every session carries a ring showing how full its context window is, so you can see who's about to compact. Hover the notch itself for a peek at your token-usage windows — the last 5 hours, today, and this week — without leaving what you're doing.

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
