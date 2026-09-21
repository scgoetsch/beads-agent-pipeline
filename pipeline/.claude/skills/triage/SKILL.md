---
name: triage
description: One triage cycle over the bd work queue (ALL projects) — resume check, surface the top ready item, load its prior context from bd memories, classify it, and draft a short plan-of-attack + single next action, WITHOUT claiming or executing. Read-only by default. Wrap in /loop or /schedule for recurring morning triage.
---

# /triage — surface + plan the top ready bead

Project-agnostic. The bd queue usually spans several projects at once. Triage is the generic
front end that reads the queue and **proposes**; it does **not** execute. Deep planning,
execution, the maker/checker verifier, and landing are separate, gated steps.

Keep token cost low: light memory search, short plan, do **not** open every file. A triage pass
that reads the whole repo costs more than the work it was triaging.

## Steps

1. **Resume check.** `bd list --status in_progress 2>/dev/null`. **Default rule: treat
   in_progress as parked / long-running and do NOT front-run it** — surface the top OPEN item
   instead. Resume an in_progress item only if asked, or if one was updated very recently
   (genuinely mid-flight, not parked). Always report the in_progress count so nothing is
   silently dropped.

2. **Surface.** `bd ready --json`. Pick the top OPEN item by **(priority asc, then created_at
   asc)**. Name 1-2 close runners-up in one line. If nothing is ready → say so and exit.

3. **Contextualize — don't re-derive.** Infer the item's **domain** from its title / desc /
   labels, then load the conventions that govern THAT domain from CLAUDE.md +
   `bd memories <key terms>`. Invariants are looked up **per item, never assumed**. Examples of
   domain → invariant (illustrative — write your own in AGENTS.md):
   - work on a dataset with a canonical/derived split → the convention that says which one is
     authoritative, so the item does not quietly re-derive it.
   - any committed markdown / report / figure → whatever doc-hygiene rules the repo enforces.
   - heavy compute → your submit path, plus the memories about it.
   Pull only the 1-3 most relevant.

4. **Classify** into exactly one:
   - `loop-can-do` — mechanical/local, safe to draft + execute behind the verifier.
   - `needs-cluster` — heavy compute → route to your submit path. Triage stops at the submit plan.
   - `needs-human-decision` — scientific judgment or scope call → name the decision; don't guess.

5. **Plan (short).** 3-6 step plan-of-attack + the **single concrete next action**. List the
   domain invariants the eventual checker must enforce on land (from step 3) plus the always-on
   ones (`bd remember` + push on close).

6. **Propose — do not claim or execute.** Offer: claim it (`bd update <id> --claim`) · open the
   full implementation plan · skip to next · resume an in_progress item. Act only on explicit go.

## Modes (args)
- _default_: read-only — surface + plan + propose. No writes.
- `--claim`: also claim the selected item.   `--comment`: post the plan as a bd comment.
- `<issue-id>`: triage that specific id.   `<project term>`: restrict to items matching a project.

## Wrapping as an automation
- Ad-hoc recurring: `/loop /triage` (model-paced) or `/loop 24h /triage`.
- Scheduled cloud: `/schedule` a daily morning run. Keep it **propose-only when unattended** —
  unattended loops make unattended mistakes; a human approves before any execute/claim/land.
