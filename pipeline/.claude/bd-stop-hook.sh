#!/usr/bin/env bash
# Fires on Claude Stop event. Warns if any issues are still in_progress.
# Root from this file's location, not a literal (see bd-prime-hook.sh).
WS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)
if [ -z "$WS" ] || ! cd "$WS"; then
    echo "⚠ bd-stop-hook: cannot resolve the workspace from '${BASH_SOURCE[0]}' — no in-progress check ran." >&2
    exit 0
fi

open=$(bd list --status=in_progress 2>/dev/null | grep -c "●" || true)

if [ "$open" -gt 0 ]; then
    echo "# ⚠️  SESSION CLOSE REMINDER"
    echo ""
    echo "You have $open in-progress issue(s) — run \`bd close <id>\` before finishing:"
    echo ""
    bd list --status=in_progress 2>/dev/null
fi
