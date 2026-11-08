#!/usr/bin/env bash
# refresh-beads-exports.sh — keep the tracked plain-text exports of the cairn store current.
#
# WHY THIS EXISTS
# .cairn/issues.jsonl, memories.jsonl, allocator.json and events.jsonl are the copy of the store
# (.cairn/cairn.db, git-ignored): plain text, in git, and what another clone rebuilds its store
# from (`cairn sync`). Nothing wrote them but a manual export someone had to remember, and the
# issues file drifted 39 issues in two weeks before anyone looked (2026-09-30, workspace-7m8.1).
# A copy that is silently two weeks old is not a copy. (The name is kept from the beads era.)
#
#   tools/refresh-beads-exports.sh            rewrite the four files from cairn
#   tools/refresh-beads-exports.sh --check    compare the working-tree files with cairn
#   tools/refresh-beads-exports.sh --cached   compare the STAGED files with cairn; .beads-hooks/pre-commit
#                                             uses this mode, because the index is what gets committed
#
# Exit 0 = current (or written, or nothing to check); 1 = stale (or refused); 2 = COULD NOT RUN.
# The third state is the point. cairn missing, failing, timing out, or printing something that is
# not an export is not "stale" and not "current": the comparison did not happen. The hook lets the
# commit through on 2, and this script says so on stderr.
#
# One `cairn export --include-memories` call supplies both JSONL files, so they are one snapshot;
# the memory rows are a separate file because the conventional issues export leaves them out.
#
# A file is replaced by rename from a temporary file beside it, and only when its content changed.
# Everything else happens in a scratch directory OUTSIDE the tree: a run that is killed outright
# must not leave a copy of the store inside the tree for the next `git add` to pick up.
# An export with no rows never replaces a file that has rows: that is what a broken CLI looks like,
# not what a store looks like. To accept a genuinely empty export, delete the file first.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

# The four tracked files live in the store directory, .cairn/ (cairn 0.7.0). cairn reads .beads/
# instead while .cairn/ holds none of them, and refuses when both do (cairn/sync.py,
# exports_dir) -- so any of them left in .beads/ (the old tracker's own issues.jsonl, after a move
# from the old tracker) is refused here first, by name: written beside it, the next `cairn sync` would fail.
X=.cairn; left=
for f in issues.jsonl memories.jsonl allocator.json events.jsonl; do
  { [ -f ".beads/$f" ] || [ -n "$(git ls-files --stage -- ".beads/$f" 2>/dev/null)" ]; } && left="$left $f"
done
if [ -n "$left" ]; then
  echo "beads-exports: .beads/ still holds tracked-export files (in .beads/:$left)." >&2
  echo "  cairn reads its exports from .cairn/ and refuses a store whose exports are split between the two." >&2
  echo "  Remove them from .beads/ (git rm -q --cached .beads/<file>, then delete it; git history keeps them)," >&2
  echo "  then run again. Nothing was written or compared as current." >&2
  exit 1
fi
ISSUES=$X/issues.jsonl
MEMORIES=$X/memories.jsonl
ISSUE_ROW='^{"_type":"issue"'
MEMORY_ROW='^{"_type":"memory"'
ME=tools/refresh-beads-exports.sh

mode=write
case ${1:-} in
  '') ;;
  --check) mode=check ;;
  --cached) mode=cached ;;
  *) echo "usage: $0 [--check | --cached]" >&2; exit 2 ;;
esac
[ $# -le 1 ] || { echo "usage: $0 [--check | --cached]" >&2; exit 2; }

written=
could_not() {
  echo "beads-exports: COULD NOT RUN — $1" >&2
  if [ "$mode" = write ] && [ -n "$written" ]; then
    echo "  ALREADY REPLACED before this failure:$written. The two files may be from different moments; run again." >&2
  elif [ "$mode" = write ]; then
    echo "  Nothing was written; the tracked exports are as they were." >&2
  else
    echo "  The tracked exports were NOT compared with the store. This is not a pass." >&2
  fi
  exit 2
}

# What is there to compare? A clone that tracks neither JSONL file has nothing to enforce, and a
# JSONL file that is not tracked is not checked: whether memories belong in git at all is the
# operator's decision (they may be sensitive), so their absence from the index is not staleness.
tracked() {  # tracked FILE -> 0 when the file is present in the place this mode looks at
  case $mode in
    cached) [ -n "$(git ls-files --stage -- "$1" 2>/dev/null)" ] ;;
    *)      [ -f "$1" ] ;;
  esac
}
if [ "$mode" != write ] && ! tracked "$ISSUES" && ! tracked "$MEMORIES"; then
  exit 0
fi

[ -d "$X" ] || could_not "there is no $X/ directory in $(pwd -P) (no cairn store: cairn init -p <PREFIX>)"
command -v cairn >/dev/null 2>&1 || could_not "cairn is not on PATH"
# Exports in .cairn/ need a cairn that reads them there (0.7.0): an older one answers from
# .beads/, finds nothing, and would let this script write the store over files it never compared.
v=$(cairn --version 2>/dev/null | sed -n 's/^cairn \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
set -- $v
if [ -n "${1:-}" ] && { [ "$1" -eq 0 ] && [ "${2:-0}" -lt 7 ]; }; then
  echo "beads-exports: the exports are in .cairn/ and cairn is $(cairn --version 2>/dev/null): 0.7.0 or later reads them there." >&2
  echo "  Update cairn (git -C <your cairn clone> pull), then run again. Nothing was written or compared as current." >&2
  exit 1
fi
set --

tmp=$(mktemp -d) || could_not "cannot create a temporary directory"
staging=
trap 'rm -rf "$tmp"; [ -n "$staging" ] && rm -f "$staging"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_cli() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "${BEADS_EXPORT_TIMEOUT:-60}" cairn "$@"
  else
    cairn "$@"
  fi
}

run_cli export --include-memories > "$tmp/raw" 2> "$tmp/err"
rc=$?
if [ "$rc" -ne 0 ]; then
  could_not "\`cairn export --include-memories\` exited $rc: $(head -n 3 "$tmp/err" | tr '\n' ' ')"
fi
# An empty line is not data and is dropped. The old tracker was seen to end an export with one
# (2026-10-02, in the minute its periodic auto-backup ran), right after a write, which is exactly
# when the exports are stale. Treating that line as "not an export" would let those commits
# through as "could not run".
command grep -v '^$' "$tmp/raw" > "$tmp/all"
[ $? -le 1 ] || could_not "cannot write to the temporary directory $tmp"
# Every other line must be one JSON object. A banner, a warning or a half-written row on stdout
# would otherwise be committed as if it were data.
if [ -s "$tmp/all" ] && { command grep -q -v '^{.*}$' "$tmp/all" || [ -n "$(tail -c 1 "$tmp/raw")" ]; }; then
  could_not "cairn printed something that is not a JSONL export (first odd line: $(command grep -m 1 -n -v '^{.*}$' "$tmp/all" | cut -c1-80))"
fi
# Braces at both ends is a shape, not a parse: a row cut off after a nested object closes still
# has it. Where python3 exists, every row is parsed.
if command -v python3 >/dev/null 2>&1; then
  bad=$(python3 -c '
import json, sys
for number, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    try:
        if not isinstance(json.loads(line), dict):
            raise ValueError("not an object")
    except ValueError as exc:
        print(f"line {number}: {exc}")
        break
' "$tmp/all" 2>&1) || bad="python3 could not read the export: $bad"
  [ -z "$bad" ] || could_not "cairn printed a row that is not a JSON object (${bad:0:120})"
fi
# Two kinds of row, one file each, told apart by how the row begins. A row that begins any other
# way means the export changed shape; filing it under issues by default would be a guess.
if command grep -q -v -e "$ISSUE_ROW" -e "$MEMORY_ROW" "$tmp/all"; then
  could_not "cairn exported a row that is neither an issue nor a memory (line $(command grep -m 1 -n -v -e "$ISSUE_ROW" -e "$MEMORY_ROW" "$tmp/all" | cut -c1-80))"
fi
command grep "$ISSUE_ROW" "$tmp/all" > "$tmp/issues";     split_rc=$?
command grep "$MEMORY_ROW" "$tmp/all" > "$tmp/memories"; [ $? -le 1 ] && [ "$split_rc" -le 1 ] || split_rc=2
# A split that ran out of disk leaves a file that is short, well-formed and wrong. Every row must
# have arrived in exactly one of the two.
if [ "$split_rc" -gt 1 ] || [ $(( $(wc -l < "$tmp/issues") + $(wc -l < "$tmp/memories") )) -ne "$(wc -l < "$tmp/all")" ]; then
  could_not "splitting the export into issues and memories lost rows (temporary directory $tmp full?)"
fi

current() {  # current FILE -> the content this mode compares against, on stdout
  case $mode in
    cached) git show ":$1" ;;
    *)      cat "$1" ;;
  esac
}

rows() { wc -l < "$1" | tr -d ' '; }

PAIRS="issues:$ISSUES memories:$MEMORIES"

# allocator.json: every id ever issued and the child counters (`cairn export
# --allocator`). No JSONL export carries them, and without them a store rebuilt from git could
# issue a deleted id again (workspace-7m8.4; cairn init --from ... --seed allocator.json).
# Exported AFTER the rows, so it covers every id they hold; a rebuild unions the two anyway.
{
  run_cli export --allocator -o "$tmp/allocator" > /dev/null 2> "$tmp/err" \
    || could_not "\`cairn export --allocator\` failed: $(head -n 3 "$tmp/err" | tr '\n' ' ')"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d["used_ids"], list)' "$tmp/allocator" 2>/dev/null \
    || could_not "cairn exported an allocator state that is not one"
  PAIRS="$PAIRS allocator:$X/allocator.json"
  # events.jsonl: the history (`cairn export --events`: one JSON line per event, in the order
  # recorded, so a new event is a new last line). It reaches the remote only through git, and
  # `cairn init --from ... --events` (or `cairn sync`) brings it back (workspace-7m8.15). Also after the rows: an event is never older than the row it changed.
  run_cli export --events -o "$tmp/events" > /dev/null 2> "$tmp/err" \
    || could_not "\`cairn export --events\` failed: $(head -n 3 "$tmp/err" | tr '\n' ' ')"
  if [ -s "$tmp/events" ] && command grep -q -v '^{"_type":"event",' "$tmp/events"; then
    could_not "cairn exported an event row that is not one (line $(command grep -m 1 -n -v '^{"_type":"event",' "$tmp/events" | cut -c1-80))"
  fi
  PAIRS="$PAIRS events:$X/events.jsonl"

  # More than one clone (workspace-7m8.21). A store that is behind the files (another clone's
  # work came in with a pull) or has diverged from them must not be written over them: that is
  # how a refresh committed a revert of the other clone's work with every guard silent. The answer
  # here is "no", so exit 1, not 2.
  sync_out=$(run_cli sync --status 2>&1); sync_state=${sync_out%%:*}
  case $sync_state in
    behind|diverged)
      [ "$sync_state" = behind ] && how="is behind" || how="has diverged from"
      echo "beads-exports: the cairn store $how the tracked exports — ${sync_out#*: }." >&2
      if [ "$sync_state" = behind ]; then
        echo "  Bring the store up to them first: cairn sync (then run this again). Writing them from this store would undo the other clone's work." >&2
      else
        echo "  Two clones wrote. \`cairn sync\` shows where the histories part; there is no merge. Nothing was written." >&2
      fi
      exit 1 ;;
  esac
  # What git already has must survive: HEAD's history (and, in a merge, the other side's) is a
  # byte prefix of what this run would commit or write. Catches a hand-made export as well.
  case $mode in
    cached) git show ":$X/events.jsonl" > "$tmp/events.new" 2>/dev/null || : > "$tmp/events.new" ;;
    check)  cat "$X/events.jsonl" > "$tmp/events.new" 2>/dev/null || : > "$tmp/events.new" ;;
    *)      cp -f "$tmp/events" "$tmp/events.new" ;;
  esac
  for ref in HEAD MERGE_HEAD; do
    git rev-parse -q --verify "$ref" >/dev/null 2>&1 || continue
    # The ref's history where that commit kept it: here, or at .beads/ in a commit from before
    # the move (the move commit itself compares against the old path).
    git show "$ref:$X/events.jsonl" > "$tmp/events.$ref" 2>/dev/null \
      || git show "$ref:.beads/events.jsonl" > "$tmp/events.$ref" 2>/dev/null || continue
    n=$(wc -c < "$tmp/events.$ref" | tr -d ' ')
    if [ "$(wc -c < "$tmp/events.new" | tr -d ' ')" -lt "$n" ] || ! cmp -s -n "$n" "$tmp/events.$ref" "$tmp/events.new"; then
      echo "beads-exports: $X/events.jsonl would drop history $ref has ($(rows "$tmp/events.$ref") events there, $(rows "$tmp/events.new") here, not an append)." >&2
      echo "  A commit must extend the history git has, never rewrite it. If another clone's work came in, run cairn sync; if two clones wrote, there is no merge. Nothing was written." >&2
      exit 1
    fi
  done
}

# Every refusal comes before the first write, so a refused run changes no file. The renames are
# still several: if the second fails the first has happened, and could_not says so.
for pair in $PAIRS; do
  kind=${pair%%:*}; file=${pair#*:}
  : > "$tmp/have.$kind"
  if tracked "$file"; then
    current "$file" > "$tmp/have.$kind" 2>/dev/null || could_not "cannot read $file"
  fi
  if [ ! -s "$tmp/$kind" ] && [ -s "$tmp/have.$kind" ]; then
    could_not "cairn exported no $kind rows, but $file has $(rows "$tmp/have.$kind"). Refusing to treat an empty export as the truth; if the store really is empty, delete $file first."
  fi
done

stale=0
enforced=
for pair in $PAIRS; do
  kind=${pair%%:*}; file=${pair#*:}
  fresh=$tmp/$kind
  have=$tmp/have.$kind

  if [ "$mode" != write ] && ! tracked "$file"; then
    # The allocator state and the history are not optional: another clone rebuilds
    # from them, and every check between clones compares the history git carries
    # (workspace-7m8.21). The first cairn write creates events.jsonl, so it starts untracked, and
    # `git commit -- <paths>` leaves an untracked file out without a word.
    case $kind in
      allocator|events)
        if [ -s "$fresh" ]; then
          stale=1; enforced="$enforced $file"
          echo "beads-exports: $file is NOT TRACKED, but the cairn store has $(rows "$fresh") rows for it; another clone could not rebuild this store." >&2
        fi ;;
    esac
    continue
  fi
  enforced="$enforced $file"

  if cmp -s "$fresh" "$have"; then
    [ "$mode" = write ] && echo "beads-exports: $file is current ($(rows "$fresh") rows)"
    continue
  fi

  if [ "$mode" = write ]; then
    was=$(rows "$have")
    staging=$file.tmp.$$
    { cp -f "$fresh" "$staging" && cmp -s "$fresh" "$staging" && mv -f "$staging" "$file"; } \
      || could_not "cannot replace $file"
    staging=
    written="$written $file"
    echo "beads-exports: $file refreshed ($was -> $(rows "$file") rows)"
    continue
  fi

  stale=1
  differing=$(comm -3 <(LC_ALL=C sort "$fresh") <(LC_ALL=C sort "$have") | wc -l | tr -d ' ')
  if [ "$mode" = cached ] && [ -f "$file" ] && cmp -s "$fresh" "$file"; then
    echo "beads-exports: $file is current in the working tree but NOT STAGED ($differing rows differ in the index)." >&2
  elif [ "$differing" -eq 0 ]; then
    echo "beads-exports: $file is STALE — it has the rows cairn exports now, in a different order." >&2
  else
    echo "beads-exports: $file is STALE — $differing rows differ from what cairn exports now (cairn: $(rows "$fresh") rows, file: $(rows "$have"))." >&2
  fi
done

if [ "$stale" -eq 1 ]; then
  cat >&2 <<MSG

  The tracked exports are the plain-text copy of the cairn store; a commit should carry the
  store as it is now. Refresh and stage them:

      $ME && git add$enforced

  Bypass once with: git commit --no-verify
MSG
  exit 1
fi
exit 0
