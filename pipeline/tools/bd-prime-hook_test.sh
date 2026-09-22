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

# jq is OPTIONAL for the pipeline (README says so): without it the hook cannot tier and must fall
# back to the full dump, loudly. This suite used to exit 2 without jq, which made the whole
# self-test fail on a box the README calls supported. Without jq, test the fallback -- that IS
# the behaviour on this box -- and say which branch ran.
if ! command -v jq >/dev/null 2>&1; then
  echo "### jq is absent here: the hook must fall back to the full dump and say so (tiering untestable)"
  : > "$T/ws/.claude/memory-hot.txt"
  out=$(run_hook)
  chk "first line names the missing jq and the fallback" "$(printf '%s' "$out" | head -1 | grep -c 'jq is not installed.*FULL bd prime dump')" 1
  chk "the rules still follow"                          "$(grep -c 'MANDATORY SESSION RULES' <<<"$out")" 1
  chk "the full dump follows"                           "$(grep -c 'BODY sentinel' <<<"$out")" 2
  echo
  printf 'RESULT: %d passed, %d failed (jq absent: fallback path only)\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]; exit
fi

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

echo "### a hot key that is not in the store is named, and the index arithmetic stays right"
# Counting raw lines of memory-hot.txt made EXPECT != GOT here, and the hook then printed
# "INDEX IS INCOMPLETE ... fix .claude/bd-prime-hook.sh" on every session: a false alarm that
# pointed at the wrong file. Duplicates counted twice for the same reason.
printf 'alpha-key\nno-such-key\nalpha-key\n' > "$T/ws/.claude/memory-hot.txt"
out=$(run_hook)
chk "unknown hot key is named in a warning"  "$(grep -c '>   no-such-key' <<<"$out")" 1
chk "no false INDEX IS INCOMPLETE"           "$(grep -c 'INDEX IS INCOMPLETE' <<<"$out")" 0
chk "HOT tier counts the ONE real key"       "$(grep -c 'HOT tier (1 always-loaded guards of 2 total)' <<<"$out")" 1
chk "duplicate hot key emitted once"         "$(grep -c 'ALPHA-BODY sentinel' <<<"$out")" 1
chk "index still lists beta only"            "$(grep -cE '^- beta-key$' <<<"$out"):$(grep -c 'index (1 more' <<<"$out")" "1:1"

echo "### scratch files are per process — nothing fixed under /tmp"
rm -f /tmp/bd-prime-mm.jsonl /tmp/bd-prime-index /tmp/bd-prime-err   # the old fixed names
run_hook >/dev/null
chk "no fixed-name scratch file created under /tmp" "$(ls -d /tmp/bd-prime-mm.jsonl /tmp/bd-prime-index /tmp/bd-prime-err 2>/dev/null | wc -l)" 0
chk "its temp dir is removed on exit"           "$(ls -d "${TMPDIR:-/tmp}"/bd-prime.* 2>/dev/null | wc -l)" 0

echo "### a store with no memories yet is tiered as 0 of 0, not treated as a failed export"
# The normal state of a fresh project. This used to print the fallback banner on every session
# until the first `bd remember`.
: > "$T/ws/.claude/memory-hot.txt"
cat > "$T/bin/bd" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  prime)  printf '# Beads Workflow Context\n\n## Persistent Memories (0)\n\n## Core Rules\n- rule one\n' ;;
  export) out=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out=$2; shift; done; : > "$out" ;;
  *) exit 0 ;;
esac
STUB
out=$(run_hook)
chk "empty store -> no fallback banner"     "$(grep -c 'bd-prime-hook:' <<<"$out")" 0
chk "empty store -> 0 of 0 total"           "$(grep -c 'HOT tier (0 always-loaded guards of 0 total)' <<<"$out")" 1
chk "empty store -> says so in words"       "$(grep -c 'no memories yet' <<<"$out")" 1
# restore the two-memory stub for the fallback cases below
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

echo "### a clone whose hooks are not wired is told so, at the top"
# core.hooksPath is local config; a clone has the guards in the tree and nothing running them.
git -C "$T/ws" init -q 2>/dev/null; mkdir -p "$T/ws/.beads-hooks"; printf '#!/bin/sh\n' > "$T/ws/.beads-hooks/pre-commit"
out=$(run_hook)
chk "unwired clone -> alarm before the rules"  "$(printf '%s' "$out" | head -1 | grep -c 'GUARDS ARE NOT WIRED')" 1
git -C "$T/ws" config core.hooksPath .beads-hooks
out=$(run_hook)
chk "wired (relative path) -> no alarm"        "$(grep -c 'NOT WIRED' <<<"$out")" 0
git -C "$T/ws" config core.hooksPath "$T/ws/.beads-hooks"
out=$(run_hook)
chk "wired (absolute path, as bd 1.3 sets it) -> no alarm" "$(grep -c 'NOT WIRED' <<<"$out")" 0

echo "### site checks: output is an alarm, silence is health, and a missing timeout is named"
mkdir -p "$T/ws/.claude/site-checks"
printf '#!/usr/bin/env bash\necho "MOUNT-DOWN sentinel"\n'        > "$T/ws/.claude/site-checks/mount.sh"
printf '#!/usr/bin/env bash\nexit 0\n'                             > "$T/ws/.claude/site-checks/quiet.sh"
printf '#!/usr/bin/env bash\necho "STDERR-ONLY sentinel" >&2\n'   > "$T/ws/.claude/site-checks/noisy-stderr.sh"
chmod +x "$T/ws/.claude/site-checks/"*.sh
out=$(run_hook)
chk "a check that prints becomes a SITE CHECK block"  "$(grep -c 'SITE CHECK — mount' <<<"$out")" 1
chk "its output is in the payload"                     "$(grep -c 'MOUNT-DOWN sentinel' <<<"$out")" 1
chk "a silent check adds nothing"                      "$(grep -c 'SITE CHECK — quiet' <<<"$out")" 0
chk "a check that speaks on stderr is heard too"       "$(grep -c 'STDERR-ONLY sentinel' <<<"$out")" 1
chk "with timeout present, no UNBOUNDED notice"        "$(grep -c 'run UNBOUNDED' <<<"$out")" 0
# Hide `timeout`: a PATH of symlinks to everything else the hook needs. The checks must still run
# and the payload must say they ran unbounded -- not skip them in silence, which is what
# `out=$(timeout 20 "$f" 2>/dev/null) || true` did on a box with no timeout (stock macOS).
mkdir -p "$T/notimeout"
for tool in bash sh mktemp rm cp chmod mkdir cat grep head tail wc git dirname basename ls sed awk sort \
            cut tr date env jq readlink realpath find xargs tee uniq mv touch python3; do
  b=$(command -v "$tool" 2>/dev/null) && ln -sf "$b" "$T/notimeout/$tool"
done
out=$(cd "$T/ws" && PATH="$T/bin:$T/notimeout" bash .claude/bd-prime-hook.sh 2>/dev/null)
chk "no timeout: the payload says checks run UNBOUNDED" "$(grep -c 'run UNBOUNDED' <<<"$out")" 1
chk "no timeout: the check still ran"                  "$(grep -c 'MOUNT-DOWN sentinel' <<<"$out")" 1
rm -rf "$T/ws/.claude/site-checks"

echo "### this suite's no-jq branch: run it again with jq hidden, and require it to pass"
# A PATH of symlinks to everything the fallback path needs, minus jq. If the nested run exits
# non-zero, a jq-less box would fail the whole self-test while the README calls jq optional.
mkdir -p "$T/nojq"
for tool in bash sh mktemp rm cp chmod mkdir cat grep head tail wc git dirname ls sed awk sort cut tr date env timeout; do
  b=$(command -v "$tool" 2>/dev/null) && ln -sf "$b" "$T/nojq/$tool"
done
nested=$(PATH="$T/nojq" bash "${BASH_SOURCE[0]}" 2>&1); nrc=$?
chk "nested run without jq exits 0"          "$nrc" 0
chk "and it says it took the fallback branch" "$(grep -c 'jq absent: fallback path only' <<<"$nested")" 1

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
