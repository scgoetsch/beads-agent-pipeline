# Skills

Two skills ship with the pipeline. **Both are inert until invoked** — a skill is a prompt your
agent loads on request, not a hook. Nothing here runs at session start, on commit, or in the
background, so leaving them installed costs you nothing at runtime.

They are also **safe to delete**: `rm -rf .claude/skills/<name>`. Nothing else in the pipeline
references them, and no guard fails if they are gone.

They are documented here rather than hidden behind an installer flag because their cost is zero
until you type their name — but they do carry assumptions, and those assumptions are below.

## What a skill assumes in general

- **bd is present and initialised.** Both skills read the bd store. Without `.beads/` they have
  nothing to work on.
- **Slash-command invocation is a harness feature.** `/memory-curate` and `/triage` are how
  Claude Code invokes them. In another harness, the `SKILL.md` body is still a perfectly good
  prompt — point your agent at the file.
- **They propose; they do not land.** Neither writes to your repo without saying so first.

---

## `memory-curate`

Keeps the bd memory store lean. bd injects memories at prime time and has no decay or compaction
of its own, so the store's size is a per-session token tax. This adds the missing lifecycle:
admission → tier → periodic curate (dedup, compact, consolidate, decay).

| | |
| --- | --- |
| **Requires** | `bd` |
| **Optional** | a semantic engine — `memory-mesh` or `bd find-duplicates`. It is **probed, never required**, and the skill falls back to bd-native comparison when absent. |
| **Assumes** | the hot/index tiering this pipeline installs (`.claude/memory-hot.txt`). Without it the "tier" mode has nothing to tier. |
| **Safety** | read-only audit by default; every destructive step is backed up and human-confirmed. |
| **Harness extras** | `/loop /memory-curate audit` for a periodic health check. Optional. |

Run the audit before trusting any of the pruning modes. The interesting output is usually the
prime-cost breakdown — it tells you which memories are actually expensive.

## `triage`

One read-only pass over the bd queue: resume check, surface the top ready issue, load its prior
context from memories, classify it, and draft a short plan plus a single next action. It does
**not** claim or execute.

| | |
| --- | --- |
| **Requires** | `bd`, and `bd ready --json` |
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
