#!/usr/bin/env bash
# Acceptance suite for .claude/skills/memory-curate/audit_wikilinks.py.
#
# WHY IT EXISTS
# The script shipped with `ISSUE_PREFIX = 'WS'` -- the prefix of the workspace it was written in.
# In any other store, every [[<prefix>-id]] issue reference read as a dangling memory link, and
# --apply rewrote each one to "<id> (memory pruned)". A skill that mutates the memory store needs
# a suite that tries to make it do the wrong thing; this one did not have one.
#
# Hermetic: a stub `bd` on PATH answers `config get`, `memories --json` and records `remember`.
set -uo pipefail
SCRIPT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/.claude/skills/memory-curate/audit_wikilinks.py
[ -f "$SCRIPT" ] || { echo "missing: $SCRIPT" >&2; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

mkdir -p "$T/bin"
stub_bd() {  # stub_bd PREFIX -> a bd that reports that prefix and a two-memory store
  cat > "$T/bin/bd" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "config get") printf '%s\n' '$1' ;;
  "memories --json")
    printf '%s\n' '{"schema_version":1,"alpha":"see [[AB-1a2b]] and [[gone-key]] and [[beta]]","beta":"plain"}' ;;
  "remember --key") printf '%s\n' "\$4" >> "$T/remembered"; ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$T/bin/bd"
}
run() { (cd "$T" && PATH="$T/bin:$PATH" python3 "$SCRIPT" "$@") 2>"$T/err"; }

echo "### the prefix comes from the store, and issue links under it are left alone"
stub_bd AB
out=$(run); rc=$?
chk "dry run exits 0"                          "$rc" 0
chk "AB-1a2b is NOT touched"                   "$(grep -c 'AB-1a2b' <<<"$out")" 0
chk "gone-key IS de-linked"                    "$(grep -c 'delink gone-key' <<<"$out")" 1
chk "beta (exists) is not touched"             "$(grep -c 'beta' <<<"$out")" 0
chk "nothing written on a dry run"             "$([ -e "$T/remembered" ] && echo written || echo no)" no

echo "### the SAME store under a different prefix: what used to happen with the constant"
stub_bd ZZ                                     # the store's prefix is ZZ; AB-1a2b is now a dangling link
out=$(run)
chk "AB-1a2b is de-linked when the store's prefix is not AB" "$(grep -c 'delink AB-1a2b' <<<"$out")" 1

echo "### no prefix -> refuse, do not guess"
cat > "$T/bin/bd" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in "config get") echo "issue_prefix (not set)" ;; *) exit 0 ;; esac
STUB
chmod +x "$T/bin/bd"
run >/dev/null; rc=$?
chk "exits non-zero"                           "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" nonzero
chk "says it is refusing to guess"             "$(grep -c 'Refusing to guess' "$T/err")" 1

echo "### --apply writes exactly the planned edits"
stub_bd AB; rm -f "$T/remembered"
run --apply >/dev/null; rc=$?
chk "apply exits 0"                            "$rc" 0
chk "one memory rewritten"                     "$(wc -l < "$T/remembered")" 1
chk "the rewrite keeps the issue link and prunes the dead one" \
    "$(grep -c '\[\[AB-1a2b\]\].*gone-key (memory pruned)' "$T/remembered")" 1

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
