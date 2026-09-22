#!/usr/bin/env bash
# Acceptance suite for .claude/bd-prime-hook.sh — the tiering, and every way it falls back.
#
# WHY IT EXISTS
# The hook ships with an EMPTY .claude/memory-hot.txt, and its fallback test was `[ -s HOTFILE ]`,
# so a default install emitted the full `bd prime` dump (76 KB on a 40-memory store) with no
# line saying so. Tiered output and the untiered fallback looked identical from the outside
# unless you counted bytes. Every fallback now names itself; this file makes each one happen.
#
# Hermetic: a stub `bd` on PATH answers `prime` and `export`, and the hook is copied into a
# throwaway .claude/ so it resolves that root from its own location. Nothing here touches the
# real store or the real hook's working tree.
set -uo pipefail
HOOK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/.claude/bd-prime-hook.sh
[ -f "$HOOK" ] || { echo "missing: $HOOK" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required to run this suite" >&2; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

# The stub store: two memories. `prime` prints them the way bd does, between the two headers
# the hook's filter keys on; `export` writes them as JSONL. The bodies are the sentinels.
mkdir -p "$T/bin" "$T/ws/.claude"
cat > "$T/bin/bd" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  prime)
    printf '# Beads Workflow Context\n\n## Persistent Memories (2)\n\n### alpha-key\nALPHA-BODY sentinel\n\n### beta-key\nBETA-BODY sentinel\n\n## Core Rules\n- rule one\n' ;;
  export)
    out=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out=$2; shift; done
    printf '{"_type":"memory","key":"alpha-key","value":"ALPHA-BODY sentinel"}\n{"_type":"memory","key":"beta-key","value":"BETA-BODY sentinel"}\n' > "$out" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$T/bin/bd"
cp -f "$HOOK" "$T/ws/.claude/bd-prime-hook.sh"
run_hook() { (cd "$T/ws" && PATH="$T/bin:$PATH" bash .claude/bd-prime-hook.sh) 2>/dev/null; }

echo "### an EMPTY hot list is a configuration, not a fallback: index only"
: > "$T/ws/.claude/memory-hot.txt"
out=$(run_hook)
chk "no fallback banner"                    "$(grep -c 'bd-prime-hook:' <<<"$out")" 0
chk "no memory body in full"                "$(grep -c 'BODY sentinel' <<<"$out")" 0
chk "both keys in the index"                "$(grep -cE '^- (alpha|beta)-key$' <<<"$out")" 2
chk "index header says 2 more"              "$(grep -c 'index (2 more' <<<"$out")" 1

echo "### one hot key: that body in full, the other in the index"
printf 'alpha-key\n' > "$T/ws/.claude/memory-hot.txt"
out=$(run_hook)
chk "hot body emitted in full"              "$(grep -c 'ALPHA-BODY sentinel' <<<"$out")" 1
chk "cold body NOT emitted"                 "$(grep -c 'BETA-BODY sentinel' <<<"$out")" 0
chk "cold key in the index, hot key not"    "$(grep -cE '^- beta-key$' <<<"$out"):$(grep -cE '^- alpha-key$' <<<"$out")" "1:0"

echo "### every fallback names itself"
rm -f "$T/ws/.claude/memory-hot.txt"
out=$(run_hook)
chk "missing hot file -> banner"            "$(grep -c 'bd-prime-hook: .*missing.*FULL bd prime dump' <<<"$out")" 1
chk "missing hot file -> full dump follows" "$(grep -c 'BODY sentinel' <<<"$out")" 2
: > "$T/ws/.claude/memory-hot.txt"
cat > "$T/bin/bd" <<'STUB'
#!/usr/bin/env bash
case "$1" in prime) printf '## Persistent Memories (0)\n## Core Rules\n' ;; export) exit 1 ;; *) exit 0 ;; esac
STUB
out=$(run_hook)
chk "export failure -> banner names it"     "$(grep -c 'bd-prime-hook: bd export .*failed' <<<"$out")" 1

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
