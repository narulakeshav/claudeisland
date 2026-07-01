#!/usr/bin/env python3
"""island-hook.py — single-process Claude Code hook dispatcher for the notch daemon.

Replaces island-hook.sh. The bash version spawned ~8-10 `python3 -c` processes per
hook event and read the whole transcript (`readlines()[-N:]`) several times — on the
USER's critical path, since PreToolUse blocks the tool. This does it in ONE python
process with ONE bounded tail read, and passes paths as variables (never interpolated
into a `-c` program, so a cwd with an apostrophe can't break it or inject code).

Reads the hook JSON on stdin, derives the session's state, and writes it to the
session's file via `island-send` (which posts the Darwin ping the daemon listens for).

Usage: island-hook.py <prompt|tool|post|attention|stop|compact|sessionstart>
Debug: ISLAND_HOOK_DRYRUN=1 prints "<path>\n<json>" instead of spawning island-send.
"""
import json, os, re, sys, subprocess, time, random

EVENT = sys.argv[1] if len(sys.argv) > 1 else ""
HERE = os.path.dirname(os.path.abspath(__file__))
SEND = os.path.join(HERE, "island-send")
ISLAND_DIR = os.environ.get("ISLAND_DIR_OVERRIDE") or os.path.expanduser("~/.claude-island")

TAIL_BYTES = 262_144   # 256KB transcript tail — covers titles, latest usage, previews, errors
HEAD_BYTES = 65_536    # 64KB head — the opening prompt lives near the very top
VERB_HOLD_S = 4.0      # re-pick the whimsical gerund at most once every few seconds (anti-flicker)
# Claude Code's rainbow extended-thinking keyword. Matched on a WORD BOUNDARY (not a bare
# substring) so "ultrathinking", "ultrathinks", or the token glued inside pasted text/URLs
# don't false-trigger the rainbow — only the literal word "ultrathink" does.
ULTRA_RE = re.compile(r"\bultrathink\b")

# Whimsical status verbs in the spirit of Claude Code's own spinner (the real word isn't
# exposed to hooks). Held for VERB_HOLD_S so a fast tool burst doesn't churn the word.
GERUNDS = [
    "Accomplishing", "Actioning", "Actualizing", "Architecting", "Baking", "Beaming", "Beboppin'",
    "Befuddling", "Billowing", "Blanching", "Bloviating", "Boogieing", "Boondoggling", "Booping",
    "Bootstrapping", "Brewing", "Bunning", "Burrowing", "Calculating", "Canoodling", "Caramelizing",
    "Cascading", "Catapulting", "Cerebrating", "Channeling", "Channelling", "Choreographing", "Churning",
    "Clauding", "Coalescing", "Cogitating", "Combobulating", "Composing", "Computing", "Concocting",
    "Considering", "Contemplating", "Cooking", "Crafting", "Creating", "Crunching", "Crystallizing",
    "Cultivating", "Deciphering", "Deliberating", "Determining", "Dilly-dallying", "Discombobulating",
    "Doing", "Doodling", "Drizzling", "Ebbing", "Effecting", "Elucidating", "Embellishing", "Enchanting",
    "Envisioning", "Evaporating", "Fermenting", "Fiddle-faddling", "Finagling", "Flambéing",
    "Flibbertigibbeting", "Flowing", "Flummoxing", "Fluttering", "Forging", "Forming", "Frolicking",
    "Frosting", "Gallivanting", "Galloping", "Garnishing", "Generating", "Gesticulating", "Germinating",
    "Gitifying", "Grooving", "Gusting", "Harmonizing", "Hashing", "Hatching", "Herding", "Honking",
    "Hullaballooing", "Hyperspacing", "Ideating", "Imagining", "Improvising", "Incubating", "Inferring",
    "Infusing", "Ionizing", "Jitterbugging", "Julienning", "Kneading", "Leavening", "Levitating",
    "Lollygagging", "Manifesting", "Marinating", "Meandering", "Metamorphosing", "Misting", "Moonwalking",
    "Moseying", "Mulling", "Mustering", "Musing", "Nebulizing", "Nesting", "Newspapering", "Noodling",
    "Nucleating", "Orbiting", "Orchestrating", "Osmosing", "Perambulating", "Percolating", "Perusing",
    "Philosophising", "Photosynthesizing", "Pollinating", "Pondering", "Pontificating", "Pouncing",
    "Precipitating", "Prestidigitating", "Processing", "Proofing", "Propagating", "Puttering", "Puzzling",
    "Quantumizing", "Razzle-dazzling", "Razzmatazzing", "Recombobulating", "Reticulating", "Roosting",
    "Ruminating", "Sautéing", "Scampering", "Schlepping", "Scurrying", "Seasoning", "Shenaniganing",
    "Shimmying", "Simmering", "Skedaddling", "Sketching", "Slithering", "Smooshing", "Sock-hopping",
    "Spelunking", "Spinning", "Sprouting", "Stewing", "Sublimating", "Swirling", "Swooping", "Symbioting",
    "Synthesizing", "Tempering", "Thundering", "Tinkering", "Tomfoolering", "Topsy-turvying",
    "Transfiguring", "Transmuting", "Twisting", "Undulating", "Unfurling", "Unravelling", "Vibing",
    "Waddling", "Wandering", "Warping", "Whatchamacalliting", "Whirlpooling", "Whirring", "Whisking",
    "Wibbling", "Working", "Wrangling", "Zesting", "Zigzagging",
]

# User-message filtering: skip system-injected pseudo-"user" turns (slash-command wrappers,
# caveats, task-notifications, tool-result blocks) so the prompt anchors read as real typing.
SKIP_PREFIX = ("<command-", "<local-command", "<system-reminder", "<task-notification",
               "Caveat:", "[Request interrupted")
SKIP_CONTAIN = ("</tool-use-id>", "<tool-use-id>", "<output-file>", "<task-id>", "<task-notification")


def read_stdin():
    try:
        return json.loads(sys.stdin.read() or "{}")
    except Exception:
        return {}


def tail(path, nbytes):
    """Last `nbytes` of a file as text (the partial first line is the caller's to skip)."""
    if not path:
        return ""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - nbytes))
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""


def head(path, nbytes):
    if not path:
        return ""
    try:
        with open(path, "rb") as f:
            return f.read(nbytes).decode("utf-8", "replace")
    except OSError:
        return ""


def parse_lines(text):
    """JSON objects from a JSONL chunk; lines that don't parse (e.g. a tail's partial
    first line) are skipped. Returned in file order (oldest first)."""
    out = []
    for line in text.split("\n"):
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def real(m):
    """Normalized user text, or '' if it's a system-injected pseudo-message."""
    m = " ".join((m or "").split())
    if not m or m.startswith(SKIP_PREFIX):
        return ""
    if any(b in m for b in SKIP_CONTAIN):
        return ""
    return m


def user_text(content):
    if isinstance(content, list):
        return " ".join(x.get("text", "") for x in content
                        if isinstance(x, dict) and x.get("type") == "text")
    return str(content)


def compute_title(entries):
    """Latest title: a manual /rename (custom-title) wins over the auto ai-title."""
    ai = ""
    for e in reversed(entries):
        t = e.get("type")
        if t == "custom-title":
            c = e.get("customTitle") or ""
            if c:
                return c                       # most-recent manual rename wins outright
        elif t == "ai-title":
            if not ai:
                ai = e.get("aiTitle") or ""
    return ai


def compute_ctx(entries):
    """Context-window fill (0..1) from the latest assistant entry's token usage."""
    override = 0
    try:
        override = int(open(os.path.join(ISLAND_DIR, "context-window")).read().strip())
    except Exception:
        override = 0
    for e in reversed(entries):
        if e.get("type") != "assistant":
            continue
        u = (e.get("message") or {}).get("usage") or {}
        total = (u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0)
                 + u.get("cache_creation_input_tokens", 0))
        if total <= 0:
            break
        window = override if override > 0 else (1_000_000 if total > 200_000 else 200_000)
        return round(max(0.0, min(1.0, total / window)), 4)
    return 0.0


def compute_lastprompt(d, entries):
    """Most recent typed user message. On UserPromptSubmit it's in the payload (clean, no
    transcript lag); otherwise scan the tail back for the latest real user message."""
    out = real(d.get("prompt", ""))
    if not out:
        for e in reversed(entries):
            if e.get("type") != "user" or e.get("isMeta"):
                continue
            m = real(user_text((e.get("message") or {}).get("content", "")))
            if m:
                out = m
                break
    return out[:200]


def compute_firstprompt(transcript):
    """The session's opening user message (a sticky 'which convo is this' anchor). Scans the
    HEAD forward for the first real typed message. Cached by the caller after the first hit."""
    for e in parse_lines(head(transcript, HEAD_BYTES)):
        if e.get("type") != "user" or e.get("isMeta"):
            continue
        m = " ".join(user_text((e.get("message") or {}).get("content", "")).split())
        if not m or m.startswith(SKIP_PREFIX):
            continue
        if any(b in m for b in SKIP_CONTAIN):
            continue
        return m[:80]
    return ""


def tool_preview(d, entries):
    """Right-side action: Claude's latest commentary this turn, else '<verb> <target>' from the
    tool about to run (file / command / pattern)."""
    # Prefer Claude's own prose. Claude Code writes each content block as its OWN transcript entry
    # — a turn is a run of separate assistant lines like [thinking], [text "Let me check X"],
    # [tool_use Read], then a [tool_result] user line — so the narration is NOT in the latest
    # (tool-only) entry. Walk back through the current turn, skipping thinking / tool-only assistant
    # lines and tool_result/meta user lines, to the most recent assistant text block. Stop at a real
    # typed user prompt (the turn boundary) so we never surface prose from an earlier turn.
    last_text = ""
    for e in reversed(entries):
        t = e.get("type")
        if t == "user":
            if e.get("isMeta"):
                continue   # tool_result / system-injected — not a turn boundary
            if real(user_text((e.get("message") or {}).get("content", ""))):
                break       # a genuine prompt: end of this turn, stop here
            continue
        if t != "assistant":
            continue
        c = (e.get("message") or {}).get("content", "")
        if isinstance(c, list):
            texts = [b.get("text", "") for b in c
                     if isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip()]
            if texts:
                last_text = texts[-1]
                break
    if last_text.strip():
        return last_text.strip().split("\n")[0][:60]
    tool = d.get("tool_name", "")
    ti = d.get("tool_input", {}) or {}
    base = lambda p: os.path.basename(p) if p else ""
    if tool in ("Edit", "MultiEdit", "Write", "Read"):
        tgt = base(ti.get("file_path", ""))
    elif tool == "NotebookEdit":
        tgt = base(ti.get("notebook_path", ""))
    elif tool == "Bash":
        parts = (ti.get("command", "") or "").strip().split()
        tgt = parts[0] if parts else ""
    elif tool in ("Grep", "Glob"):
        tgt = ti.get("pattern", "")
    else:
        tgt = ""
    label = {"Edit": "Editing", "MultiEdit": "Editing", "Write": "Writing", "Read": "Reading",
             "NotebookEdit": "Editing", "Bash": "Running", "Grep": "Searching", "Glob": "Finding",
             "Task": "Delegating", "WebFetch": "Fetching", "WebSearch": "Searching",
             "TodoWrite": "Planning"}.get(tool, tool)
    return (label + " " + tgt).strip()


def post_error(entries):
    """If the just-finished tool errored, its failure text (latest user tool_result)."""
    msg = ""
    for e in reversed(entries):
        if e.get("type") != "user":
            continue
        c = (e.get("message") or {}).get("content", "")
        if not isinstance(c, list):
            continue
        for b in c:
            if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error"):
                cc = b.get("content", "")
                msg = (" ".join(x.get("text", "") if isinstance(x, dict) else str(x) for x in cc)
                       if isinstance(cc, list) else str(cc or ""))
        break
    return " ".join(msg.split())[:120]


def consec_tool_errors(entries):
    """Count of trailing consecutive errored tool steps (a tool_result with is_error), newest
    first; the first clean tool_result ends the streak. One tool error is routine — the agent
    reads it and recovers — but a run of them means it's stuck, surfaced as 'struggling'."""
    n = 0
    for e in reversed(entries):
        if e.get("type") != "user":
            continue
        c = (e.get("message") or {}).get("content", "")
        if not isinstance(c, list):
            continue
        trs = [b for b in c if isinstance(b, dict) and b.get("type") == "tool_result"]
        if not trs:
            continue                       # assistant text etc. — not a tool step
        if any(b.get("is_error") for b in trs):
            n += 1
        else:
            break                          # a clean tool result ends the streak
    return n


def _controlling_tty():
    # The tty AppleScript matches against to focus the exact tab (Terminal/iTerm), and it also
    # keys ghostty/vscode sessions — so this MUST be reliable: an intermittent "" makes the same
    # session flip its state-file name (e.g. cursor-ttysNNN ⇄ local), which the daemon then
    # dedups against itself, blinking the row in and out.
    #
    # Fast, subprocess-free path first: under Terminal/iTerm/Ghostty/Cursor the CC process keeps
    # a real controlling tty, so one of its inherited fds is that tty. os.ttyname can't time out.
    for fd in (2, 1, 0):
        try:
            if os.isatty(fd):
                return os.ttyname(fd)
        except Exception:
            pass
    # Fallback (e.g. all fds redirected): walk UP the process tree to the first ancestor that
    # still owns a tty — the interactive shell above CC does even when CC itself detached (Warp).
    pid = os.getppid()
    for _ in range(10):
        try:
            out = subprocess.run(["/bin/ps", "-o", "tty=,ppid=", "-p", str(pid)],
                                 capture_output=True, text=True, timeout=5).stdout.split()
        except Exception:
            return ""
        if not out:
            return ""
        t = out[0]
        if t and t != "??":
            return t if t.startswith("/dev/") else "/dev/" + t
        if len(out) >= 2 and out[1].isdigit() and out[1] != "0":
            pid = int(out[1])
        else:
            return ""
    return ""


def detect_terminal(cwd=""):
    """Identify the terminal tab this session runs in. Returns (kind, tab_id, focus).

    tab_id keys the state file (one card per tab) and MUST match what the daemon derives from
    the CC process env — so it's built from a per-tab env var the daemon can read too (mirrors
    the proven Warp uuid path). focus is a scheme-tagged descriptor the daemon dispatches on:
        warp://session/<uuid>   Warp deep link            (NSWorkspace.open)
        term:<kind>:<tty>       AppleScript-driven tabs    (focus the tab owning <tty>)
        app:<bundleid>          no per-tab scripting        (just bring the app frontmost)
    Unknown terminals fold into the single always-visible "local" card (unchanged behavior).
    """
    warp_uuid = os.environ.get("WARP_TERMINAL_SESSION_UUID", "")
    warp_focus = os.environ.get("WARP_FOCUS_URL", "")
    if warp_uuid or warp_focus:
        tab = warp_uuid or (warp_focus.rsplit("/", 1)[-1] if warp_focus else "")
        return "warp", (tab or "local"), warp_focus
    tp = os.environ.get("TERM_PROGRAM", "")
    tty = _controlling_tty()
    if tp == "iTerm.app":
        sid = os.environ.get("ITERM_SESSION_ID", "")
        if sid:
            focus = ("term:iterm2:" + tty) if tty else "app:com.googlecode.iterm2"
            return "iterm2", "iterm-" + sid.replace(":", "-"), focus
    elif tp == "Apple_Terminal":
        sid = os.environ.get("TERM_SESSION_ID", "")
        if sid:
            focus = ("term:apple_terminal:" + tty) if tty else "app:com.apple.Terminal"
            return "apple_terminal", "aterm-" + sid.replace(":", "-"), focus
    elif tp == "ghostty" and tty:
        # Ghostty has no per-tab env id, so key by tty. But it DOES ship an AppleScript
        # dictionary, so we can focus the exact tab on click — matched by working directory
        # (encoded in the descriptor; the daemon iterates Ghostty's terminals to find it).
        focus = ("ghostty:" + cwd) if cwd else "app:com.mitchellh.ghostty"
        return "ghostty", "ghostty-" + tty.rsplit("/", 1)[-1], focus
    elif tp == "vscode" and tty:
        # VS Code / Cursor integrated terminal (both report TERM_PROGRAM=vscode). No per-panel
        # scripting to reach a specific terminal, but the `code`/`cursor` CLI can focus the
        # WINDOW holding a workspace via `-r <cwd>` — targets the right window with no side
        # effects. `__CFBundleIdentifier` (set by the launching app, inherited here) tells Cursor
        # from VS Code, gives the bundle for icon/app-resolve. Encode bundle+cwd; daemon runs the CLI.
        bundle = os.environ.get("__CFBundleIdentifier", "")
        is_cursor = ("cursor" in bundle.lower() or "todesktop" in bundle.lower()
                     or "Cursor" in os.environ.get("VSCODE_GIT_ASKPASS_NODE", ""))
        if not bundle:
            bundle = "com.todesktop.230313mzl4w4u92" if is_cursor else "com.microsoft.VSCode"
        kind = "cursor" if is_cursor else "vscode"
        focus = ("editor:" + bundle + ":" + cwd) if cwd else ("app:" + bundle)
        return kind, kind + "-" + tty.rsplit("/", 1)[-1], focus
    return "local", "local", ""


def main():
    d = read_stdin()
    cwd = d.get("cwd") or os.getcwd()
    project = os.path.basename(cwd.rstrip("/")) or "Claude Code"
    title = "Claude Code · " + project

    # Hooks run as children of Claude Code inside the terminal tab, so we inherit the terminal's
    # env. From it we derive a stable per-tab id (keys this session's file — one card per tab)
    # and a focus descriptor the daemon dispatches on to jump back to the tab. See detect_terminal.
    kind, tab, focus = detect_terminal(cwd)
    session_out = "sessions/%s.json" % tab
    ts = float(int(time.time()))
    transcript = d.get("transcript_path", "") or ""

    # The session's last-written state — for the verb-hold carry, the firstPrompt cache, and
    # the attention/idle settle decisions. One small read; missing/garbled → empty.
    prev = {}
    try:
        with open(os.path.join(ISLAND_DIR, session_out)) as f:
            prev = json.load(f)
    except Exception:
        prev = {}
    curmode = prev.get("mode", "")
    prev_vw = prev.get("vw", "")
    prev_vt = float(prev.get("vt", 0) or 0)
    # "ultrathink" (CC's rainbow extended-thinking keyword) flags the turn so the daemon paints
    # the verb in a rainbow gradient. Recomputed on each prompt; carried across the turn otherwise.
    ultra = bool(prev.get("ultra", False))

    # ONE bounded tail read serves title / context / lastPrompt / preview / error.
    entries = parse_lines(tail(transcript, TAIL_BYTES)) if transcript else []
    aiTitle = compute_title(entries)
    context = compute_ctx(entries)
    lastPrompt = compute_lastprompt(d, entries)
    # firstPrompt never changes after turn one — reuse the cached value, else read the head.
    firstPrompt = prev.get("firstPrompt") or compute_firstprompt(transcript)

    def send(payload):
        if os.environ.get("ISLAND_HOOK_DRYRUN"):
            sys.stdout.write(session_out + "\n" + json.dumps(payload) + "\n")
            return
        try:
            p = subprocess.Popen([SEND, session_out], stdin=subprocess.PIPE)
            p.communicate(json.dumps(payload).encode("utf-8"))
        except Exception:
            pass

    def emit(mode, detail, preview="", keep=False, qheader="", qtext="",
             vw="", vt=0.0, ctx=None):
        # keep=True (emit_keep) omits preview/qHeader/qText so the daemon RETAINS the last
        # ones (its merge keeps fields the event omitted) — used for a follow-up Notification
        # on the same pause. A full emit always sends them, so a normal turn clears the prior
        # question. vw/vt carry the held verb word across events (daemon ignores unknown keys).
        payload = {
            "mode": mode, "detail": detail, "project": project, "title": title,
            "context": float(context if ctx is None else ctx), "focus": focus, "id": tab,
            "aiTitle": aiTitle, "cwd": cwd, "ts": ts, "kind": EVENT, "transcript": transcript,
            "firstPrompt": firstPrompt, "lastPrompt": lastPrompt, "ultra": ultra,
        }
        if not keep:
            payload["preview"] = preview or ""
            payload["qHeader"] = qheader
            payload["qText"] = qtext
        if vw:
            payload["vw"] = vw
            payload["vt"] = float(vt)
        send(payload)

    if EVENT == "prompt":
        # Turn just started: thinking, no narration yet. Seed a fresh verb for the new turn so
        # the first tool within VERB_HOLD_S reuses it (and a new turn always gets a new word).
        ultra = bool(ULTRA_RE.search((d.get("prompt", "") or "").lower()))
        emit("thinking", "Thinking…", "", vw=random.choice(GERUNDS), vt=ts)

    elif EVENT == "tool":
        tool = d.get("tool_name", "") or ""
        if tool == "AskUserQuestion":
            # AskUserQuestion always pauses for the user — treat it as "needs input" right here
            # (don't wait on a Notification that may not fire). Carry the question's short
            # header + full text so the dropdown row can show exactly what's being asked.
            qs = (d.get("tool_input", {}) or {}).get("questions") or []
            q = qs[0] if qs else {}
            emit("attention", "Input Needed", "",
                 qheader=(q.get("header", "") or "")[:40],
                 qtext=(q.get("question", "") or "")[:160],
                 vw=prev_vw, vt=prev_vt)
        elif consec_tool_errors(entries) >= 3:
            # Mid-streak of consecutive tool failures → the agent is stuck; show "Struggling…".
            emit("struggling", "Struggling…", tool_preview(d, entries), vw=prev_vw, vt=prev_vt)
        else:
            # Hold the verb for VERB_HOLD_S, then re-pick — matches Claude Code's own spinner
            # cadence and stops the per-tool flicker.
            if prev_vw and (ts - prev_vt) < VERB_HOLD_S:
                vw, vt = prev_vw, prev_vt
            else:
                vw, vt = random.choice(GERUNDS), ts
            emit("working", vw + "…", tool_preview(d, entries), vw=vw, vt=vt)

    elif EVENT == "post":
        err = post_error(entries)
        if err:
            # A tool error is routine — the agent reads it and recovers — so we DON'T flip red
            # for it (red is reserved for API/connection failures, detected daemon-side). But a
            # RUN of consecutive failures surfaces as the amber "struggling" state.
            if consec_tool_errors(entries) >= 3:
                emit("struggling", "Struggling…", err, vw=prev_vw, vt=prev_vt)
            # else: stay working — the next PreToolUse refreshes the verb.
        elif curmode == "attention":
            # Parked "Waiting for input" and the tool just completed → the user responded and
            # Claude is moving again. Flip back to a live thinking state.
            emit("thinking", "Thinking…", "", vw=prev_vw, vt=prev_vt)
        elif curmode == "struggling":
            # A clean tool result broke the failure streak → back to a live working state.
            vw = random.choice(GERUNDS)
            emit("working", vw + "…", "", vw=vw, vt=ts)
        # else: nothing to say — leave the live spinner as-is.

    elif EVENT == "attention":
        nt = d.get("notification_type", "") or ""
        if nt == "idle_prompt":
            # A passive ~60s idle nudge — NOT a real "user needed". Never manufacture a red
            # waiting state. A turn still parked working/thinking here was interrupted (Esc fires
            # no Stop), so settle it to a calm "Finished" rather than a stuck spinner.
            if curmode in ("working", "thinking"):
                emit("done", "", "", vw=prev_vw, vt=prev_vt)
        elif curmode == "attention":
            # Already parked in attention — almost always an AskUserQuestion pause (the only
            # other way in here), and Claude Code's own Notification hook fires again for that
            # same pause. Don't stomp its "Input Needed" label with the generic "Permission" —
            # just refresh the heartbeat so the card doesn't look stale.
            emit("attention", prev.get("detail") or "Input Needed", keep=True, vw=prev_vw, vt=prev_vt)
        else:
            # Permission: keep the pending tool action (from the preceding PreToolUse) on the
            # right, label the left "Permission".
            emit("attention", "Permission", keep=True, vw=prev_vw, vt=prev_vt)

    elif EVENT == "stop":
        # The Stop payload carries the full final message — reliable, no transcript race.
        emit("done", "", d.get("last_assistant_message", "") or "", vw=prev_vw, vt=prev_vt)

    elif EVENT == "compact":
        # PreCompact: transcript is about to be compacted. Show "Compacting…" until it finishes.
        emit("compacting", "Compacting…", "", vw=prev_vw, vt=prev_vt)

    elif EVENT == "sessionstart":
        # SessionStart fires for startup/resume/clear/compact. Only source=compact means a
        # compaction just finished. Force the ring low (the latest usage is the summarization
        # call, which read the full pre-compaction context — stale-high); the next turn recomputes.
        if (d.get("source", "") or "") == "compact":
            emit("compacted", "Compacted", "", ctx=0.0, vw=prev_vw, vt=prev_vt)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass   # never let a hook error bubble — CC reports any non-zero hook exit as an error
    sys.exit(0)
