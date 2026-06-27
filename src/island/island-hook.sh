#!/bin/bash
# island-hook.sh — dispatches Claude Code hook events to the notch daemon.
# Usage: island-hook.sh <prompt|tool|attention|stop>
# Reads the hook JSON payload on stdin, builds a normalized payload, pipes to
# island-send. Left shows a verb (or "Done"); right shows a clip of Claude's
# latest message, read live from the transcript.

EVENT="$1"
SEND="$(dirname "$0")/island-send"
INPUT=$(cat)

PROJECT=$(echo "$INPUT" | python3 -c "
import sys, json, os
try: d = json.load(sys.stdin)
except: d = {}
cwd = d.get('cwd') or os.getcwd()
print(os.path.basename(cwd.rstrip('/')) or 'Claude Code')
" 2>/dev/null)
[ -z "$PROJECT" ] && PROJECT="Claude Code"
TITLE="Claude Code · $PROJECT"

# Warp sets a per-tab/pane deep link in the shell env (warp://session/<uuid>).
# Hooks run as children of Claude Code inside that tab, so we inherit it and can
# refocus the exact tab on click — not just bring Warp forward. This is also the
# per-session key the multi-session UX will hang off of.
FOCUS="${WARP_FOCUS_URL:-}"

# Per-tab identity (Warp's session UUID) keys this session's state file, so the
# daemon shows one card per tab and routes clicks back to the right one. Falls
# back to the UUID inside the focus URL, then to "local" for non-Warp shells.
TAB_UUID="${WARP_TERMINAL_SESSION_UUID:-}"
[ -z "$TAB_UUID" ] && [ -n "$FOCUS" ] && TAB_UUID="${FOCUS##*/}"
[ -z "$TAB_UUID" ] && TAB_UUID="local"
SESSION_OUT="sessions/${TAB_UUID}.json"
TS=$(date +%s)
CWD=$(echo "$INPUT" | python3 -c "import sys,json,os;d=json.load(sys.stdin);print(d.get('cwd') or os.getcwd())" 2>/dev/null)

TRANSCRIPT=$(echo "$INPUT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null)

# Claude Code's AI-generated session title — the card's label when hovered.
AITITLE=$(python3 -c "
import json
t = ''
try:
    for line in reversed(open('$TRANSCRIPT').readlines()[-500:]):
        try: d = json.loads(line)
        except: continue
        if d.get('type') == 'ai-title':
            t = d.get('aiTitle', '') or ''
            break
except: pass
print(t)
" 2>/dev/null)

# Context-window fill (0..1) from the latest assistant entry's token usage.
# input + cache_read + cache_creation ≈ the live prompt size. The transcript
# strips the model's "[1m]" suffix, so the window can't be read reliably from
# the model id; honor an explicit override in ~/.claude-island/context-window
# (a plain integer), else infer 1M once usage exceeds the 200k base window.
CTX=$(python3 -c "
import json, os
tx = '$TRANSCRIPT'
override = 0
try:
    override = int(open(os.path.expanduser('~/.claude-island/context-window')).read().strip())
except: pass
pct = 0.0
try:
    for line in reversed(open(tx).readlines()[-200:]):
        try: d = json.loads(line)
        except: continue
        if d.get('type') != 'assistant': continue
        u = d.get('message', {}).get('usage', {}) or {}
        total = (u.get('input_tokens', 0) + u.get('cache_read_input_tokens', 0)
                 + u.get('cache_creation_input_tokens', 0))
        if total <= 0: break
        window = override if override > 0 else (1_000_000 if total > 200_000 else 200_000)
        pct = max(0.0, min(1.0, total / window))
        break
except: pass
print(round(pct, 4))
" 2>/dev/null)
[ -z "$CTX" ] && CTX=0

# Whimsical status verbs in the spirit of Claude Code's own spinner (the real
# word isn't exposed to hooks). A fresh one fires on each prompt/tool event.
GERUNDS=(Baking Brewing Cogitating Computing Conjuring Cooking Crafting Crunching \
Deliberating Divining Finagling Forging Hatching Herding Honking Ideating Imagining \
Incubating Manifesting Marinating Moseying Mulling Musing Noodling Percolating Pondering \
Processing Puzzling Reticulating Ruminating Schlepping Shimmying Simmering Spelunking \
Sprouting Stewing Synthesizing Tinkering Transmuting Unfurling Vibing Wandering Whirring)
pick() { echo "${GERUNDS[$((RANDOM % ${#GERUNDS[@]}))]}"; }

# First line of Claude's most recent assistant text in the transcript.
latest_text() {
    [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || { echo ""; return; }
    python3 -c "
import json
last = ''
try:
    lines = open('$TRANSCRIPT').readlines()[-400:]
    for line in reversed(lines):
        try: d = json.loads(line)
        except: continue
        if d.get('type') == 'assistant':
            c = d.get('message', {}).get('content', '')
            if isinstance(c, list):
                texts = [x.get('text','') for x in c if x.get('type') == 'text']
                msg = texts[-1] if texts else ''
            else:
                msg = str(c)
            first = msg.strip().split(chr(10))[0][:120]
            if first:           # skip tool_use-only entries; keep scanning back
                last = first
                break
except: pass
print(last)
" 2>/dev/null
}

emit() { # emit <mode> <detail> <preview>
    python3 -c "
import json, sys
print(json.dumps({'mode': sys.argv[1], 'detail': sys.argv[2], 'preview': sys.argv[3],
                  'project': sys.argv[4], 'title': sys.argv[5], 'context': float(sys.argv[6]),
                  'focus': sys.argv[7], 'id': sys.argv[8], 'aiTitle': sys.argv[9],
                  'cwd': sys.argv[10], 'ts': float(sys.argv[11]), 'kind': sys.argv[12],
                  'transcript': sys.argv[13]}))
" "$1" "$2" "$3" "$PROJECT" "$TITLE" "$CTX" "$FOCUS" "$TAB_UUID" "$AITITLE" "$CWD" "$TS" "$EVENT" "$TRANSCRIPT" | "$SEND" "$SESSION_OUT"
}

emit_keep() { # emit <mode> <detail>, omitting preview so the daemon retains it
    python3 -c "
import json, sys
print(json.dumps({'mode': sys.argv[1], 'detail': sys.argv[2], 'project': sys.argv[3],
                  'title': sys.argv[4], 'context': float(sys.argv[5]), 'focus': sys.argv[6],
                  'id': sys.argv[7], 'aiTitle': sys.argv[8], 'cwd': sys.argv[9],
                  'ts': float(sys.argv[10]), 'kind': sys.argv[11], 'transcript': sys.argv[12]}))
" "$1" "$2" "$PROJECT" "$TITLE" "$CTX" "$FOCUS" "$TAB_UUID" "$AITITLE" "$CWD" "$TS" "$EVENT" "$TRANSCRIPT" | "$SEND" "$SESSION_OUT"
}

case "$EVENT" in
    prompt)
        # Turn just started: Claude is thinking, no narration/tool yet.
        emit thinking "Thinking…" ""
        ;;
    tool)
        # Show Claude's text if its latest block is text, else the tool action.
        PREVIEW=$(echo "$INPUT" | python3 -c "
import sys, json, os
d = json.load(sys.stdin)
tx = d.get('transcript_path','')
last_kind=''; last_text=''
try:
    for line in reversed(open(tx).readlines()[-400:]):
        try: e=json.loads(line)
        except: continue
        if e.get('type')=='assistant':
            c=e.get('message',{}).get('content','')
            if isinstance(c,list) and c:
                lb=c[-1]
                last_kind=lb.get('type','')
                ts=[b.get('text','') for b in c if b.get('type')=='text']
                if ts: last_text=ts[-1]
            break
except: pass
if last_kind=='text' and last_text.strip():
    print(last_text.strip().split(chr(10))[0][:60])
else:
    tool=d.get('tool_name',''); ti=d.get('tool_input',{}) or {}
    base=lambda p: os.path.basename(p) if p else ''
    if tool in ('Edit','MultiEdit','Write','Read'): tgt=base(ti.get('file_path',''))
    elif tool=='NotebookEdit': tgt=base(ti.get('notebook_path',''))
    elif tool=='Bash':
        parts=(ti.get('command','') or '').strip().split(); tgt=parts[0] if parts else ''
    elif tool in ('Grep','Glob'): tgt=ti.get('pattern','')
    else: tgt=''
    label={'Edit':'Editing','MultiEdit':'Editing','Write':'Writing','Read':'Reading',
           'NotebookEdit':'Editing','Bash':'Running','Grep':'Searching','Glob':'Finding',
           'Task':'Delegating','WebFetch':'Fetching','WebSearch':'Searching','TodoWrite':'Planning'}.get(tool,tool)
    print((label+' '+tgt).strip())
" 2>/dev/null)
        emit working "$(pick)…" "$PREVIEW"
        ;;
    post)
        # A tool just finished. If it errored, flash an error state with the
        # failure text; the next tool/stop event restores the normal spinner.
        ERR=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
tx = d.get('transcript_path','')
def text_of(c):
    if isinstance(c, list):
        return ' '.join(b.get('text','') if isinstance(b,dict) else str(b) for b in c)
    return str(c or '')
msg = ''
try:
    for line in reversed(open(tx).readlines()[-200:]):
        try: e = json.loads(line)
        except: continue
        if e.get('type') != 'user': continue
        c = e.get('message',{}).get('content','')
        if not isinstance(c, list): continue
        for b in c:
            if isinstance(b, dict) and b.get('type') == 'tool_result' and b.get('is_error'):
                msg = text_of(b.get('content',''))
        break
except: pass
print(' '.join(msg.split())[:120])
" 2>/dev/null)
        if [ -n "$ERR" ]; then
            emit error "" "$ERR"
        else
            # If the session was parked "Waiting for input" — an AskUserQuestion answer or
            # a permission prompt — and the tool just completed, the user has responded and
            # Claude is moving again. Flip the ticker back to a live thinking state instead
            # of leaving it stuck on the stale attention label until the next prompt.
            CURMODE=$(python3 -c "
import json, os
try: print(json.load(open(os.path.expanduser('~/.claude-island/$SESSION_OUT'))).get('mode',''))
except: print('')
" 2>/dev/null)
            if [ "$CURMODE" = "attention" ]; then emit thinking "Thinking…" ""; fi
        fi
        ;;
    attention)
        NT=$(echo "$INPUT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('notification_type','') or '')" 2>/dev/null)
        if [ "$NT" = "idle_prompt" ]; then
            # A finished (done) session that's merely sitting idle should stay green
            # "Finished" — not flip to a red attention state just because Claude Code
            # nudges "Waiting for input" ~60s later. Suppress the nudge when already done.
            # (Permission prompts in the else-branch keep their red attention state.)
            CURMODE=$(python3 -c "
import json, os
try: print(json.load(open(os.path.expanduser('~/.claude-island/$SESSION_OUT'))).get('mode',''))
except: print('')
" 2>/dev/null)
            if [ "$CURMODE" != "done" ]; then emit attention "Waiting for input" ""; fi
        else
            # Permission: keep the pending tool action (set by the preceding
            # PreToolUse) on the right, label the left "Permission".
            emit_keep attention "Permission"
        fi
        ;;
    stop)
        # The Stop payload carries the full final message — reliable, no transcript race.
        MSG=$(echo "$INPUT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('last_assistant_message','') or '')" 2>/dev/null)
        emit done "" "$MSG"
        ;;
    *)
        exit 0
        ;;
esac

# Never let a hook's incidental exit code (e.g. a falsy test on the last line)
# bubble up — Claude Code reports any non-zero hook exit as an error.
exit 0
