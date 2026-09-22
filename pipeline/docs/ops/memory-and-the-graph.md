# Memory: what goes in, and the graph over it

`bd remember` is the durable store. The rules that keep it useful are about *admission* and
*linking*, not volume — a store nobody trusts is worse than a small one.

## What belongs in a memory

A memory is a **load-bearing fact that outlives the session**: a convention, a measured number
with its method, a trap and how to avoid it, a tool's real behaviour. Write the key as a sentence
(`set-e-pipeline-assignment-kills-the-branch-below`), because the key is what the session-start
index shows.

What does **not** belong: session state, handoff notes, task lists, "where I left off". That is
what issue notes (`bd note <id>`) and commit messages are for. `.claude/bd-prerun-hook.sh` enforces
this at write time — it blocks `bd remember` without `--key`, and blocks bodies that are
structurally a handoff memo.

That gate is deliberately **structural, not lexical**. An earlier version blocked on vocabulary —
any body containing "handoff", "wrap-up" and so on — which matched memories that merely *mentioned*
the pattern (a memory documenting the rule blocked itself) while a determined write got through by
rephrasing. It was strongest against its own documentation and weakest against the thing it
existed to prevent. If you tighten it, tighten the structure test.

## Every `--<field>` is a SET, not an append

`bd update <id> --notes "..."` REPLACES the notes. `bd remember --key X` REPLACES the body. Use
`bd note <id>` to add to a running record, and `bd recall <key>` immediately before any
`bd remember` you intend as an edit. With more than one session running the same rule becomes a
race — see `docs/ops/concurrent-sessions.md`, installed only with `install.sh --with-peer`.

## The hot tier

`.claude/memory-hot.txt` lists, one key per line, the memories injected **in full** at session
start. Everything else appears as a key-only index, retrievable with `bd memories <keyword>` or
`bd recall <key>`.

Keep the hot list to recurring-mistake guards — the things an agent must not rediscover the hard
way. Two measurements from a live store that shaped this design:

- A 70-character preview per index entry cost 38,480 bytes of a 76,290-byte payload: half the
  hook, spent restating keys that are already full sentences. Keys only.
- Hosts truncate the session payload (~39 KB was observed). **Anything appended at the bottom is
  invisible precisely when it matters**, which is why alarms are emitted at the top.

An empty `memory-hot.txt` is fine and is the right default for a new repo: the hook falls back to
the full `bd prime` output.

## bd-memgraph

[bd-memgraph](https://github.com/scgoetsch/bd-memgraph) (MIT) is an **optional** layer that reads
`bd memories --json` and treats `[[wikilinks]]` in memory bodies as a typed graph. bd is never
modified; the structure lives inside the memory bodies, so it survives upgrades and exports.

It is a single python3 file with no dependencies:

```bash
git clone https://github.com/scgoetsch/bd-memgraph
ln -sf "$PWD/bd-memgraph/bd-memgraph.py" ~/.local/bin/bd-memgraph
```

**Nothing breaks without it.** The `.beads-hooks/pre-commit` stanza tests for the binary and
skips when it is absent, so the pipeline installs and runs fine either way. That silence is a
deliberate exception to this repo's usual rule: silence is the enemy when it hides a FAILURE, but
an optional tool you chose not to install is a decision, not a fault, and a hook that nags about
it every commit would be noise. What is *not* silent is whether the stanza is present at all —
the installer reports each guard in the pre-commit by name, so a hook missing one is visible.

If you ever re-run `bd hooks install --shared`, it rewrites only the region between its own
`BEADS INTEGRATION` markers, so the memory-graph and agent-docs stanzas should survive. Re-run
the installer afterwards to confirm rather than assuming — it prints one line per guard.

- Bare `[[key]]` means *related*. Type it when the relation is causal: `supersedes::`,
  `depends-on::`, `contradicts::`, `justified-by::`, `refines::`.
- **Links live in the NEWER memory, and targets must already exist.**
- Before writing: `bd-memgraph evolve "<draft>"` tells you near-duplicate (update in place) vs
  novel, and suggests link candidates.
- To supersede: write the corrected body under an accurate key with `supersedes::[[old-key]]`, run
  `bd-memgraph check`, repoint the inbound links it lists, then `bd forget` the old key.
- At session close `bd-memgraph check` should report OK — no dangling links, no unswept
  supersedes. The pre-commit guard runs it with `--no-ledger`, which records no observations, so
  **a green hook is not evidence the ledger saw your session**; run a plain `check` before staging.
  A non-observing run says so on its own status line — read it.

**Commit the ledger.** `bd-memgraph` writes `.beads/memgraph-ledger.json`, which carries tombstone
history so a superseded key stays known after `bd forget`. Without it in git the history is
local-only and the next machine re-learns nothing. bd itself does not ignore it: bd 1.1.2 and 1.3.0
both ship a `.beads/.gitignore` that excludes specific state files (`sync-state.json`, `*.db`, …),
not the directory, and `git check-ignore -v .beads/memgraph-ledger.json` prints nothing on either.
So the whole step is `git add .beads/memgraph-ledger.json` once; a tracked file is not subject to
ignore rules afterwards. The installer's verify step says so if it finds a ledger that is ignored.

Only if your own root `.gitignore` excludes `.beads/` wholesale do you need a re-include, and then
it must exclude the directory's **contents**, not the directory — git cannot re-include a file
under an excluded directory, so the pair this doc used to show (`.beads/` then
`!.beads/memgraph-ledger.json`) ignored the ledger anyway, verified 2026-09-22:

```gitignore
.beads/*
!.beads/memgraph-ledger.json
```

`tools/../.claude/skills/memory-curate/audit_wikilinks.py` repairs dangling links in bulk. Its
repoint table ships empty on purpose: you fill it in per repair, and only for successors you have
verified carry the same claim. A link that points somewhere plausible but wrong is worse than one
that is visibly broken, because nothing will flag it again.
