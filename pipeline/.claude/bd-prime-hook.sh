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

# (SessionStart stderr is not shown: the rules below repeat an unknown value in the payload.)
STORE_CLI_BAD=""
[ -f "$WS/.claude/store-cli" ] && [ -z "$STORE_MODE" ] && STORE_CLI_BAD=$(tr -d ' \t\r\n' < "$WS/.claude/store-cli")

# ── SESSION IDENTITY FOR bd's AUDIT TRAIL ──────────────────────────────────────────────────────
# bd stamps an actor on created_by, on the assignee a --claim sets, on comment authors and on the
# field-change rows of .beads/interactions.jsonl; the default is git user.name, so every session of
# one human is one name and the log cannot say which run did what (188 of 188 rows on the box that
# motivated this, 2026-10-10). Claude Code hands SessionStart hooks CLAUDE_ENV_FILE: assignments
# appended there are sourced before every later Bash call of the session and inherited by its
# children (git hooks, the exports refresh, bd dolt push). So: BEADS_ACTOR=<git user.name>/claude/<8>
# -- the human first, so a search for the name still hits every old and new row; then the harness;
# then 8 hex chars of the hook payload's session_id, which prefix-match the claims record under
# .git/bd-session-claims/ and the transcript file. Precedence in bd: --actor > BEADS_ACTOR > config.
# CONSEQUENCE, by design: `bd update --claim` is compare-and-swap on the assignee, so a second
# session is refused by name and takes over with --assignee first (logged); bd-prerun-hook.sh's
# stop reminder says how. BD_PRIME_SESSION_ACTOR=0 opts out. Never reads a terminal. Writes nothing
# to stdout here: a FAILED export is named by emit_session_actor at the top of the payload; a host
# without CLAUDE_ENV_FILE is not a failure. Guard: tools/bd-prime-hook_test.sh.
SESSION_ACTOR=""; SESSION_ACTOR_FAIL=""
if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ "${BD_PRIME_SESSION_ACTOR:-1}" != "0" ]; then
  sid=""
  if [ ! -t 0 ]; then
    sid=$(python3 -c '
import sys, json, re
try: data = json.load(sys.stdin)
except Exception: data = {}
if not isinstance(data, dict): data = {}
print(re.sub(r"[^A-Za-z0-9._-]", "_", str(data.get("session_id") or ""))[:128])
' 2>/dev/null)
  fi
  sid=${sid//$'\r'/}   # a native Windows python3 ends its output with CR LF (see the jq note below)
  if [ -z "$sid" ]; then
    SESSION_ACTOR_FAIL="no session_id in the hook payload, or no python3"
  else
    who=$(git -C "$WS" config user.name 2>/dev/null); who=${who//$'\r'/}; who=${who:-${USER:-unknown}}; who=${who//\'/}
    SESSION_ACTOR="$who/claude/${sid:0:8}"
    printf "export BEADS_ACTOR='%s'\n" "$SESSION_ACTOR" >> "$CLAUDE_ENV_FILE" 2>/dev/null \
      || { SESSION_ACTOR_FAIL="cannot append to CLAUDE_ENV_FILE='$CLAUDE_ENV_FILE'"; SESSION_ACTOR=""; }
  fi
fi
HOTFILE="$WS/.claude/memory-hot.txt"
BUDGET=${BD_PRIME_BUDGET:-10000}
case $BUDGET in ''|*[!0-9]*) BUDGET=10000 ;; esac
SITE_CHECK_CAP=1500
# The last line of every payload. A host that cuts the tail cuts this first, so a reader who
# does not see it knows the payload is incomplete -- the one signal a truncated payload can carry.
FOOTER="# — end of bd-prime-hook payload —"
# Scratch files are per process. Fixed names under /tmp were shared by every user on the box
# (the second user hit Permission denied on the first user's 0644 files and silently fell back)
# and by every concurrent session of one user (the --with-concurrent case), which raced on the index.
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
  local dir="$WS/.claude/site-checks" f out rc name limit=${BD_PRIME_CHECK_TIMEOUT:-20} bound unbounded_said=0
  bound="timeout $limit"
  [ -d "$dir" ] || return 0
  # `timeout` is coreutils; stock macOS has none. `out=$(timeout 20 "$f" 2>/dev/null)` with no
  # timeout binary failed with "command not found" -- on the stderr that was discarded -- and
  # every check was skipped with no line saying so: the open-and-silent shape. Run unbounded
  # instead and SAY so once; a hung check then stalls session start visibly (the README warns of
  # it) rather than never running invisibly. Found by the 2026-09-22 review; the suite hides
  # timeout and requires both the notice and the check's output.
  command -v timeout >/dev/null 2>&1 || bound=""
  for f in "$dir"/*.sh; do
    [ -e "$f" ] || continue                       # the glob matched nothing
    name=$(basename "$f" .sh)
    if [ ! -x "$f" ]; then
      # `[ -x ] || continue` used to skip it in silence, and a check that never ran read as a
      # check that found nothing (a clone with core.fileMode off, a copy that dropped the bit).
      # Found by the 2026-09-30 cairn review.
      echo "## ⚠ SITE CHECK — $name: NOT RUN — the file is not executable (chmod +x .claude/site-checks/$name.sh)"
      echo ""
      continue
    fi
    if [ -z "$bound" ] && [ "$unbounded_said" -eq 0 ]; then
      echo "## ⚠ bd-prime-hook: no \`timeout\` on this box — site checks run UNBOUNDED (a hung check stalls session start)"
      echo ""
      unbounded_said=1
    fi
    # Both streams: a check that dies on stderr ("command not found", a missing interpreter) is
    # a check that did not run, and that has to reach the payload too.
    out=$($bound "$f" 2>&1) && rc=0 || rc=$?
    # A check the bound kills has usually printed nothing yet, and `timeout` exits 124 on the
    # discarded stderr -- so the kill read as health, the open-and-silent shape again (2026-09-30
    # cairn review). Name it, first, so the cap below cannot drop the note.
    if [ -n "$bound" ] && [ "$rc" -eq 124 ]; then
      out="⚠ KILLED after $limit s by bd-prime-hook — the check did not finish; treat it as NOT RUN, not as healthy.${out:+
$out}"
    elif [ "$rc" -ne 0 ] && [ -z "$out" ]; then
      # A check that fails without a word has no verdict; its silence is not health. The
      # 2026-10-06 sync dropped this branch and nothing noticed for a week (workspace WS-sibz).
      out="⚠ $name exited $rc without a verdict — treat it as NOT RUN, not as healthy."
    fi
    [ -n "$out" ] || continue
    # A check is bounded in BYTES as well as time. One that dumps a log would push the rules over
    # the host's cap and take the whole payload with it (peer review, 2026-09-22): say what is
    # wrong, not everything about it.
    n=$(printf '%s' "$out" | wc -c | tr -d ' ')
    if [ "$n" -gt "$SITE_CHECK_CAP" ]; then
      out="$(printf '%s' "$out" | head -c "$SITE_CHECK_CAP")
… [cut by bd-prime-hook at $SITE_CHECK_CAP of $n bytes — a check should say what is wrong, not dump it]"
    fi
    echo "## ⚠ SITE CHECK — $name"
    echo '```'
    echo "$out"
    echo '```'
    echo ""
  done
}
# The git-layer guards live in .beads-hooks/, but git only runs them if core.hooksPath says so,
# and that is local config that no clone inherits. Say it at the TOP of the payload (hosts keep
# the head, not the tail), in both the tiered and the fallback path.
# One directory, two spellings: git reports C:/... where the shell says /c/... and /tmp is a
# mount alias (Git Bash); macOS has /var beside /private/var. -ef answers by inode; across MSYS
# mounts the device differs, so there cygpath settles it.
same_dir() {  # same_dir A B -> 0 when both name one directory
  [ "$1" -ef "$2" ] && return 0
  command -v cygpath >/dev/null 2>&1 || return 1
  # -l: the long name. %TEMP% on a hosted runner is the 8.3 form (RUNNER~1), so the two spellings
  # of one directory differed there even in mixed form; Windows paths are case-insensitive too.
  local a b
  a=$(cygpath -ml "$1" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  b=$(cygpath -ml "$2" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  [ -n "$a" ] && [ "$a" = "$b" ]
}
emit_hooks_unwired() {
  local hp want got
  [ -f "$WS/.beads-hooks/pre-commit" ] || return 0
  hp=$(git -C "$WS" config core.hooksPath 2>/dev/null || true)
  case "$hp" in ""|/*|[A-Za-z]:[/\\]*) ;; *) hp="$WS/$hp" ;; esac   # a drive letter is absolute too (git reports C:/... on Windows)
  want=$(cd "$WS/.beads-hooks" 2>/dev/null && pwd -P); got=$( [ -n "$hp" ] && cd "$hp" 2>/dev/null && pwd -P)
  [ -n "$got" ] && same_dir "$got" "$want" && return 0
  echo "# 🚨 GIT-LAYER GUARDS ARE NOT WIRED IN THIS CLONE: core.hooksPath is '${hp:-unset}', so nothing in"
  echo "#    .beads-hooks/ runs on commit. Fix now:  git config core.hooksPath .beads-hooks"; echo ""
}
emit_session_rules() {
  echo "# 🚨 MANDATORY SESSION RULES — READ BEFORE RESPONDING 🚨"; echo ""
  if [ -f "$WS/projects.tsv" ]; then
    # A project registry scopes the work: the brief below replaces "run bd ready NOW", which
    # ranked every project's backlog together (on one store, 45 of 68 top items belonged to a
    # retired project).
    echo "1. Work comes from the ACTIVE projects listed below; inactive ones stay parked unless the user reopens them."
    echo "2. Use \`$STORE_CLI create ... -l project:<name>\` for ALL task tracking — never TodoWrite, TaskCreate, or markdown lists."
  else
    echo "1. Run \`$STORE_CLI ready\` NOW to check for available work before doing anything else."
    echo "2. Use \`$STORE_CLI create\` for ALL task tracking — never TodoWrite, TaskCreate, or markdown lists."
  fi
  echo "3. Use \`$STORE_CLI update <id> --claim\` before starting any issue."
  echo "4. Use \`$STORE_CLI close <id>\` when work is complete."
  echo "5. Use \`$STORE_CLI remember --key <slug>\` for persistent knowledge — never MEMORY.md files."
  if [ "$STORE_MODE" = cairn ]; then
    echo "6. This checkout's store is written with \`cairn\` (.claude/store-cli). \`bd\` is frozen here: EVERY bd call"
    echo "   is BLOCKED (\`bd dolt push\` included; a read would answer from the old store without saying so)."
    echo "   Where AGENTS.md or a memory says \`bd <verb>\`, run \`cairn <verb>\` with the same flags; the gate names"
    echo "   the cairn verb, or says cairn has none (search, label, history, ...)."
  fi
  [ -n "$STORE_CLI_BAD" ] && echo "⚠ .claude/store-cli says '$STORE_CLI_BAD' (expected bd or cairn) — using bd, nothing write-blocked."
  echo ""
  emit_projects
}
# OPTIONAL PROJECT REGISTRY. When the repo keeps a projects.tsv (one bd store, several projects,
# each marked active or inactive) and a tools/projects.py beside it, `projects.py brief` prints a
# ~1.5 KB brief: per active project, its ready count and top items. Neither file is part of the
# pipeline payload yet; a repo without the registry gets nothing here. A registry WITHOUT the
# tool, or a tool that fails, is said out loud and never blocks the session.
emit_projects() {
  local tool="$WS/tools/projects.py" out bound=""
  [ -f "$WS/projects.tsv" ] || return 0
  if [ ! -f "$tool" ]; then echo "## ⚠ projects.tsv exists but tools/projects.py is missing — no project brief"; echo ""; return 0; fi
  command -v timeout >/dev/null 2>&1 && bound="timeout 30"   # stock macOS has none: unbounded, as the site checks are
  if out=$($bound python3 "$tool" brief 2>&1); then out=${out//$'\r'/}; printf '%s\n\n' "$out"
  else echo "## ⚠ tools/projects.py brief failed — run it by hand:"; printf '%s\n\n' "$out" | head -c 400; fi
}
# The session-actor export above names its own failure here, at the top, so a session whose bd
# writes will carry the bare user.name knows it before its first write. Silent when it worked and
# when the host gave no CLAUDE_ENV_FILE (that host has no such mechanism; nothing to report).
emit_session_actor() {
  [ -n "$SESSION_ACTOR_FAIL" ] || return 0
  echo "# ⚠ bd-prime-hook: BEADS_ACTOR NOT exported for this session ($SESSION_ACTOR_FAIL); bd writes will"
  echo "#   carry the bare git user.name. A claim another session holds still needs --assignee to take over."; echo ""
}
emit_rules() { emit_hooks_unwired; emit_session_actor; emit_session_rules; emit_site_checks; }
# Every fallback SAYS it is one, and why. The full dump is the degraded path -- it was measured
# at 76 KB on a 40-memory store, far past what the host shows -- and a silent fallback reads
# exactly like the tiered output it replaced. An EMPTY hot list is not a reason to fall back:
# it is a valid configuration (nothing in full, everything in the index), and it is how this
# file ships. The old `[ -s "$HOTFILE" ]` test meant a default install got the full dump with
# no line saying so. The dump is budgeted like everything else: what does not fit is CUT, and
# the cut is announced on line 2, because a 36 KB dump that the host reduces to its first
# 2,000 bytes is not "the full dump" however the hook labels it.
fallback_full() {
  local banner="# ⚠ bd-prime-hook: $1 — emitting the FULL $STORE_CLI prime dump (no memory tiering)."
  local note="" used total dump room
  echo "$banner"
  emit_rules > "$TMPD/s.rules_all"
  if ! "$STORE_CLI" prime > "$TMPD/dump" 2>"$ERR"; then { echo "# WARNING: $STORE_CLI prime failed (is $STORE_CLI installed? .claude/store-cli selects it) — this session is NOT primed with the store's context"; cat "$ERR"; } >> "$TMPD/dump"; fi
  used=$(( ${#banner} + 1 + $(size "$TMPD/s.rules_all") + ${#FOOTER} + 2 )); dump=$(size "$TMPD/dump"); total=$((used + dump))
  if [ "$BUDGET" -gt 0 ] && [ "$total" -gt "$BUDGET" ]; then
    note="# ⚠ bd-prime-hook: this dump is $total bytes and the host shows at most BD_PRIME_BUDGET=$BUDGET per hook (Claude Code: a 2,000-byte preview above 10,000) — CUT to fit. Run \`$STORE_CLI prime\` yourself for all of it; fix the cause named above so the tiered path can run, and keep the store lean (memory-curate)."
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
"$STORE_CLI" export --include-memories -o "$MM" 2>/dev/null || { fallback_full "$STORE_CLI export --include-memories failed"; exit 0; }
[ -f "$MM" ] || { fallback_full "$STORE_CLI export exited 0 but wrote no file"; exit 0; }
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
# cairn prints its own layout and has no "## Core Rules": bd's range would delete from the first
# memory heading to the END of it. Its context is everything before its first memory heading;
# the memories are tiered below from the export, as for bd.
if "$STORE_CLI" prime > "$TMPD/prime" 2>"$ERR"; then
  if [ "$STORE_CLI" = cairn ]; then
    sed '/^## Persistent Memories/,$d' "$TMPD/prime" > "$TMPD/s.ctx"
  else
    sed '/^## Persistent Memories/,/^## Core Rules/{/^## Core Rules/!d;}' "$TMPD/prime" > "$TMPD/s.ctx"
  fi
else
  { echo "# WARNING: $STORE_CLI prime failed — workflow context unavailable; memories below came from export."
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
# tr -d '\r' on every jq output read back here: a native Windows jq ends each line with CR LF,
# and a hot key read back as "key\r" matched nothing, so no hot body was ever emitted (Actions
# windows job, 2026-10-06). The hot list is read the same way, for a memory-hot.txt saved CR LF.
HOTLIST=$(tr -d '\r' < "$HOTFILE" | jq -R -s 'split("\n") | map(select(length > 0)) | reduce .[] as $k ([]; if index($k) then . else . + [$k] end)' | tr -d '\r')
HOTN=$(jq -r --argjson hot "$HOTLIST" -s '[.[] | select(._type=="memory") | .key] as $keys | [$hot[] | select(. as $h | $keys | index($h))] | length' "$MM" | tr -d '\r')
UNKNOWN=$(jq -r --argjson hot "$HOTLIST" -s '[.[] | select(._type=="memory") | .key] as $keys | [$hot[] | select(. as $h | $keys | index($h) | not)] | .[]' "$MM" | tr -d '\r')
{
  echo ""; echo "## Persistent Memories — HOT tier ($HOTN selected keys of $TOTAL total; bodies included while budget permits)"
  if [ -n "$UNKNOWN" ]; then
    echo "> ⚠ .claude/memory-hot.txt names memories that are not in the store — fix the list or \`$STORE_CLI remember\` them:"
    printf '%s\n' "$UNKNOWN" | sed 's/^/>   /'; echo ""
  fi
  [ "$TOTAL" -eq 0 ] && echo "_The store has no memories yet — nothing to tier. \`$STORE_CLI remember --key <slug> \"<fact>\"\` adds the first._"
  echo "_Only recurring-mistake guards are injected in full below. Retrieve any other memory on demand with \`$STORE_CLI memories <keyword>\`._"; echo ""
} > "$TMPD/s.hothdr"
# One scratch file per hot body, in memory-hot.txt order, so the budget can keep the first N
# that fit and name the rest. hot.keys holds the key for each file, line for line.
: > "$TMPD/hot.keys"; n=0
jq -r '.[]' <<<"$HOTLIST" | tr -d '\r' | while IFS= read -r k; do [ -z "$k" ] && continue
  f=$(printf '%s/hot.%04d' "$TMPD" "$n"); n=$((n+1))
  jq -r --arg k "$k" 'select(._type=="memory" and .key==$k) | "### \(.key)\n\(.value)\n"' "$MM" | tr -d '\r' > "$f"
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
   "$MM" | tr -d '\r' > "$INDEX"
EXPECT=$((TOTAL - HOTN)); GOT=$(grep -c . "$INDEX")
{
  echo ""; echo "## Persistent Memories — index ($EXPECT more; retrieve full text with \`$STORE_CLI memories <keyword>\` or \`$STORE_CLI recall <key>\`)"
  echo "_Keys only. They are written as sentences precisely so this index does not need previews._"
  if [ "$GOT" -ne "$EXPECT" ]; then
    echo "> ⚠ INDEX IS INCOMPLETE — listing $GOT of an expected $EXPECT memories."
    echo "> Do not read the list below as the full set. Use \`$STORE_CLI memories <keyword>\` to search the"
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
    # Too many keys to list. An arbitrary prefix of them (alphabetical: 85 of 385 on one real
    # store) tells the reader almost nothing and spends the budget the HOT tier needs, so list
    # NONE and say so plainly; search is the discovery path. Never implies the list is complete.
    INDEX_PARTIAL=1; INDEX_SHOWN=0
    {
      echo ""; echo "## Persistent Memories — index ($EXPECT more; retrieve full text with \`$STORE_CLI memories <keyword>\` or \`$STORE_CLI recall <key>\`)"
      echo "> INDEX OMITTED — $EXPECT keys are too many to list within the host budget. Search with \`$STORE_CLI memories <keyword>\`; list every key with \`$STORE_CLI export --include-memories\`."
    } > "$TMPD/s.index"
  fi
fi
# ---- assemble against the budget ------------------------------------------------------------
# Priority when something has to go: alarms, rules, site checks and hot header stay first;
# the index is replaced by an explicit OMITTED line if its keys would exceed the cap. Hot bodies are kept
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
if [ -n "$dropped" ]; then
  echo "# ⚠ bd-prime-hook: PAYLOAD TRIMMED TO FIT THIS HOST — the tiered output is $all bytes and the host shows at most BD_PRIME_BUDGET=$BUDGET per hook (Claude Code: a 2,000-byte preview above 10,000). Not shipped, fetch on demand:"
  echo "#   hot memories, in full via \`$STORE_CLI recall <key>\`:$dropped"
  [ "$ctx_in" -eq 0 ] && echo "#   $STORE_CLI's workflow context and command reference: run \`$STORE_CLI prime\`"
  echo "#   Fix: trim .claude/memory-hot.txt or shrink the bodies it names (/memory-curate). BD_PRIME_BUDGET=0 lifts the cap on a host that has none."; echo ""
elif [ "$ctx_in" -eq 0 ]; then
  # Expected on a large store, not an alarm: AGENTS.md carries bd's quick reference.
  echo "# bd-prime-hook: $STORE_CLI's workflow context is not inlined (host budget) — run \`$STORE_CLI prime\` for it."; echo ""
fi
cat "$TMPD/s.unwired" "$TMPD/s.rules" "$TMPD/s.site" "$TMPD/s.index" "$TMPD/s.hothdr"
emit_hot "$kept"
[ "$ctx_in" -eq 1 ] && cat "$TMPD/s.ctx"
echo ""; echo "$FOOTER"
exit 0
