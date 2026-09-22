#!/usr/bin/env bash
# Acceptance suite for .claude/bd-prerun-hook.sh.
#
# The property under test: the guard must block a BARE pkill/killall, must let
# through the forms that cannot select the agent's own shell, and must not fire
# on the word appearing inside prose. A guard nobody has watched fire is worth
# little here -- see the CLAUDE.md note on guards weaker than the check they
# gate.
#
# Hermetic: feeds the hook a synthetic PreToolUse JSON payload on stdin and
# reads its exit code. Never runs the commands it is testing, and never signals
# anything.
#
#   bash tools/bd-prerun-hook_test.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.claude/bd-prerun-hook.sh"
PASS=0; FAIL=0

ok()  { PASS=$((PASS+1)); printf '  \033[32m/\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mX\033[0m %s\n' "$1"; printf '      %s\n' "${2:-}"; }

# run_hook <command-string> -> RC
run_hook() {
    RC=0
    printf '%s' "$1" | python3 -c '
import sys, json
print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))
' | bash "$HOOK" >/dev/null 2>&1
    RC=$?
}

blocks() {  # blocks <label> <command>
    run_hook "$2"
    if [ "$RC" -eq 2 ]; then ok "$1"; else bad "$1" "expected exit 2, got $RC"; fi
}
allows() {  # allows <label> <command>
    run_hook "$2"
    if [ "$RC" -eq 0 ]; then ok "$1"; else bad "$1" "expected exit 0, got $RC"; fi
}

[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 2; }

echo "### BLOCK: bare forms that can self-match the agent shell"
blocks "pkill -f"                       "pkill -f rsync"
blocks "pkill by name"                  "pkill dolt"
blocks "killall"                        "killall python3"
blocks "sudo pkill"                     "sudo pkill -9 dolt"
blocks "after a semicolon"              "echo hi; pkill -f rsync"
blocks "after &&"                       "echo hi && killall foo"
blocks "inside a pipeline segment"      "true | pkill -f rsync"
blocks "on a later line"                "$(printf 'echo a\npkill -f rsync\n')"
blocks "would bypass via bd remember"   "bd remember --key k 'a fact about scripts/x.py' ; pkill -f rsync"
blocks "-n/--newest is NOT a safe flag" "pkill -n -f rsync"

echo "### ALLOW: forms that cannot select the just-started shell"
allows "pkill -O age filter"            "pkill -O 60 -f rsync"
allows "pkill --older age filter"       "pkill --older 60 -f rsync"
allows "pkill -o oldest only"           "pkill -o -f rsync"
allows "killall --older-than"           "killall -o 60s python3"
allows "pkill -F explicit pidfile"      "pkill -F /tmp/x.pid"
allows "pkill --help"                   "pkill --help"

echo "### ALLOW: not a kill at all"
allows "pgrep inspection"               "pgrep -af rsync"
allows "kill with explicit PIDs"        "kill 12345 12346"
allows "plain command"                  "echo hello"

echo "### ALLOW: the word inside prose must not trip the guard"
allows "mid-string in a bd note"        "bd note WS-x 'the pkill trap bit us twice'"
allows "mid-string in a commit message" "git commit -m 'document the killall self-match'"

echo "### REGRESSION: the pre-existing memory gate still works"
blocks "bd remember without --key"      "bd remember 'some floating fact'"
allows "bd remember with --key"         "bd remember --key some-topic 'a durable fact about scripts/x.py'"

echo "### the allowlist is judged per pkill INVOCATION, not over the whole line"
# `ls -h && pkill -f x`: the -h belongs to ls. The old whole-line test read it as pkill's
# --help and let the bare kill through.
blocks "an allowed-looking flag on ANOTHER command licenses nothing" "ls -h && pkill -f rsync"
blocks "grep -o before a bare pkill"                                  "grep -o x f; pkill -f rsync"
allows "the age filter on the pkill itself is still allowed"         "ls && pkill -O 60 -f rsync"
blocks "one allowed and one bare invocation: still blocked"          "pkill -O 60 -f a; pkill -f b"

echo "### the untracked-scripts gate: consults bd, needs an in_progress issue, fails open"
# A stub bd on PATH answers `bd list --status=in_progress` with whatever BD_STUB_LIST holds.
# This gate had no coverage at all while three documents said this suite covered it.
STUB=$(mktemp -d); trap 'rm -rf "$STUB"' EXIT
printf '#!/usr/bin/env bash\ncase "$*" in *in_progress*) printf "%%s\\n" "$BD_STUB_LIST" ;; esac\nexit 0\n' > "$STUB/bd"
chmod +x "$STUB/bd"
export BD_STUB_LIST=""
PATH="$STUB:$PATH" blocks "python3 scripts/run.py with nothing in_progress"   "python3 scripts/run.py"
PATH="$STUB:$PATH" blocks "bash scripts/x.sh with nothing in_progress"        "bash scripts/x.sh"
PATH="$STUB:$PATH" blocks "a direct scripts/run_* invocation"                 "scripts/run_analysis --fast"
PATH="$STUB:$PATH" blocks "an admitted bd remember does not license the script after it" \
                          "bd remember --key k 'fact' && python3 scripts/run.py"
PATH="$STUB:$PATH" allows "a script outside scripts/ is not gated"            "python3 other/run.py"
PATH="$STUB:$PATH" allows "the word scripts/ in prose is not a script run"    "git commit -m 'moved scripts/x.py'"
export BD_STUB_LIST="● proj-1 P2 something in flight"
PATH="$STUB:$PATH" allows "with an issue in_progress the script runs"        "python3 scripts/run.py"
unset BD_STUB_LIST
# bd absent entirely: the gate must fail OPEN (a broken bd must not block all work).
bare_path=""; oldifs=$IFS; IFS=:
for d in $PATH; do [ -x "$d/bd" ] || bare_path="${bare_path:+$bare_path:}$d"; done
IFS=$oldifs
if PATH="$bare_path" command -v python3 >/dev/null 2>&1 && ! PATH="$bare_path" command -v bd >/dev/null 2>&1; then
  PATH="$bare_path" allows "no bd on PATH: the scripts gate fails open"         "python3 scripts/run.py"
else
  bad "no bd on PATH: the scripts gate fails open" "could not build a PATH without bd but with python3"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
