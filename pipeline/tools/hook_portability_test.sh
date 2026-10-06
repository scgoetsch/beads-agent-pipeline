#!/usr/bin/env bash
# hook_portability_test.sh — the hooks must follow their own clone, and fail LOUD.
#
# WHAT IT GUARDS
# .claude/settings.json is version-controlled, so whatever path the hooks name travels to
# every clone. When that path was a literal like /home/alice/workspace, the hooks' `cd ... || exit 0`
# failed OPEN and SILENT on any other clone: no session rules, no bd memories, no pkill guard,
# no untracked-script gate, and no error anywhere. A second operator would have run plain
# Claude Code in a directory that merely contained the files.
#
# So these checks relocate the hooks to a throwaway root and assert they follow. A test that
# only ran them in place would pass against the very bug it exists to catch.
#
# Run: tools/hook_portability_test.sh     (no network, no bd store, no cluster)

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT=$(pwd -P)

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
sec()  { printf '\n\033[1m### %s\033[0m\n' "$1"; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
# One spelling for one directory. mktemp names /var/... on macOS and /tmp/... on Git Bash while
# the hooks resolve the physical path (/private/var/..., /c/Users/.../Temp/...), so the checks
# below compare canonical forms (Actions macos and windows jobs, 2026-10-06).
canon() { local p; p=$(cd -- "$1" 2>/dev/null && pwd -P) || p=$1
          if command -v cygpath >/dev/null 2>&1; then cygpath -m "$p"; else printf '%s\n' "$p"; fi; }

# ---- a throwaway "clone" at a path that is NOT this repo --------------------
CLONE="$TMP/some other place/clone"     # the space is deliberate: paths get quoted wrong
mkdir -p "$CLONE/.claude" "$CLONE/.beads" "$CLONE/tools"
CLONE_CANON=$(canon "$CLONE")
cp "$ROOT/.claude/bd-prime-hook.sh" "$ROOT/.claude/bd-prerun-hook.sh" \
   "$ROOT/.claude/bd-stop-hook.sh" "$CLONE/.claude/"
cp "$ROOT/tools/dolt-guard.sh" "$CLONE/tools/"
printf 'some-hot-memory\n' > "$CLONE/.claude/memory-hot.txt"

# stub bd: records the cwd it was called from, then gets out of the way
mkdir -p "$TMP/bin"
cat > "$TMP/bin/bd" <<'STUB'
#!/usr/bin/env bash
pwd -P >> "$BD_CWD_LOG"
exit 1
STUB
chmod +x "$TMP/bin/bd"
export BD_CWD_LOG="$TMP/cwd.log"
PATH="$TMP/bin:$PATH"; export PATH

run_hook() {  # run_hook <script> [stdin]
    : > "$BD_CWD_LOG"
    printf '%s' "${2-}" | bash "$CLONE/.claude/$1" 2>"$TMP/err" >"$TMP/out"
    echo $?
}

sec "the hooks follow their own file to a relocated clone"

rc=$(run_hook bd-stop-hook.sh)
chk "bd-stop-hook runs bd from the relocated clone" "$(canon "$(head -1 "$BD_CWD_LOG")")" "$CLONE_CANON"
chk "bd-stop-hook exits 0" "$rc" "0"

rc=$(run_hook bd-prime-hook.sh)
chk "bd-prime-hook runs bd from the relocated clone" "$(canon "$(head -1 "$BD_CWD_LOG")")" "$CLONE_CANON"
chk "bd-prime-hook still emits the session rules" \
    "$(grep -c 'MANDATORY SESSION RULES' "$TMP/out")" "1"

JSON='{"tool_name":"Bash","tool_input":{"command":"python3 scripts/run_thing.py"}}'
# The scripts gate is the prerun hook's only bd call; pin it on, since a clone's
# .claude/bd-prerun.conf may turn it off.
rc=$(BD_SCRIPT_DIRS_RE=scripts run_hook bd-prerun-hook.sh "$JSON")
chk "bd-prerun-hook runs bd from the relocated clone" "$(canon "$(head -1 "$BD_CWD_LOG")")" "$CLONE_CANON"

sec "the guards still fire after relocation (not just the path resolution)"

# bd is never consulted for the pkill gate, so this proves the gate itself survived the move.
JSON='{"tool_name":"Bash","tool_input":{"command":"pkill -f rsync"}}'
rc=$(run_hook bd-prerun-hook.sh "$JSON")
chk "bare pkill is still blocked (exit 2)" "$rc" "2"
chk "  ...and says why on stderr" "$(grep -c 'BARE pkill' "$TMP/err")" "1"

JSON='{"tool_name":"Bash","tool_input":{"command":"bd remember \"no key here\""}}'
rc=$(run_hook bd-prerun-hook.sh "$JSON")
chk "bd remember without --key is still blocked" "$rc" "2"

sec "unresolvable root is LOUD, never a silent exit 0"

mkdir -p "$TMP/lonely"          # ".." has no .claude/, so resolution must fail
cp "$ROOT/.claude/bd-prime-hook.sh" "$TMP/lonely/"
out=$(bash "$TMP/lonely/bd-prime-hook.sh" 2>&1)
chk "bd-prime-hook announces it could not resolve the workspace" \
    "$(printf '%s' "$out" | grep -c 'CANNOT RESOLVE THE WORKSPACE')" "1"
chk "  ...and says the session is NOT primed" \
    "$(printf '%s' "$out" | grep -ci 'no project rules')" "1"

sec "dolt-guard defaults to its own repo, not a hardcoded path"

got=$(BD_DOLT_GUARD_NORUN=1 bash -c '. "$1/tools/dolt-guard.sh"; printf %s "$__BD_DOLT_GUARD_ROOT"' _ "$CLONE")
chk "sourced from the relocated clone, root is that clone" "$(canon "$got")" "$CLONE_CANON"

sec "no executable line names a hardcoded workspace root"

# Comments may cite the old path (the history is the rationale); code may not.
code_hits=$(cat "$ROOT"/.claude/*.sh | sed 's/#.*//' | grep -cE '(/home/|/Users/)[A-Za-z0-9_.-]+/' || true)
chk "no hook script has the literal root outside a comment" "$code_hits" "0"
json_hits=$(grep -cE '(/home/|/Users/)[A-Za-z0-9_.-]+/' "$ROOT/.claude/settings.json" || true)
chk "settings.json has no literal root" "$json_hits" "0"
# The file goes in on stdin: a path inside the -c string reaches a native Windows Python as an
# MSYS path it cannot open (Actions windows job, 2026-10-06); an argument would be converted.
chk "settings.json is valid JSON" \
    "$(python3 -c "import json,sys;json.load(sys.stdin);print('ok')" < "$ROOT/.claude/settings.json" 2>/dev/null | tr -d '\r')" "ok"
hooked=$(python3 - "$ROOT/.claude/settings.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
c=[h["command"] for evs in d["hooks"].values() for ev in evs for h in ev["hooks"]]
print(sum(1 for x in c if "CLAUDE_PROJECT_DIR" in x and "rev-parse" in x))
PY
)
chk "every hook command resolves the root at run time" "$hooked" "4"

sec "negative control: the check above really would catch a regression"

probe="$TMP/regress.sh"
printf '#!/usr/bin/env bash\ncd /home/someone/project || exit 0\n' > "$probe"
chk "a reintroduced hardcoded cd IS detected" \
    "$(sed 's/#.*//' "$probe" | grep -cE '(/home/|/Users/)[A-Za-z0-9_.-]+/')" "1"

printf '\n======================\npass %d  fail %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
