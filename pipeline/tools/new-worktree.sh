#!/usr/bin/env bash
# new-worktree.sh — a second working tree for a concurrent session that shares THIS checkout's
# cairn store through an untracked .cairn/redirect (workspace-i6od.2, workspace-7m8.5.6).
#
#   tools/new-worktree.sh <dir> [branch]      create <dir> as a worktree on <branch> (new branch,
#                                             default: the dir's basename), link the store into it
#   tools/new-worktree.sh --remove <dir>      git worktree remove (refuses if the tree is dirty)
#
# Why a plain `git worktree add` is not enough: the store's database is untracked, so a worktree
# has none, and cairn there finds no store, or (through the post-checkout `cairn sync`) builds one
# of its own that the main checkout never sees. The untracked `.cairn/redirect` names the main
# store by ABSOLUTE path (one hop; cairn README, worktrees), and every write from either tree lands
# in the one database (its write lock queues them).
#
# The tracked exports stay per tree: tools/refresh-beads-exports.sh regenerates them from the
# shared store before each commit, as in the main checkout, and a merge conflict on them is
# resolved by running the refresh again — they are derived data. A session in the worktree records
# its claims under .git/worktrees/<name>/bd-session-claims/ (the hooks' --absolute-git-dir).
set -euo pipefail
usage() { sed -n '2,10p' "$0"; exit "${1:-0}"; }
[ $# -ge 1 ] || usage 1
# The MAIN checkout, also when this runs inside a worktree: --show-toplevel would name the worktree,
# whose .cairn/ is a redirect already, and a redirect to a redirect is refused (one hop;
# found 2026-10-20 by three sessions of the cairn re-measure). The main checkout owns the common dir.
COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "not inside a git checkout" >&2; exit 1; }
MAIN=$(dirname "$COMMON")
[ -d "$MAIN/.cairn" ] || { echo "no .cairn/ in $MAIN — nothing to share" >&2; exit 1; }
if [ "$1" = "--remove" ]; then
    [ $# -eq 2 ] || usage 1
    git -C "$MAIN" worktree remove "$2"
    echo "removed worktree $2 (its branch is kept; delete it with git branch -d when merged)"
    exit 0
fi
DIR=$1; BRANCH=${2:-$(basename "$DIR")}
case "$DIR" in /*) ;; *) DIR=$PWD/$DIR ;; esac
[ -e "$DIR" ] && { echo "$DIR exists" >&2; exit 1; }
# The redirect goes in BEFORE the checkout: the post-checkout hook runs `cairn sync`, and in a tree
# with no redirect yet that builds a store of its own, a stray 3 MB database a later write could
# land in (found 2026-11-08, workspace-7m8.5.6). The store's database is untracked, and an
# untracked .cairn/redirect names the main store (cairn README, worktrees).
git -C "$MAIN" worktree add --no-checkout "$DIR" -b "$BRANCH"
mkdir -p "$DIR/.cairn"
printf '%s\n' "$MAIN/.cairn" > "$DIR/.cairn/redirect"
git -C "$DIR" checkout -q "$BRANCH"
echo "worktree: $DIR  branch: $BRANCH"
echo "store: $DIR/.cairn/redirect -> $MAIN/.cairn (untracked by .cairn/.gitignore)"
echo "check: (cd $DIR && cairn list) shows the same issues as here; writes from either tree land in the one store."
echo "the session working there still claims its issues (cairn update <id> --claim) and commits on $BRANCH; merge it from the main checkout."
