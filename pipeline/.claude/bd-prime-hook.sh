#!/usr/bin/env bash
# bd-prime-hook.sh — TIERED memory injection (see .claude/skills/memory-curate, mode `tier`).
# Emits: session rules + bd workflow context + bd command reference + HOT memories (full) + index of the rest.
# Full store stays in bd; situational memories are pulled on demand via `bd memories <kw>`.
# REPO ROOT COMES FROM THIS FILE'S OWN LOCATION (.claude/ -> repo root), never a literal.
# This is load-bearing, and it was learned the hard way: an earlier version said
# `cd /home/you/project || exit 0`. Because .claude/settings.json is version-controlled,
# that hardcoded root travelled to every clone and resolved on NONE of them, and the
# `|| exit 0` then failed OPEN and SILENT -- no rules, no memories, no guards, and no error
# anywhere. Never put an absolute path in version-controlled config.
# Guard: tools/hook_portability_test.sh.
WS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)
if [ -z "$WS" ] || [ ! -d "$WS/.claude" ]; then
  # SessionStart stdout becomes the session payload, so this alarm is the loud path.
  echo "# 🚨 bd-prime-hook: CANNOT RESOLVE THE WORKSPACE from '${BASH_SOURCE[0]}'."
  echo "# This session has NO project rules and NO bd memories — do not treat it as primed."
  echo "# Fix: re-run the installer against this repo, then check .claude/settings.json."
  exit 0
fi
cd "$WS" || { echo "# 🚨 bd-prime-hook: cannot cd to '$WS' — session NOT primed."; exit 0; }
HOTFILE="$WS/.claude/memory-hot.txt"; MM=/tmp/bd-prime-mm.jsonl
# SITE CHECKS — optional, repo-local health checks, run at session start.
#
# Drop any executable script into .claude/site-checks/. The contract is the one property that
# makes a check worth having in a session payload: PRINT NOTHING WHEN HEALTHY. A check that
# chatters every session trains its reader to skip the block, and then it is worthless on the
# day it has something to say.
#
# This runs inside emit_rules for two reasons. emit_rules runs in BOTH the normal and the
# fallback_full path, so a check cannot be skipped by a degraded session; and hosts truncate
# the session payload (~39 KB was measured on one), so anything appended at the BOTTOM is
# invisible precisely when it matters. Each check is bounded by `timeout` and its failure is
# swallowed: a monitor that can hang or fail session start is worse than the outage it reports.
#
# Example: a check that reports a dead network mount, so an agent does not read a stale local
# directory and believe it. Write it so that "everything is fine" produces zero bytes.
emit_site_checks() {
  local dir="$WS/.claude/site-checks" f out
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.sh; do
    [ -x "$f" ] || continue
    out=$(timeout 20 "$f" 2>/dev/null) || true
    [ -n "$out" ] || continue
    echo "## ⚠ SITE CHECK — $(basename "$f" .sh)"
    echo '```'
    echo "$out"
    echo '```'
    echo ""
  done
}
emit_rules() {
  echo "# 🚨 MANDATORY SESSION RULES — READ BEFORE RESPONDING 🚨"; echo ""
  echo "1. Run \`bd ready\` NOW to check for available work before doing anything else."
  echo "2. Use \`bd create\` for ALL task tracking — never TodoWrite, TaskCreate, or markdown lists."
  echo "3. Use \`bd update <id> --claim\` before starting any issue."
  echo "4. Use \`bd close <id>\` when work is complete."
  echo "5. Use \`bd remember\` for persistent knowledge — never MEMORY.md files."; echo ""
  emit_site_checks
}
fallback_full() { emit_rules; if ! bd prime 2>/tmp/bd-prime-err; then echo "# WARNING: bd prime failed"; cat /tmp/bd-prime-err; fi; }
command -v jq >/dev/null 2>&1 || { fallback_full; exit 0; }
[ -s "$HOTFILE" ] || { fallback_full; exit 0; }
bd export --include-memories -o "$MM" 2>/dev/null || { fallback_full; exit 0; }
grep -q '"_type":"memory"' "$MM" 2>/dev/null || { fallback_full; exit 0; }
emit_rules
# bd workflow context + command reference, with the full memory dump removed
# (delete from "## Persistent Memories" up to but NOT including "## Core Rules")
bd prime 2>/tmp/bd-prime-err | sed '/^## Persistent Memories/,/^## Core Rules/{/^## Core Rules/!d;}'
TOTAL=$(grep -c '"_type":"memory"' "$MM"); HOTN=$(grep -c . "$HOTFILE")
echo ""; echo "## Persistent Memories — HOT tier ($HOTN always-loaded guards of $TOTAL total)"
echo "_Only recurring-mistake guards are injected in full below. Retrieve any other memory on demand with \`bd memories <keyword>\`._"; echo ""
while IFS= read -r k; do [ -z "$k" ] && continue
  jq -r --arg k "$k" 'select(._type=="memory" and .key==$k) | "### \(.key)\n\(.value)\n"' "$MM"; done < "$HOTFILE"
echo "## Persistent Memories — index ($(($TOTAL-$HOTN)) more; retrieve full text with \`bd memories <keyword>\` or \`bd recall <key>\`)"
echo "_Keys only. They are written as sentences precisely so this index does not need previews._"
# KEYS ONLY, NO 70-CHAR PREVIEW. Measured on a live store: the preview made this index
# 38,480 B of a 76,290 B payload -- half the hook, spent restating keys that are already full
# sentences ("stable-global-mean-does-not-license-a-regional-claim"). Dropping it costs ~nothing
# in discoverability and is the single largest saving available without deciding what the fleet
# stops always-loading.
#
# Exact-match filtering via jq rather than `grep -vFf` on "- key:" patterns: the old form
# matched by substring, so any key that is a PREFIX of another would have hidden the longer one
# from the index. Not observed to have bitten, but it is a silent-omission bug in the one
# component whose whole job is to tell you what exists.
HOTJSON=$(jq -R -s 'split("\n") | map(select(length > 0))' "$HOTFILE")
# NOTE THE `.key as $k` BINDING -- it is load-bearing. Writing the obvious
# `select(($hot | index(.key)) == null)` silently emits NOTHING: inside the pipe, `.key` is
# evaluated against $hot (the array) rather than the memory, jq errors per line on stderr, and
# because stderr is discarded the hook prints a well-formed header over an empty list. Caught
# only because the byte count fell further than the change could explain.
jq -r --argjson hot "$HOTJSON" \
   'select(._type=="memory") | .key as $k | select($hot | index($k) | not) | "- \($k)"' \
   "$MM" > /tmp/bd-prime-index
# The index is the one component whose whole job is to say what EXISTS, so an empty or short one
# is worse than a large one: it reads as "there is nothing else" rather than as a failure.
# Assert the arithmetic instead of trusting it.
EXPECT=$((TOTAL - HOTN)); GOT=$(grep -c . /tmp/bd-prime-index)
if [ "$GOT" -ne "$EXPECT" ]; then
  echo "> ⚠ INDEX IS INCOMPLETE — listing $GOT of an expected $EXPECT memories."
  echo "> Do not read the list below as the full set. Use \`bd memories <keyword>\` to search the"
  echo "> store directly, and fix .claude/bd-prime-hook.sh."; echo ""
fi
cat /tmp/bd-prime-index
