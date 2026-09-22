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
HOTFILE="$WS/.claude/memory-hot.txt"
# Scratch files are per process. Fixed names under /tmp were shared by every user on the box
# (the second user hit Permission denied on the first user's 0644 files and silently fell back)
# and by every concurrent session of one user (the --with-peer case), which raced on the index.
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/bd-prime.XXXXXX") || { echo "# 🚨 bd-prime-hook: cannot create a temp dir — session NOT primed."; exit 0; }
trap 'rm -rf "$TMPD"' EXIT
MM="$TMPD/mm.jsonl"; ERR="$TMPD/err"; INDEX="$TMPD/index"
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
# invisible precisely when it matters. Each check is bounded by `timeout` where the box has one,
# and its exit status is ignored: a monitor that can fail session start is worse than the outage
# it reports. But NOT silently -- see the note inside.
#
# Example: a check that reports a dead network mount, so an agent does not read a stale local
# directory and believe it. Write it so that "everything is fine" produces zero bytes.
emit_site_checks() {
  local dir="$WS/.claude/site-checks" f out bound="timeout 20" unbounded_said=0
  [ -d "$dir" ] || return 0
  # `timeout` is coreutils; stock macOS has none. `out=$(timeout 20 "$f" 2>/dev/null)` with no
  # timeout binary failed with "command not found" -- on the stderr that was discarded -- and
  # every check was skipped with no line saying so: the open-and-silent shape. Run unbounded
  # instead and SAY so once; a hung check then stalls session start visibly (the README warns of
  # it) rather than never running invisibly. Found by the 2026-09-22 review; the suite hides
  # timeout and requires both the notice and the check's output.
  command -v timeout >/dev/null 2>&1 || bound=""
  for f in "$dir"/*.sh; do
    [ -x "$f" ] || continue
    if [ -z "$bound" ] && [ "$unbounded_said" -eq 0 ]; then
      echo "## ⚠ bd-prime-hook: no \`timeout\` on this box — site checks run UNBOUNDED (a hung check stalls session start)"
      echo ""
      unbounded_said=1
    fi
    # Both streams: a check that dies on stderr ("command not found", a missing interpreter) is
    # a check that did not run, and that has to reach the payload too.
    out=$($bound "$f" 2>&1) || true
    [ -n "$out" ] || continue
    echo "## ⚠ SITE CHECK — $(basename "$f" .sh)"
    echo '```'
    echo "$out"
    echo '```'
    echo ""
  done
}
# The git-layer guards live in .beads-hooks/, but git only runs them if core.hooksPath says so,
# and that is local config that no clone inherits. Say it at the TOP of the payload (hosts truncate
# the bottom), in both the tiered and the fallback path.
emit_hooks_unwired() {
  local hp want got
  [ -f "$WS/.beads-hooks/pre-commit" ] || return 0
  hp=$(git -C "$WS" config core.hooksPath 2>/dev/null || true)
  case "$hp" in ""|/*) ;; *) hp="$WS/$hp" ;; esac
  want=$(cd "$WS/.beads-hooks" 2>/dev/null && pwd -P); got=$( [ -n "$hp" ] && cd "$hp" 2>/dev/null && pwd -P)
  [ -n "$got" ] && [ "$got" = "$want" ] && return 0
  echo "# 🚨 GIT-LAYER GUARDS ARE NOT WIRED IN THIS CLONE: core.hooksPath is '${hp:-unset}', so nothing in"
  echo "#    .beads-hooks/ runs on commit. Fix now:  git config core.hooksPath .beads-hooks"; echo ""
}
emit_rules() {
  emit_hooks_unwired
  echo "# 🚨 MANDATORY SESSION RULES — READ BEFORE RESPONDING 🚨"; echo ""
  echo "1. Run \`bd ready\` NOW to check for available work before doing anything else."
  echo "2. Use \`bd create\` for ALL task tracking — never TodoWrite, TaskCreate, or markdown lists."
  echo "3. Use \`bd update <id> --claim\` before starting any issue."
  echo "4. Use \`bd close <id>\` when work is complete."
  echo "5. Use \`bd remember\` for persistent knowledge — never MEMORY.md files."; echo ""
  emit_site_checks
}
# Every fallback SAYS it is one, and why. The full dump is the degraded path -- it was measured
# at 76 KB on a 40-memory store, past what hosts keep of a session payload -- and a silent
# fallback reads exactly like the tiered output it replaced. An EMPTY hot list is not a reason
# to fall back: it is a valid configuration (nothing in full, everything in the index), and it
# is how this file ships. The old `[ -s "$HOTFILE" ]` test meant a default install got the
# full dump with no line saying so.
fallback_full() { echo "# ⚠ bd-prime-hook: $1 — emitting the FULL bd prime dump (no memory tiering)."; emit_rules
  if ! bd prime 2>"$ERR"; then echo "# WARNING: bd prime failed"; cat "$ERR"; fi; }
command -v jq >/dev/null 2>&1 || { fallback_full "jq is not installed"; exit 0; }
[ -e "$HOTFILE" ] || { fallback_full "$HOTFILE is missing (an empty file is fine)"; exit 0; }
bd export --include-memories -o "$MM" 2>/dev/null || { fallback_full "bd export --include-memories failed"; exit 0; }
[ -f "$MM" ] || { fallback_full "bd export exited 0 but wrote no file"; exit 0; }
# A store with NO memories yet is the normal state of a fresh project, not a failed export: the
# tiered output is simply "0 of 0". Treating it as a fallback put a warning banner on every
# session of a new project until its first `bd remember`. The failure this guards against -- an
# export that exits 0 and writes nothing -- is the missing-file case above.
emit_rules
# bd workflow context + command reference, with the full memory dump removed
# (delete from "## Persistent Memories" up to but NOT including "## Core Rules")
bd prime 2>"$ERR" | sed '/^## Persistent Memories/,/^## Core Rules/{/^## Core Rules/!d;}'
TOTAL=$(grep -c '"_type":"memory"' "$MM")
# HOT = the keys in memory-hot.txt that EXIST in the store. Counting raw lines instead meant a
# typo, a duplicate or a key not yet remembered made the index arithmetic below come out wrong,
# and the hook then said "INDEX IS INCOMPLETE ... fix bd-prime-hook.sh" on every session -- a
# false alarm pointing at the wrong file. Name the unknown keys instead; that is the fix.
HOTLIST=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$HOTFILE")
HOTN=$(jq -r --argjson hot "$HOTLIST" -s '[.[] | select(._type=="memory") | .key] as $keys | [$hot[] | select(. as $h | $keys | index($h))] | length' "$MM")
UNKNOWN=$(jq -r --argjson hot "$HOTLIST" -s '[.[] | select(._type=="memory") | .key] as $keys | [$hot[] | select(. as $h | $keys | index($h) | not)] | .[]' "$MM")
echo ""; echo "## Persistent Memories — HOT tier ($HOTN always-loaded guards of $TOTAL total)"
if [ -n "$UNKNOWN" ]; then
  echo "> ⚠ .claude/memory-hot.txt names memories that are not in the store — fix the list or \`bd remember\` them:"
  printf '%s\n' "$UNKNOWN" | sed 's/^/>   /'; echo ""
fi
[ "$TOTAL" -eq 0 ] && echo "_The store has no memories yet — nothing to tier. \`bd remember --key <slug> \"<fact>\"\` adds the first._"
echo "_Only recurring-mistake guards are injected in full below. Retrieve any other memory on demand with \`bd memories <keyword>\`._"; echo ""
jq -r '.[]' <<<"$HOTLIST" | while IFS= read -r k; do [ -z "$k" ] && continue
  jq -r --arg k "$k" 'select(._type=="memory" and .key==$k) | "### \(.key)\n\(.value)\n"' "$MM"; done
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
HOTJSON=$HOTLIST
# NOTE THE `.key as $k` BINDING -- it is load-bearing. Writing the obvious
# `select(($hot | index(.key)) == null)` silently emits NOTHING: inside the pipe, `.key` is
# evaluated against $hot (the array) rather than the memory, jq errors per line on stderr, and
# because stderr is discarded the hook prints a well-formed header over an empty list. Caught
# only because the byte count fell further than the change could explain.
jq -r --argjson hot "$HOTJSON" \
   'select(._type=="memory") | .key as $k | select($hot | index($k) | not) | "- \($k)"' \
   "$MM" > "$INDEX"
# The index is the one component whose whole job is to say what EXISTS, so an empty or short one
# is worse than a large one: it reads as "there is nothing else" rather than as a failure.
# Assert the arithmetic instead of trusting it.
EXPECT=$((TOTAL - HOTN)); GOT=$(grep -c . "$INDEX")
if [ "$GOT" -ne "$EXPECT" ]; then
  echo "> ⚠ INDEX IS INCOMPLETE — listing $GOT of an expected $EXPECT memories."
  echo "> Do not read the list below as the full set. Use \`bd memories <keyword>\` to search the"
  echo "> store directly, and fix .claude/bd-prime-hook.sh."; echo ""
fi
cat "$INDEX"
