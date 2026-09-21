#!/usr/bin/env bash
# agent_docs_test.sh — every path an agent doc points at must exist.
#
# WHY THIS EXISTS
#   AGENTS.md and the skills under .claude/skills/ are the first things an agent reads, and
#   they are almost entirely POINTERS: run this script, read that doc, the guard lives here.
#   A pointer that has rotted is worse than no pointer — the agent goes to the named place,
#   finds nothing, and concludes the thing does not exist. Agents assert "X is not installed"
#   from a check that was merely looking in the wrong place, and then act on it.
#
#   The usual cause is ordinary maintenance: sections get moved out of AGENTS.md into docs/,
#   and the pointers are left behind. This test is the stop for that.
#
# WHAT IT ASSERTS
#   1. CLAUDE.md is still the symlink (delegated to check-agent-docs-linked.sh if present).
#   2. Every repo-relative path cited in AGENTS.md resolves.
#   3. Every path cited in a skill's SKILL.md resolves.
#   4. Every docs/ops/*.md pointer in AGENTS.md resolves.
#   5. Every command named in the Build & Test block exists and is executable.
#   6. AGENTS.md carries no unfilled template placeholder.
#   8. Every path cited in a nested repo's CLAUDE.md resolves (own repo, then root).
#   9. Each nested repo exposes BOTH CLAUDE.md and AGENTS.md as one file.
#   7. NEGATIVE CONTROL: a probe doc citing a missing file must FAIL the path check.
#      Without (7) a checker that silently matches nothing would pass this suite — the exact
#      defect class the repo keeps hitting. See the memory
#      [[checks-narrower-than-what-they-check]].
#
# Exit 0 = all good. Exit 1 = a pointer is broken (fix the doc or restore the file).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

# Deliberately-absent or not-local tokens. Everything else that LOOKS like a repo path
# must resolve. Kept short on purpose: a long allowlist is how a rotted pointer hides.
# word/* are parts INSIDE a .docx zip (OOXML), not files on disk.
ALLOW='^(MEMORY\.md|ChIP-seq/.*|/home2/.*|/project/.*|/endosome/.*|~/mount/.*|word/.*)$'

# Extract backticked path-looking tokens from a markdown file and report unresolved ones.
unresolved() {
  python3 - "$1" "$ALLOW" "${2:-}" <<'PY'
import re, os, sys, subprocess, glob
path, allow = sys.argv[1], sys.argv[2]
base = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else os.getcwd()
s = open(path, encoding="utf-8", errors="replace").read()
root = os.getcwd()
out = []
for m in re.finditer(r'`([^`\n]+)`', s):
    t = m.group(1).strip()
    if not re.match(r'^[~./A-Za-z0-9_-][A-Za-z0-9_./~-]*$', t):
        continue
    # A token counts as a path only if it is anchored in this repo or carries a file
    # extension. Without this, prose like `retracted/superseded` and slash-commands like
    # `/schedule` get treated as paths and the test cries wolf until nobody runs it.
    # Directories that anchor a token as a repo path. Add your own top-level dirs here;
    # anything with a file extension is checked regardless of where it sits.
    ROOTS = ('tools/', 'docs/', 'scripts/', '.claude/', '.beads/', '.beads-hooks/')
    has_ext = re.search(r'\.[A-Za-z0-9]{1,6}$', t) is not None
    if not (t.startswith(ROOTS) or has_ext):
        continue
    # A bare token with no directory must still look like a real filename. This drops
    # suffix conventions written as prose (`_test.sh`) and bare extensions (`.err`),
    # which are the only two things that survived the anchor test.
    if '/' not in t and not re.match(r'^[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9]{1,6}$', t):
        continue
    if re.match(allow, t):
        continue
    p = os.path.expanduser(t)
    # Resolve against the doc's own repo FIRST, then the root, because a nested CLAUDE.md
    # legitimately cites root tooling like `tools/sweep.sh`.
    if p.startswith('/'):
        cands = [p]
    else:
        cands = [os.path.join(base, p), os.path.join(root, p)]
    if any(os.path.exists(c.rstrip('/')) for c in cands):
        continue
    # A NAME STEM: docs often name a family of outputs by stem (`results.q5`) where the real
    # files carry a suffix or prefix. A glob hit counts.
    if any(glob.glob(c + '*') or glob.glob(os.path.join(os.path.dirname(c), '*' + os.path.basename(c)))
           for c in cands):
        continue
    # Last resort: the stem appears ANYWHERE in a real filename under this repo, e.g. a doc
    # citing `results.q5` for a real results.q5.bed.
    bn = os.path.basename(t.rstrip('/'))
    hit = subprocess.run(["find", base, "-not", "-path", "*/.git/*",
                          "-not", "-path", "*/.pixi/*", "-name", "*" + bn + "*"],
                         capture_output=True, text=True).stdout.strip()
    if not hit:
        out.append(t)
print("\n".join(sorted(set(out))))
PY
}

echo "agent-docs conformance"
echo "======================"

# ---- 1 symlink ------------------------------------------------------------
if [ -x tools/check-agent-docs-linked.sh ]; then
  if tools/check-agent-docs-linked.sh >/dev/null 2>&1; then
    ok "T1  CLAUDE.md/AGENTS.md link intact"
  else
    bad "T1  CLAUDE.md/AGENTS.md link intact" "run tools/check-agent-docs-linked.sh"
  fi
else
  [ -L CLAUDE.md ] && ok "T1  CLAUDE.md is a symlink" || bad "T1  CLAUDE.md is a symlink"
fi

# ---- 2 AGENTS.md paths ----------------------------------------------------
U=$(unresolved AGENTS.md)
if [ -z "$U" ]; then ok "T2  every path cited in AGENTS.md resolves"
else bad "T2  every path cited in AGENTS.md resolves" "$(echo "$U" | tr '\n' ' ')"; fi

# ---- 3 skills -------------------------------------------------------------
SKILL_FAIL=""
for sk in .claude/skills/*/SKILL.md; do
  [ -e "$sk" ] || continue
  U=$(unresolved "$sk")
  [ -n "$U" ] && SKILL_FAIL="$SKILL_FAIL $sk:[$(echo "$U" | tr '\n' ' ')]"
done
if [ -z "$SKILL_FAIL" ]; then ok "T3  every path cited in a skill resolves"
else bad "T3  every path cited in a skill resolves" "$SKILL_FAIL"; fi

# ---- 4 docs/ops pointers --------------------------------------------------
MISS=""
for p in $(grep -o 'docs/ops/[A-Za-z0-9._/-]*\.md' AGENTS.md | sort -u); do
  [ -f "$p" ] || MISS="$MISS $p"
done
if [ -z "$MISS" ]; then ok "T4  every docs/ops pointer resolves"
else bad "T4  every docs/ops pointer resolves" "$MISS"; fi

# ---- 5 Build & Test commands ----------------------------------------------
MISS=""
while read -r c; do
  [ -z "$c" ] && continue
  case "$c" in
    tools/*) [ -x "$c" ] || MISS="$MISS $c" ;;
    *)       command -v "$c" >/dev/null 2>&1 || MISS="$MISS $c" ;;
  esac
done < <(awk '/^## Build & Test/,/^## What is in this repo/' AGENTS.md |
         awk '/^```bash/{f=1;next}/^```/{f=0}f{print $1}')
if [ -z "$MISS" ]; then ok "T5  every Build & Test command exists"
else bad "T5  every Build & Test command exists" "$MISS"; fi

# ---- 6 no unfilled placeholders -------------------------------------------
if grep -qE '^_Add .*_$|# npm install' AGENTS.md; then
  bad "T6  no unfilled template placeholder" "$(grep -nE '^_Add .*_$|# npm install' AGENTS.md | head -2)"
else ok "T6  no unfilled template placeholder"; fi

# ---- 8 nested-repo agent docs ---------------------------------------------
# A nested project directory may carry its own CLAUDE.md. Those never load at session start,
# so they are not a payload problem — but they are the FIRST thing an agent reads once it
# enters that subtree, so a rotted pointer there is just as expensive.
NEST_FAIL=""
for nd in */CLAUDE.md; do
  [ -e "$nd" ] || continue
  d=$(dirname "$nd")
  U=$(unresolved "$nd" "$ROOT/$d")
  [ -n "$U" ] && NEST_FAIL="$NEST_FAIL $nd:[$(echo "$U" | tr '\n' ' ')]"
done
if [ -z "$NEST_FAIL" ]; then ok "T8  every path cited in a nested CLAUDE.md resolves"
else bad "T8  every path cited in a nested CLAUDE.md resolves" "$NEST_FAIL"; fi

# ---- 9 nested repos expose BOTH agent-doc names ---------------------------
# The root keeps AGENTS.md as the real file with CLAUDE.md symlinked to it. The nested
# repos had only CLAUDE.md, so an agent following the AGENTS.md convention found nothing
# on entering that subtree. They now symlink the other way (AGENTS.md -> CLAUDE.md) —
# direction does not matter, both names resolving to ONE file does.
NAME_FAIL=""
for nd in */CLAUDE.md; do
  [ -e "$nd" ] || continue
  d=$(dirname "$nd")
  if [ ! -f "$d/AGENTS.md" ]; then NAME_FAIL="$NAME_FAIL $d(no AGENTS.md)"; continue; fi
  a=$(readlink -f "$d/CLAUDE.md"); b=$(readlink -f "$d/AGENTS.md")
  [ "$a" = "$b" ] || NAME_FAIL="$NAME_FAIL $d(diverged)"
done
if [ -z "$NAME_FAIL" ]; then ok "T9  nested repos: CLAUDE.md and AGENTS.md are one file"
else bad "T9  nested repos: CLAUDE.md and AGENTS.md are one file" "$NAME_FAIL"; fi

# ---- 7 NEGATIVE CONTROL ---------------------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf 'See `tools/this_file_does_not_exist_%s.sh` for details.\n' "$$" > "$TMP/probe.md"
if [ -n "$(unresolved "$TMP/probe.md")" ]; then
  ok "T7  negative control: a missing path IS detected"
else
  bad "T7  negative control: a missing path IS detected" \
      "the checker matched nothing — every other result above is meaningless"
fi

echo "======================"
echo "pass $PASS  fail $FAIL"
[ $FAIL -eq 0 ] || exit 1
