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
# MUST stay ABOVE the "bd remember" gate below: that gate exits 0 for any
# command containing a bd remember call, so a compound such as
#     bd remember --key k "..." ; pkill -f rsync
# would bypass this guard entirely if it came second.
#
# THE TRAP. pkill -f PATTERN matches against the FULL command line, and the
# agent shell running the command has that very pattern on its own command
# line. So the pattern matches the shell issuing it and the command kills
# itself. Observed twice on 2026-07-25 (exit 144), once aborting a chained job
# submission; and again on 2026-08-13, where the same self-match killed twelve
# running simulations mid-flight (rc=143) plus the shell writing the note that
# was documenting the trap.
#
# Anchored to COMMAND POSITION (line start, or after ; & | ( or a command
# substitution opener) so the bare word inside prose does not trip it. A line
# of prose that BEGINS with the word still will. That is the safe direction,
# and long prose is supposed to go to a file and be passed as "$(cat file)"
# here anyway.
if echo "$command" | grep -qE '(^|[;&|(]|[$][(])[[:space:]]*(sudo[[:space:]]+)?(pkill|killall)([[:space:]]|$)'; then
    # Allowed forms are the ones that cannot select the just-started shell: an
    # age filter excludes it, an explicit pidfile names its targets, and help
    # kills nothing. Note -n/--newest and -y/--younger-than are deliberately
    # NOT allowed: both preferentially select the newest process, which is the
    # agent shell itself.
    #
    # Flags VERIFIED against procps-ng 4.0.4 and psmisc killall. pkill spells
    # the age filter -O / --older SECONDS. --older-than is KILLALL's spelling and
    # is NOT a pkill flag -- the request that prompted this guard suggested it for
    # pkill, which would not have worked. Check your own procps before editing.
    if ! echo "$command" | grep -qE '(^|[[:space:]])(-O|--older|-o|--older-than|-F|--pidfile|-h|--help)([[:space:]]|=|$)'; then
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
    exit 0
fi

# ── Detect analysis script execution ─────────────────────────────────────────
# Which directory holds the scripts that count as tracked work. Edit this one line to
# match your layout (it is a regex alternation: 'scripts|pipelines|analysis').
# Matches:
#   python[3] [path/]scripts/<file>.py
#   Rscript   [path/]scripts/<file>.R
#   bash/sh   [path/]scripts/<file>.sh
#   direct:   [path/]scripts/run_* plot_* map_* etc.
SCRIPT_DIRS_RE='scripts'
is_script=0

if echo "$command" | grep -qE \
    '(^|[[:space:]])(python3?|Rscript)[[:space:]]+([^[:space:]]*/)?('"$SCRIPT_DIRS_RE"')/[^[:space:]]+(\.py|\.R)([[:space:]]|$)'; then
    is_script=1
elif echo "$command" | grep -qE \
    '(^|[[:space:]])(bash|sh)[[:space:]]+([^[:space:]]*/)?('"$SCRIPT_DIRS_RE"')/[^[:space:]]+\.sh([[:space:]]|$)'; then
    is_script=1
elif echo "$command" | grep -qE \
    '(^|[;&|]{1,2}[[:space:]]*)([^[:space:]]*/)?('"$SCRIPT_DIRS_RE"')/(run_|plot_|map_|join_|rank_|extract_|prepare_)[^[:space:]]+'; then
    is_script=1
fi

[ "$is_script" -eq 0 ] && exit 0

# ── Check for an in_progress beads issue ─────────────────────────────────────
if ! bd_output=$(bd list --status=in_progress 2>/dev/null); then
    # bd unavailable — fail open rather than block all work
    exit 0
fi

in_progress=$(echo "$bd_output" | grep -c "●" 2>/dev/null || true)
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
