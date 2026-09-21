#!/usr/bin/env bash
# Acceptance test for check-no-agent-cache-paths.sh — prove it BLOCKS, ALLOWS and RATCHETS.
#
# Written because the ancestor of this guard silently PASSED a commit adding an agent-cache
# path: `grep -E '^\+' | grep -v '^\+\+\+'` — the second grep had no -E, and in BRE `\+` is
# GNU's one-or-more operator, so the pattern was malformed and -v excluded EVERY line.
# "The guard is written" and "the guard fires" are different claims; this file is the second.
#
# Hermetic: it builds a throwaway git repo under mktemp and never touches your working tree.
set -uo pipefail
GUARD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/check-no-agent-cache-paths.sh
[ -x "$GUARD" ] || { echo "missing or non-executable: $GUARD" >&2; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git -C "$T" init -q
git -C "$T" config user.email test@example.com
git -C "$T" config user.name  test

pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
run_guard() { (cd "$T" && "$GUARD") >/dev/null 2>&1; echo $?; }

# Built at runtime so this file does not itself contain a literal the guard would reject.
BAD_DOC="/home/someone/.claude/projects/$(uuidgen 2>/dev/null || echo 1234)/figure.png"
BAD_TMP="/tmp/claude-1000/scratch/out.txt"
BAD_AGY="/home/someone/.gemini/antigravity-cli/brain/abc/plot.png"

echo "### a clean tree passes"
printf 'see [fig](results/figure.png)\n' > "$T/clean.md"
git -C "$T" add clean.md
chk "clean staged doc allowed" "$(run_guard)" 0

echo "### BLOCK: a cache path in a document"
printf 'see ![fig](%s)\n' "$BAD_DOC" > "$T/report.md"
git -C "$T" add report.md
chk "claude projects path in .md blocked" "$(run_guard)" 1
git -C "$T" rm -q --cached report.md; rm -f "$T/report.md"

echo "### BLOCK: agy brain path, and a /tmp scratch path in generated JSON"
printf '![p](%s)\n' "$BAD_AGY" > "$T/walkthrough.md"
git -C "$T" add walkthrough.md
chk "agy brain path blocked" "$(run_guard)" 1
git -C "$T" rm -q --cached walkthrough.md; rm -f "$T/walkthrough.md"
printf '{"out": "%s"}\n' "$BAD_TMP" > "$T/manifest.json"
git -C "$T" add manifest.json
chk "scratch path in .json blocked" "$(run_guard)" 1
git -C "$T" rm -q --cached manifest.json; rm -f "$T/manifest.json"

echo "### BLOCK: a cache path ADDED to code"
printf 'x = 1\n' > "$T/s.py"; git -C "$T" add s.py
git -C "$T" -c core.hooksPath=/dev/null commit -qm base
printf 'x = 1\nout = "%s"\n' "$BAD_TMP" > "$T/s.py"; git -C "$T" add s.py
chk "added line in .py blocked" "$(run_guard)" 1

echo "### RATCHET: a pre-existing violation does not block unrelated work"
# s.py now HOLDS a bad path in the committed tree; a later edit elsewhere in the file must
# still be committable, or the guard makes --no-verify a habit and stops meaning anything.
git -C "$T" -c core.hooksPath=/dev/null commit -qm "legacy violation lands"
printf 'x = 1\nout = "%s"\ny = 2\n' "$BAD_TMP" > "$T/s.py"; git -C "$T" add s.py
chk "unrelated added line allowed" "$(run_guard)" 0

echo "### NEGATIVE CONTROL: the added-line filter really filters"
# If the filter were the malformed-BRE version, it would drop every line and this would
# pass — the exact bug this file was written for. The check above must therefore be able
# to fail: re-add the SAME bad line as a new addition and require a block.
printf 'x = 1\n' > "$T/t.py"; git -C "$T" add t.py
git -C "$T" -c core.hooksPath=/dev/null commit -qm t-base
printf 'x = 1\nz = "%s"\n' "$BAD_AGY" > "$T/t.py"; git -C "$T" add t.py
chk "a fresh bad added line still blocks" "$(run_guard)" 1

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
