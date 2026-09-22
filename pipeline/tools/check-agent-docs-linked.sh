#!/usr/bin/env bash
# check-agent-docs-linked.sh — assert CLAUDE.md is still a symlink to AGENTS.md.
#
# WHY THIS EXISTS
# AGENTS.md and CLAUDE.md are one file: CLAUDE.md is a symlink, so the two cannot
# drift apart, and git carries the link to every clone. That holds as long as the
# link survives. It does not survive a writer that replaces a file rather than
# writing through it — write-to-temp-then-rename is the common pattern, and a
# `bd setup claude` run may install a regular file too. The moment that happens
# the two documents are independent again and drift silently, which is the state
# this repo was in until 2026-08-31 (bd doctor had been reporting it; the two had
# diverged by ~180 lines).
#
# Run manually any time. It is also invoked from .beads-hooks/pre-commit, which git uses via
# core.hooksPath -- NOT from .git/hooks/, which git ignores entirely while that is set.
#
# Exit 0 = linked (or nothing to check), 1 = drifted.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 0

# Nothing to enforce if neither name is present at all.
[ -e AGENTS.md ] || [ -e CLAUDE.md ] || [ -L CLAUDE.md ] || exit 0

# A BROKEN SYMLINK IS NOT "ABSENT". `[ -e ]` follows the link, so it is FALSE for a dangling one
# -- and an earlier version of this guard tested only `[ -e CLAUDE.md ]` and therefore exited 0
# on exactly the state it exists to catch: CLAUDE.md pointing at a file that is no longer there.
# Renaming or moving AGENTS.md produces it, silently, and nothing else would have told you.
if [ -L CLAUDE.md ] && [ ! -e CLAUDE.md ]; then
    echo "agent-docs: CLAUDE.md is a BROKEN symlink -> '$(readlink CLAUDE.md)' (target missing)." >&2
    echo "  Reading CLAUDE.md fails, so an agent that looks there finds nothing at all." >&2
    echo "  Restore the target, or repoint it: rm CLAUDE.md && ln -s AGENTS.md CLAUDE.md" >&2
    exit 1
fi

[ -e AGENTS.md ] || exit 0
[ -e CLAUDE.md ] || exit 0

if [ ! -L CLAUDE.md ]; then
    cat >&2 <<'MSG'
agent-docs: CLAUDE.md is a REGULAR FILE, not a symlink to AGENTS.md.

  The two are meant to be one file so they cannot diverge. Either something
  replaced the link -- commonly a tool that writes to a temp file and renames
  over the target, or a `bd setup claude` run -- or this clone was checked out
  on a filesystem without symlink support, where git materialises the link as a
  small regular file containing the text "AGENTS.md".

  Check which: `cat CLAUDE.md`. If it is one line reading AGENTS.md, it is the
  checkout case -- see docs/ops/agent-docs-symlink.md.

  Reconcile first (the regular file may hold edits the symlink target lacks):

      diff CLAUDE.md AGENTS.md

  Fold anything worth keeping into AGENTS.md, then restore the link:

      rm CLAUDE.md && ln -s AGENTS.md CLAUDE.md

  Bypass once with: git commit --no-verify
MSG
    exit 1
fi

target=$(readlink CLAUDE.md)
if [ "$target" != "AGENTS.md" ]; then
    echo "agent-docs: CLAUDE.md points at '$target', expected 'AGENTS.md'." >&2
    echo "  Fix with: rm CLAUDE.md && ln -s AGENTS.md CLAUDE.md" >&2
    exit 1
fi

# The landmine this restructure defused: workspace protocol must stay OUTSIDE the
# bd-managed markers, because `bd setup` regenerates whatever is between them.
if command grep -q 'BEGIN BEADS INTEGRATION' AGENTS.md; then
    managed=$(sed -n '/BEGIN BEADS INTEGRATION/,/END BEADS INTEGRATION/p' AGENTS.md)

    # STRUCTURAL CHECK, and the one that actually holds. The keyword list below is a
    # BLOCKLIST: it only catches protocol whose wording someone already thought of.
    # Verified 2026-09-01 that a section titled "Corrections protocol", using none of
    # those four words, passes it untouched. Size does not care about wording.
    #
    # The region held 22 lines when this was written and bd's own generated template is
    # 56, so the cap sits above a legitimate `bd setup` regeneration and far below the
    # 307 lines of workspace protocol that were once in there.
    managed_lines=$(printf '%s' "$managed" | wc -l)
    if [ "$managed_lines" -gt 70 ]; then
        echo "agent-docs: the BEADS INTEGRATION region in AGENTS.md is $managed_lines lines." >&2
        echo "  That is too large to be bd's generated block alone (its template is ~56)." >&2
        echo "  \`bd setup\` REGENERATES this region — anything hand-written in it will be" >&2
        echo "  destroyed. Move it below the END marker." >&2
        exit 1
    fi

    # Only wording that is OURS belongs on this list. 'Session Completion' was on it and was
    # wrong: bd 1.3.0's own generated block carries a "## Session Completion" heading, so on a
    # fresh install every commit was blocked, with advice ("move it below the END marker") that
    # would have been wrong to follow. Found 2026-09-22 on the first box with a current bd.
    for pattern in 'sweep\.sh' 'memgraph' 'SUPERSEDE'; do
        if printf '%s' "$managed" | command grep -qE "$pattern"; then
            echo "agent-docs: '$pattern' is INSIDE the BEADS INTEGRATION markers in AGENTS.md." >&2
            echo "  \`bd setup\` regenerates that region and would silently destroy it." >&2
            echo "  Move it below the END marker." >&2
            exit 1
        fi
    done
fi

exit 0
