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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
