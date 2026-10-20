#!/usr/bin/env bash
# store-cli-harness-hooks_test.sh — the harness hooks bd writes follow .claude/store-cli.
#
# Hermetic: a throwaway git repo holding the three harness configs as bd 1.3.0's `bd init` wrote
# them (plus one of the pipeline's own script hooks, which must be left alone); every guarded
# command is then RUN through sh against a stub bd that logs its calls.
set -uo pipefail
TOOL=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/store-cli-harness-hooks.sh
[ -f "$TOOL" ] || { echo "missing: $TOOL" >&2; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

R=$T/repo; mkdir -p "$R/tools" "$R/.claude" "$R/.codex" "$R/.cursor" "$R/sub/dir" "$T/bin"
cp "$TOOL" "$R/tools/"
git -C "$R" init -q .
cat > "$R/.claude/settings.json" <<'J'
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"command": "bash .claude/bd-prime-hook.sh", "type": "command"}], "matcher": ""},
      {"hooks": [{"command": "bd prime --hook-json", "type": "command"}], "matcher": ""}
    ]
  }
}
J
cat > "$R/.codex/hooks.json" <<'J'
{"hooks": {"SessionStart": [{"hooks": [{"command": "bd codex-hook SessionStart", "type": "command"}],
  "matcher": "startup|resume|clear"}],
  "PreCompact": [{"hooks": [{"command": "bd codex-hook PreCompact", "type": "command"}], "matcher": "manual|auto"}]}}
J
cat > "$R/.cursor/hooks.json" <<'J'
{"hooks": {"sessionStart": [{"command": "bd cursor-hook sessionStart"}]}, "version": 1}
J
printf '#!/usr/bin/env bash\necho "bd $*" >> "%s/calls"\n' "$T" > "$T/bin/bd"; chmod +x "$T/bin/bd"
cmds() { python3 - "$R" <<'PY'
import json, sys, os
r = sys.argv[1]
for p in (".claude/settings.json", ".codex/hooks.json", ".cursor/hooks.json"):
    d = json.load(open(os.path.join(r, p)))
    for ev, gs in d["hooks"].items():
        for g in gs:
            for e in (g["hooks"] if "hooks" in g else [g]):
                print(e["command"])
PY
}
# Run every bd-derived command the way a harness does (sh -c from a cwd), count the bd calls.
fire() { : > "$T/calls"; cmds | grep -v bd-prime-hook.sh | while IFS= read -r c; do
           (cd "$1" && env -u CLAUDE_PROJECT_DIR PATH="$T/bin:$PATH" sh -c "$c"); done
         wc -l < "$T/calls" | tr -d ' '; }

echo "### before: --check names all four bd hooks"
(cd "$R" && bash tools/store-cli-harness-hooks.sh --check) 2> "$T/err"; rc=$?
chk "--check exits 1"                           "$rc" 1
chk "…naming each bd hook"                      "$(grep -c 'runs bd under cairn' "$T/err")" 4
chk "--check changed nothing"                   "$(cmds | grep -c '^bd ')" 4

echo "### guard"
(cd "$R" && bash tools/store-cli-harness-hooks.sh) > "$T/out"; rc=$?
chk "exit 0"                                    "$rc" 0
chk "four hooks guarded"                        "$(grep -c 'now stops under cairn' "$T/out")" 4
chk "no hook starts with bd any more"           "$(cmds | grep -c '^bd ')" 0
chk "the pipeline's script hook is untouched"   "$(cmds | grep -c '^bash .claude/bd-prime-hook.sh$')" 1
chk "--check passes now"                        "$(cd "$R" && bash tools/store-cli-harness-hooks.sh --check >/dev/null 2>&1; echo $?)" 0
chk "idempotent: a second run changes nothing"  "$(cd "$R" && bash tools/store-cli-harness-hooks.sh | wc -l | tr -d ' ')" 0
chk "the files are still JSON"                  "$(cmds >/dev/null 2>&1; echo $?)" 0

echo "### the guarded hooks follow the switch"
chk "no store-cli: every hook still runs bd"    "$(fire "$R")" 4
printf 'bd\n' > "$R/.claude/store-cli"
chk "store-cli = bd: every hook runs bd"        "$(fire "$R")" 4
printf 'cairn\n' > "$R/.claude/store-cli"
chk "store-cli = cairn: no hook runs bd"        "$(fire "$R")" 0
chk "…also from a subdirectory (git top level)" "$(fire "$R/sub/dir")" 0
: > "$T/calls"; (cd "$R" && PATH="$T/bin:$PATH" sh -c "$(cmds | grep -m1 'prime --hook-json')"); rc=$?
chk "…and a skipped hook exits 0"               "$rc" 0
printf 'cairn\n' > "$R/.claude/store-cli"; rm -f "$R/.claude/store-cli"
chk "rollback (file gone): bd runs again"       "$(fire "$R")" 4

echo "### a file that is not JSON is reported, not rewritten"
printf '{ not json\n' > "$R/.cursor/hooks.json"
(cd "$R" && bash tools/store-cli-harness-hooks.sh) 2> "$T/err"; rc=$?
chk "exit 1"                                    "$rc" 1
chk "…and it says so"                           "$(grep -c 'is not JSON' "$T/err")" 1
chk "…and leaves the file alone"                "$(cat "$R/.cursor/hooks.json")" "{ not json"

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
