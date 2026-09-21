# Concurrent sessions against one bd store

AGENTS.md keeps the practice; this keeps the storage-layer verification and the decay patterns.

## The SET-not-append trap becomes a race

**Several agent sessions can run against one bd store at once.** That is *safe at the storage
layer* and needs no coordination: there is one `dolt sql-server`, every session is a client of
it, and `bd` opens a connection per command rather than holding one. Writes are interleaved SQL
transactions serialised by the server — no corruption, no lost rows. Verified by running four
memory writes from two sessions concurrently: all four landed, graph clean.

**What concurrency changes is the SET rule, not the database.** Because `bd remember --key X` and
`bd update --<field>` REPLACE rather than append, a second session can overwrite between your read
and your write: you `bd recall`, they rewrite, you write back your stale-plus-edit body, and their
change is gone. `bd show` / `bd memories` display only what survived, so it looks like one clean
write. Within a single session this is a mistake you can avoid by reading first; across sessions it
is a genuine race with no error message.

Practice, in descending order of value:

1. **Partition by scope, not by lock.** Sessions working disjoint issues and disjoint memory keys
   cannot collide, and this is what actually keeps the store safe day to day. Before a session
   starts, know which area it owns.
2. **`bd recall <key>` immediately before `bd remember --key <key>`** — not a recall from earlier
   in the session. Narrow the window rather than trusting a stale read.
3. **`bd note <id>`** for anything appending to a running record, always.
4. **Serialise `bd dolt push`.** Simultaneous pushes to a shared blob store are the likeliest place
   to see damage; the metadata branch `__dolt_remote_info__` force-updates on push. Have one session
   push at close, or stagger them.

If two sessions may edit the same key, say so in the memory body rather than assuming the other
session will read your mind. File-level collisions (`AGENTS.md`, `.claude/memory-hot.txt`) are
ordinary git conflicts and git will tell you — it is only the bd layer that fails silently.

## Two decay patterns to look for specifically

- *Negatives evaporate.* A tested-and-failed hypothesis leaves no artifact, so nothing contradicts
  it if the record is lost — it just looks unexplored and gets re-attempted. Record the
  operationalisation, the numbers, the scope limits, and an explicit "do not re-propose".
- *Hedges harden.* Qualifiers get dropped as claims move up into summaries ("dominant **with a real
  but secondary secondary effect**" → "dominant, NOT the other thing"). When correcting, check the
  summary layer *and* the memory key name — a key name is itself a claim.
