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

# ── Parse the hook JSON payload: session id (line 1), then the command ─────────
# session_id is what Claude Code sends with every hook call (the Pi adapter sends its own); it
# scopes the untracked-scripts gate to what THIS session claimed. Sanitized, because
# it names a file.
parsed=$(python3 -c '
import sys, json, re
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
if not isinstance(data, dict): data = {}
print(re.sub(r"[^A-Za-z0-9._-]", "_", str(data.get("session_id") or ""))[:128])
tool = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
print(tool.get("command", "") if isinstance(tool.get("command", ""), str) else "")
' 2>/dev/null)
session_id=${parsed%%$'\n'*}
command=${parsed#*$'\n'}
[ "$command" = "$parsed" ] && command=""

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

def remember_call(name, args):
    """(is a `bd remember` call, lacks --key) for one unwrapped command. Help is not a write."""
    if name != 'bd': return False, False
    sub = next((a for a in args if not a.startswith('-')), None)
    if sub != 'remember' or any(a in ('-h', '--help') for a in args): return False, False
    return True, not any(a == '--key' or a.startswith('--key=') for a in args)

ISSUE_ID = re.compile(r'[A-Za-z][A-Za-z0-9]*-[A-Za-z0-9]+(?:\.[0-9]+)*')
# bd update flags that take NO value; every other flag's next word is its value, not an issue id.
BD_BOOL = {'--claim', '--allow-empty-description', '--ephemeral', '--history', '--no-history',
           '--persistent', '--stdin', '-h', '--help', '--json', '--profile', '--global',
           '--ignore-schema-skew'}
BD_GLOBAL_VALUED = {'--actor', '--db', '-C', '--directory', '--dolt-auto-commit'}

def claim_call(name, args):
    """Issue ids this command moves to in_progress: bd update <id...> --claim | --status in_progress.

    Recorded per session, because the bd store is shared by every session and all of them claim
    as the same actor: bd itself cannot say which in-progress issue is whose."""
    if name != 'bd': return set()
    i = 0
    while i < len(args) and args[i].startswith('-'):
        i += 2 if args[i] in BD_GLOBAL_VALUED else 1
    if i >= len(args) or args[i] != 'update': return set()
    rest = args[i + 1:]; ids = set(); claim = False; j = 0
    while j < len(rest):
        a = rest[j]; j += 1
        if a == '--claim': claim = True
        elif a.startswith(('--status=', '-s=')): claim |= a.split('=', 1)[1] == 'in_progress'
        elif a in ('--status', '-s'):
            if j < len(rest): claim |= rest[j] == 'in_progress'; j += 1
        elif a.startswith('-'):
            if '=' not in a and a not in BD_BOOL: j += 1
        elif ISSUE_ID.fullmatch(a): ids.add(a)
    return ids if claim else set()

def inspect(command, depth=0):
    """-> (bare kill, analysis script, bd remember call, bd remember WITHOUT --key, claimed ids)."""
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
    flags = [False] * 4 + [set()]
    def merge(more):
        for k, v in enumerate(more): flags[k] |= v
    # Retain the previous guard's conservative coverage of literal command substitutions,
    # including ones shlex folds into a quoted argument. No substitution is ever evaluated.
    for sub in re.finditer(r'\$\(([^()]*)\)|`([^`]*)`', command):
        merge(inspect(sub[1] if sub[1] is not None else sub[2], depth + 1))
    for words in units:
        words = unwrap(words)
        if not words: continue
        name = os.path.basename(words[0]); args = words[1:]
        if name in ('pkill', 'killall') and not safe_kill(name, args): flags[0] = True
        is_remember, keyless = remember_call(name, args)
        if is_remember: flags[2] = True; flags[3] |= keyless
        flags[4] |= claim_call(name, args)
        if name in ('bash', 'sh', 'zsh'):
            for i, arg in enumerate(args):
                if arg.startswith('-') and not arg.startswith('--') and 'c' in arg and i + 1 < len(args):
                    merge(inspect(args[i + 1], depth + 1))
                    break
        if script_path.search(words[0]): flags[1] = True
        if re.fullmatch(r'python(?:[0-9]+(?:\.[0-9]+)*)?|Rscript|bash|sh', name):
            i = 0
            while i < len(args):
                arg = args[i]; i += 1
                if arg in ('-c', '-m', '-e') or (name in ('bash', 'sh') and arg.startswith('-') and 'c' in arg): break
                if arg in ('-W', '-X') and i < len(args): i += 1; continue
                if arg.startswith('-'): continue
                if script_path.search(arg): flags[1] = True
                break  # later arguments belong to the script, not the interpreter
    return tuple(flags)

def line_fallback(command):
    """The pre-tokenizer checks, for text shlex cannot parse.

    An unbalanced quote -- `don't` in the body of an unquoted heredoc is the everyday case --
    makes shlex raise. This used to exit 0 and switch off ALL THREE gates for the whole command,
    while the regex hook it replaced had caught exactly those commands. So when tokenizing
    fails, judge the raw text line by line, the way the old hook did: a command word at line
    start or after ; & | ( $( counts, whatever the quoting. It over-matches prose that begins a
    line with the word, which is the safe direction for an accident guard."""
    pos = r'(?:^|[;&|(]|\$\()[ \t]*'
    bare = False
    for m in re.finditer(pos + r'(?:sudo[ \t]+)?(?:\S*/)?(pkill|killall)(?=[ \t]|$)', command, re.M):
        segment = re.split(r'[;&|\n]', command[m.end():], maxsplit=1)[0]
        if not safe_kill(m[1], segment.split()): bare = True
    calls = [command[m.end():].split('\n', 1)[0]
             for m in re.finditer(pos + r'bd[ \t]+remember(?=[ \t]|$)', command, re.M)]
    calls = [c for c in calls if not re.match(r'[ \t]+(?:-h|--help)(?:[ \t]|$)', c)]
    keyless = any(not re.search(r'--key(?:[ \t]|=)', c) for c in calls)
    d = sys.argv[2]
    script = bool(re.search(r'(?:^|[ \t])(?:python3?|Rscript)[ \t]+(?:\S*/)?(?:' + d + r')/\S+\.(?:py|R)(?:[ \t]|$)', command, re.M)
                  or re.search(r'(?:^|[ \t])(?:bash|sh)[ \t]+(?:\S*/)?(?:' + d + r')/\S+\.sh(?:[ \t]|$)', command, re.M)
                  or re.search(pos + r'(?:\S*/)?(?:' + d + r')/\S+', command, re.M))
    claims = set()
    for m in re.finditer(pos + r'bd[ \t]+(?:\S+[ \t]+)*?update(?=[ \t])', command, re.M):
        segment = re.split(r'[;&|\n]', command[m.end():], maxsplit=1)[0]
        if re.search(r'--claim\b|(?:--status|-s)[ \t=]+in_progress\b', segment):
            claims |= {w for w in segment.split() if ISSUE_ID.fullmatch(w)}
    return bare, script, bool(calls), keyless, claims

SHELLS = ('bash', 'sh', 'zsh', 'dash', 'ksh', 'ssh')

def drop_data_heredocs(command):
    """Remove the bodies of heredocs that feed DATA to a command (cat, git commit -F -, tee ...).

    A heredoc body is text, not commands -- unless the command reading it is a shell (bash <<EOF,
    ssh host <<EOF), whose body is kept and checked like any other lines. Bodies were the main
    source of both failures fixed here: prose such as "don't" made the whole command
    untokenizable, and a prose line that happened to START with a guarded word ("bd remember
    ...", "pkill -f is ...") was judged as a call. A body is dropped only when its terminator
    line is found; an unterminated operator (e.g. '<<EOF' quoted in prose) leaves the text as is.
    """
    lines = command.split('\n')
    out = []; i = 0
    op = re.compile(r'(?<!<)<<(-?)[ \t]*(["\']?)([A-Za-z_][A-Za-z0-9_]*)\2')
    while i < len(lines):
        line = lines[i]; out.append(line); i += 1
        for m in op.finditer(line):
            head = re.split(r'[;&|(]', line[:m.start()])[-1].split()
            feeds_shell = bool(head) and os.path.basename(unwrap(head)[0] if unwrap(head) else head[0]) in SHELLS
            end = re.compile(('\t*' if m[1] else '') + re.escape(m[3]) + r'[ \t]*$')
            j = next((k for k in range(i, len(lines)) if end.fullmatch(lines[k])), None)
            if j is None: continue
            if feeds_shell: out.extend(lines[i:j + 1])
            i = j + 1
    return '\n'.join(out)

text = drop_data_heredocs(sys.argv[1])
try:
    flags = inspect(text)
except (ValueError, re.error) as exc:
    print('bd-prerun-hook: command not tokenizable (' + str(exc) + '); judged by the line-based fallback checks instead', file=sys.stderr)
    flags = line_fallback(text)
print(*(int(x) for x in flags[:4]), ','.join(sorted(flags[4])) or '-')
PY
) || exit 0   # python itself failed: open, as the header says
read -r bare is_script remember remember_keyless claims <<< "$policy"
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
# inline bodies; fails open. Scoped strictly to `bd remember` invocations -- which the parser
# above identifies by TOKENS. The old trigger was a regex over the raw text, so a
# quoted argument of another command ("... ; bd remember without --key" in a bd create
# description) was gated as a write, while `env X=1 bd remember ...` or `bash -c "bd remember"`
# escaped it. Unparsable text falls back to that regex, line by line.
if [ "$remember" -eq 1 ]; then
    gate_reason=""
    if [ "$remember_keyless" -eq 1 ]; then
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

# ── Session scope: which in-progress issues are THIS session's ────────────
# The bd store is SHARED by every session and project on this machine, and every session claims
# as the same actor, so bd cannot say whose an in-progress issue is. A busy store always holds some
# in-progress issue -- often a stale one -- so "any issue in progress" licensed every script
# everywhere and this gate could never fire. So the hook records what each session CLAIMS (bd update <id>
# --claim / --status in_progress, recognized above) under its session id, in the git dir where it
# is never committed. A session's issues are the ones it claimed that are still in progress.
# bd-stop-hook.sh reads the same record; keep claims_dir and in_progress_ids identical there.
claims_dir() {
    if [ -n "${BD_SESSION_CLAIMS_DIR:-}" ]; then printf '%s' "$BD_SESSION_CLAIMS_DIR"; return; fi
    local g; g=$(git rev-parse --absolute-git-dir 2>/dev/null)
    if [ -n "$g" ]; then printf '%s/bd-session-claims' "$g"
    else printf '%s/bd-session-claims-%s' "${TMPDIR:-/tmp}" "$(id -u)"; fi
}
# "<id><TAB><title>" per in-progress issue; returns 1 when bd is unavailable.
in_progress_rows() {
    local json rows text
    if json=$(bd --json list --status=in_progress 2>/dev/null) && rows=$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert isinstance(d, list)
for x in d:
    if isinstance(x, dict) and x.get("id"): print("%s\t%s" % (x["id"], x.get("title", "")))
' 2>/dev/null); then
        printf '%s' "$rows"; return 0
    fi
    text=$(bd list --status=in_progress 2>/dev/null) || return 1
    # rows start with the in_progress glyph after any tree prefix; the legend never does
    printf '%s\n' "$text" | awk '/^[^[:alnum:]]*◐ /{ sub(/^[^[:alnum:]]*◐ +/, ""); id = $1;
        sub(/^[^ ]+ */, ""); print id "\t" $0 }'
}

if [ -n "$session_id" ] && [ "$claims" != "-" ]; then
    d=$(claims_dir)
    if mkdir -p "$d" 2>/dev/null; then
        printf '%s\n' ${claims//,/ } >> "$d/$session_id" && sort -u -o "$d/$session_id" "$d/$session_id"
        find "$d" -type f -mtime +30 -delete 2>/dev/null
    else
        echo "⚠ bd-prerun-hook: cannot record this session's claim in $d — its scripts gate cannot see it." >&2
    fi
fi

# ── Analysis script execution was classified with the literal commands above ──

[ "$is_script" -eq 0 ] && exit 0

if [ -n "$session_id" ]; then
    # A claim in the SAME command licenses it: `bd update X --claim && python3 scripts/run.py`.
    [ "$claims" != "-" ] && exit 0
    rows=$(in_progress_rows) || exit 0      # bd unavailable — fail open rather than block all work
    mine=$(printf '%s\n' "$rows" | cut -f1 | grep -Fx -f "$(claims_dir)/$session_id" 2>/dev/null | head -1)
    [ -n "$mine" ] && exit 0
    others=$(printf '%s\n' "$rows" | grep -c . || true)
    cat >&2 <<SBLOCK
⛔ UNTRACKED WORK BLOCKED

No issue claimed by THIS session is in progress. The $others in progress in the shared bd store
belong to other sessions or projects; they do not cover this work.

Claim the issue this work belongs to -- also when it is already in progress from an earlier
session; --claim is idempotent:

  bd update <id> --claim
  (new work: bd create --title="..." --description="..." --type=task, then claim it)

Then re-run your command.

Blocked command: $command
SBLOCK
    exit 2
fi

# No session id (a manual run, an older adapter): the pre-session behaviour, global.


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
