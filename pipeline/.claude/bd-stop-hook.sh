#!/usr/bin/env bash
# Fires on Claude Stop event. Warns if any issues are still in_progress.
# Root from this file's location, not a literal (see bd-prime-hook.sh).
WS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)
if [ -z "$WS" ] || ! cd "$WS"; then
    echo "⚠ bd-stop-hook: cannot resolve the workspace from '${BASH_SOURCE[0]}' — no in-progress check ran." >&2
    exit 0
fi

# COUNT ISSUE ROWS, NOT GLYPHS. In `bd list` output ◐ marks in_progress; ● is the BLOCKED glyph,
# and it is also the priority separator in every row ("◐ ws-1 ● P2 [bug] ..."), and a non-empty
# listing ends with a legend that itself says "● blocked". `grep -c "●"` therefore reported 2 for
# one issue (its row plus the legend), so the number in the reminder was wrong whenever it was
# shown (found 2026-09-22; tools/bd-stop-hook_test.sh). Prefer the JSON listing when jq is here;
# otherwise count rows that START with the in_progress glyph, after any tree prefix, which the
# legend line never does. bd-prerun-hook.sh carries the same function; keep the two identical.
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

open=$(count_in_progress) || open=0

if [ "$open" -gt 0 ]; then
    echo "# ⚠️  SESSION CLOSE REMINDER"
    echo ""
    echo "You have $open in-progress issue(s) — run \`bd close <id>\` before finishing:"
    echo ""
    bd list --status=in_progress 2>/dev/null
fi
