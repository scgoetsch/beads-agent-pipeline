#!/usr/bin/env bash
# PreToolUse hook — blocks analysis scripts when no beads issue is in_progress.
#
# Claude Code passes the tool call as JSON on stdin:
#   { "tool_name": "Bash", "tool_input": { "command": "..." }, ... }
#
# Exit 2 + stderr blocks the tool and surfaces the message to Claude.
# Exit 0 allows the tool to proceed.

# Root from this file's location, not a literal -- see the note in bd-prime-hook.sh. This one fails OPEN on purpose: exit 2 here would block every Bash call
# and brick the session, which is worse than the outage. Open, but never silent.
WS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)
if [ -z "$WS" ] || ! cd "$WS"; then
    echo "⚠ bd-prerun-hook: cannot resolve the workspace from '${BASH_SOURCE[0]}' — the pkill, bd-remember and untracked-script guards are OFF for this session." >&2
    exit 0
fi

# ── Parse command from hook JSON payload ──────────────────────────────────────
command=$(python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('tool_input', {}).get('command', ''))
except Exception:
    print('')
" 2>/dev/null)

[ -z "$command" ] && exit 0

# ── GUARD: bare pkill / killall ────────────────────────────────────────
# Runs before memory admission; all invocations in a compound command are checked.
#
# THE TRAP. pkill -f PATTERN matches against the FULL command line, and the
# agent shell running the command has that very pattern on its own command
# line. So the pattern matches the shell issuing it and the command kills
# itself. Observed twice on 2026-07-25 (exit 144), once aborting a chained job
# submission; and again on 2026-08-13, where the same self-match killed twelve
# running simulations mid-flight (rc=143) plus the shell writing the note that
# was documenting the trap.
#
# This is an accident guard, NOT a shell sandbox. Tokenize literal commands to handle quoting,
# wrappers and interpreter options; never evaluate shell input. Dynamic expansion/aliases and
# arbitrary shell programs remain outside this heuristic's scope.
SCRIPT_DIRS_RE='scripts'  # regex alternation, e.g. scripts|pipelines|analysis
policy=$(python3 - "$command" "$SCRIPT_DIRS_RE" <<'PY'
import os, re, shlex, sys

script_path = re.compile(r'(?:^|/)(?:' + sys.argv[2] + r')/[^/].*')
assignment = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')

def unwrap(words):
    while words:
        name = os.path.basename(words[0])
        if assignment.match(words[0]) or name in ('command', 'exec', 'nohup', 'then', 'do', 'if', '!'):
            words = words[1:]
            if words and words[0] == '--': words = words[1:]
        elif name in ('sudo', 'env'):
            words = words[1:]
            takes_value = {'-u', '-g', '-h', '-p', '-C', '-T', '-r', '-t', '--user', '--group', '--host'} if name == 'sudo' else {'-u', '--unset', '-C', '--chdir'}
            while words and (words[0].startswith('-') or assignment.match(words[0])):
                opt = words.pop(0)
                if opt == '--': break
                if opt in takes_value and words: words.pop(0)
                elif name == 'env' and opt in ('-S', '--split-string') and words:
                    words = shlex.split(words.pop(0)) + words
        elif name in ('pixi', 'uv') and len(words) > 1 and words[1] == 'run':
            words = words[2:]
            while words and words[0].startswith('-'):
                opt = words.pop(0)
                if opt in ('-e', '--environment', '--manifest-path', '--project', '--directory') and words: words.pop(0)
        else:
            break
    return words

def safe_kill(name, args):
    # Parse options, not words anywhere in a pattern or an unrelated command. Oldest (-o)
    # is NOT pkill's age filter; zero/negative/missing age values protect nothing.
    i = 0
    while i < len(args):
        opt = args[i]; i += 1
        if opt == '--': break
        if opt in ('-h', '--help'): return True
        age = ('-O', '--older') if name == 'pkill' else ('-o', '--older-than')
        pid = ('-F', '--pidfile') if name == 'pkill' else ()
        for flag in age + pid:
            value = None
            if opt == flag:
                if i < len(args): value = args[i]; i += 1
            elif opt.startswith(flag + '='):
                value = opt[len(flag) + 1:]
            elif len(flag) == 2 and opt.startswith(flag) and len(opt) > 2:
                value = opt[2:]
            if value is not None:
                if flag in pid:
                    if value and not value.startswith('-'): return True
                else:
                    match = re.fullmatch(r'([0-9]+(?:\.[0-9]+)?)([smhdwMy]?)', value)
                    if match and float(match[1]) > 0 and (name != 'pkill' or not match[2]): return True
                break
    return False

def inspect(command, depth=0):
    if depth > 8: raise ValueError('nested shell command limit exceeded')
    lexer = shlex.shlex(command, posix=True, punctuation_chars=';&|()\n')
    lexer.whitespace = ' \t\r'; lexer.whitespace_split = True
    units = []; unit = []
    for token in lexer:
        if token and all(c in ';&|()\n' for c in token):
            if unit: units.append(unit)
            unit = []
        else: unit.append(token)
    if unit: units.append(unit)
    bare = script = False
    # Retain the previous guard's conservative coverage of literal command substitutions,
    # including ones shlex folds into a quoted argument. No substitution is ever evaluated.
    for sub in re.finditer(r'\$\(([^()]*)\)|`([^`]*)`', command):
        b, s = inspect(sub[1] if sub[1] is not None else sub[2], depth + 1)
        bare |= b; script |= s
    for words in units:
        words = unwrap(words)
        if not words: continue
        name = os.path.basename(words[0]); args = words[1:]
        if name in ('pkill', 'killall') and not safe_kill(name, args): bare = True
        if name in ('bash', 'sh', 'zsh'):
            for i, arg in enumerate(args):
                if arg.startswith('-') and not arg.startswith('--') and 'c' in arg and i + 1 < len(args):
                    b, s = inspect(args[i + 1], depth + 1); bare |= b; script |= s
                    break
        if script_path.search(words[0]): script = True
        if re.fullmatch(r'python(?:[0-9]+(?:\.[0-9]+)*)?|Rscript|bash|sh', name):
            i = 0
            while i < len(args):
                arg = args[i]; i += 1
                if arg in ('-c', '-m', '-e') or (name in ('bash', 'sh') and arg.startswith('-') and 'c' in arg): break
                if arg in ('-W', '-X') and i < len(args): i += 1; continue
                if arg.startswith('-'): continue
                if script_path.search(arg): script = True
                break  # later arguments belong to the script, not the interpreter
    return bare, script

try:
    print(*(int(x) for x in inspect(sys.argv[1])))
except (ValueError, re.error) as exc:
    print('bd-prerun-hook: cannot parse command policy; guards fail open: ' + str(exc), file=sys.stderr)
    sys.exit(1)
PY
) || exit 0
read -r bare is_script <<< "$policy"
if [ "$bare" -eq 1 ]; then
    cat >&2 <<KILLGATE
⛔ BARE pkill / killall BLOCKED

pkill -f PATTERN matches on the full command line, so PATTERN also matches the
shell you are running it from. It kills its own caller. The tool call comes
back as exit 143/144, which reads like an ordinary failure, and anything that
shell was supervising dies with it.

Do this instead:

  1. See what would match, INCLUDING this shell:
       pgrep -af 'PATTERN'
  2. Then kill the specific ones by PID:
       kill 12345 12346
  3. Or exclude the just-started shell with an age filter:
       pkill -O 60 -f 'PATTERN'        # procps: -O/--older SECONDS
       killall -o 60s NAME             # psmisc: -o/--older-than TIME

'kill' with explicit PIDs is never blocked by this guard.

(Guard: .claude/bd-prerun-hook.sh. Tests: tools/bd-prerun-hook_test.sh)
Blocked command: $command
KILLGATE
    exit 2
fi

# ── GATE: bd remember admission control (memory-curate "gate" mode) ───────────
# Keep the persistent-memory store lean at the SOURCE. Blocks only unambiguous
# violations (missing --key; transient session/status state); warns on oversized
# inline bodies; fails open. Scoped strictly to `bd remember` invocations.
if echo "$command" | grep -qE '(^|[;&|])[[:space:]]*bd[[:space:]]+remember([[:space:]]|$)' \
   && ! echo "$command" | grep -qE 'remember[[:space:]]+(-h|--help)([[:space:]]|$)'; then
    gate_reason=""
    if ! echo "$command" | grep -qE '[-]{2}key([[:space:]]|=)'; then
        gate_reason='"bd remember" without --key. Auto-generated keys cannot be deduped or updated
in place — that is how the store bloats. Re-run with a stable slug:

  bd remember --key <topic-slug> "<load-bearing fact>"'
    else
        # This used to block on VOCABULARY — any body containing
        # "session-handoff", "wrap-up", etc. That matched memories which merely MENTION the
        # pattern (e.g. tool knowledge citing what a curation pass pruned), while a determined
        # write got through by rephrasing. It was strongest against its own documentation and
        # weakest against the thing it exists to prevent — the "guard weaker than the check it
        # gates" shape that AGENTS.md tells agents to hunt for. Now: match STRUCTURE, exempt tool knowledge, and warn rather
        # than block when the evidence is only lexical.
        body=$(printf '%s' "$command" | sed -n 's/.*--key[[:space:]][^[:space:]]*[[:space:]]*//p')
        [ -z "$body" ] && body="$command"
        head200=$(printf '%s' "$body" | head -c 200)

        # STRUCTURAL signals — things only a session/status memo actually does.
        struct=0
        printf '%s' "$body" | grep -qiE 'next session|pick(ing)? up where|hand(ing)? off to|resume (here|next)|left off' && struct=$((struct+1))
        printf '%s' "$body" | grep -qiE '(^|[[:space:]])- \[[ x]\]|(^|[[:space:]])TODO[[:space:]]*:' && struct=$((struct+1))
        printf '%s' "$head200" | grep -qiE 'status:?[[:space:]]*(blocked|done|complete|in.?progress)' && struct=$((struct+1))
        printf '%s' "$head200" | grep -qiE '^[[:space:]]*(session|handoff|wrap.?up)\b' && struct=$((struct+1))

        # EXEMPTION — a body that cites a committed tool/script/doc path is operational
        # knowledge, whatever vocabulary it happens to use.
        cites_path=0
        printf '%s' "$body" | grep -qE '[A-Za-z0-9_./-]+\.(py|sh|R|sbatch|md|json|tsv|toml|yaml)([[:space:]]|:|,|\)|$)' && cites_path=1
        printf '%s' "$body" | grep -qE '(scripts|\.claude|projects|integration)/' && cites_path=1

        lexical=0
        printf '%s' "$body" | grep -qiE 'session.?handoff|wrap.?up|pushed @|all( work)? (committed|pushed)|pickup (note|complete|done)' && lexical=1

        if [ "$struct" -ge 2 ] && [ "$cites_path" -eq 0 ]; then
            gate_reason='This is structurally a session/status memo, not durable knowledge (it reads as
a handoff: next-session pointers, task lists, and/or a leading status line, with no
committed tool or file path). Put it in the git commit message, or a bd issue note
(bd note <id> "..."), not a memory.

If it IS durable knowledge, name the artifact it applies to — a script, doc or path —
and it will be admitted.'
        elif [ "$struct" -ge 1 ] || { [ "$lexical" -eq 1 ] && [ "$cites_path" -eq 0 ]; }; then
            echo "⚠ memory-curate gate: body mentions session/status vocabulary. Admitted — it cites a committed path and/or lacks the structure of a handoff memo. If this IS session state, put it in a bd note instead. (Allowed.)" >&2
        fi
    fi
    if [ -n "$gate_reason" ]; then
        cat >&2 <<GATE
⛔ MEMORY ADMISSION BLOCKED

$gate_reason

(Gate: .claude/bd-prerun-hook.sh — /memory-curate "gate" mode; fails open on error.)
Blocked command: $command
GATE
        exit 2
    fi
    # advisory only (non-blocking): oversized inline body
    if echo "$command" | grep -qE '"[^"]{1600,}"'; then
        echo "⚠ memory-curate gate: large inline memory body (>~1.5KB) — keep load-bearing facts, move long detail to a repo doc + pointer. (Allowed.)" >&2
    fi
    # No `exit 0` here: an admitted `bd remember` used to end the hook, so
    # `bd remember --key k "fact" && python3 scripts/run.py` never reached the scripts gate below.
fi

# ── Analysis script execution was classified with the literal commands above ──

[ "$is_script" -eq 0 ] && exit 0

# ── Check for an in_progress beads issue ─────────────────────────────────────
# Count issue ROWS, not ● glyphs: ● is bd's priority bullet on every row and its BLOCKED glyph in
# the legend under any non-empty listing, so `grep -c "●"` matched rows for the wrong reason and
# the legend for no reason. Only "any or none" matters here, but the same function feeds the
# number bd-stop-hook.sh prints; keep the two identical (the comment there has the shape).
count_in_progress() {
    local text n=""
    text=$(bd list --status=in_progress 2>/dev/null) || return 1
    if command -v jq >/dev/null 2>&1; then
        n=$(bd --json list --status=in_progress 2>/dev/null \
            | jq -r 'if type == "array" then length else empty end' 2>/dev/null)
    fi
    case $n in ''|*[!0-9]*) n=$(printf '%s\n' "$text" | grep -cE '^[^[:alnum:]]*◐ ' || true) ;; esac
    printf '%s' "${n:-0}"
}

# bd unavailable — fail open rather than block all work
in_progress=$(count_in_progress) || exit 0
: "${in_progress:=0}"
[ "$in_progress" -gt 0 ] && exit 0

# ── Block ─────────────────────────────────────────────────────────────────────
cat >&2 <<BLOCK
⛔ UNTRACKED WORK BLOCKED

No beads issue is in_progress. Running analysis scripts without a tracked
issue creates reproducibility gaps — untracked output files and no audit trail.
Untracked runs are how reproducibility gaps get created in the first place.

Before running scripts, create and claim an issue:

  bd create --title="..." --description="..." --type=task
  bd update <id> --claim

Then re-run your command.

Blocked command: $command
BLOCK

exit 2
