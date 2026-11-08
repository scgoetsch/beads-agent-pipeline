# Skills

Two skills ship with the pipeline. **Both are inert until invoked** — a skill is a prompt your
agent loads on request, not a hook. Nothing here runs at session start, on commit, or in the
background, so leaving them installed costs you nothing at runtime.

They are also **safe to delete**: `rm -rf .claude/skills/<name>`. Nothing else in the pipeline
references them, and no guard fails if they are gone.

They are documented here rather than hidden behind an installer flag because their cost is zero
until you type their name — but they do carry assumptions, and those assumptions are below.

## What a skill assumes in general

- **cairn is present and the store initialised.** Both skills read the cairn store. Without
  `.cairn/` (`cairn init -p <PREFIX>`) they have nothing to work on.
- **Slash-command invocation is a harness feature.** `/memory-curate` and `/triage` are how
  Claude Code invokes them. In another harness, the `SKILL.md` body is still a perfectly good
  prompt — point your agent at the file.
- **They propose; they do not land.** Neither writes to your repo without saying so first.

---

## `memory-curate`

Keeps the cairn memory store lean. The session-start hook injects every memory key and the hot
bodies, and the store has no decay or compaction of its own, so its size is a per-session token
tax. This adds the missing lifecycle:
admission → tier → periodic curate (dedup, compact, consolidate, decay).

| | |
| --- | --- |
| **Requires** | `cairn` (its `audit_wikilinks.py` reads the issue prefix from `.cairn/config.json`) |
| **Optional** | a semantic engine — `memory-mesh`. It is **probed, never required**, and the skill falls back to cairn-native comparison (`cairn memories`, `cairn related`, `cairn memories --rank`) when absent. |
| **Assumes** | the hot/index tiering this pipeline installs (`.claude/memory-hot.txt`). Without it the "tier" mode has nothing to tier. |
| **Safety** | read-only audit by default; every destructive step is backed up and human-confirmed. |
| **Cadence** | the session-start gate `.claude/site-checks/memory-curation-gate.sh` asks for an audit once the store is 30 days or 10 memories past the stamp in `.claude/memory-curation.txt`; every run of the skill ends by rewriting that stamp. No `/loop` needed. |

Run the audit before trusting any of the pruning modes. The interesting output is usually the
prime-cost breakdown — it tells you which memories are actually expensive.

## `triage`

One read-only pass over the cairn queue: resume check, surface the top ready issue, load its prior
context from memories, classify it, and draft a short plan plus a single next action. It does
**not** claim or execute.

| | |
| --- | --- |
| **Requires** | `cairn`, and `cairn ready --json` — or, when the repo keeps a project registry (a projects.tsv with a projects.py beside it under tools/, not shipped here), that tool's `ready` and `audit` modes, which group the queue by ACTIVE project. |
| **Assumes** | a queue worth triaging. It was written where the queue spanned several projects; with one project it still works, it just has less to disambiguate. |
| **Safety** | read-only by default. `--claim` and `--comment` are explicit opt-ins. |
| **Harness extras** | `/loop /triage` or `/schedule` for a recurring morning pass. Optional — and keep it **propose-only when unattended**. |

**One thing it references that this pipeline does not provide:** step 4 classifies work as
`loop-can-do` — "safe to draft and execute behind the verifier" — and the Modes section mentions a
maker/checker verifier. That verifier is **yours to define**; there is no verifier in this repo.
Until you have one, read `loop-can-do` as "small enough that you would review the diff in one
sitting", and treat the classification as advice rather than authorisation.

Its domain-invariant step (3) is deliberately generic and is the part most worth editing: replace
the illustrative examples with the conventions from your own `AGENTS.md`, so triage loads the
rules that actually govern the work instead of guessing.
