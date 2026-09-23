#!/usr/bin/env bash
# bd-prime-hook.sh — TIERED memory injection (see .claude/skills/memory-curate, mode `tier`).
# Emits, in this order: alarms, the session rules, site-check output, a key-only index of the
# memory store, the HOT memories (memory-hot.txt) in full, then bd's workflow context and command
# reference. Full store stays in bd; anything not hot is pulled on demand via `bd recall <key>`.
#
# THE HOST HAS A BUDGET, AND IT IS SMALL. Claude Code keeps only a 2,000-byte preview of any one
# SessionStart hook command's stdout above 10,000 bytes; the rest goes to a file. Measured
# 2026-09-22 with synthetic hooks (10,000 bytes arrive whole, 12,000 do not; the JSON
# additionalContext form is capped identically) and stated by anthropics/claude-code#70460
# (closed 2026-08-07): 10 KB, 2 KB, per hook command, no setting to raise it. A 15.9 KB tiered
# payload lost its hot tier AND its index that way while looking like a successful run from the
# outside -- the open-and-silent shape this pipeline exists to prevent. So this hook budgets:
# BD_PRIME_BUDGET (default 10000; 0 = no limit) bounds what it emits; the load-bearing parts come
# first; index keys and hot bodies that do not fit are NAMED instead of silently lost;
# the bd context is the first thing dropped; any trimming is announced at the top. Guard: tools/bd-prime-hook_test.sh.
#
# REPO ROOT COMES FROM THIS FILE'S OWN LOCATION (.claude/ -> repo root), never a literal.
# This is load-bearing, and it was learned the hard way: an earlier version said
# `cd /home/you/project || exit 0`. Because .claude/settings.json is version-controlled,
# that hardcoded root travelled to every clone and resolved on NONE of them, and the
# `|| exit 0` then failed OPEN and SILENT -- no rules, no memories, no guards, and no error
# anywhere. Never put an absolute path in version-controlled config.
# Guard: tools/hook_portability_test.sh.
WS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd -P)
if [ -z "$WS" ] || [ ! -d "$WS/.claude" ]; then
  # SessionStart stdout becomes the session payload, so this alarm is the loud path.
  echo "# 🚨 bd-prime-hook: CANNOT RESOLVE THE WORKSPACE from '${BASH_SOURCE[0]:-$0}'."
  echo "# This session has NO project rules and NO bd memories — do not treat it as primed."
  echo "# Fix: re-run the installer against this repo, then check .claude/settings.json."
  exit 0
fi
cd "$WS" || { echo "# 🚨 bd-prime-hook: cannot cd to '$WS' — session NOT primed."; exit 0; }
HOTFILE="$WS/.claude/memory-hot.txt"
BUDGET=${BD_PRIME_BUDGET:-10000}
case $BUDGET in ''|*[!0-9]*) BUDGET=10000 ;; esac
SITE_CHECK_CAP=1500
# The last line of every payload. A host that cuts the tail cuts this first, so a reader who
# does not see it knows the payload is incomplete -- the one signal a truncated payload can carry.
FOOTER="# — end of bd-prime-hook payload —"
# Scratch files are per process. Fixed names under /tmp were shared by every user on the box
# (the second user hit Permission denied on the first user's 0644 files and silently fell back)
# and by every concurrent session of one user (the --with-peer case), which raced on the index.
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/bd-prime.XXXXXX") || { echo "# 🚨 bd-prime-hook: cannot create a temp dir — session NOT primed."; exit 0; }
trap 'rm -rf "$TMPD"' EXIT
MM="$TMPD/mm.jsonl"; ERR="$TMPD/err"; INDEX="$TMPD/index"
size() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }
# SITE CHECKS — optional, repo-local health checks, run at session start.
#
# Drop any executable script into .claude/site-checks/. The contract is the one property that
# makes a check worth having in a session payload: PRINT NOTHING WHEN HEALTHY. A check that
# chatters every session trains its reader to skip the block, and then it is worthless on the
# day it has something to say.
#
# This runs inside emit_rules for two reasons. emit_rules runs in BOTH the normal and the
# fallback_full path, so a check cannot be skipped by a degraded session; and the host keeps
# only the head of the payload (see the budget note above), so anything appended at the BOTTOM
# is invisible precisely when it matters. Each check is bounded by `timeout` where the box has
# one, and its exit status is ignored: a monitor that can fail session start is worse than the
# outage it reports. But NOT silently -- see the note inside.
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
    # A check is bounded in BYTES as well as time. One that dumps a log would push the rules over
    # the host's cap and take the whole payload with it (peer review, 2026-09-22): say what is
    # wrong, not everything about it.
    n=$(printf '%s' "$out" | wc -c | tr -d ' ')
    if [ "$n" -gt "$SITE_CHECK_CAP" ]; then
      out="$(printf '%s' "$out" | head -c "$SITE_CHECK_CAP")
… [cut by bd-prime-hook at $SITE_CHECK_CAP of $n bytes — a check should say what is wrong, not dump it]"
    fi
    echo "## ⚠ SITE CHECK — $(basename "$f" .sh)"
    echo '```'
    echo "$out"
    echo '```'
    echo ""
  done
}
# The git-layer guards live in .beads-hooks/, but git only runs them if core.hooksPath says so,
# and that is local config that no clone inherits. Say it at the TOP of the payload (hosts keep
# the head, not the tail), in both the tiered and the fallback path.
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
emit_session_rules() {
  echo "# 🚨 MANDATORY SESSION RULES — READ BEFORE RESPONDING 🚨"; echo ""
  echo "1. Run \`bd ready\` NOW to check for available work before doing anything else."
  echo "2. Use \`bd create\` for ALL task tracking — never TodoWrite, TaskCreate, or markdown lists."
  echo "3. Use \`bd update <id> --claim\` before starting any issue."
  echo "4. Use \`bd close <id>\` when work is complete."
  echo "5. Use \`bd remember\` for persistent knowledge — never MEMORY.md files."; echo ""
}
emit_rules() { emit_hooks_unwired; emit_session_rules; emit_site_checks; }
# Every fallback SAYS it is one, and why. The full dump is the degraded path -- it was measured
# at 76 KB on a 40-memory store, far past what the host shows -- and a silent fallback reads
# exactly like the tiered output it replaced. An EMPTY hot list is not a reason to fall back:
# it is a valid configuration (nothing in full, everything in the index), and it is how this
# file ships. The old `[ -s "$HOTFILE" ]` test meant a default install got the full dump with
# no line saying so. The dump is budgeted like everything else: what does not fit is CUT, and
# the cut is announced on line 2, because a 36 KB dump that the host reduces to its first
# 2,000 bytes is not "the full dump" however the hook labels it.
fallback_full() {
  local banner="# ⚠ bd-prime-hook: $1 — emitting the FULL bd prime dump (no memory tiering)."
  local note="" used total dump room
  echo "$banner"
  emit_rules > "$TMPD/s.rules_all"
  if ! bd prime > "$TMPD/dump" 2>"$ERR"; then { echo "# WARNING: bd prime failed"; cat "$ERR"; } >> "$TMPD/dump"; fi
  used=$(( ${#banner} + 1 + $(size "$TMPD/s.rules_all") + ${#FOOTER} + 2 )); dump=$(size "$TMPD/dump"); total=$((used + dump))
  if [ "$BUDGET" -gt 0 ] && [ "$total" -gt "$BUDGET" ]; then
    note="# ⚠ bd-prime-hook: this dump is $total bytes and the host shows at most BD_PRIME_BUDGET=$BUDGET per hook (Claude Code: a 2,000-byte preview above 10,000) — CUT to fit. Run \`bd prime\` yourself for all of it; fix the cause named above so the tiered path can run, and keep the store lean (memory-curate)."
    echo "$note"; used=$((used + ${#note} + 1))
  fi
  cat "$TMPD/s.rules_all"
  if [ -n "$note" ]; then
    room=$((BUDGET - used - 60)); [ "$room" -gt 0 ] || room=0
    head -c "$room" "$TMPD/dump"; echo ""; echo "# … [cut here by bd-prime-hook: over budget]"
  else
    cat "$TMPD/dump"
  fi
  echo ""; echo "$FOOTER"
}
command -v jq >/dev/null 2>&1 || { fallback_full "jq is not installed"; exit 0; }
[ -e "$HOTFILE" ] || { fallback_full "$HOTFILE is missing (an empty file is fine)"; exit 0; }
bd export --include-memories -o "$MM" 2>/dev/null || { fallback_full "bd export --include-memories failed"; exit 0; }
[ -f "$MM" ] || { fallback_full "bd export exited 0 but wrote no file"; exit 0; }
# A store with NO memories yet is the normal state of a fresh project, not a failed export: the
# tiered output is simply "0 of 0". Treating it as a fallback put a warning banner on every
# session of a new project until its first `bd remember`. The failure this guards against -- an
# export that exits 0 and writes nothing -- is the missing-file case above.
#
# Every section is built into its own scratch file first, so the whole payload can be measured
# against the budget and reordered before a byte of it is printed.
emit_hooks_unwired > "$TMPD/s.unwired"
emit_session_rules > "$TMPD/s.rules"
emit_site_checks   > "$TMPD/s.site"
# bd workflow context + command reference, with the full memory dump removed
# (delete from "## Persistent Memories" up to but NOT including "## Core Rules")
# Capture status BEFORE filtering. A pipeline ending in sed hid bd's failure, and the
# captured stderr was then discarded. Put the alarm with the never-dropped top sections.
if bd prime > "$TMPD/prime" 2>"$ERR"; then
  sed '/^## Persistent Memories/,/^## Core Rules/{/^## Core Rules/!d;}' "$TMPD/prime" > "$TMPD/s.ctx"
else
  { echo '# WARNING: bd prime failed — workflow context unavailable; memories below came from export.'
    head -c 1000 "$ERR"; echo; } >> "$TMPD/s.unwired"
  : > "$TMPD/s.ctx"
fi
TOTAL=$(grep -c '"_type":"memory"' "$MM")
# HOT = the keys in memory-hot.txt that EXIST in the store. Counting raw lines instead meant a
# typo, a duplicate or a key not yet remembered made the index arithmetic below come out wrong,
# and the hook then said "INDEX IS INCOMPLETE ... fix bd-prime-hook.sh" on every session -- a
# false alarm pointing at the wrong file. Name the unknown keys instead; that is the fix.
# Deduplicated but in FILE ORDER: jq's `unique` sorts, which made the budget below keep hot
# bodies alphabetically -- on a real store it kept `evaluation-…` and dropped `operational-state`
# because `e` < `o`, whatever the list said. The order of memory-hot.txt is the priority order.
HOTLIST=$(jq -R -s 'split("\n") | map(select(length > 0)) | reduce .[] as $k ([]; if index($k) then . else . + [$k] end)' "$HOTFILE")
HOTN=$(jq -r --argjson hot "$HOTLIST" -s '[.[] | select(._type=="memory") | .key] as $keys | [$hot[] | select(. as $h | $keys | index($h))] | length' "$MM")
UNKNOWN=$(jq -r --argjson hot "$HOTLIST" -s '[.[] | select(._type=="memory") | .key] as $keys | [$hot[] | select(. as $h | $keys | index($h) | not)] | .[]' "$MM")
{
  echo ""; echo "## Persistent Memories — HOT tier ($HOTN selected keys of $TOTAL total; bodies included while budget permits)"
  if [ -n "$UNKNOWN" ]; then
    echo "> ⚠ .claude/memory-hot.txt names memories that are not in the store — fix the list or \`bd remember\` them:"
    printf '%s\n' "$UNKNOWN" | sed 's/^/>   /'; echo ""
  fi
  [ "$TOTAL" -eq 0 ] && echo "_The store has no memories yet — nothing to tier. \`bd remember --key <slug> \"<fact>\"\` adds the first._"
  echo "_Only recurring-mistake guards are injected in full below. Retrieve any other memory on demand with \`bd memories <keyword>\`._"; echo ""
} > "$TMPD/s.hothdr"
# One scratch file per hot body, in memory-hot.txt order, so the budget can keep the first N
# that fit and name the rest. hot.keys holds the key for each file, line for line.
: > "$TMPD/hot.keys"; n=0
jq -r '.[]' <<<"$HOTLIST" | while IFS= read -r k; do [ -z "$k" ] && continue
  f=$(printf '%s/hot.%04d' "$TMPD" "$n"); n=$((n+1))
  jq -r --arg k "$k" 'select(._type=="memory" and .key==$k) | "### \(.key)\n\(.value)\n"' "$MM" > "$f"
  if [ -s "$f" ]; then echo "$k" >> "$TMPD/hot.keys"; else rm -f "$f"; n=$((n-1)); fi
done
# The index is the one component whose whole job is to say what EXISTS, so an empty or short one
# is worse than a large one: it reads as "there is nothing else" rather than as a failure.
# KEYS ONLY, NO 70-CHAR PREVIEW. Measured on a live store: the preview made this index
# 38,480 B of a 76,290 B payload -- half the hook, spent restating keys that are already full
# sentences. Dropping it costs ~nothing in discoverability and is the single largest saving
# available without deciding what the fleet stops always-loading.
#
# Exact-match filtering via jq rather than `grep -vFf` on "- key:" patterns: the old form
# matched by substring, so any key that is a PREFIX of another would have hidden the longer one
# from the index. Not observed to have bitten, but it is a silent-omission bug in the one
# component whose whole job is to tell you what exists.
#
# NOTE THE `.key as $k` BINDING -- it is load-bearing. Writing the obvious
# `select(($hot | index(.key)) == null)` silently emits NOTHING: inside the pipe, `.key` is
# evaluated against $hot (the array) rather than the memory, jq errors per line on stderr, and
# because stderr is discarded the hook prints a well-formed header over an empty list. Caught
# only because the byte count fell further than the change could explain.
jq -r --argjson hot "$HOTLIST" \
   'select(._type=="memory") | .key as $k | select($hot | index($k) | not) | "- \($k)"' \
   "$MM" > "$INDEX"
EXPECT=$((TOTAL - HOTN)); GOT=$(grep -c . "$INDEX")
{
  echo ""; echo "## Persistent Memories — index ($EXPECT more; retrieve full text with \`bd memories <keyword>\` or \`bd recall <key>\`)"
  echo "_Keys only. They are written as sentences precisely so this index does not need previews._"
  if [ "$GOT" -ne "$EXPECT" ]; then
    echo "> ⚠ INDEX IS INCOMPLETE — listing $GOT of an expected $EXPECT memories."
    echo "> Do not read the list below as the full set. Use \`bd memories <keyword>\` to search the"
    echo "> store directly, and fix .claude/bd-prime-hook.sh."; echo ""
  fi
  cat "$INDEX"
} > "$TMPD/s.index"
# Even a keys-only index can exceed the host limit on a mature store. Keep only whole keys that
# fit a fixed discovery allowance; disclose both the expected count and the omitted count,
# prominently and through a separate top-of-payload warning. NEVER call this a full index.
INDEX_FULL_BYTES=$(size "$TMPD/s.index"); INDEX_PARTIAL=0; INDEX_SHOWN=$EXPECT
if [ "$BUDGET" -gt 0 ]; then
  # Save space for alarms, rules, site checks, hot header, trim notice and some hot body text.
  other=$(( $(size "$TMPD/s.unwired") + $(size "$TMPD/s.rules") + $(size "$TMPD/s.site") + $(size "$TMPD/s.hothdr") + ${#FOOTER} + 1600 ))
  index_cap=$((BUDGET - other)); [ "$index_cap" -gt 4000 ] && index_cap=4000
  [ "$index_cap" -gt 350 ] || index_cap=350
  if [ "$INDEX_FULL_BYTES" -gt "$index_cap" ]; then
    INDEX_PARTIAL=1; INDEX_SHOWN=0; selected_bytes=0
    : > "$TMPD/index.selected"
    # Leave room for a header and explicit PARTIAL warning.
    while IFS= read -r key; do
      b=$(printf '%s\n' "$key" | wc -c | tr -d ' ')
      [ $((selected_bytes + b + 350)) -le "$index_cap" ] || break
      printf '%s\n' "$key" >> "$TMPD/index.selected"
      selected_bytes=$((selected_bytes + b)); INDEX_SHOWN=$((INDEX_SHOWN+1))
    done < "$INDEX"
    {
      echo ""; echo "## Persistent Memories — index ($EXPECT more; retrieve full text with \`bd memories <keyword>\` or \`bd recall <key>\`)"
      echo "> ⚠ INDEX PARTIAL — showing $INDEX_SHOWN of $EXPECT keys; $((EXPECT - INDEX_SHOWN)) omitted. Search via \`bd memories <keyword>\` or list keys with \`bd export --include-memories\`."
      cat "$TMPD/index.selected"
    } > "$TMPD/s.index"
  fi
fi
# ---- assemble against the budget ------------------------------------------------------------
# Priority when something has to go: alarms, rules, site checks and hot header stay first;
# the index is explicitly PARTIAL if its keys alone would exceed the cap. Hot bodies are kept
# in list order while they fit; the bd context goes first, because AGENTS.md carries bd's quick reference and
# `bd prime` prints the rest on demand. Whatever is dropped is named at the top so the reader
# can fetch it, instead of not knowing it existed.
fixed=$(( $(size "$TMPD/s.unwired") + $(size "$TMPD/s.rules") + $(size "$TMPD/s.site") + $(size "$TMPD/s.index") + $(size "$TMPD/s.hothdr") + ${#FOOTER} + 2 ))
hot_total=0; keys_bytes=0
for f in "$TMPD"/hot.[0-9]*; do [ -f "$f" ] || continue; hot_total=$((hot_total + $(size "$f"))); done
while IFS= read -r k; do keys_bytes=$((keys_bytes + ${#k} + 2)); done < "$TMPD/hot.keys"
ctx=$(size "$TMPD/s.ctx"); all=$((fixed + hot_total + ctx + INDEX_FULL_BYTES - $(size "$TMPD/s.index")))
emit_hot() { local f; for f in "$TMPD"/hot.[0-9]*; do [ -f "$f" ] || continue; case " $1 " in *" $(basename "$f") "*) cat "$f" ;; esac; done; }
if [ "$BUDGET" -eq 0 ] || { [ "$all" -le "$BUDGET" ] && [ "$INDEX_PARTIAL" -eq 0 ]; }; then
  cat "$TMPD/s.unwired" "$TMPD/s.rules" "$TMPD/s.site" "$TMPD/s.index" "$TMPD/s.hothdr"
  for f in "$TMPD"/hot.[0-9]*; do [ -f "$f" ] && cat "$f"; done
  cat "$TMPD/s.ctx"
  echo ""; echo "$FOOTER"
  exit 0
fi
# Over budget. Reserve room for the alarm (its text plus every hot key it might have to name),
# keep hot bodies in list order while they fit, then the context only if it still fits.
reserve=$((650 + keys_bytes)); used=$((fixed + reserve)); kept=""; dropped=""; i=0
for f in "$TMPD"/hot.[0-9]*; do
  [ -f "$f" ] || continue; i=$((i+1)); k=$(sed -n "${i}p" "$TMPD/hot.keys"); b=$(size "$f")
  if [ $((used + b)) -le "$BUDGET" ]; then used=$((used + b)); kept="$kept $(basename "$f")"; else dropped="$dropped $k"; fi
done
ctx_in=0; if [ $((used + ctx)) -le "$BUDGET" ]; then ctx_in=1; used=$((used + ctx)); fi
echo "# ⚠ bd-prime-hook: PAYLOAD TRIMMED TO FIT THIS HOST — the tiered output is $all bytes and the host shows at most BD_PRIME_BUDGET=$BUDGET per hook (Claude Code: a 2,000-byte preview above 10,000). Not shipped, fetch on demand:"
[ "$INDEX_PARTIAL" -eq 1 ] && echo "#   memory key index: $INDEX_SHOWN of $EXPECT shown; find the rest with \`bd memories <keyword>\` or \`bd export --include-memories\`"
[ -n "$dropped" ] && echo "#   hot memories, in full via \`bd recall <key>\`:$dropped"
[ "$ctx_in" -eq 0 ] && echo "#   bd's workflow context and command reference: run \`bd prime\`"
echo "#   Fix: trim .claude/memory-hot.txt or shrink the bodies it names (/memory-curate). BD_PRIME_BUDGET=0 lifts the cap on a host that has none."; echo ""
cat "$TMPD/s.unwired" "$TMPD/s.rules" "$TMPD/s.site" "$TMPD/s.index" "$TMPD/s.hothdr"
emit_hot "$kept"
[ "$ctx_in" -eq 1 ] && cat "$TMPD/s.ctx"
echo ""; echo "$FOOTER"
exit 0
