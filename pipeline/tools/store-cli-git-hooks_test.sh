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
# a stanza AFTER bd's block does not count
printf '#!/usr/bin/env sh\n# --- BEGIN BEADS INTEGRATION v1.1.2 ---\nbd hooks run x\n# --- END BEADS INTEGRATION v1.1.2 ---\n# >>> store CLI: cairn stops here >>>\n' > "$T/r/.beads-hooks/post-merge"
chk "a stanza after bd's block is reported"    "$(bash "$T/r/tools/store-cli-git-hooks.sh" --check 2>&1 | grep -c post-merge)" 1
echo; printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
