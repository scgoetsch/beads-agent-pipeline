#!/usr/bin/env bash
# store-cli-git-hooks.sh — make bd's own git hooks stop under cairn.
#
# `bd hooks install --shared` writes post-checkout, post-merge, pre-push and prepare-commit-msg into
# .beads-hooks/ itself (the pipeline ships only pre-commit, which carries this stanza already). Each
# runs `bd hooks run <hook>` inside bd's markers. With .claude/store-cli = cairn bd's store is
# frozen, and those calls would read, sync or push it. This inserts, right after the shebang of
# every hook holding bd's markers, a stanza that exits 0 under cairn and does nothing otherwise.
# bd keeps everything outside its markers when it reinstalls a hook. Idempotent.
#
#   tools/store-cli-git-hooks.sh           insert where missing; prints what it changed
#   tools/store-cli-git-hooks.sh --check   exit 1 and name the hooks that lack it (changes nothing)
#
# Run it before writing `cairn` into .claude/store-cli, and again after any `bd hooks install`.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
MARK='# >>> store CLI: cairn stops here >>>'
read -r -d '' STANZA <<'ST'
# >>> store CLI: cairn stops here >>>
# With .claude/store-cli = cairn bd's store is frozen; skip bd's managed block below (git runs this
# hook from the top of the work tree). Inserted by tools/store-cli-git-hooks.sh.
[ -f .claude/store-cli ] && [ "$(tr -d ' \t\r\n' < .claude/store-cli)" = cairn ] && exit 0
# <<< store CLI: cairn stops here <<<
ST
check=0; [ "${1:-}" = --check ] && check=1
missing=0
for h in .beads-hooks/*; do
  [ -f "$h" ] || continue
  grep -q 'BEGIN BEADS INTEGRATION' "$h" || continue
  # The stanza must come BEFORE bd's block to stop it: its line number, not its presence.
  m=$(grep -nF -- "$MARK" "$h" | head -n 1 | cut -d: -f1)
  b=$(grep -n 'BEGIN BEADS INTEGRATION' "$h" | head -n 1 | cut -d: -f1)
  if [ -n "$m" ] && [ "$m" -lt "$b" ]; then continue; fi
  if [ "$check" -eq 1 ]; then echo "store-cli-git-hooks: $h does not stop before bd's block under cairn" >&2; missing=1; continue; fi
  first=$(head -n 1 "$h")
  case $first in '#!'*) ;; *) echo "store-cli-git-hooks: $h has no shebang line; not touched" >&2; missing=1; continue ;; esac
  { printf '%s\n' "$first"; printf '%s\n' "$STANZA"; tail -n +2 "$h"; } > "$h.tmp.$$" && chmod --reference="$h" "$h.tmp.$$" 2>/dev/null
  mv -f "$h.tmp.$$" "$h" && echo "store-cli-git-hooks: $h now stops before bd's block under cairn"
done
exit "$missing"
