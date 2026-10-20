#!/usr/bin/env bash
# store-cli-git-hooks_test.sh — bd's own git hooks get the stanza, and it stops them under cairn only.
set -uo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/store-cli-git-hooks.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
mkdir -p "$T/r/tools" "$T/r/.beads-hooks" "$T/r/.claude" "$T/bin"; cp "$SRC" "$T/r/tools/"
for h in post-checkout post-merge pre-push prepare-commit-msg; do
  printf '#!/usr/bin/env sh\n# --- BEGIN BEADS INTEGRATION v1.1.2 ---\nbd hooks run %s "$@"\n# --- END BEADS INTEGRATION v1.1.2 ---\n' "$h" > "$T/r/.beads-hooks/$h"
  chmod 755 "$T/r/.beads-hooks/$h"
done
printf '#!/usr/bin/env sh\necho mine\n' > "$T/r/.beads-hooks/custom"; chmod 755 "$T/r/.beads-hooks/custom"
printf '#!/bin/sh\necho "$*" >> "%s/calls"\n' "$T" > "$T/bin/bd"; chmod +x "$T/bin/bd"
calls() { : > "$T/calls"; for h in post-checkout post-merge pre-push prepare-commit-msg; do
  (cd "$T/r" && PATH="$T/bin:$PATH" sh ".beads-hooks/$h" a b); done; grep -c . "$T/calls"; }
chk "--check names the four before"            "$(bash "$T/r/tools/store-cli-git-hooks.sh" --check 2>&1 | grep -c 'does not stop')" 4
chk "insert reports the four"                  "$(bash "$T/r/tools/store-cli-git-hooks.sh" | grep -c 'now stops')" 4
chk "a hook without bd's markers is untouched" "$(cat "$T/r/.beads-hooks/custom")" $'#!/usr/bin/env sh\necho mine'
chk "idempotent: a second run changes nothing" "$(bash "$T/r/tools/store-cli-git-hooks.sh" | grep -c .)" 0
chk "--check passes after"                     "$(bash "$T/r/tools/store-cli-git-hooks.sh" --check; echo $?)" 0
chk "still executable"                         "$( [ -x "$T/r/.beads-hooks/pre-push" ] && echo y)" y
chk "no store-cli: bd runs from all four"      "$(calls)" 4
printf 'cairn\n' > "$T/r/.claude/store-cli"
chk "store-cli = cairn: bd runs from none"     "$(calls)" 0
printf 'bd\n' > "$T/r/.claude/store-cli"
chk "store-cli = bd: bd runs from all four"    "$(calls)" 4
echo "### under cairn, post-merge and post-checkout bring the store up to the exports (workspace-7m8.21)"
printf '#!/bin/sh\necho "cairn $*" >> "%s/calls"; exit "${CAIRN_RC:-0}"\n' "$T" > "$T/bin/cairn"; chmod +x "$T/bin/cairn"
printf 'cairn\n' > "$T/r/.claude/store-cli"
: > "$T/calls"; for h in post-checkout post-merge pre-push prepare-commit-msg; do (cd "$T/r" && PATH="$T/bin:$PATH" sh ".beads-hooks/$h" a b 2>/dev/null); done
chk "cairn sync from post-merge and post-checkout only" "$(grep -c '^cairn sync$' "$T/calls"):$(grep -c '^bd ' "$T/calls")" "2:0"
chk "a refused sync does not fail the git command" "$(cd "$T/r" && CAIRN_RC=2 PATH="$T/bin:$PATH" sh .beads-hooks/post-merge 2>/dev/null; echo $?)" 0
rm -f "$T/r/.claude/store-cli"
echo "### an older stanza is replaced"
old_stanza=$'# >>> store CLI: cairn stops here >>>\n# old\n[ -f .claude/store-cli ] && [ "$(tr -d \' \\t\\r\\n\' < .claude/store-cli)" = cairn ] && exit 0\n# <<< store CLI: cairn stops here <<<'
printf '#!/usr/bin/env sh\n%s\n# --- BEGIN BEADS INTEGRATION v1.1.2 ---\nbd hooks run post-merge "$@"\n# --- END BEADS INTEGRATION v1.1.2 ---\n' "$old_stanza" > "$T/r/.beads-hooks/post-merge"
chk "--check names the older stanza"           "$(bash "$T/r/tools/store-cli-git-hooks.sh" --check 2>&1 | grep -c 'older store-CLI stanza')" 1
chk "a run updates it"                         "$(bash "$T/r/tools/store-cli-git-hooks.sh" | grep -c 'stanza updated')" 1
chk "…once: the start marker appears once"     "$(grep -c '>>> store CLI: cairn stops here >>>' "$T/r/.beads-hooks/post-merge")" 1
chk "…and bd's block is kept"                  "$(grep -c 'bd hooks run post-merge' "$T/r/.beads-hooks/post-merge")" 1
chk "--check passes after"                     "$(bash "$T/r/tools/store-cli-git-hooks.sh" --check; echo $?)" 0
# a stanza AFTER bd's block does not count
printf '#!/usr/bin/env sh\n# --- BEGIN BEADS INTEGRATION v1.1.2 ---\nbd hooks run x\n# --- END BEADS INTEGRATION v1.1.2 ---\n# >>> store CLI: cairn stops here >>>\n' > "$T/r/.beads-hooks/post-merge"
chk "a stanza after bd's block is reported"    "$(bash "$T/r/tools/store-cli-git-hooks.sh" --check 2>&1 | grep -c post-merge)" 1
echo "### the pipeline's own pre-commit keeps its own stanza"
cp -f "$(dirname "$SRC")/../.beads-hooks/pre-commit" "$T/r/.beads-hooks/pre-commit"
before=$(cksum < "$T/r/.beads-hooks/pre-commit")
chk "--check accepts it"                       "$(bash "$T/r/tools/store-cli-git-hooks.sh" --check 2>&1 | grep -c pre-commit)" 0
bash "$T/r/tools/store-cli-git-hooks.sh" >/dev/null 2>&1
chk "a run leaves it byte for byte"            "$(cksum < "$T/r/.beads-hooks/pre-commit")" "$before"
echo; printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
