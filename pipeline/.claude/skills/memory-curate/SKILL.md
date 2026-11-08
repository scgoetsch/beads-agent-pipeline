---
name: memory-curate
description: Curate the cairn persistent-memory store — audit prime cost, prune dead/transient memories, dedup, compact bloated bodies, consolidate clusters, and tier hot vs situational to shrink the session-start prime dump. cairn-native; a semantic engine (memory-mesh) is an OPTIONAL accelerator, never required. Read-only audit by default; every destructive step is backed up + human-confirmed.
---

# /memory-curate — keep the cairn memory store lean and load-bearing

Prime injects every memory KEY at session start, plus the bodies of the hot tier
(`.claude/memory-hot.txt`), so the key list and the hot bodies are a per-session token tax,
and the store has no decay/compaction of its own. This skill adds the missing lifecycle:
**admission → tier → periodic curate (dedup / compact / consolidate / decay)**.

- **cairn is the system of record.** Every write/delete here goes to cairn (`cairn remember --key` /
  `cairn forget`). Every replaced body stays readable: `cairn history --memory <key>`.
- **Semantic engine is optional.** Probe it (`memory-mesh stats`); if up, use it to sharpen
  near-dup detection and synthesis; if down/WIP, fall back to `cairn memories`
  keyword clustering + your own summarization. **Never a hard dependency.**
- **Always:** export a backup first, propose a diff, human-confirm every prune/merge, stay
  idempotent, and **report the metric** (prime KB before→after) so the win is measurable.

## Modes (first arg; default `audit`)

### `audit`  — read-only report
1. **Metrics:** count = `grep -c '^{"_type":"memory"' .cairn/memories.jsonl`; memory payload bytes =
   `cairn export --include-memories` size − `cairn export` size → KB and ~tokens (KB×256).
2. **Classify** each memory into: `transient` · `retracted/superseded` · `near-dup cluster` ·
   `bloated` (>~15 lines) · `stale` (not updated > 3 months) · `KEEP-HOT` (convention/gotcha guard).
3. Report tallies + % recoverable + the top consolidation targets. **No writes.**

### `prune`  — cleanup (propose → confirm → apply)
1. **Backup:** `cairn export --include-memories -o .cairn/memories-backup-<YYYY-MM-DD>.jsonl`
   (`.cairn/` is git-ignored; git and `cairn history --memory` keep the old bodies as well).
2. **Verify preservation (retractions):** before forgetting any retracted/superseded memory,
   confirm the active memory that still holds the fact exists **by its EXACT full key**
   (`cairn recall <key>` — keys often carry a dataset or topic prefix like `acme-loadtest-…`; never match a substring
   or a guessed/truncated name). Target absent → do NOT prune; compact to "X wrong → see Y" instead.
3. **Propose:** transient + verified-retracted → `forget`; bloated → compact to 2-4 load-bearing
   lines, or move the long body to a repo doc and keep a one-line pointer.
4. Show the diff → human-confirms → apply via `cairn forget <key>` / `cairn remember --key <k> "<tight>"`.

### `consolidate`  — merge clusters into one canonical memory
1. **Detect** near-dup / same-topic clusters (mesh `search` if up, else `cairn memories <kw>` + `cairn related <key>` + judgment).
2. **Synthesize** ONE canonical memory per cluster (mesh `reflect -t <topic>` if up, else summarize),
   keeping a `Supersedes:` line + `[[links]]` so the trail is traceable.
3. Confirm → `cairn remember --key <merged> "<text>"` + `cairn forget` the sources.

### `tier`  — the structural win (shrink prime permanently; measured 76 KB → 7 KB on a 40-memory store)
The tiering itself is already built: `.claude/bd-prime-hook.sh` injects the memories listed in
`.claude/memory-hot.txt` in full and a key-only index of the rest. **Do not edit the hook** — an
earlier version of this skill said to, and following it would rewrite a tested file. This mode
decides what goes on the list:
1. Classify HOT (always-relevant guards, ~top 10-20) vs SITUATIONAL.
2. Write the HOT keys to `.claude/memory-hot.txt`, one per line. Keys not in the store are named
   at the next session start rather than silently ignored. **Mind the budget:** the hook trims
   to `BD_PRIME_BUDGET` (default 10,000 bytes, the Claude Code cap) and names any hot body that
   did not fit — on Claude Code that is roughly 8 KB of bodies in total. A hot list that
   overflows is not hot; compact the bodies or shorten the list until the top line is gone.
3. Mid-session, pull situational detail on demand via `cairn memories <kw>` (or mesh `search`).
   Cold-start is safe because the always-on guards are exactly what's needed before the task is known.

### `gate`  — write discipline (stop future bloat at the source) — **IMPLEMENTED**
Enforced automatically by the `PreToolUse` hook `.claude/bd-prerun-hook.sh` (no per-call action
needed). On any `cairn remember`:
- **BLOCK** (exit 2, with fix instructions): missing `--key`; a body that is STRUCTURALLY a
  handoff memo (status lines, next-step lists, commit hashes as state). The test is structural:
  the words `handoff`, `wrap-up`, `pickup` alone only WARN, because a vocabulary blocklist once
  refused the memory that documented the rule while a rephrase walked through.
- **WARN** (allowed): oversized inline body (>~1.5 KB) → keep load-bearing facts, move detail to a doc.
- Fails open on any error; scoped strictly to `remember` (all other commands untouched).
- cairn's own `remember` adds admission control on top: a long body that near-duplicates another
  key is refused with that key named (cairn README, "Memory links").
- Limitation: body checks only see content that is literal in the command string (not `"$(cat file)"`);
  the structural rules (`--key` present, command shape) are robust regardless.

## Decay rules (used by `audit`/`prune`)
- transient (session-handoff / status / pickup / dated one-time) → **prune**
- retracted/superseded → **prune IF** the fact lives in a named active memory, else **compact** to "X is wrong → see Y"
- near-dup ≥ threshold → **merge** (`consolidate`)
- bloated (>~15 lines / survey log) → **compact** or move to a repo doc + pointer
- not updated > 3 months → **flag for review** (don't auto-prune)

## Importance heuristic (rank hot vs prunable — no embeddings needed)
`cairn memories --rank` computes the graph half: PageRank over the `[[links]]` times recency
(half-life 90 days), superseded keys × 0.1 (`--json` for the numbers). Add judgment for what a
graph cannot see:
`score = rank + is_convention_guard + type_weight − is_transient − length_penalty`
HOT = convention/gotcha guards + high rank. Everything else is situational → retrieval-gated.

## Stamp — after ANY mode, audit included
The session-start gate (`.claude/site-checks/memory-curation-gate.sh`) reads
`.claude/memory-curation.txt` — one line, `YYYY-MM-DD<TAB>memory-count` — and prints a
"Memory curation due" notice once the store is 30 days or 10 memories past it (env
`BD_CURATION_MAX_DAYS` / `BD_CURATION_MAX_NEW`). The installer writes the stamp once; every run
of this skill ends by rewriting it and committing it with the curation:

```bash
printf '%s\t%s\n' "$(date +%F)" "$(/usr/bin/grep -c '^{"_type":"memory"' .cairn/memories.jsonl)" > .claude/memory-curation.txt
```

The count is the one the gate makes: memory rows of the tracked export (refresh it first,
`tools/refresh-beads-exports.sh`). `/usr/bin/grep`, not a bare `grep`: an agent shell's wrapper
can print nothing instead of a count.

An audit that finds nothing to do still stamps — otherwise the gate nags every session. The
gate replaces the old advice to wrap `audit` in `/loop`; run `prune` / `consolidate` / `tier`
interactively when the audit flags enough drift.
