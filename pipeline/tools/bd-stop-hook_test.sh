#!/usr/bin/env bash
# Acceptance suite for .claude/bd-stop-hook.sh — the number in the reminder is the number of issues.
#
# WHY IT EXISTS
# The hook counted lines containing ● and said "You have 2 in-progress issue(s)" for one issue: ●
# is bd's priority bullet on every row AND its BLOCKED glyph in the legend under every non-empty
# listing. Found by the 2026-09-22 review; nothing had ever run the hook against bd's real output.
#
# Hermetic: a stub bd on PATH answers `bd list --status=in_progress` (text, bd 1.3's real shape)
# and `bd --json list ...`, and the hook is copied into a throwaway .claude/ so it resolves that
# root from its own location. Nothing here touches the real store.
set -uo pipefail
HOOK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/.claude/bd-stop-hook.sh
[ -f "$HOOK" ] || { echo "missing: $HOOK" >&2; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/ws/.claude"
cat > "$T/bin/bd" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *--json*)      printf '%s\n' "${BD_STUB_JSON-}" ;;
  *in_progress*) printf '%s\n' "${BD_STUB_LIST-}" ;;
esac
exit 0
STUB
chmod +x "$T/bin/bd"
cp -f "$HOOK" "$T/ws/.claude/bd-stop-hook.sh"
run_hook() { (cd "$T/ws" && PATH="$T/bin:${HOOK_PATH:-$PATH}" bash .claude/bd-stop-hook.sh) 2>/dev/null; }

ROW1='◐ proj-1 ● P2 [bug] one thing in flight'
ROW2='◐ proj-2 ● P1 [task] another'
LEGEND=$'\n--------\nTotal: 1 issues (0 open, 1 in progress)\n\nStatus: ○ open  ◐ in_progress  ● blocked  ✓ closed  ❄ deferred'

echo "### nothing in progress: no reminder"
export BD_STUB_LIST="No issues found." BD_STUB_JSON="[]"
chk "silent"                                "$(run_hook | grep -c 'SESSION CLOSE')" 0

echo "### one issue in progress: the reminder says 1, not 2"
export BD_STUB_LIST="$ROW1$LEGEND" BD_STUB_JSON='[{"id":"proj-1","status":"in_progress"}]'
out=$(run_hook)
chk "reminder shown"                        "$(grep -c 'SESSION CLOSE' <<<"$out")" 1
chk "count is 1 (row + legend both carry ●)" "$(grep -c 'You have 1 in-progress' <<<"$out")" 1
chk "the listing follows"                   "$(grep -c 'proj-1' <<<"$out")" 1

echo "### the text fallback (JSON unusable) counts rows, not glyphs"
export BD_STUB_JSON="not json"
chk "one row -> 1"                          "$(run_hook | grep -c 'You have 1 in-progress')" 1
export BD_STUB_LIST="$ROW1"$'\n'"$ROW2$LEGEND"
chk "two rows -> 2"                         "$(run_hook | grep -c 'You have 2 in-progress')" 1
export BD_STUB_LIST="Status: ○ open  ◐ in_progress  ● blocked  ✓ closed"
chk "a legend with no rows -> no reminder"  "$(run_hook | grep -c 'SESSION CLOSE')" 0

echo "### without jq on PATH the same numbers come out"
mkdir -p "$T/nojq"
for tool in bash sh grep cat sed dirname mktemp rm; do
  b=$(command -v "$tool" 2>/dev/null) && ln -sf "$b" "$T/nojq/$tool"
done
export BD_STUB_LIST="$ROW1$LEGEND" BD_STUB_JSON='[{"id":"proj-1","status":"in_progress"}]'
chk "no jq: one row -> 1"                   "$(HOOK_PATH="$T/nojq" run_hook | grep -c 'You have 1 in-progress')" 1
export BD_STUB_LIST="No issues found." BD_STUB_JSON="[]"
chk "no jq: nothing -> silent"              "$(HOOK_PATH="$T/nojq" run_hook | grep -c 'SESSION CLOSE')" 0

echo "### bd absent: silent, exit 0 (a broken bd must not fail the Stop event)"
rc=0; out=$(cd "$T/ws" && PATH="$T/nojq" bash .claude/bd-stop-hook.sh 2>/dev/null) || rc=$?
chk "exit 0"                                "$rc" 0
chk "no reminder"                           "$(grep -c 'SESSION CLOSE' <<<"$out")" 0

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
