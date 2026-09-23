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
run_hook() {  # HOOK_SID=<id> adds the session_id Claude Code sends with every hook call
    RC=0
    printf '%s' "$1" | HOOK_SID="${HOOK_SID-}" python3 -c '
import sys, json, os
d = {"tool_name": "Bash", "tool_input": {"command": sys.stdin.read()}}
if os.environ.get("HOOK_SID"): d["session_id"] = os.environ["HOOK_SID"]
print(json.dumps(d))
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
blocks "pkill -o is not an age filter"  "pkill -o -f rsync"
allows "killall --older-than"           "killall -o 60s python3"
allows "pkill -F explicit pidfile"      "pkill -F /tmp/x.pid"
allows "pkill --help"                   "pkill --help"

echo "### wrappers and non-protective age values"
blocks "env wrapper"                   "env pkill -f rsync"
blocks "assignment and command wrapper" "X=1 command /usr/bin/pkill -f rsync"
blocks "sudo user option"              "sudo -u someone pkill -f rsync"
blocks "zero age"                      "pkill -O 0 -f rsync"
blocks "zero age attached"             "pkill --older=0 -f rsync"
blocks "zero killall age"              "killall -o 0s bash"
blocks "missing pidfile"               "pkill -F"
blocks "quoted command substitution"   'echo "$(pkill -f rsync)"'
blocks "shell -c wrapper"               "bash -c 'pkill -f rsync'"
blocks "help text in pattern after --" "pkill -f -- '-h'"
allows "wrapped positive age"          "env X=1 command pkill --older=60 -f rsync"
allows "attached positive age"         "pkill -O60 -f rsync"
allows "quoted separators in prose"    "echo 'pkill -f x; killall bash'"

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

echo "### text shlex cannot tokenize is judged by the line fallback, not waved through"
# An unbalanced quote -- 'don't' in an unquoted heredoc body -- made the tokenizer raise, and the
# hook then exited 0 for the WHOLE command: no pkill guard, no memory gate, no scripts gate. The
# regex hook before it blocked these. Each case below was allowed by the first tokenizing hook.
blocks "heredoc prose with an apostrophe, then a bare pkill" $'cat <<EOF\ndon\'t\nEOF\npkill -f rsync'
blocks "heredoc prose, then a key-less bd remember"         $'cat > /tmp/n <<EOF\ndon\'t forget\nEOF\nbd remember "$(cat /tmp/n)"'
blocks "an unbalanced quote on the pkill line itself"       $'pkill -f don\'t'
allows "unparsable text with nothing guarded in it"          $'cat <<EOF\nit\'s fine\nEOF\necho done'
allows "the fallback still honours a pkill age filter"       $'cat <<EOF\ndon\'t\nEOF\npkill -O 60 -f rsync'
allows "the fallback admits a keyed bd remember"             $'cat <<EOF\nit\'s\nEOF\nbd remember --key k "a fact about scripts/x.py"'

echo "### heredoc bodies that feed DATA are text, not commands; shell-fed ones are commands"
# Found while committing the fix: a commit-message line that BEGAN with 'bd remember ...' was judged
# as a key-less call, and the old regex hook did the same with prose lines starting 'pkill -f'.
allows "commit message, a line starting with the memory phrase" $'git commit -F - <<\'EOF\'\nFix the gate\nbd remember admission gate no longer skipped; it\'s fixed\nEOF'
allows "commit message, a line starting with pkill -f"          $'git commit -F - <<\'EOF\'\nWhy:\npkill -f matches its own shell\nEOF'
allows "the \$(cat <<EOF) commit idiom, apostrophe in the body" $'git commit -m "$(cat <<\'EOF\'\nIt\'s done; pkill -f is guarded\nEOF\n)"'
blocks "a heredoc fed to bash is still checked"                 $'bash <<\'EOF\'\npkill -f rsync\nEOF'
blocks "…also when its body is unparsable"                      $'sudo bash <<EOF\ndon\'t\npkill -f rsync\nEOF'
blocks "a heredoc fed to ssh is still checked"                  $'ssh host <<EOF\nkillall python3\nEOF'
blocks "an unterminated heredoc operator hides nothing"         $'echo "write <<EOF here"\npkill -f rsync'
blocks "commands after a data heredoc are still checked"        $'cat > /tmp/x <<\'EOF\'\nprose\nEOF\npkill -f rsync'

echo "### the memory gate fires on bd remember CALLS, found by tokens, not on the phrase"
# The trigger used to be a regex over the raw text: '; bd remember' inside a quoted argument of
# another command was gated as a write (it blocked a bd create whose description quoted it), while a
# wrapped call escaped it.
allows "the phrase in another command's quoted argument"     "bd create --title x --description 'see foo; bd remember without --key'"
allows "the phrase in a commit message"                      "git commit -m 'gate: x; bd remember with no key is blocked'"
blocks "bd remember behind env"                              "env X=1 bd remember 'floating fact'"
blocks "bd remember inside bash -c"                          "bash -c 'bd remember \"floating fact\"'"
blocks "bd remember in a command substitution"              'echo "$(bd remember floating)"'
allows "the --key=slug form"                                 "bd remember --key=some-topic 'a durable fact about scripts/x.py'"
allows "bd remember --help is not a write"                   "bd remember --help"

echo "### the untracked-scripts gate: consults bd, needs an in_progress issue, fails open"
# A stub bd on PATH answers `bd list --status=in_progress` with whatever BD_STUB_LIST holds and
# `bd --json list ...` with BD_STUB_JSON. The text fixtures below are bd 1.3's REAL shape: a row is
# "◐ id ● P2 [type] title" (● is the priority bullet) and a non-empty listing ends with a legend
# that says "● blocked". The old fixture was "● proj-1 P2 ..." — a row the hook matched for the
# wrong reason, which is how `grep -c "●"` survived here (2026-09-22).
# This gate had no coverage at all while three documents said this suite covered it.
STUB=$(mktemp -d); trap 'rm -rf "$STUB"' EXIT
cat > "$STUB/bd" <<'BDSTUB'
#!/usr/bin/env bash
case "$*" in
  *--json*)      printf '%s\n' "${BD_STUB_JSON-}" ;;
  *in_progress*) printf '%s\n' "${BD_STUB_LIST-}" ;;
esac
exit 0
BDSTUB
chmod +x "$STUB/bd"
LEGEND=$'\n--------\nTotal: 1 issues (0 open, 1 in progress)\n\nStatus: ○ open  ◐ in_progress  ● blocked  ✓ closed  ❄ deferred'
export BD_STUB_LIST="No issues found." BD_STUB_JSON="[]"
PATH="$STUB:$PATH" blocks "python3 scripts/run.py with nothing in_progress"   "python3 scripts/run.py"
PATH="$STUB:$PATH" blocks "bash scripts/x.sh with nothing in_progress"        "bash scripts/x.sh"
PATH="$STUB:$PATH" blocks "a direct scripts/run_* invocation"                 "scripts/run_analysis --fast"
PATH="$STUB:$PATH" blocks "an admitted bd remember does not license the script after it" \
                          "bd remember --key k 'fact' && python3 scripts/run.py"
PATH="$STUB:$PATH" blocks "interpreter flags do not bypass the gate" "python3 -u scripts/run.py"
PATH="$STUB:$PATH" blocks "quoted script path" "python3 -u 'scripts/my run.py'"
PATH="$STUB:$PATH" blocks "shell flags" "bash -eu scripts/x.sh"
PATH="$STUB:$PATH" blocks "pixi wrapper" "pixi run python3 -u scripts/run.py"
PATH="$STUB:$PATH" blocks "direct script without a magic prefix" "./scripts/analyze.py"
PATH="$STUB:$PATH" blocks "a script after unparsable heredoc text"   $'cat <<EOF\nit\'s\nEOF\npython3 scripts/run.py'
PATH="$STUB:$PATH" allows "a script outside scripts/ is not gated"            "python3 other/run.py"
PATH="$STUB:$PATH" allows "the word scripts/ in prose is not a script run"    "git commit -m 'moved scripts/x.py'"
export BD_STUB_LIST="◐ proj-1 ● P2 [task] something in flight$LEGEND" BD_STUB_JSON='[{"id":"proj-1","status":"in_progress"}]'
PATH="$STUB:$PATH" allows "with an issue in_progress the script runs"        "python3 scripts/run.py"
# The text fallback (no usable JSON) must count ROWS: one row + the legend is 1, and a legend with
# no row above it is 0 even though both carry ●.
export BD_STUB_JSON="not json"
PATH="$STUB:$PATH" allows "text fallback: a real row above the legend counts"  "python3 scripts/run.py"
export BD_STUB_LIST="Status: ○ open  ◐ in_progress  ● blocked  ✓ closed"
PATH="$STUB:$PATH" blocks "text fallback: the legend's ● is not an issue"      "python3 scripts/run.py"
echo "### with a session id, only issues THIS session claimed license its scripts"
# The shared store held 22 in-progress issues from other sessions and projects (18 untouched for a
# week), so 'any issue in progress' licensed every script everywhere and the gate never fired.
export BD_SESSION_CLAIMS_DIR="$STUB/claims"
CL="$BD_SESSION_CLAIMS_DIR"
OTHERS='{"id":"other-1","title":"someone else"},{"id":"other-2","title":"stale since June"}'
export BD_STUB_JSON="[$OTHERS]" BD_STUB_LIST="◐ other-1 ● P2 [task] someone else$LEGEND"
PATH="$STUB:$PATH" HOOK_SID=s1 blocks "unrelated in-progress issues do not license this session" "python3 scripts/run.py"
PATH="$STUB:$PATH"            allows "…while a caller with no session id keeps the global rule" "python3 scripts/run.py"
PATH="$STUB:$PATH" HOOK_SID=s1 allows "a claim in the SAME command licenses it"  "bd update mine-1 --claim && python3 scripts/run.py"
PATH="$STUB:$PATH" HOOK_SID=s1 allows "claiming is itself allowed"               "bd update mine-2 --claim"
chk_rec() { if grep -qx "$2" "$CL/s1" 2>/dev/null; then ok "$1"; else bad "$1" "$(cat "$CL/s1" 2>/dev/null | tr '\n' ' ')"; fi; }
nochk_rec() { if grep -qx "$2" "$CL/s1" 2>/dev/null; then bad "$1" "recorded $2"; else ok "$1"; fi; }
chk_rec "the claim is recorded for this session"                              mine-2
export BD_STUB_JSON="[$OTHERS,{\"id\":\"mine-2\",\"title\":\"mine\"}]"
PATH="$STUB:$PATH" HOOK_SID=s1 allows "its claimed issue in progress licenses later scripts" "python3 scripts/run.py"
PATH="$STUB:$PATH" HOOK_SID=s2 blocks "…but not another session's"              "python3 scripts/run.py"
export BD_STUB_JSON="[$OTHERS]"
PATH="$STUB:$PATH" HOOK_SID=s1 blocks "claimed, then closed: no longer licensed" "python3 scripts/run.py"
PATH="$STUB:$PATH" HOOK_SID=s1 allows "--status in_progress is a claim"          "bd update mine-3 --status in_progress"
PATH="$STUB:$PATH" HOOK_SID=s1 allows "--status=in_progress is a claim"          "bd update mine-4 --status=in_progress"
PATH="$STUB:$PATH" HOOK_SID=s1 allows "a flag before the id"                     "bd update --claim mine-5"
PATH="$STUB:$PATH" HOOK_SID=s1 allows "a flag value is not an id"                "bd update mine-6 --title my-fix --claim"
PATH="$STUB:$PATH" HOOK_SID=s1 allows "not a claim"                              "bd update mine-7 --notes progress"
PATH="$STUB:$PATH" HOOK_SID=s1 allows "a claim in unparsable text (fallback)"    "bd update mine-8 --claim; echo don't"
for id in mine-3 mine-4 mine-5 mine-6 mine-8; do chk_rec "recorded: $id" "$id"; done
nochk_rec "not recorded: a --title value"                                       my-fix
nochk_rec "not recorded: an update that is not a claim"                         mine-7
export BD_STUB_JSON="[$OTHERS,{\"id\":\"mine-8\",\"title\":\"mine\"}]"
PATH="$STUB:$PATH" HOOK_SID=s1 allows "a fallback-recorded claim licenses too"   "python3 scripts/run.py"
unset BD_SESSION_CLAIMS_DIR
unset BD_STUB_LIST BD_STUB_JSON
# bd absent entirely: the gate must fail OPEN (a broken bd must not block all work).
bare_path=""; oldifs=$IFS; IFS=:
for d in $PATH; do [ -x "$d/bd" ] || bare_path="${bare_path:+$bare_path:}$d"; done
IFS=$oldifs
if PATH="$bare_path" command -v python3 >/dev/null 2>&1 && ! PATH="$bare_path" command -v bd >/dev/null 2>&1; then
  PATH="$bare_path" allows "no bd on PATH: the scripts gate fails open"         "python3 scripts/run.py"
  PATH="$bare_path" HOOK_SID=s1 allows "…also for a session-scoped call"         "python3 scripts/run.py"
else
  bad "no bd on PATH: the scripts gate fails open" "could not build a PATH without bd but with python3"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
