#!/usr/bin/env bash
# End-of-turn / end-of-session reminder about in-progress issues.
#
# Claude Code runs this on its Stop event and the Pi adapter on agent_settled -- and BOTH fire at
# the end of EVERY turn, not at session close. With the session id in the payload (Claude Code
# sends one; the Pi adapter sends its own) the reminder is scoped and quiet:
#   * hook_event_name Stop (turn end): the issues THIS session claimed that are still in progress,
#     printed only when that set CHANGES -- never the same notice twice;
#   * hook_event_name SessionEnd (actual close; the Pi adapter sends it on quit/new): the close
#     reminder for those issues, every time, if any are open.
# Why scoped: the bd store is shared by every session and project on this machine, and every
# session claims as the same actor. A busy store holds many in-progress issues from other sessions,
# often stale, and the old reminder repeated all of them after every Pi turn. What a session claimed is
# recorded by .claude/bd-prerun-hook.sh when it sees `bd update <id> --claim`.
# Without a session id (a manual run, an older adapter) this is the old global reminder.
# Root from this file's location, not a literal (see bd-prime-hook.sh).
WS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)
if [ -z "$WS" ] || ! cd "$WS"; then
    echo "⚠ bd-stop-hook: cannot resolve the workspace from '${BASH_SOURCE[0]}' — no in-progress check ran." >&2
    exit 0
fi

# ── The store's CLI: bd (default) or cairn ────────────────────────────────────
# .claude/store-cli holds one word, bd or cairn. It is TRACKED, so every session, every harness and
# the git hooks agree; there is deliberately no environment override (one session must not write
# a store the others have left). Absent: the CLI is bd and neither name is write-blocked, which is
# how every install that never opted in keeps working. Present: the named CLI runs, and a write
# through the OTHER name is blocked below, because it would land in a store nobody reads.
# Keep this block identical in bd-prime-hook.sh, bd-stop-hook.sh and .beads-hooks/pre-commit.
STORE_MODE=""
if [ -f "$WS/.claude/store-cli" ]; then
    STORE_MODE=$(tr -d ' \t\r\n' < "$WS/.claude/store-cli")
    case $STORE_MODE in
        bd|cairn) ;;
        *) echo "⚠ .claude/store-cli says '$STORE_MODE' (expected bd or cairn) — using bd, nothing write-blocked." >&2
           STORE_MODE="" ;;
    esac
fi
STORE_CLI=${STORE_MODE:-bd}

# COUNT ISSUE ROWS, NOT GLYPHS. In `bd list` output ◐ marks in_progress; ● is the BLOCKED glyph,
# and it is also the priority separator in every row ("◐ ws-1 ● P2 [bug] ..."), and a non-empty
# listing ends with a legend that itself says "● blocked". `grep -c "●"` therefore reported 2 for
# one issue (its row plus the legend), so the number in the reminder was wrong whenever it was
# shown (found 2026-09-22; tools/bd-stop-hook_test.sh). Prefer the JSON listing when jq is here;
# otherwise count rows that START with the in_progress glyph, after any tree prefix, which the
# legend line never does. bd-prerun-hook.sh carries the same function; keep the two identical.
count_in_progress() {
    local text n=""
    text=$("$STORE_CLI" list --status=in_progress --limit 0 2>/dev/null) || return 1
    if command -v jq >/dev/null 2>&1; then
        n=$("$STORE_CLI" --json list --status=in_progress --limit 0 2>/dev/null \
            | jq -r 'if type == "array" then length else empty end' 2>/dev/null)
    fi
    case $n in ''|*[!0-9]*) n=$(printf '%s\n' "$text" | grep -cE '^[^[:alnum:]]*◐ ' || true) ;; esac
    printf '%s' "${n:-0}"
}

# Session scope -- keep claims_dir and in_progress_rows identical to .claude/bd-prerun-hook.sh.
claims_dir() {
    if [ -n "${BD_SESSION_CLAIMS_DIR:-}" ]; then printf '%s' "$BD_SESSION_CLAIMS_DIR"; return; fi
    local g; g=$(git rev-parse --absolute-git-dir 2>/dev/null)
    if [ -n "$g" ]; then printf '%s/bd-session-claims' "$g"
    else printf '%s/bd-session-claims-%s' "${TMPDIR:-/tmp}" "$(id -u)"; fi
}
# "<id><TAB><title><TAB><assignee>" per in-progress issue; returns 1 when the CLI is unavailable.
# --limit 0: both CLIs stop at 50 rows by default, and say so only on the stderr discarded here.
in_progress_rows() {
    local json rows text
    if json=$("$STORE_CLI" --json list --status=in_progress --limit 0 2>/dev/null) && rows=$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert isinstance(d, list)
for x in d:
    if isinstance(x, dict) and x.get("id"):
        print("%s\t%s\t%s" % (x["id"], str(x.get("title", "")).replace("\t", " "), x.get("assignee") or ""))
' 2>/dev/null); then
        printf '%s' "${rows//$'\r'/}"; return 0   # CR LF from a native Windows Python
    fi
    text=$("$STORE_CLI" list --status=in_progress --limit 0 2>/dev/null) || return 1
    # rows start with the in_progress glyph after any tree prefix; the legend never does
    printf '%s\n' "$text" | awk '/^[^[:alnum:]]*◐ /{ sub(/^[^[:alnum:]]*◐ +/, ""); id = $1;
        sub(/^[^ ]+ */, ""); print id "\t" $0 }'
}

# The hook payload, if one was piped in. Never wait on a terminal; never wait forever on a pipe.
payload=""
[ -t 0 ] || IFS= read -r -d '' -t 5 payload || :
parsed=$(printf '%s' "$payload" | python3 -c '
import sys, json, re
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
if not isinstance(d, dict): d = {}
print(re.sub(r"[^A-Za-z0-9._-]", "_", str(d.get("session_id") or ""))[:128])
print(re.sub(r"[^A-Za-z]", "", str(d.get("hook_event_name") or "")))
' 2>/dev/null)
session_id=$(printf '%s\n' "$parsed" | sed -n 1p)
event=$(printf '%s\n' "$parsed" | sed -n 2p)

if [ -z "$session_id" ]; then
    open=$(count_in_progress) || open=0
    if [ "$open" -gt 0 ]; then
        echo "# ⚠️  SESSION CLOSE REMINDER"
        echo ""
        echo "You have $open in-progress issue(s) — run \`$STORE_CLI close <id>\` before finishing:"
        echo ""
        "$STORE_CLI" list --status=in_progress --limit 0 2>/dev/null
    fi
    exit 0
fi

rows=$(in_progress_rows) || exit 0          # CLI unavailable: nothing to report, never fail the event
record="$(claims_dir)/$session_id"
mine=""
# -s, not -f: with an EMPTY first file awk's NR == FNR stays true into stdin and every row "matches".
[ -s "$record" ] && mine=$(printf '%s\n' "$rows" | awk -F'\t' 'NR == FNR { claimed[$1]; next } ($1 in claimed)' "$record" - | sort -u)
# Also the issues the store assigns to this session's own actor: a claim the record missed (an id
# in a variable, `ready --claim`). Session-scoped actors only (<user>/<harness>/<id>); a bare user
# name is shared by every session. Same rule as the scripts gate in bd-prerun-hook.sh.
case ${BEADS_ACTOR:-} in
    */*) mine=$(printf '%s\n%s\n' "$mine" "$(printf '%s\n' "$rows" | awk -F '\t' -v a="$BEADS_ACTOR" '$3 == a')" \
                | grep . | sort -u) ;;
esac
n=$(printf '%s\n' "$mine" | grep -c . || true)

if [ "$event" = "SessionEnd" ]; then
    [ "$n" -gt 0 ] || exit 0
    echo "# ⚠️  SESSION CLOSE REMINDER"
    echo ""
    echo "$n issue(s) claimed in this session are still in progress — \`$STORE_CLI close <id>\` each, or note why it stays open:"
    echo ""
    printf '%s\n' "$mine" | awk -F'\t' '{ print "  ◐ " $1 "  " $2 }'
    exit 0
fi

# Turn end: speak only when this session's set changed since the last time it was reported.
last=""; [ -f "$record.reported" ] && last=$(cat "$record.reported")
[ "$mine" = "$last" ] && exit 0
if [ -d "$(dirname "$record")" ]; then printf '%s' "$mine" > "$record.reported" 2>/dev/null; fi
[ "$n" -gt 0 ] || exit 0
echo "# ◐ In progress, claimed in this session ($n) — close each with \`$STORE_CLI close <id>\` when done:"
printf '%s\n' "$mine" | awk -F'\t' '{ print "  ◐ " $1 "  " $2 }'
exit 0
