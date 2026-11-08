#!/usr/bin/env bash
# Acceptance suite for tools/refresh-beads-exports.sh and its stanza in .beads-hooks/pre-commit.
#
# WHAT IT GUARDS
# The script has three answers — current, stale, could not run — and the dangerous mistakes are
# the ones that collapse two of them: a cairn that fails read as "current" (the drift this exists
# to stop comes back, silently), or read as "stale" (every commit blocked on a box without cairn),
# or an empty export from a broken cairn written over the tracked files (the memories file comes
# through a filter, so a failed export looks exactly like a store with no memories).
#
# Hermetic: a throwaway repo under mktemp and a stub `cairn` that prints what the case tells it to.
# It never runs the real cairn and never touches this working tree.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SCRIPT=$HERE/refresh-beads-exports.sh
HOOK=$HERE/../.beads-hooks/pre-commit
[ -x "$SCRIPT" ] || { echo "missing or non-executable: $SCRIPT" >&2; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

# The script resolves its root from its OWN location, so run a copy inside a fake root.
R=$T/root
mkdir -p "$R/tools" "$R/.cairn" "$T/bin"
cp -f "$SCRIPT" "$R/tools/refresh-beads-exports.sh"

# The stub answers exactly the questions the script asks: the rows (stdout, rc and stderr from the
# case), the allocator and the events (each to its -o file, from a canned file), the sync state and
# the version. Any other invocation is a failure of the test, not something to answer politely: a
# script that started calling cairn differently should be noticed.
cat > "$T/bin/cairn" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$BD_STUB_DIR/calls"
case "$*" in
  "export --include-memories")
    [ -f "$BD_STUB_DIR/stderr" ] && cat "$BD_STUB_DIR/stderr" >&2
    [ -f "$BD_STUB_DIR/stdout" ] && cat "$BD_STUB_DIR/stdout"
    exit "$(cat "$BD_STUB_DIR/rc" 2>/dev/null || echo 0)" ;;
  "export --allocator -o "*)   [ -f "$BD_STUB_DIR/alloc-fail" ] && { echo "stub: allocator broke" >&2; exit 1; }
                               if [ -f "$BD_STUB_DIR/alloc" ]; then cp -f "$BD_STUB_DIR/alloc" "${@: -1}"
                               else printf '{"used_ids": [], "child_counters": {}}\n' > "${@: -1}"; fi; exit 0 ;;
  "export --events -o "*)      [ -f "$BD_STUB_DIR/events-fail" ] && { echo "stub: events broke" >&2; exit 1; }
                               if [ -f "$BD_STUB_DIR/events" ]; then cp -f "$BD_STUB_DIR/events" "${@: -1}"
                               else : > "${@: -1}"; fi; exit 0 ;;
  "sync --status")             cat "$BD_STUB_DIR/sync" 2>/dev/null || echo "equal: in step"; exit 0 ;;
  "--version")                 cat "$BD_STUB_DIR/version" 2>/dev/null || echo "cairn 0.7.0"; exit 0 ;;
  *) echo "stub cairn: unexpected arguments: $*" >&2; exit 64 ;;
esac
STUB
chmod +x "$T/bin/cairn"
export BD_STUB_DIR=$T/stub; mkdir -p "$BD_STUB_DIR"
STUBPATH=$T/bin:$PATH

I1='{"_type":"issue","id":"t-aaa","title":"one"}'
I2='{"_type":"issue","id":"t-bbb","title":"two"}'
I3='{"_type":"issue","id":"t-ccc","title":"three"}'
M1='{"_type":"memory","key":"alpha","value":"first"}'
M2='{"_type":"memory","key":"beta","value":"second"}'

cairn_rows()  { printf '%s\n' "$@" > "$BD_STUB_DIR/stdout"; echo 0 > "$BD_STUB_DIR/rc"; rm -f "$BD_STUB_DIR/stderr"; }
cairn_fails() { : > "$BD_STUB_DIR/stdout"; echo "${1:-1}" > "$BD_STUB_DIR/rc"; echo "Error: database is locked" > "$BD_STUB_DIR/stderr"; }
run()      { (cd "$R" && PATH=$STUBPATH ./tools/refresh-beads-exports.sh "$@") > "$T/out" 2> "$T/err"; echo $?; }
sum()      { cat "$R/.cairn/issues.jsonl" "$R/.cairn/memories.jsonl" 2>/dev/null | cksum | tr -d ' '; }
leftover() { find "$R/.cairn" -mindepth 1 ! -name issues.jsonl ! -name memories.jsonl ! -name allocator.json ! -name events.jsonl | wc -l | tr -d ' '; }
said()     { grep -c -- "$1" "$T/err" | tr -d ' '; }

echo "### write mode"
cairn_rows "$I1" "$I2" "$M1"
chk "first run writes both files"                 "$(run)" 0
chk "issues file holds the issue rows only"       "$(cat "$R/.cairn/issues.jsonl")" "$(printf '%s\n' "$I1" "$I2")"
chk "memories file holds the memory rows only"    "$(cat "$R/.cairn/memories.jsonl")" "$M1"
inode_of() { ls -i "$1" | awk '{print $1}'; }
inode=$(inode_of "$R/.cairn/issues.jsonl")
chk "  (the inode was read: it is a number)"      "$(case $inode in ''|*[!0-9]*) echo no ;; *) echo yes ;; esac)" yes
chk "second run with nothing changed exits 0"     "$(run)" 0
chk "an unchanged file is not replaced"           "$(inode_of "$R/.cairn/issues.jsonl")" "$inode"
cairn_rows "$I1" "$I2" "$I3" "$M1" "$M2"
chk "a changed store is written"                  "$(run)" 0
chk "issues file follows the store"               "$(wc -l < "$R/.cairn/issues.jsonl" | tr -d ' ')" 3
chk "memories file follows the store"             "$(wc -l < "$R/.cairn/memories.jsonl" | tr -d ' ')" 2
chk "nothing but the exports is in .cairn/"   "$(leftover)" 0

echo "### an empty line in the export is not data, and not a reason to give up"
# Seen from the old tracker at the moment its auto-backup ran. Read as "not an export" it would
# turn the check into "could not run" — and so into a pass — right after a write.
before=$(sum)
cairn_rows "$I1" "$I2" "$I3" "$M1" "$M2" ""
chk "a trailing empty line: still current -> 0"   "$(run --check)" 0
cairn_rows "$I1" "" "$I2" "$M1" "$M2" ""
chk "empty lines and a missing row -> 1, not 2"   "$(run --check)" 1
cairn_rows "$I1" "$I2" "$I3" "$M1" "$M2" ""
chk "write mode with a trailing empty line -> 0"  "$(run)" 0
chk "  and the empty line is not written"         "$(sum)" "$before"

echo "### could not run is its own answer, and writes nothing"
before=$(sum)
cairn_fails 1
chk "cairn exits non-zero -> 2"                      "$(run)" 2
chk "  it says COULD NOT RUN"                     "$(said 'COULD NOT RUN')" 1
chk "  files untouched"                           "$(sum)" "$before"
# THE CASE THE MEMORIES FILTER MAKES DANGEROUS: the export prints nothing and still exits 0.
cairn_rows; : > "$BD_STUB_DIR/stdout"
chk "cairn prints nothing, exits 0 -> 2"             "$(run)" 2
chk "  files untouched"                           "$(sum)" "$before"
# The issue rows here DIFFER from the file's, so a script that wrote issues before refusing on
# memories would be caught by the checksum. With identical rows it could not be.
cairn_rows "$I1"
chk "issues but no memories, file has rows -> 2"  "$(run)" 2
chk "  NEITHER file touched (no partial write)"   "$(sum)" "$before"
cairn_rows "$M1" "$M2"
chk "memories but no issues, file has rows -> 2"  "$(run)" 2
chk "  files untouched"                           "$(sum)" "$before"
cairn_rows "Warning: schema drift detected" "$I1" "$M1"
chk "a banner on stdout -> 2"                     "$(run)" 2
chk "  files untouched"                           "$(sum)" "$before"
cairn_rows "$I1" "$M1"; printf '%s\n{"_type":"issue","id":"t-tr' "$I1" > "$BD_STUB_DIR/stdout"
chk "a row cut off mid-line -> 2"                 "$(run)" 2
chk "  files untouched"                           "$(sum)" "$before"
# Ends in a brace and a newline, so it has the SHAPE of a row; it is cut off after a nested object.
cairn_rows "$I1" '{"_type":"issue","id":"t-cut","metadata":{}' "$M1"
if command -v python3 >/dev/null 2>&1; then
chk "a cut-off row that still ends in a brace -> 2" "$(run)" 2
chk "  files untouched"                           "$(sum)" "$before"
else echo "  SKIP  no python3: rows are checked for shape only"; fi
cairn_rows '{"id":"t-zzz","_type":"issue","title":"keys in another order"}' "$M1"
chk "a row that is neither kind -> 2"             "$(run)" 2
chk "  files untouched"                           "$(sum)" "$before"
cairn_rows "$I1" "$M1"; echo 124 > "$BD_STUB_DIR/rc"
chk "a timeout status (124) -> 2"                 "$(run)" 2
chk "  files untouched"                           "$(sum)" "$before"
chk "nothing left in .cairn/ after any failure"   "$(leftover)" 0
cairn_rows "$I1" "$M1"
nocli=$( (cd "$R" && PATH=/usr/bin:/bin ./tools/refresh-beads-exports.sh) >/dev/null 2>&1; echo $? )
if PATH=/usr/bin:/bin command -v cairn >/dev/null 2>&1; then echo "  SKIP  cairn lives in /usr/bin or /bin here; cannot hide it"
else chk "cairn not on PATH -> 2"                 "$nocli" 2; fi
chk "an unknown flag -> 2 (usage)"                "$(run --frobnicate)" 2
chk "two flags -> 2 (usage)"                      "$(run --check --cached)" 2

echo "### an empty export is accepted only where there is nothing to lose"
rm -f "$R/.cairn/memories.jsonl"
cairn_rows "$I1" "$I2" "$I3"
chk "no memories and no memories file -> 0"       "$(run)" 0
chk "  and the file is created, empty (a fresh store's first commit carries all four)" "$([ -e "$R/.cairn/memories.jsonl" ] && wc -l < "$R/.cairn/memories.jsonl" | tr -d ' ' || echo absent)" 0

echo "### --check compares the working tree and never writes"
cairn_rows "$I1" "$I2" "$I3" "$M1" "$M2"; run >/dev/null
before=$(sum)
chk "in sync -> 0"                                "$(run --check)" 0
cairn_rows "$I1" "$I2" "$I3" "$M1" "$M2" '{"_type":"issue","id":"t-ddd","title":"four"}'
chk "one issue behind -> 1"                       "$(run --check)" 1
chk "  the fix command is printed"                "$(said 'tools/refresh-beads-exports.sh && git add')" 1
cairn_rows "$I1" "$I2" "$I3" "$M1" '{"_type":"memory","key":"beta","value":"edited"}'
chk "one memory body changed -> 1"                "$(run --check)" 1
chk "  it names the memories file"                "$(grep -c 'memories.jsonl is STALE' "$T/err" | tr -d ' ')" 1
cairn_rows "$I3" "$I2" "$I1" "$M1" "$M2"
chk "same rows in another order -> 1"             "$(run --check)" 1
chk "  and it says so instead of '0 rows differ'" "$(said 'in a different order')" 1
cairn_fails 1
chk "cairn fails -> 2, not 1 and not 0"              "$(run --check)" 2
chk "  it says the comparison did not happen"     "$(said 'NOT compared')" 1
chk "--check wrote nothing in any of those"       "$(sum)" "$before"
mkdir -p "$T/hold"; mv -f "$R/.cairn/issues.jsonl" "$R/.cairn/memories.jsonl" "$T/hold/"
: > "$BD_STUB_DIR/calls"; cairn_fails 1
chk "neither file present -> 0, nothing to check" "$(run --check)" 0
chk "  and cairn was not even asked"                 "$(wc -l < "$BD_STUB_DIR/calls" | tr -d ' ')" 0
mv -f "$T/hold/issues.jsonl" "$R/.cairn/"
cairn_rows "$I1" "$I2" "$I3" "$M1" "$M2"
chk "only the issues file present, in sync -> 0"  "$(run --check)" 0
cairn_rows "$I1" "$I2" "$M1" "$M2"
chk "only the issues file present, stale -> 1"    "$(run --check)" 1
chk "  the fix stages the file that exists"       "$(said 'git add .cairn/issues.jsonl .cairn/allocator.json .cairn/events.jsonl$')" 1
cairn_rows "$I1" "$I2" "$I3" "$M1" "$M2"
mv -f "$T/hold/memories.jsonl" "$R/.cairn/"

echo "### --cached compares the INDEX, which is what a commit carries"
git -C "$R" init -q
git -C "$R" config user.email t@example.invalid; git -C "$R" config user.name tester
chk "nothing staged -> 0, nothing to check"       "$(run --cached)" 0
git -C "$R" add .cairn/issues.jsonl .cairn/memories.jsonl .cairn/allocator.json
chk "staged and current -> 0"                     "$(run --cached)" 0
cairn_rows "$I1" "$I2" "$M1" "$M2"
chk "store moved on, index did not -> 1"          "$(run --cached)" 1
run >/dev/null                                    # refresh the working tree, do NOT stage
chk "working tree refreshed but not staged -> 1"  "$(run --cached)" 1
chk "  and it says NOT STAGED (issues only)"      "$(said 'issues.jsonl is current in the working tree but NOT STAGED')" 1
git -C "$R" add .cairn/issues.jsonl .cairn/memories.jsonl .cairn/allocator.json
printf '%s\n' "$I1" > "$R/.cairn/issues.jsonl"    # working tree now contradicts the index
chk "index current, working tree stale -> 0"      "$(run --cached)" 0
chk "  while --check sees the working tree -> 1"  "$(run --check)" 1
cairn_fails 1
chk "cairn fails -> 2"                             "$(run --cached)" 2
git -C "$R" checkout -q -- .cairn/issues.jsonl

echo "### the pre-commit stanza: blocks on stale, and ONLY on stale"
# Run the stanza as it is written in the real hook, not a paraphrase of it.
{ echo '#!/usr/bin/env sh'
  sed -n '/^# >>> export freshness guard >>>/,/^# <<< export freshness guard <<</p' "$HOOK"
} > "$T/pre-commit"
chmod +x "$T/pre-commit"
chk "the stanza is present in .beads-hooks/pre-commit" "$(grep -c 'refresh-beads-exports.sh --cached' "$T/pre-commit" | tr -d ' ')" 1
mkdir -p "$R/hooks"; cp -f "$T/pre-commit" "$R/hooks/pre-commit"
git -C "$R" config core.hooksPath hooks
commit() { (cd "$R" && PATH=$STUBPATH git commit -q --allow-empty -m "$1") > "$T/out" 2> "$T/err"; echo $?; }
commits() { git -C "$R" rev-list --count HEAD 2>/dev/null || echo 0; }
cairn_rows "$I1" "$I2" "$M1" "$M2"
# The stanza is the LAST thing in this hook, so its own status is the hook's. Written as
# `[ $? -eq 1 ] && exit 1` it blocked every commit whose exports were current: the false test
# became the hook's exit status (in the 0.1-era hook a block ran afterwards and hid it).
chk "exports current: commit goes through"        "$(commit one)" 0
cairn_rows "$I1" "$I2" "$I3" "$M1" "$M2"
chk "exports stale: commit is blocked"            "$(commit two)" 1
chk "  nothing was committed"                     "$(commits)" 1
chk "  the fix command is shown to the committer" "$(said 'tools/refresh-beads-exports.sh && git add')" 1
cairn_fails 1
chk "cairn cannot run: commit goes through"          "$(commit three)" 0
chk "  with the warning on stderr"                "$(said 'COULD NOT RUN')" 1
chk "  and it was committed"                      "$(commits)" 2
chk "the check left nothing behind in .cairn/"    "$(leftover)" 0
chmod -x "$R/tools/refresh-beads-exports.sh"
cairn_rows "$I1" "$I2" "$I3" "$M1" "$M2"
# Git Bash keeps a .sh executable whatever chmod says, so there is no such state to test there.
if [ -x "$R/tools/refresh-beads-exports.sh" ]; then
  echo "  SKIP  script not executable: chmod -x does not take on this filesystem"
else
  chk "script not executable: commit goes through"  "$(commit five)" 0
  chk "  but not silently"                          "$(said 'NOT compared')" 1
fi
chmod +x "$R/tools/refresh-beads-exports.sh"
(cd "$R" && PATH=$STUBPATH ./tools/refresh-beads-exports.sh >/dev/null 2>&1 && git add .cairn/issues.jsonl .cairn/memories.jsonl .cairn/allocator.json)
chk "after the printed fix: commit goes through"  "$(commit four)" 0
chk "  and the commit carries the new export"     "$(git -C "$R" show HEAD:.cairn/issues.jsonl | wc -l | tr -d ' ')" 3

echo "### the allocator state and the history are exports too (workspace-7m8.4, 7m8.15)"
E1='{"_type":"event","id":"ev-1","kind":"created","issue_id":"t-aaa","memory_key":null,"actor":"al","created_at":"2026-10-16T10:00:00Z","data":{}}'
E2='{"_type":"event","id":"ev-2","kind":"closed","issue_id":"t-aaa","memory_key":null,"actor":"al","created_at":"2026-10-16T10:00:01Z","data":{"reason":"done"}}'
cairn_says() { printf '%s\n' "$I1" "$I2" "$I3" "$M1" "$M2" > "$BD_STUB_DIR/stdout"; echo 0 > "$BD_STUB_DIR/rc"; rm -f "$BD_STUB_DIR/stderr"
               printf '{"used_ids": ["t-aaa"], "child_counters": {}}\n' > "$BD_STUB_DIR/alloc"
               printf '%s\n' "$@" > "$BD_STUB_DIR/events"; rm -f "$BD_STUB_DIR/events-fail" "$BD_STUB_DIR/alloc-fail"; }
rm -f "$R/.cairn/allocator.json" "$R/.cairn/events.jsonl"; git -C "$R" rm -q --cached --ignore-unmatch .cairn/allocator.json .cairn/events.jsonl
cairn_says "$E1"
chk "run writes all four files -> 0"  "$(run)" 0
chk "  the events file holds the event rows"       "$(cat "$R/.cairn/events.jsonl")" "$E1"
chk "  the allocator state is written"             "$(grep -c used_ids "$R/.cairn/allocator.json" | tr -d ' ')" 1
chk "  cairn was asked for rows, allocator, events, sync state" "$(tail -n 4 "$BD_STUB_DIR/calls" | cut -d' ' -f1-2 | tr '\n' ' ')" "export --include-memories export --allocator export --events sync --status "
cairn_says "$E1" "$E2"
chk "a new event: the file is refreshed"           "$(run)" 0
chk "  by appending (the old line is still first)" "$(head -n 1 "$R/.cairn/events.jsonl")" "$E1"
chk "  and it names the events file"               "$(grep -c 'events.jsonl refreshed' "$T/out" | tr -d ' ')" 1
before=$(cat "$R/.cairn/events.jsonl" | cksum | tr -d ' ')
cairn_says
chk "cairn exports no events, file has rows -> 2"  "$(run)" 2
chk "  the events file is untouched"               "$(cat "$R/.cairn/events.jsonl" | cksum | tr -d ' ')" "$before"
cairn_says "$E1" "$I1"
chk "a row that is not an event -> 2"              "$(run)" 2
chk "  the events file is untouched"               "$(cat "$R/.cairn/events.jsonl" | cksum | tr -d ' ')" "$before"
cairn_says "$E1" "$E2"; touch "$BD_STUB_DIR/events-fail"
chk "the events export fails -> 2 (could not run)" "$(run)" 2
chk "  it says which call failed"                  "$(said 'cairn export --events')" 1
chk "  the events file is untouched"               "$(cat "$R/.cairn/events.jsonl" | cksum | tr -d ' ')" "$before"
cairn_says "$E1" "$E2"
chk "--check with everything current -> 0"         "$(run --check)" 0
cairn_says "$E1" "$E2" '{"_type":"event","id":"ev-3","kind":"x","issue_id":null,"memory_key":"k","actor":"al","created_at":"2026-10-16T10:00:02Z","data":{}}'
chk "--check with an event behind -> 1"            "$(run --check)" 1
chk "  it names the events file"                   "$(grep -c 'events.jsonl is STALE' "$T/err" | tr -d ' ')" 1
chk "  the fix stages it too"                      "$(said 'git add.* .cairn/events.jsonl')" 1
git -C "$R" add .cairn/events.jsonl .cairn/allocator.json .cairn/issues.jsonl .cairn/memories.jsonl
chk "--cached: index behind the store -> 1"        "$(run --cached)" 1
cairn_says "$E1" "$E2"
chk "--cached: index current -> 0"                 "$(run --cached)" 0

echo "### more than one clone: a stale store never writes over the files (workspace-7m8.21)"
git -C "$R" -c user.name=t -c user.email=t@t commit -q --no-verify -m "exports at E1 E2" -- .cairn >/dev/null
before=$(cat "$R/.cairn/events.jsonl" | cksum | tr -d ' ')
printf 'behind: 1 events in the files the store does not have\n' > "$BD_STUB_DIR/sync"; cairn_says "$E1"
chk "store behind the files: run -> 1"             "$(run)" 1
chk "  it says to run cairn sync"                  "$(said 'cairn sync')" 1
chk "  nothing was written"                        "$(cat "$R/.cairn/events.jsonl" | cksum | tr -d ' ')" "$before"
chk "  --cached refuses too -> 1"                  "$(run --cached)" 1
printf 'diverged: the histories part at event 2\n' > "$BD_STUB_DIR/sync"
chk "store diverged: run -> 1"                     "$(run)" 1
chk "  it says there is no merge"                  "$(said 'there is no merge')" 1
rm -f "$BD_STUB_DIR/sync"
cairn_says "$E1"
chk "an export without HEAD's last event -> 1"     "$(run)" 1
chk "  it says the history would be dropped"       "$(said 'would drop history HEAD has')" 1
chk "  nothing was written"                        "$(cat "$R/.cairn/events.jsonl" | cksum | tr -d ' ')" "$before"
printf '%s\n' "$E1" > "$R/.cairn/events.jsonl"; git -C "$R" add .cairn/events.jsonl
chk "a hand-shortened history staged: --cached -> 1" "$(run --cached)" 1
git -C "$R" checkout -q HEAD -- .cairn/events.jsonl
cairn_says "$E1" "$E2" '{"_type":"event","id":"ev-3","kind":"x","issue_id":null,"memory_key":"k","actor":"al","created_at":"2026-10-16T10:00:02Z","data":{}}'
chk "an append to HEAD's history: run -> 0"        "$(run)" 0
git -C "$R" add .cairn; git -C "$R" rm -q --cached .cairn/events.jsonl
chk "the history dropped from the index: --cached -> 1" "$(run --cached)" 1
chk "  (that is history HEAD has, dropped)"        "$(said 'would drop history HEAD has')" 1
git -C "$R" -c user.name=t -c user.email=t@t commit -q --no-verify -m "a commit without the history" >/dev/null
chk "the history never tracked: --cached -> 1"     "$(run --cached)" 1
chk "  it says the file is not tracked"            "$(said 'events.jsonl is NOT TRACKED')" 1
chk "  the fix stages it"                          "$(said 'git add.* .cairn/events.jsonl')" 1
git -C "$R" add .cairn/events.jsonl
chk "staged again: --cached -> 0"                  "$(run --cached)" 0
echo "### cairn older than 0.7.0, and exports left in .beads/: refused, by name"
echo "cairn 0.6.0" > "$BD_STUB_DIR/version"
chk "an older cairn with exports in .cairn/ -> 1"  "$(run)" 1
chk "  it says 0.7.0 reads them there"             "$(said '0.7.0 or later reads them there')" 1
rm -f "$BD_STUB_DIR/version"
mkdir -p "$R/.beads"; cp -f "$R/.cairn/issues.jsonl" "$R/.beads/issues.jsonl"
chk "an issues.jsonl left in .beads/ -> 1"         "$(run)" 1
chk "  it names the file left behind"              "$(said 'in .beads/: issues.jsonl')" 1
chk "  --cached refuses too"                       "$(run --cached)" 1
rm -f "$R/.beads/issues.jsonl"
chk "removed: run -> 0"                            "$(run)" 0
echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
