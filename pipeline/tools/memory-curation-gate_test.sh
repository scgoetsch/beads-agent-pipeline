#!/usr/bin/env bash
# Test for .claude/site-checks/memory-curation-gate.sh: tries to make the gate stay silent when
# it should speak, and speak when it should stay silent.
#
# Hermetic: the gate is COPIED into a scratch clone so it resolves that clone from its own
# location (the portability rule), with a fabricated stamp and memories export, and a stub `bd`
# on a private PATH for the no-export branch. "Today" is pinned with BD_CURATION_TODAY. Nothing
# here touches the real .claude/ or .beads/.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
GATE="$HERE/.claude/site-checks/memory-curation-gate.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

ws="$T/ws"; mkdir -p "$ws/.claude/site-checks" "$ws/.beads"
cp "$GATE" "$ws/.claude/site-checks/" && chmod +x "$ws/.claude/site-checks/memory-curation-gate.sh"
G="$ws/.claude/site-checks/memory-curation-gate.sh"
export BD_CURATION_TODAY=2026-10-06
rows() { : > "$ws/.beads/memories.jsonl"; for i in $(seq 1 "$1"); do printf '{"_type":"memory","key":"k%d"}\n' "$i" >> "$ws/.beads/memories.jsonl"; done; }
stamp() { printf '%s\t%s\n' "$1" "$2" > "$ws/.claude/memory-curation.txt"; }
run() { out=$("$G" 2>&1); rc=$?; }

echo "### healthy: fresh stamp, little growth -> prints nothing, exits 0"
rows 100; stamp 2026-10-01 95; run
chk "silent when within both thresholds"          "$out" ""
chk "exit 0 when silent"                          "$rc" 0

echo "### age: 45 days since the stamp -> fires and names the days"
rows 100; stamp 2026-08-22 100; run
chk "fires on age"                                "$(grep -c '^Memory curation due' <<<"$out")" 1
chk "names 45 days"                               "$(grep -c 'after 45 days' <<<"$out")" 1
chk "names the stamp date and count"              "$(grep -c '2026-08-22 at 100 memories' <<<"$out")" 1
chk "still exits 0 (a monitor must not fail session start)" "$rc" 0

echo "### growth: 12 new memories in 5 days -> fires and names the growth"
rows 112; stamp 2026-10-01 100; run
chk "fires on growth"                             "$(grep -c '^Memory curation due' <<<"$out")" 1
chk "names 12 new"                                "$(grep -c '(12 new)' <<<"$out")" 1
chk "names the command to run"                    "$(grep -c '/memory-curate audit' <<<"$out")" 1

echo "### boundaries: exactly at threshold fires, one under does not"
rows 110; stamp 2026-10-01 100; run
chk "10 new (== default max) fires"               "$(grep -c '^Memory curation due' <<<"$out")" 1
rows 109; stamp 2026-10-01 100; run
chk "9 new stays silent"                          "$out" ""
rows 100; stamp 2026-09-06 100; run
chk "30 days (== default max) fires"              "$(grep -c 'after 30 days' <<<"$out")" 1
rows 100; stamp 2026-09-07 100; run
chk "29 days stays silent"                        "$out" ""

echo "### thresholds are overridable, and junk overrides fall back to the defaults"
rows 112; stamp 2026-10-01 100
out=$(BD_CURATION_MAX_NEW=20 "$G" 2>&1); chk "MAX_NEW=20 silences 12 new"     "$out" ""
out=$(BD_CURATION_MAX_NEW=abc "$G" 2>&1); chk "junk MAX_NEW -> default 10, fires" "$(grep -c '^Memory curation due' <<<"$out")" 1
rows 100; stamp 2026-09-20 100
out=$(BD_CURATION_MAX_DAYS=10 "$G" 2>&1); chk "MAX_DAYS=10 fires at 16 days" "$(grep -c '^Memory curation due' <<<"$out")" 1

echo "### a gate that cannot run says so -- never silent"
rows 100; rm -f "$ws/.claude/memory-curation.txt"; run
chk "missing stamp -> 'did NOT run'"              "$(grep -c 'did NOT run' <<<"$out")" 1
chk "missing stamp names the file"                "$(grep -c 'memory-curation.txt is missing' <<<"$out")" 1
printf 'yesterday\t5\n' > "$ws/.claude/memory-curation.txt"; run
chk "malformed date -> 'did NOT run'"             "$(grep -c 'did NOT run' <<<"$out")" 1
printf '2026-10-01\tlots\n' > "$ws/.claude/memory-curation.txt"; run
chk "non-numeric count -> 'did NOT run'"          "$(grep -c 'did NOT run' <<<"$out")" 1
printf '2026-10-01 100\n' > "$ws/.claude/memory-curation.txt"; run
chk "space instead of TAB -> 'did NOT run'"       "$(grep -c 'did NOT run' <<<"$out")" 1
rows 100; stamp 2026-12-01 100; run
chk "stamp in the future -> 'did NOT run'"        "$(grep -c 'did NOT run' <<<"$out")" 1
chk "every loud path still exits 0"               "$rc" 0

echo "### no export: counts through bd; without bd it says so"
# A private PATH: symlinks to every tool the gate needs, plus a stub bd whose listing has 115
# keys in bd's two-space-indented shape under a header line that must not be counted.
mkdir -p "$T/bin"
for tool in bash sh grep head tr wc date cat sed dirname seq; do p=$(command -v "$tool") && ln -sf "$p" "$T/bin/$tool"; done
printf '#!/usr/bin/env bash\n[ "$1" = memories ] || exit 1\necho "Memories matching \\"\\":"\nfor i in $(seq 1 115); do printf "  key-%%03d\\n    body\\n" "$i"; done\n' > "$T/bin/bd"; chmod +x "$T/bin/bd"
rm -f "$ws/.beads/memories.jsonl"; stamp 2026-10-01 100
out=$(PATH="$T/bin" "$G" 2>&1); rc=$?
chk "no export + stub bd: counts 115 keys, 15 new -> fires" "$(grep -c '(15 new)' <<<"$out")" 1
chk "header and body lines are not counted"       "$(grep -c 'now 115 ' <<<"$out")" 1
printf '#!/usr/bin/env bash\nexit 3\n' > "$T/bin/bd"
out=$(PATH="$T/bin" "$G" 2>&1); rc=$?
chk "no export + failing bd -> 'did NOT run'"      "$(grep -c 'did NOT run' <<<"$out")" 1
rm -f "$T/bin/bd"
out=$(PATH="$T/bin" "$G" 2>&1); rc=$?
chk "no export + no bd -> 'did NOT run'"           "$(grep -c 'did NOT run' <<<"$out")" 1
chk "...and names both missing sources"            "$(grep -c 'no .beads/memories.jsonl and no bd' <<<"$out")" 1
chk "exit 0 on every counting failure"             "$rc" 0
rows 100; stamp 2026-10-01 100
out=$(PATH="$T/bin" "$G" 2>&1)
chk "export present: bd is not consulted (no bd on PATH, still silent)" "$out" ""

echo "### the export is counted by memory rows, not by lines of anything"
rows 100; printf '{"_type":"issue","id":"WS-x"}\n' >> "$ws/.beads/memories.jsonl"; stamp 2026-10-01 100; run
chk "an issue row does not count as a memory"     "$out" ""

echo "### stays well under the hook's 1500-byte site-check cap"
rows 150; stamp 2026-07-01 100; run
chk "firing line under 600 bytes"                 "$([ "$(printf '%s' "$out" | wc -c)" -lt 600 ] && echo yes || echo no)" yes
chk "one line, not a dump"                        "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 1

echo "### the real clone's gate runs from its own location"
out=$(BD_CURATION_TODAY= "$GATE" 2>&1); rc=$?
chk "real gate exits 0"                           "$rc" 0
chk "real gate prints nothing or one line"        "$([ -z "$out" ] || [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] && echo ok)" ok

printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
