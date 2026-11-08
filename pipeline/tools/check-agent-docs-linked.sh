#!/usr/bin/env bash
# check-agent-docs-linked.sh — assert CLAUDE.md is still a symlink to AGENTS.md.
#
# WHY THIS EXISTS
# AGENTS.md and CLAUDE.md are one file: CLAUDE.md is a symlink, so the two cannot
# drift apart, and git carries the link to every clone. That holds as long as the
# link survives. It does not survive a writer that replaces a file rather than
# writing through it — write-to-temp-then-rename is the common pattern, and a
# harness's own setup command may install a regular file too. The moment that happens
# the two documents are independent again and drift silently, which is the state
# the repo this came from was in until 2026-08-31 (the two had diverged by ~180 lines).
#
# Run manually any time to inspect the working tree. --cached inspects the index instead;
# .beads-hooks/pre-commit always uses that mode. Git uses the hook via
# core.hooksPath -- NOT from .git/hooks/, which git ignores entirely while that is set.
#
# Exit 0 = linked (or nothing to check), 1 = drifted.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

case ${1:-} in
  --cached)
    # Snapshot only the two INDEX entries, never checkout the working tree or follow arbitrary
    # staged symlinks. This also respects GIT_INDEX_FILE (git commit --only's temporary index).
    mode=$(git ls-files --stage -- CLAUDE.md) || exit 1
    if [ -z "$mode" ]; then
        # AGENTS-only is the documented no-symlinks fallback for a NEW repo. It is not valid
        # when this repo already committed the link: a staged deletion of CLAUDE.md would
        # silently unhook Claude Code, which reads only that name.
        if git cat-file -e HEAD:CLAUDE.md 2>/dev/null; then
            echo 'agent-docs: staged deletion of the previously tracked CLAUDE.md symlink.' >&2
            echo '  Restore it: git checkout HEAD -- CLAUDE.md' >&2
            exit 1
        fi
        exit 0
    fi
    case "$mode" in
      "120000 "*" 0"$'\t'CLAUDE.md) ;;
      *) echo "agent-docs: staged CLAUDE.md is a REGULAR FILE or unmerged, not a symlink." >&2
         echo '  On a filesystem without symlinks, stage it as the link git itself uses there (a file holding the text AGENTS.md):' >&2
         echo '      printf AGENTS.md > CLAUDE.md && git update-index --add --cacheinfo 120000,$(printf AGENTS.md | git hash-object -w --stdin),CLAUDE.md' >&2
         exit 1 ;;
    esac
    target=$(git show :CLAUDE.md) || exit 1
    if [ "$target" != AGENTS.md ]; then
      echo "agent-docs: staged CLAUDE.md points at '$target', expected 'AGENTS.md'." >&2; exit 1
    fi
    mode=$(git ls-files --stage -- AGENTS.md) || exit 1
    case "$mode" in
      "100644 "*" 0"$'\t'AGENTS.md|"100755 "*" 0"$'\t'AGENTS.md) ;;
      *) echo "agent-docs: staged AGENTS.md is missing, unmerged or not a regular file (BROKEN symlink target)." >&2; exit 1 ;;
    esac
    snapshot=$(mktemp -d) || exit 1
    trap 'rm -rf "$snapshot"' EXIT
    git show :AGENTS.md > "$snapshot/AGENTS.md" || exit 1
    # The index has just proved the link; the snapshot holds its pointer form rather than a
    # symlink, so this mode needs no symlink support (MSYS `ln -s` would have COPIED AGENTS.md).
    printf 'AGENTS.md' > "$snapshot/CLAUDE.md" || exit 1
    staged_link=1
    cd "$snapshot" || exit 1 ;;
  '') ;;
  *) echo "usage: $0 [--cached]" >&2; exit 2 ;;
esac

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

# Nothing to enforce when CLAUDE.md is simply absent. Its presence as anything but the link is a
# drift state WHETHER OR NOT AGENTS.md exists: with no AGENTS.md beside it, every harness that
# follows the AGENTS.md convention finds no instructions at all, which is the split the link is
# there to prevent. An earlier version tested `[ -e AGENTS.md ] || exit 0` first, so a lone
# regular CLAUDE.md passed untouched (2026-09-22 review; the suite now has that state).
[ -e CLAUDE.md ] || exit 0

# THE POINTER-FILE STATE. On a filesystem without symlinks (Git for Windows without Developer
# Mode, core.symlinks=false), git's own on-disk form of the link is a regular file holding the
# text "AGENTS.md", and the installer writes exactly that where `ln -s` cannot link. It is the
# symlink, not a divergent copy, when git agrees: the index carries CLAUDE.md as mode 120000, or
# this checkout says core.symlinks=false (or --cached proved the index above). The content must
# be the target's name and nothing else; a stale copy of AGENTS.md is still the drift state below.
pointer=0
if [ ! -L CLAUDE.md ] && [ -f CLAUDE.md ] && [ "$(cat CLAUDE.md)" = "AGENTS.md" ]; then
    case "$(git ls-files --stage -- CLAUDE.md 2>/dev/null)" in "120000 "*) pointer=1 ;; esac
    [ "$(git config --get core.symlinks 2>/dev/null)" = false ] && pointer=1
    [ "${staged_link:-0}" -eq 1 ] && pointer=1
fi
if [ "$pointer" -eq 1 ] && [ ! -e AGENTS.md ]; then
    echo "agent-docs: CLAUDE.md is the pointer form of a symlink -> 'AGENTS.md', and the target is missing." >&2
    echo "  Restore AGENTS.md (the pointer is git's on-disk link on a filesystem without symlinks)." >&2
    exit 1
fi

if [ ! -L CLAUDE.md ] && [ ! -e AGENTS.md ]; then
    cat >&2 <<'MSG'
agent-docs: CLAUDE.md is a REGULAR FILE and there is no AGENTS.md beside it.

  Only Claude Code reads CLAUDE.md. Every other harness looks for AGENTS.md and finds
  nothing, so the two names must resolve to ONE file. Make this one it:

      git mv CLAUDE.md AGENTS.md && ln -s AGENTS.md CLAUDE.md && git add CLAUDE.md

  Bypass once with: git commit --no-verify
MSG
    exit 1
fi

if [ ! -L CLAUDE.md ] && [ "$pointer" -eq 0 ]; then
    cat >&2 <<'MSG'
agent-docs: CLAUDE.md is a REGULAR FILE, not a symlink to AGENTS.md.

  The two are meant to be one file so they cannot diverge. Either something
  replaced the link -- commonly a tool that writes to a temp file and renames
  over the target, or a harness's setup command -- or this clone was checked out
  on a filesystem without symlink support, where git materialises the link as a
  small regular file containing the text "AGENTS.md".

  Check which: `cat CLAUDE.md`. If it is one line reading AGENTS.md, it is the
  checkout case -- see docs/ops/agent-docs-symlink.md.

  Reconcile first (the regular file may hold edits the symlink target lacks):

      diff CLAUDE.md AGENTS.md

  Fold anything worth keeping into AGENTS.md, then restore the link:

      rm CLAUDE.md && ln -s AGENTS.md CLAUDE.md

  On a filesystem without symlinks, use the form git itself keeps there -- the file
  holds the text AGENTS.md and the index holds a symlink -- which this guard accepts:

      printf AGENTS.md > CLAUDE.md
      git update-index --add --cacheinfo 120000,$(printf AGENTS.md | git hash-object -w --stdin),CLAUDE.md

  Bypass once with: git commit --no-verify
MSG
    exit 1
fi

if [ -L CLAUDE.md ]; then target=$(readlink CLAUDE.md); else target=AGENTS.md; fi
if [ "$target" != "AGENTS.md" ]; then
    echo "agent-docs: CLAUDE.md points at '$target', expected 'AGENTS.md'." >&2
    echo "  Fix with: rm CLAUDE.md && ln -s AGENTS.md CLAUDE.md" >&2
    exit 1
fi

# The old tracker appended a marker-managed block to AGENTS.md (`BEGIN/END BEADS INTEGRATION`)
# and regenerated it on every setup run; this guard used to measure that region, because
# protocol written inside it was destroyed on the next regeneration. Nothing regenerates it any
# more, and what it says (use the old CLI) is now wrong. It is the user's file, so the block is NAMED, not
# removed, and the commit is not blocked for it.
if command grep -q 'BEGIN BEADS INTEGRATION' AGENTS.md; then
    echo "agent-docs: AGENTS.md still carries the old tracker's managed block (BEGIN/END BEADS INTEGRATION)." >&2
    echo "  Nothing regenerates it now, and it tells agents to use a store this repo no longer has." >&2
    echo "  Delete it, keeping anything of yours that sits inside the markers." >&2
fi

exit 0
