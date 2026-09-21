# Concurrent sessions against one bd store

**This document is OPTIONAL and environment-dependent.** It applies only if more than one agent
session may run against this repo at once. If you work one session at a time, none of it is
needed — install it with `install.sh --with-peer`, or skip it.

Nothing else in the pipeline assumes peers. The one piece of concurrency machinery that always
ships is the `flock` in `tools/dolt-guard.sh`, which stops two shells racing to start the Dolt
server; that costs a single-session user nothing and prevents a real race when it matters.

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


## Talking to a peer session

If your harness can message other live sessions, the expensive mistake is **broadcasting
repo-specific instructions to sessions that are not in your repo.**

Learned directly: asked to share a change with the other sessions, an agent sent a ~30-line
briefing to all three live peers. Only one plausibly shared the workspace. One replied that it was
in a different repo with its own `.beads`, so none of it applied; the others reported the message
as noise.

**The cause was a missing fact, not a judgement slip.** A peer listing typically reports name,
kind, state — **not the peer's working directory or repo.** A session's title is not evidence
either ("Check status" says nothing about where it is). So there was no evidence any peer shared
the workspace, and the broadcast went out as if there were.

What to do instead, cheapest first:

1. **Ask before briefing.** One line — "are you working in `<repo>`?" — costs the peer almost
   nothing. A long briefing to a session on another project costs it context it did not ask for.
2. **Make the message self-scoping in its FIRST line**, which is usually all the recipient sees as
   a preview: *"Only relevant if you are in `<repo>` — ignore otherwise."*
3. **Prefer letting the peer discover it.** A change git carries — a committed symlink, a tracked
   script, an updated `AGENTS.md` — reaches every clone on the next pull with no message at all.
   Ask whether the message is needed before composing it.

### An issue-prefix does not imply a separate store

A peer reasoning "my ids are `ab-*` and yours are `xy-*`, so we cannot collide" has the right
conclusion for the wrong reason. **bd resolves its store by upward directory discovery, not by
prefix.** What separates two sessions is having separate `.beads/` directories. A session working
anywhere under a repo hits that repo's store whatever its task is — and the SET-not-append
semantics above turn that into a silent overwrite rather than a visible conflict.

### If a peer edits your working tree

Treat a peer's report as a claim to verify, not a fact. Check `git log` and `git status` yourself
before building on it: a peer that committed your uncommitted work has changed what `HEAD` means
for you, and only your own `git diff HEAD` will tell you whether anything of yours is still
outstanding.
