#!/usr/bin/env bash
# Acceptance test for tools/new-worktree.sh — prove the worktree shares the cairn store through the
# redirect (a write from the worktree is visible in the main tree), git ignores the redirect, no
# stray database is built in the worktree, and --remove works.
# Hermetic: a throwaway repo with its own cairn store under mktemp. Needs cairn; skips without it.
set -uo pipefail
TOOL=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/new-worktree.sh
[ -x "$TOOL" ] || { echo "missing or non-executable: $TOOL" >&2; exit 2; }
command -v cairn >/dev/null 2>&1 || { echo "SKIP: cairn not installed"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R=$T/main; mkdir -p "$R"; cd "$R" || exit 2
git init -q . && git config user.name t && git config user.email t@example.com
unset BEADS_ACTOR CAIRN_DIR
cairn init -p t --actor t -q || { echo "SKIP: cairn init failed here"; exit 0; }
cairn create --title=main-issue --type=task --priority=4 --actor t --silent >/dev/null
# A post-checkout hook like this repo's: `cairn sync` in the new tree (the stray-store case).
mkdir -p hooks && printf '#!/bin/sh\ncairn sync >/dev/null 2>&1 || true\n' > hooks/post-checkout
chmod +x hooks/post-checkout && git config core.hooksPath hooks
cairn export --all -o .cairn/issues.jsonl >/dev/null && cairn export --events -o .cairn/events.jsonl >/dev/null
git add .cairn hooks && git commit -qm init
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
out=$("$TOOL" "$T/side" 2>&1); rc=$?
chk "create exits 0" "$rc" 0
chk "says where the store is" "$(printf '%s' "$out" | grep -c 'redirect -> ')" 1
chk "refusing an existing dir" "$("$TOOL" "$T/side" >/dev/null 2>&1; echo $?)" 1
chk "redirect holds the main store's absolute path" "$(cat "$T/side/.cairn/redirect")" "$R/.cairn"
chk "no stray database in the worktree" "$([ -e "$T/side/.cairn/cairn.db" ] && echo stray || echo none)" none
chk "worktree sees the main issue" "$(cd "$T/side" && cairn list 2>/dev/null | grep -c main-issue)" 1
(cd "$T/side" && cairn create --title=from-side --type=task --priority=4 --actor t --silent >/dev/null 2>&1)
chk "main sees the worktree's write" "$(cairn list 2>/dev/null | grep -c from-side)" 1
chk "redirect invisible to git status" "$(cd "$T/side" && git status --porcelain -- .cairn | grep -c redirect)" 0
# From INSIDE a worktree: the new one must point at the main store, not at the worktree's redirect
# (a redirect to a redirect is refused; found by the cairn re-measure, 2026-10-20).
(cd "$T/side" && "$TOOL" "$T/nested" nested >/dev/null 2>&1); chk "a worktree made from a worktree exits 0" "$?" 0
chk "  its redirect names the main store" "$(cat "$T/nested/.cairn/redirect")" "$(cat "$T/side/.cairn/redirect")"
"$TOOL" --remove "$T/nested" >/dev/null 2>&1
out=$("$TOOL" --remove "$T/side" 2>&1); chk "--remove exits 0" "$?" 0
chk "worktree gone" "$([ -e "$T/side" ] && echo still || echo gone)" gone
chk "main store intact after remove" "$(cairn list 2>/dev/null | grep -c from-side)" 1
printf '%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
