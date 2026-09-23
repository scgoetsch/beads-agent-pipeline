#!/usr/bin/env bash
# sweep_test.sh — acceptance tests for tools/sweep.sh.
#
# The property under test is NOT "the sweep finds things". It is that the sweep
# DISTINGUISHES "searched the corpus and found nothing" from "did not search the
# corpus" — the confusion that made the correction protocol a silent no-op.
#
# Run: tools/sweep_test.sh

set -uo pipefail
cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)" || exit 1
SWEEP=tools/sweep.sh

pass=0; fail=0; skip=0
chk()  { if [[ $2 == "$3" ]]; then printf '  PASS  %s (%s)\n' "$1" "$2"; ((pass++));
         else printf '  FAIL  %s (got %s, want %s)\n' "$1" "$2" "$3"; ((fail++)); fi; }
# A skipped check is ANNOUNCED and counted. A check that quietly does not run is the exact
# defect this suite exists to catch, one level up.
skipc() { printf '  SKIP  %s\n' "$1"; ((skip++)); }

# THE FIXTURE IS BUILT AT RUNTIME, never checked in. Two reasons, both learned:
#   * A literal "absent" string committed here would live in the very corpus the sweep
#     searches, so "absent" would score a hit. The first draft of this file did exactly that.
#   * The original version of this suite asserted against a real path in a private corpus
#     and a magic "rg saw < 100 files" threshold. Both rotted: the path is not yours, and the
#     threshold drifted as the tree grew until the suite read amber for no reason. A fixture
#     proves the property on ANY machine and cannot drift.
ABSENT="zzq$$-$(date +%s%N)-absent-fixture"
PHRASE="zzq$$-$(date +%s%N)-corpus-canary"

FIX=$(mktemp -d); BINDIR=""; BSD=""
cleanup() {
  rm -rf "$FIX"
  [ -z "$BINDIR" ] || rm -rf "$BINDIR"
  [ -z "$BSD" ] || rm -rf "$BSD"
}
trap cleanup EXIT
mkdir -p "$FIX/tools" "$FIX/nested"
cp "$SWEEP" "$FIX/tools/sweep.sh"; chmod +x "$FIX/tools/sweep.sh"
printf 'nested/\n' > "$FIX/.gitignore"          # the nested repo has its own remote: ignored here
printf 'nothing to see\n' > "$FIX/visible.md"
printf '%s\n' "$PHRASE" > "$FIX/nested/hidden.md"   # the claim lives ONLY here
git -C "$FIX" init -q 2>/dev/null
git -C "$FIX/nested" init -q 2>/dev/null

echo "### the bug: a gitignore-aware front-end from the root cannot see the corpus"
# NOTE: do NOT assert on a bare `grep -rn ... .` here. A gitignore-aware `grep` is usually a
# shell FUNCTION, which scripts do not inherit -- inside this file `grep` is /usr/bin/grep,
# which traverses everything instead. The trap fires in the AGENT'S shell, where the function
# is live; in a script the same command fails differently, by being slow. Both present as
# "nothing useful came back". rg reproduces the gitignore behaviour cheaply and honestly.
if command -v rg >/dev/null; then
  chk "rg blind to the nested repo" "$(rg -n "$PHRASE" "$FIX" 2>/dev/null | /usr/bin/grep -c . )" 0
fi
chk "but the file really has it" \
    "$(/usr/bin/grep -c "$PHRASE" "$FIX/nested/hidden.md" 2>/dev/null)" 1

echo "### ACCEPTANCE: sweep.sh reaches the gitignored nested repo"
out=$("$FIX/tools/sweep.sh" "$PHRASE" 2>&1); rc=$?
chk "exit 0"              "$rc" 0
chk "hit in nested repo"  "$(printf '%s' "$out" | /usr/bin/grep -c 'hidden.md')" 1
chk "no control failed"   "$(printf '%s' "$out" | /usr/bin/grep -c 'CONTROL FAILED')" 0
chk "counts both repos"   "$(printf '%s' "$out" | /usr/bin/grep -cE 'in 2 repos')" 1

echo "### discovery has no implicit depth ceiling"
mkdir -p "$FIX/deep/a/b/c/repo"
printf 'deep/\n' >> "$FIX/.gitignore"
git -C "$FIX/deep/a/b/c/repo" init -q
printf '%s deep-only\n' "$PHRASE" > "$FIX/deep/a/b/c/repo/claim.md"
out=$("$FIX/tools/sweep.sh" "$PHRASE deep-only" 2>&1); rc=$?
chk "deep repo found by default" "$(printf '%s' "$out" | grep -c 'claim.md:')" 1
chk "unlimited discovery exits 0" "$rc" 0
out=$("$FIX/tools/sweep.sh" --depth 4 "$PHRASE deep-only" 2>&1); rc=$?
chk "explicit limited discovery cannot certify absence" "$rc" 2
chk "depth limit is announced" "$(printf '%s' "$out" | grep -c 'discovery depth=4')" 1

# A fresh boundary-only repo avoids unrelated files affecting the skip count.
CAP="$FIX/cap"; mkdir -p "$CAP/tools"; git -C "$CAP" init -q
cp -f "$SWEEP" "$CAP/tools/sweep.sh"
printf 'positive control long enough\n' > "$CAP/control.md"
printf '%-63s' 'size-canary' > "$CAP/under.md"
printf '%-64s' 'size-canary' > "$CAP/exact.md"
printf '%-65s' 'size-canary' > "$CAP/over.md"
out=$("$CAP/tools/sweep.sh" --include '*.md' --max-bytes 64 size-canary 2>&1); rc=$?
chk "file below cap is searched" "$(printf '%s' "$out" | grep -c 'under.md:')" 1
chk "file exactly at cap is searched" "$(printf '%s' "$out" | grep -c 'exact.md:')" 1
chk "file above cap is not searched" "$(printf '%s' "$out" | grep -c 'over.md:')" 0
chk "only the above-cap file is counted as skipped" "$(printf '%s' "$out" | grep -c '1 file(s) skipped over')" 1
chk "boundary scan exits 0" "$rc" 0

echo "### the same hazard, measured on THIS tree"
# The fixture above proves the MECHANISM on any machine. This measures whether the hazard is
# actually live in the tree you are installed into -- and it is the check that taught us the
# most, because its first version pinned "rg saw < 100 files" and aged out the moment the root
# repo grew (72 files one month, 131 the next). The assertion silently inverted and the suite
# went red while the hazard it guards had not changed at all. Never pin an absolute count.
#
# Both sides are measured with the SAME instrument, so the ratio isolates the gitignore effect
# rather than a difference between two tools. The corpus side uses sweep.sh's own repo
# discovery and honours SWEEP_DEPTH the way sweep.sh does.
if command -v rg >/dev/null; then
  root_visible=$(rg --files . 2>/dev/null | wc -l)
  corpus=0
  while IFS= read -r _repo; do
    corpus=$(( corpus + $(rg --files "$_repo" 2>/dev/null | wc -l) ))
  done < <(printf '.\n'
           find . -name .git -prune -exec dirname {} \; 2>/dev/null | sort | grep -v '^\.$')
  # THE DENOMINATOR IS ASSERTED BEFORE THE RATIO IS TRUSTED. A corpus measure that silently
  # returned ~0 would satisfy any ratio trivially -- a guard weaker than the check it gates,
  # one level down. Here it decides whether there is anything to measure at all: a repo with
  # no gitignored nested repos has no hazard, and that is a SKIP, never a quiet pass.
  if (( corpus > 1000 )); then
    chk "rg at root sees <5% of the corpus" "$(( root_visible * 100 < corpus * 5 ))" 1
  else
    skipc "no multi-repo corpus here ($corpus files in reach) — the hazard needs nested repos"
  fi
else
  skipc "rg absent — cannot demonstrate the gitignore-aware front end"
fi

echo "### a zero that CAN be trusted"
out=$("$SWEEP" "$ABSENT" 2>&1); rc=$?
chk "exit 0"              "$rc" 0
chk "0 hits"              "$(printf '%s' "$out" | /usr/bin/grep -c '^0 hit(s)')" 1
chk "licenses the zero"   "$(printf '%s' "$out" | /usr/bin/grep -c 'can be trusted')" 1

echo "### a zero that must NOT be trusted — unsearched corpus fails loud"
out=$("$SWEEP" --include '*.nonexistentext' anything 2>&1); rc=$?
chk "exit 2"              "$rc" 2
chk "says NOT TRUSTWORTHY" "$(printf '%s' "$out" | /usr/bin/grep -c 'SWEEP NOT TRUSTWORTHY')" 1

echo "### narrowing is always announced, and never announced falsely"
chk "narrowed run says so" \
    "$("$SWEEP" --docs "$ABSENT" 2>&1 | /usr/bin/grep -c 'NARROWED BY filter')" 1
chk "full run does not"   \
    "$("$SWEEP" "$ABSENT" 2>&1 | /usr/bin/grep -c 'NARROWED BY filter')" 0

echo "### a file grep calls BINARY is reported, not silently unsearched"
# The failure this guards: plain prose carrying one malformed byte is classified binary,
# contributes no hits and no error, and the sweep's zero then looks clean. Build exactly
# that file -- readable prose, one bad byte -- and require the run to admit it skipped it.
# cwd is already the repo root (set at the top of this file).
BINDIR=.sweep_bintest.$$
mkdir -p "$BINDIR"
# Assemble the canary from halves: if the whole token appeared literally in THIS file,
# the sweep would legitimately find it here and the "0 hits" assertion below would fail
# for a reason that has nothing to do with binary detection.
CAN_A=SWEEPBIN; CAN_B=ARYCANARY; CANARY="${CAN_A}${CAN_B}"
printf 'the phrase %s is right here in plain prose \xff\n' "$CANARY" > "$BINDIR/canary.md"
out=$("$SWEEP" --docs "$CANARY" 2>&1); rc=$?
chk "exit 0"                  "$rc" 0
chk "grep -a proves the phrase is really in the file" \
    "$(/usr/bin/grep -ac "$CANARY" "$BINDIR/canary.md")" 1
chk "sweep finds 0 hits"      "$(printf '%s' "$out" | /usr/bin/grep -c '^0 hit(s)')" 1
chk "but SAYS it skipped a binary file" \
    "$(printf '%s' "$out" | /usr/bin/grep -c 'NOT SEARCHED because grep classifies them as binary')" 1
# ATTRIBUTE THE COUNT TO THIS FILE. The assertion above only says a binary notice appeared
# SOMEWHERE in the sweep, which is too loose to test what it claims. Mutation-testing the
# detector in a real multi-repo tree showed this check staying GREEN with the old, broken
# predicate, because an unrelated EMPTY file was being miscounted as binary and printing the
# notice on the canary's behalf. It passed for a reason with nothing to do with the canary.
# So pin the root repo's own BINARY cell, with and without the file, and require exactly 1.
root_bin() { printf '%s' "$1" | awk '$1=="<root>" {print $4; exit}'; }
bin_with=$(root_bin "$out")
rm -rf "$BINDIR"
out_without=$("$SWEEP" --docs "$CANARY" 2>&1)
bin_without=$(root_bin "$out_without")
chk "the canary itself is what was counted" "$(( ${bin_with:-0} - ${bin_without:-0} ))" 1

echo "### with no such file, the binary notice is NOT printed"
chk "no false binary notice" \
    "$("$SWEEP" --include '*.md' "$ABSENT" 2>&1 | /usr/bin/grep -c 'NOT SEARCHED because grep')" 0

echo "### BSD xargs (rejects -r, runs nothing on empty input): the sweep still runs"
# `xargs -r` is GNU. sweep.sh probes for it once instead of assuming it; prove the probe with
# an xargs on PATH that behaves like BSD's: -r is an illegal option, and empty input runs
# nothing. Before the probe every sweep on macOS died with "xargs: illegal option -- r".
REAL_XARGS=$(type -P xargs)
BSD=$(mktemp -d)
cat > "$BSD/xargs" <<FAKE
#!/usr/bin/env bash
for a in "\$@"; do case \$a in -r) echo "xargs: illegal option -- r" >&2; exit 1 ;; esac; done
in=\$(mktemp); cat > "\$in"
if [ -s "\$in" ]; then "$REAL_XARGS" "\$@" < "\$in"; rc=\$?; else rc=0; fi
rm -f "\$in"; exit \$rc
FAKE
chmod +x "$BSD/xargs"
out=$(PATH="$BSD:$PATH" "$FIX/tools/sweep.sh" "$PHRASE" 2>&1); rc=$?
chk "exit 0 under a BSD-like xargs"  "$rc" 0
chk "hit in nested repo under it"    "$(printf '%s' "$out" | /usr/bin/grep -c 'hidden.md')" 1
chk "no 'illegal option' leaked"     "$(printf '%s' "$out" | /usr/bin/grep -c 'illegal option')" 0
rm -rf "$BSD"

echo
printf 'RESULT: %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[[ $fail -eq 0 ]]
