#!/usr/bin/env bash
# Acceptance suite for tools/check-agent-docs-linked.sh.
#
# WHY IT EXISTS
# This was the ONE tool in tools/ with no _test.sh beside it, and it is exactly where a hole
# survived: `[ -e CLAUDE.md ]` FOLLOWS the symlink, so it is false for a dangling one, and the
# guard exited 0 on the very state it exists to catch. Every other guard here has a suite that
# tries to make it fail; this one did not, so nothing ever tried.
#
# Hermetic: builds a throwaway repo under mktemp. It never touches this working tree, so it is
# safe to run at any time, including with uncommitted work in progress. Four link states, the
# pointer-file state of a filesystem without symlinks, and the bd-managed region check.
set -uo pipefail
GUARD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/check-agent-docs-linked.sh
[ -x "$GUARD" ] || { echo "missing or non-executable: $GUARD" >&2; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

# The guard resolves its repo root from its OWN location (dirname/..), so stage a fake root
# with a tools/ dir holding a copy, and run that copy.
mkdir -p "$T/tools"
cp -f "$GUARD" "$T/tools/check-agent-docs-linked.sh"
printf '# Agent Instructions\n\nSome rules.\n' > "$T/AGENTS.md"
run() { (cd "$T" && ./tools/check-agent-docs-linked.sh) >/dev/null 2>&1; echo $?; }
cached() { (cd "$T" && ./tools/check-agent-docs-linked.sh --cached) >/dev/null 2>&1; echo $?; }

# Real symlinks or nothing: MSYS `ln -s` copies by default, which would turn every link case
# below into a regular-file case. nativestrict makes it a real link or a failure, and a box that
# cannot link at all (Windows without Developer Mode) runs only the pointer-file section.
export MSYS=winsymlinks:nativestrict
NOLINK=""
{ ln -s AGENTS.md "$T/probe.lnk" 2>/dev/null && [ -L "$T/probe.lnk" ]; } || NOLINK=1
rm -f "$T/probe.lnk"

if [ -z "$NOLINK" ]; then
echo "### the four states of CLAUDE.md"
ln -sf AGENTS.md "$T/CLAUDE.md"
chk "symlink to AGENTS.md passes"        "$(run)" 0

rm -f "$T/CLAUDE.md"; printf 'a divergent copy\n' > "$T/CLAUDE.md"
chk "regular file is caught"             "$(run)" 1

rm -f "$T/CLAUDE.md"; printf 'x\n' > "$T/OTHER.md"; ln -s OTHER.md "$T/CLAUDE.md"
chk "symlink to the wrong target caught"  "$(run)" 1

# THE REGRESSION THIS FILE WAS WRITTEN FOR. [ -e ] is false for a dangling link, so the old
# preamble returned "nothing to enforce" here and exited 0 — silently, on the exact state the
# guard exists to catch.
rm -f "$T/CLAUDE.md"; ln -s AGENTS-renamed.md "$T/CLAUDE.md"
chk "DANGLING symlink is caught"          "$(run)" 1

echo "### a lone regular CLAUDE.md is a drift state too"
# `[ -e AGENTS.md ] || exit 0` used to run before the regular-file test, so a regular CLAUDE.md
# with no AGENTS.md beside it passed — and every non-Claude harness found nothing in that repo.
rm -f "$T/CLAUDE.md" "$T/AGENTS.md"; printf 'rules only Claude sees\n' > "$T/CLAUDE.md"
chk "regular CLAUDE.md with NO AGENTS.md is caught"   "$(run)" 1
rm -f "$T/CLAUDE.md"; printf 'x\n' > "$T/OTHER.md"; ln -s OTHER.md "$T/CLAUDE.md"
chk "symlink elsewhere with NO AGENTS.md is caught"   "$(run)" 1
rm -f "$T/CLAUDE.md" "$T/OTHER.md"; printf '# Agent Instructions\n\nSome rules.\n' > "$T/AGENTS.md"

echo "### nothing to enforce is still nothing to enforce"
rm -f "$T/CLAUDE.md"
chk "no CLAUDE.md at all passes"          "$(run)" 0
rm -f "$T/AGENTS.md"
chk "neither file present passes"         "$(run)" 0

echo "### the bd-managed region check"
printf '# Agent Instructions\n\nrules\n' > "$T/AGENTS.md"
ln -sf AGENTS.md "$T/CLAUDE.md"
chk "no BEADS markers -> nothing to check" "$(run)" 0
{ printf '# Agent Instructions\n\n<!-- BEGIN BEADS INTEGRATION -->\n'
  printf 'protocol line mentioning sweep.sh\n'
  printf '<!-- END BEADS INTEGRATION -->\n'; } > "$T/AGENTS.md"
chk "protocol inside the markers is caught" "$(run)" 1

# bd's OWN block must pass, whatever bd chooses to put in it. bd 1.3.0 generates a
# "## Session Completion" section between its markers; the guard once listed that heading as
# protocol-of-ours and blocked every commit on a fresh install. The shape below is the real
# 1.3.0 block, cut down: a versioned marker, bd's headings, nothing of ours.
{ printf '# Agent Instructions\n\nrules\n\n'
  printf '<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:1105d646 -->\n'
  printf '## Beads Issue Tracker\n\nRun `bd prime`.\n\n'
  printf '## Session Completion\n\n**When ending a work session**, close issues and push.\n'
  printf '<!-- END BEADS INTEGRATION -->\n'; } > "$T/AGENTS.md"
chk "bd 1.3.0's own block (with its Session Completion heading) passes" "$(run)" 0

echo "### the size cap follows bd's own template, not a number written down in 2026"
# The guard asks `bd setup --print` how long bd's block is (floor 56) and allows that plus slack.
# Compute the same figure here, so this stays true when bd's template grows.
tmpl=0
if bd setup --help 2>&1 | grep -q -- '--print'; then tmpl=$(bd setup --print 2>/dev/null | wc -l | tr -d ' '); fi
case $tmpl in ''|*[!0-9]*) tmpl=0 ;; esac; [ "$tmpl" -lt 56 ] && tmpl=56
region() {  # region N -> AGENTS.md whose managed block holds N generated-looking lines
  { printf '# Agent Instructions\n\nrules\n\n<!-- BEGIN BEADS INTEGRATION v:1 -->\n'
    i=0; while [ "$i" -lt "$1" ]; do printf -- '- generated line %d\n' "$i"; i=$((i+1)); done
    printf '<!-- END BEADS INTEGRATION -->\n'; } > "$T/AGENTS.md"
}
region "$tmpl";         chk "a block as long as bd's template ($tmpl) passes"   "$(run)" 0
region $((tmpl + 40));  chk "a block 40 lines past bd's template is caught"     "$(run)" 1

echo "### --cached validates the index, including the managed block"
git -C "$T" init -q
region "$tmpl"; git -C "$T" add AGENTS.md CLAUDE.md
chk "valid staged pair passes" "$(cached)" 0
git -C "$T" -c user.email=test@example.invalid -c user.name=fixture commit -qm baseline
git -C "$T" rm -q --cached CLAUDE.md
chk "cannot silently remove an already-tracked link" "$(cached)" 1
git -C "$T" add CLAUDE.md
# The working copy deliberately contradicts every staged state below.
rm -f "$T/CLAUDE.md"; printf 'regular copy\n' > "$T/CLAUDE.md"; git -C "$T" add CLAUDE.md
rm -f "$T/CLAUDE.md"; ln -s AGENTS.md "$T/CLAUDE.md"
chk "staged regular copy caught despite working symlink" "$(cached)" 1
git -C "$T" add CLAUDE.md
region $((tmpl + 40)); git -C "$T" add AGENTS.md; region "$tmpl"
chk "staged oversized managed block caught despite clean working doc" "$(cached)" 1
git -C "$T" add AGENTS.md
git -C "$T" rm -q --cached AGENTS.md
chk "staged link with only an untracked target is broken" "$(cached)" 1
git -C "$T" add AGENTS.md
rm -f "$T/CLAUDE.md"; printf 'unstaged divergent copy\n' > "$T/CLAUDE.md"
chk "unstaged link break does not reject valid index" "$(cached)" 0
chk "manual mode still sees the working-tree break" "$(run)" 1
else
  printf '  SKIP  every symlink case: this filesystem cannot create a symlink (Windows without Developer Mode) — only the pointer-file section runs\n'
fi

echo "### the pointer-file state: a filesystem without symlinks"
# git's on-disk form of the link where it cannot make one is a regular file holding "AGENTS.md",
# and the installer writes that form. It passes only when git agrees it is a symlink: an index
# entry of mode 120000, or core.symlinks=false for the checkout. The same bytes with neither are
# a stale copy; anything beyond the name is a copy; a missing target is a dangling link.
git -C "$T" init -q 2>/dev/null; git -C "$T" rm -q -f --cached CLAUDE.md AGENTS.md 2>/dev/null
rm -f "$T/CLAUDE.md"; printf '# Agent Instructions\n\nSome rules.\n' > "$T/AGENTS.md"
printf 'AGENTS.md' > "$T/CLAUDE.md"
git -C "$T" config core.symlinks true
chk "pointer file, symlinks available, nothing staged: a copy, caught" "$(run)" 1
git -C "$T" config core.symlinks false
chk "pointer file passes when core.symlinks=false"                     "$(run)" 0
git -C "$T" config --unset core.symlinks
blob=$(printf 'AGENTS.md' | git -C "$T" hash-object -w --stdin)
git -C "$T" update-index --add --cacheinfo "120000,$blob,CLAUDE.md"; git -C "$T" add AGENTS.md
chk "pointer file passes when the index holds it as mode 120000"       "$(run)" 0
chk "...and --cached sees the valid staged link"                       "$(cached)" 0
printf 'AGENTS.md\nand a line of my own\n' > "$T/CLAUDE.md"
chk "a pointer file with extra content is a copy, caught"              "$(run)" 1
printf 'AGENTS.md' > "$T/CLAUDE.md"; rm -f "$T/AGENTS.md"
chk "a pointer whose target is missing is caught (dangling)"           "$(run)" 1
printf '# Agent Instructions\n\nSome rules.\n' > "$T/AGENTS.md"
git -C "$T" rm -q -f --cached CLAUDE.md AGENTS.md 2>/dev/null; rm -f "$T/CLAUDE.md"

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
