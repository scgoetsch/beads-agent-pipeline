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
# safe to run at any time, including with uncommitted work in progress.
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

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
