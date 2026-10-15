#!/usr/bin/env bash
# pre-commit-store-cli_test.sh — the shared pre-commit follows .claude/store-cli.
#
# Absent or bd: bd-memgraph reads bd itself and bd's managed block (`bd hooks run pre-commit`)
# runs. cairn: bd-memgraph is fed `cairn memories --json`, and bd is never called. Hermetic: the
# hook runs in a throwaway git repo against stubs that log every call; nothing is committed.
set -uo pipefail
HOOK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/.beads-hooks/pre-commit
[ -f "$HOOK" ] || { echo "missing: $HOOK" >&2; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin" "$T/repo/.beads" "$T/repo/.claude"
for tool in bd cairn bd-memgraph; do
  cat > "$T/bin/$tool" <<STUB
#!/usr/bin/env bash
echo "$tool \$*" >> "$T/calls"
case "\$*" in *"memories --json"*) echo '{"schema_version":1,"k":"v"}' ;; esac
exit 0
STUB
  chmod +x "$T/bin/$tool"
done
git -C "$T/repo" init -q .
run() { : > "$T/calls"; (cd "$T/repo" && PATH="$T/bin:$PATH" sh "$HOOK") >/dev/null 2>"$T/err"; echo $?; }

echo "### no .claude/store-cli: bd as before"
chk "exit 0"                                   "$(run)" 0
chk "bd-memgraph checks bd's store itself"     "$(grep -c '^bd-memgraph --no-ledger check' "$T/calls")" 1
chk "bd's managed block runs"                  "$(grep -c '^bd hooks run pre-commit' "$T/calls")" 1
chk "cairn is not called"                      "$(grep -c '^cairn' "$T/calls")" 0

echo "### store-cli = cairn: bd is never called"
printf 'cairn\n' > "$T/repo/.claude/store-cli"
chk "exit 0"                                   "$(run)" 0
chk "bd is not called at all"                  "$(grep -c '^bd ' "$T/calls")" 0
chk "cairn supplies the memory map"            "$(grep -c '^cairn memories --json' "$T/calls")" 1
chk "bd-memgraph reads it from a file"         "$(grep -c '^bd-memgraph --no-ledger --json-file .* check' "$T/calls")" 1

echo "### store-cli = cairn and the memory graph has errors: the commit is refused"
printf '#!/usr/bin/env bash\necho "bd-memgraph $*" >> "%s/calls"; exit 1\n' "$T" > "$T/bin/bd-memgraph"
chk "exit 1"                                   "$(run)" 1

echo "### store-cli = bd: as with none"
printf '#!/usr/bin/env bash\necho "bd-memgraph $*" >> "%s/calls"; exit 0\n' "$T" > "$T/bin/bd-memgraph"
printf 'bd\n' > "$T/repo/.claude/store-cli"
chk "exit 0, bd's block runs"                  "$(run)/$(grep -c '^bd hooks run pre-commit' "$T/calls")" "0/1"

echo "### an unknown value: bd, with a warning"
printf 'beads\n' > "$T/repo/.claude/store-cli"
chk "bd's block runs"                          "$(run)/$(grep -c '^bd hooks run pre-commit' "$T/calls")" "0/1"
chk "…and the warning says so"                 "$(grep -c 'neither bd nor cairn' "$T/err")" 1

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
