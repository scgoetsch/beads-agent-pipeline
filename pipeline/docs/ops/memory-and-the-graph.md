# Memory: what goes in, and the graph over it

`cairn remember` is the durable store. The rules that keep it useful are about *admission* and
*linking*, not volume — a store nobody trusts is worse than a small one.

## What belongs in a memory

A memory is a **load-bearing fact that outlives the session**: a convention, a measured number
with its method, a trap and how to avoid it, a tool's real behaviour. Write the key as a sentence
(`set-e-pipeline-assignment-kills-the-branch-below`), because the key is what the session-start
index shows.

What does **not** belong: session state, handoff notes, task lists, "where I left off". That is
what issue notes (`cairn note <id>`) and commit messages are for. `.claude/bd-prerun-hook.sh`
enforces this at write time — it blocks `cairn remember` without `--key`, and blocks bodies that
are structurally a handoff memo.

That gate is deliberately **structural, not lexical**. An earlier version blocked on vocabulary —
any body containing "handoff", "wrap-up" and so on — which matched memories that merely *mentioned*
the pattern (a memory documenting the rule blocked itself) while a determined write got through by
rephrasing. It was strongest against its own documentation and weakest against the thing it
existed to prevent. If you tighten it, tighten the structure test.

## Every `--<field>` is a SET, not an append

`cairn update <id> --notes "..."` REPLACES the notes. `cairn remember --key X` REPLACES the body
(the old one stays readable in `cairn history --memory X`). Use `cairn note <id>` to add to a
running record, and `cairn recall <key>` immediately before any `cairn remember` you intend as an
edit. With more than one session running the same rule becomes a
race — see `docs/ops/concurrent-sessions.md`, installed only with `install.sh --with-concurrent`.

## The hot tier

`.claude/memory-hot.txt` lists, one key per line and in priority order, memories selected for
**full** injection at session start *when they fit the host budget*. Omitted HOT bodies are named
at the top. Other memories appear in a key-only index; if its keys alone exceed the budget, no keys are
listed and one **INDEX OMITTED** line gives the count instead (an arbitrary prefix of keys told the
reader almost nothing). Search the whole store with
`cairn memories <keyword>` and fetch a body with `cairn recall <key>`.

Keep the hot list to recurring-mistake guards — the things an agent must not rediscover the hard
way. Two measurements from a live store that shaped this design:

- A 70-character preview per index entry cost 38,480 bytes of a 76,290-byte payload: half the
  hook, spent restating keys that are already full sentences. Keys only.
- The host keeps far less than the hook can emit. Claude Code shows a 2,000-byte preview of any
  one SessionStart hook output above 10,000 bytes and files the rest (measured 2026-09-22;
  anthropics/claude-code#70460); an earlier ~39 KB figure was wrong. **Anything appended at the
  bottom is invisible precisely when it matters**, which is why alarms come first, the index comes
  before the hot bodies, and the hook trims to `BD_PRIME_BUDGET` (default 10000) rather than
  letting the host trim for it: it names omitted HOT bodies and replaces an index that cannot fit
with an explicit INDEX OMITTED line, whereas what the host drops nobody sees.

An empty `memory-hot.txt` is fine and is how it ships: the hook emits the rules, cairn's context and a
key-only index (replaced by an INDEX OMITTED line on large stores), with nothing in full. It does NOT fall back to the full `cairn prime`
dump for an empty list (an earlier version did, silently); it falls back only when it cannot tier at
all — no `jq`, no hot file, a failed export — and then says so on its first line.

## The graph

`[[wikilinks]]` in memory bodies form a typed graph, and the store keeps it: the bodies stay the
source, and the links are parsed from them in the same transaction as every `remember` and
`forget`.

- Bare `[[key]]` means *related*. Type it when the relation is causal: `supersedes::`,
  `depends-on::`, `contradicts::`, `justified-by::`, `refines::`.
- **Links live in the NEWER memory, and targets must already exist.**
- **Admission** is `cairn remember` itself. A body of 20 words or more that nearly duplicates
  ANOTHER key is refused, exit 1, naming that key and the update recipe (a shorter one is stored
  with the advice); `--force` stores it anyway. A key the body `supersedes::` is not a candidate,
  and rewriting the same key is never refused. A related body that links to no memory is stored,
  with the keys worth linking named on stderr.
- **Checking:** `cairn check` reports dangling and self links as errors and explains a link to a
  deleted key; it also checks the issues (dangling dependencies, a second parent, a `blocks`
  cycle). The pre-commit runs it.
- **Walking and ranking:** `cairn related <key>` lists a memory's links, out and in (`--depth`
  walks them); `cairn memories --rank` orders the store by the link graph (PageRank times recency,
  superseded keys discounted), which is what the memory-curate skill's tier mode starts from.
- **To supersede:** write the corrected body under an accurate key with `supersedes::[[old-key]]`,
  run `cairn related old-key` to find the inbound links and repoint them, `cairn check`, then
  `cairn forget old-key`.
- **Timestamps, earlier bodies and deletions** are in cairn's own history (`cairn history --memory
  <key>`, and `.cairn/events.jsonl` in git), so there is no separate ledger to commit.

Before 0.2.0 an optional memory-graph tool did the admission, check, rank and lineage jobs, with
a ledger file of its own; cairn absorbed them with the same notation and thresholds, so bodies
written under it carry over unchanged, and the pipeline no longer ships its pre-commit stanza.

`.claude/skills/memory-curate/audit_wikilinks.py` repairs dangling links in bulk. Its
repoint table ships empty on purpose: you fill it in per repair, and only for successors you have
verified carry the same claim. A link that points somewhere plausible but wrong is worse than one
that is visibly broken, because nothing will flag it again.
