#!/usr/bin/env bash
# memory-curation-gate.sh — says when the bd memory store is due for curation.
#
# Incident: bd has no consolidation cadence of its own. A store that was curated once on
# 2026-09-18 then grew for weeks with nothing prompting anyone to run /memory-curate again; the
# comparison with an agent CLI whose consolidation runs automatically, gated on hours and
# sessions, made the gap plain (2026-10-06).
#
# Site-check contract (emit_site_checks in .claude/bd-prime-hook.sh): PRINT NOTHING WHEN
# HEALTHY. This prints ONE line when the store has gone uncurated for BD_CURATION_MAX_DAYS
# (default 30) or has grown by BD_CURATION_MAX_NEW memories (default 10) since the stamp.
#
# Inputs:
#   .claude/memory-curation.txt   one line: YYYY-MM-DD<TAB>memory-count at the last curation.
#                                 The installer writes it once; /memory-curate rewrites it after
#                                 ANY mode, audit included. Tracked in git so every clone agrees.
#   the current memory count      from .beads/memories.jsonl when a tracked export exists (no bd
#                                 call, no server needed), else from `bd memories`.
#
# An input it cannot read is said out loud. A gate that could not run must never look like a
# gate that passed -- that is the open-and-silent shape this hook exists to prevent.
# BD_CURATION_TODAY=YYYY-MM-DD pins "today" for the test suite.

WS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P) || {
  echo "memory curation gate: cannot resolve this clone from the script location — the gate did NOT run."
  exit 0
}
STAMP="$WS/.claude/memory-curation.txt"
EXPORT="$WS/.beads/memories.jsonl"
MAXD=${BD_CURATION_MAX_DAYS:-30}; case $MAXD in ''|*[!0-9]*) MAXD=30 ;; esac
MAXN=${BD_CURATION_MAX_NEW:-10};  case $MAXN in ''|*[!0-9]*) MAXN=10 ;; esac
HOWTO="Run /memory-curate audit (prune/consolidate if it flags drift), then stamp .claude/memory-curation.txt with today's date<TAB>memory count."

if [ ! -r "$STAMP" ]; then
  echo "memory curation gate: .claude/memory-curation.txt is missing — the gate did NOT run. $HOWTO"
  exit 0
fi
IFS=$'\t' read -r last count _ < "$STAMP" || true
case $last in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) echo "memory curation gate: stamp '$(head -c 60 "$STAMP" | tr -d '\n')' is not YYYY-MM-DD<TAB>count — the gate did NOT run. $HOWTO"; exit 0 ;;
esac
case $count in
  ''|*[!0-9]*) echo "memory curation gate: stamp count '$count' is not a number — the gate did NOT run. $HOWTO"; exit 0 ;;
esac

# Count: the tracked export first (cheap, no server), `bd memories` otherwise. bd's listing puts
# each key on a line indented by two spaces; count those lines, not the header.
if [ -r "$EXPORT" ]; then
  now=$(grep -c '^{"_type":"memory"' "$EXPORT")
elif command -v bd >/dev/null 2>&1; then
  listing=$(bd memories 2>/dev/null) || {
    echo "memory curation gate: no .beads/memories.jsonl and \`bd memories\` failed — cannot count memories, the gate did NOT run."
    exit 0
  }
  now=$(printf '%s\n' "$listing" | grep -cE '^  [a-z0-9]')
else
  echo "memory curation gate: no .beads/memories.jsonl and no bd on PATH — cannot count memories, the gate did NOT run."
  exit 0
fi

today=${BD_CURATION_TODAY:-$(date +%Y-%m-%d)}
lastep=$(date -d "$last" +%s 2>/dev/null) && nowep=$(date -d "$today" +%s 2>/dev/null) || {
  echo "memory curation gate: this date(1) cannot parse '$last' / '$today' (GNU date -d needed) — the gate did NOT run."
  exit 0
}
days=$(( (nowep - lastep) / 86400 ))
if [ "$days" -lt 0 ]; then
  echo "memory curation gate: stamp date $last is after today ($today) — the gate did NOT run. Fix the stamp."
  exit 0
fi
added=$(( now - count ))
if [ "$days" -ge "$MAXD" ] || [ "$added" -ge "$MAXN" ]; then
  echo "Memory curation due: last curated $last at $count memories; now $now ($added new) after $days days — threshold $MAXD days or $MAXN new. $HOWTO"
fi
exit 0
