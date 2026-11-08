#!/usr/bin/env bash
# Acceptance suite for .claude/skills/memory-curate/audit_wikilinks.py.
#
# WHY IT EXISTS
# The script shipped with `ISSUE_PREFIX = 'WS'` -- the prefix of the workspace it was written in.
# In any other store, every [[<prefix>-id]] issue reference read as a dangling memory link, and
# --apply rewrote each one to "<id> (memory pruned)". A skill that mutates the memory store needs
# a suite that tries to make it do the wrong thing; this one did not have one.
#
# Hermetic: a throwaway git repo whose .cairn/config.json names the prefix, and a stub `cairn` on
# PATH that answers `memories --json` and records `remember`.
set -uo pipefail
SCRIPT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/.claude/skills/memory-curate/audit_wikilinks.py
[ -f "$SCRIPT" ] || { echo "missing: $SCRIPT" >&2; exit 2; }

# The stub below is a shell script. A native Windows Python (the hosted-toolcache one under Git
# Bash, sys.platform == win32) spawns `cairn` through CreateProcess, which runs no shell script;
# the real cairn is what users have, so the script works there, but this suite's fixture cannot.
# Say so and skip, as the Pi suite does, rather than fail every case.
if [ "$(python3 -c 'import sys; print(sys.platform)' 2>/dev/null | tr -d '\r')" = win32 ]; then
  echo "SKIP audit_wikilinks_test.sh: a native Windows Python cannot run this suite's shell stub for cairn (CreateProcess runs no shell script) — run it under WSL"
  exit 0
fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

R=$T/repo; mkdir -p "$T/bin" "$R/.cairn"; git -C "$R" init -q
cat > "$T/bin/cairn" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "memories --json")
    printf '%s\n' '{"schema_version":1,"alpha":"see [[AB-1a2b]] and [[gone-key]] and [[beta]]","beta":"plain"}' ;;
  "remember --key") printf '%s\n' "\$4" >> "$T/remembered"; ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$T/bin/cairn"
config() { printf '%s\n' "$1" > "$R/.cairn/config.json"; }
run() { (cd "$R" && PATH="$T/bin:$PATH" python3 "$SCRIPT" "$@") 2>"$T/err"; }

echo "### the prefix comes from the store (.cairn/config.json), and issue links under it are left alone"
config '{"prefix": "ab"}'
out=$(run); rc=$?
chk "dry run exits 0"                          "$rc" 0
chk "AB-1a2b is NOT touched (prefixes match without case)" "$(grep -c 'AB-1a2b' <<<"$out")" 0
chk "gone-key IS de-linked"                    "$(grep -c 'delink gone-key' <<<"$out")" 1
chk "beta (exists) is not touched"             "$(grep -c 'beta' <<<"$out")" 0
chk "nothing written on a dry run"             "$([ -e "$T/remembered" ] && echo written || echo no)" no
config '{"prefix": "zz", "issue_prefixes": ["ab"]}'
chk "a prefix in issue_prefixes counts too"    "$(run | grep -c 'AB-1a2b')" 0

echo "### the SAME store under a different prefix: what used to happen with the constant"
config '{"prefix": "zz"}'                      # the store's prefix is zz; AB-1a2b is now a dangling link
out=$(run)
chk "AB-1a2b is de-linked when the store's prefix is not AB" "$(grep -c 'delink AB-1a2b' <<<"$out")" 1

echo "### no prefix -> refuse, do not guess"
rm -f "$R/.cairn/config.json"
run >/dev/null; rc=$?
chk "no config.json: exits non-zero"           "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" nonzero
chk "  says it is refusing to guess"           "$(grep -c 'Refusing to guess' "$T/err")" 1
config '{}'
run >/dev/null; rc=$?
chk "a config naming no prefix: exits non-zero" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" nonzero
chk "  says it is refusing to guess"           "$(grep -c 'refusing to guess' "$T/err")" 1

echo "### --apply writes exactly the planned edits"
config '{"prefix": "ab"}'; rm -f "$T/remembered"
run --apply >/dev/null; rc=$?
chk "apply exits 0"                            "$rc" 0
chk "one memory rewritten"                     "$(wc -l < "$T/remembered" | tr -d ' ')" 1
chk "the rewrite keeps the issue link and prunes the dead one" \
    "$(grep -c '\[\[AB-1a2b\]\].*gone-key (memory pruned)' "$T/remembered")" 1

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
