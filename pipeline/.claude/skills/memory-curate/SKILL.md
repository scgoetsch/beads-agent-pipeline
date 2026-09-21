---
name: memory-curate
description: Curate the bd persistent-memory store — audit prime cost, prune dead/transient memories, dedup, compact bloated bodies, consolidate clusters, and tier hot vs situational to shrink the session-start prime dump. bd-native; a semantic engine (memory-mesh / bd find-duplicates) is an OPTIONAL accelerator, never required. Read-only audit by default; every destructive step is backed up + human-confirmed.
---

# /memory-curate — keep the bd memory store lean and load-bearing

bd injects **every** memory at prime time, so the store's size is a per-session token tax,
and bd has no decay/compaction of its own. This skill adds the missing lifecycle:
**admission → tier → periodic curate (dedup / compact / consolidate / decay)**.

- **bd is the system of record.** Every write/delete here goes to bd (`remember --key` / `forget`).
- **Semantic engine is optional.** Probe it (`memory-mesh stats`, or `bd find-duplicates`); if up,
  use it to sharpen near-dup detection and synthesis; if down/WIP, fall back to `bd memories`
  keyword clustering + your own summarization. **Never a hard dependency.**
- **Always:** export a backup first, propose a diff, human-confirm every prune/merge, stay
  idempotent, and **report the metric** (prime KB before→after) so the win is measurable.

## Modes (first arg; default `audit`)

### `audit`  — read-only report
1. **Metrics:** count = `bd memories | grep -cE '^  [a-z0-9]'`; memory payload bytes =
   `bd export --include-memories` size − `bd export` size → KB and ~tokens (KB×256).
2. **Classify** each memory into: `transient` · `retracted/superseded` · `near-dup cluster` ·
   `bloated` (>~15 lines) · `stale` (not updated > 3 months) · `KEEP-HOT` (convention/gotcha guard).
3. Report tallies + % recoverable + the top consolidation targets. **No writes.**

### `prune`  — cleanup (propose → confirm → apply)
1. **Backup:** `bd export --include-memories -o .beads/memories-backup-<YYYY-MM-DD>.jsonl`.
2. **Verify preservation (retractions):** before forgetting any retracted/superseded memory,
   confirm the active memory that still holds the fact exists **by its EXACT full key**
   (`bd memories <key>` — keys often carry a dataset or topic prefix like `acme-loadtest-…`; never match a substring
   or a guessed/truncated name). Target absent → do NOT prune; compact to "X wrong → see Y" instead.
3. **Propose:** transient + verified-retracted → `forget`; bloated → compact to 2-4 load-bearing
   lines, or move the long body to a repo doc and keep a one-line pointer.
4. Show the diff → human-confirms → apply via `bd forget <key>` / `bd remember --key <k> "<tight>"`.

### `consolidate`  — merge clusters into one canonical memory
1. **Detect** near-dup / same-topic clusters (mesh `search` if up, else `bd memories <kw>` + judgment).
2. **Synthesize** ONE canonical memory per cluster (mesh `reflect -t <topic>` if up, else summarize),
   keeping a `Supersedes:` line + `[[links]]` so the trail is traceable.
3. Confirm → `bd remember --key <merged> "<text>"` + `bd forget` the sources.

### `tier`  — the structural win (shrink prime permanently, ~340 KB → ~25 KB)
1. Classify HOT (always-relevant guards, ~top 10-20) vs SITUATIONAL.
2. Mark HOT (key-prefix or a `tier:hot` line in the body).
3. Edit `.claude/bd-prime-hook.sh` to inject **only HOT + a one-line index** of the rest, instead
   of the full `bd prime` dump.
4. Mid-session, pull situational detail on demand via `bd memories <kw>` (or mesh `search`).
   Cold-start is safe because the always-on guards are exactly what's needed before the task is known.

### `gate`  — write discipline (stop future bloat at the source) — **IMPLEMENTED**
Enforced automatically by the `PreToolUse` hook `.claude/bd-prerun-hook.sh` (no per-call action
needed). On any `bd remember`:
- **BLOCK** (exit 2, with fix instructions): missing `--key`; transient session/status state
  (`handoff`, `wrap-up`, `pushed @hash`, `status: done/blocked`, `set-up-running`, `pickup`).
- **WARN** (allowed): oversized inline body (>~1.5 KB) → keep load-bearing facts, move detail to a doc.
- Fails open on any error; scoped strictly to `bd remember` (all other commands untouched).
- Limitation: body checks only see content that is literal in the command string (not `"$(cat file)"`);
  the structural rules (`--key` present, command shape) are robust regardless.

## Decay rules (used by `audit`/`prune`)
- transient (session-handoff / status / pickup / dated one-time) → **prune**
- retracted/superseded → **prune IF** the fact lives in a named active memory, else **compact** to "X is wrong → see Y"
- near-dup ≥ threshold → **merge** (`consolidate`)
- bloated (>~15 lines / survey log) → **compact** or move to a repo doc + pointer
- not updated > 3 months → **flag for review** (don't auto-prune)

## Importance heuristic (rank hot vs prunable — no embeddings needed)
`score = is_convention_guard + reference_frequency + recency + type_weight − is_transient − length_penalty`
HOT = convention/gotcha guards + high-reference. Everything else is situational → retrieval-gated.

## Wrapping
- `/loop /memory-curate audit` (or `/loop 1w …`) for a periodic health check.
- Run `prune` / `consolidate` / `tier` interactively when audit flags enough drift.
