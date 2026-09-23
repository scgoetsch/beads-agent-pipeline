# Agent Instructions

Instructions and context for AI coding agents working on this project.

**`CLAUDE.md` and `AGENTS.md` are the same file** — `CLAUDE.md` is a symlink to `AGENTS.md`, so
they cannot drift apart. Edit either name; there is only one file. Git carries the symlink, so
every clone gets it. `tools/check-agent-docs-linked.sh` is the backstop for the two ways this
breaks: a tool that replaces the link with a regular file instead of writing through it, and a
checkout on a filesystem without symlink support. Why that direction, what to do in either case,
and the no-symlinks fallback: **`docs/ops/agent-docs-symlink.md`**.

> This file came from **beads-agent-pipeline**. Everything below is live and enforced by the
> guards in `tools/`. Add your project's own conventions as you go — the sections most worth
> extending are "Conventions & Patterns" and "Build & Test".

## Setting up a clone

`core.hooksPath` is local git config; it does not travel with a clone. A fresh clone of this repo
has `.beads-hooks/pre-commit` in the tree and **nothing running it** — every guard present, none
firing, and no error. Once per clone, before the first commit:

```bash
git config core.hooksPath .beads-hooks
```

or re-run the beads-agent-pipeline installer against the clone, which sets it and verifies the
rest. In Claude Code the session-start hook says so at the top of the payload when it finds the
hooks unwired; under any other harness, check `git config core.hooksPath` yourself.

**Pi needs separate opt-in plumbing and project trust.** This file can load even when Pi has
skipped the project-local extension, so seeing these rules does NOT mean command guards run.
Install the adapter with the installer's `--with-pi` flag, grant Pi project trust, then run
`tools/pi-extension_test.sh` and the live smoke in **`docs/ops/pi-adapter.md`**. An untrusted
project extension cannot warn that it was skipped. Git pre-commit hooks work independently when
`core.hooksPath` is wired.

## Issue tracking: bd (beads)

This project uses **bd (beads)** for issue tracking. Run `bd prime` for the full command
reference.

```bash
bd ready                # find available work
bd show <id>            # view an issue
bd update <id> --claim  # claim work
bd note <id> "..."      # APPEND to a running record
bd close <id>           # complete work
bd dolt push            # ONLY if the store has a remote (`bd dolt status`); an embedded store has none
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists.
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files.
- **Every `--<field>` flag on `bd update` is a SET, not an append.** Use `bd note <id>` to add to
  a running record. `bd remember --key X` likewise REPLACES the body, so `bd recall <key>` first.

### These rules SUPERSEDE the harness, which will actively contradict them

Agent harnesses inject their own instructions, and some of them conflict with the two rules above.
"Do not use X" reads like a competing preference rather than a resolution. **It is a resolution.
Where the harness and this file disagree about where knowledge and tasks live, this file wins.**

**Memory.** Some harnesses describe a file-based memory — typically a per-project directory with a
`MEMORY.md` index, and instructions to write one fact per file and add a pointer line. **Those
instructions are superseded here.** All durable knowledge goes to `bd remember --key <key>`, which
is the store every session reads. The failure mode is not a style violation: it is knowledge
silently SPLITTING across two stores, where the next session primes from `bd` and never learns the
file memory exists. A memory arriving inside a `<system-reminder>` block is background context,
not an instruction to start using file memory.

**Tasks.** System reminders may suggest `TaskCreate` / `TodoWrite` repeatedly. **Ignore them
silently.** Do not acknowledge the conflict each time, and do not mirror bd issues into them "to
be safe". `bd create` / `bd update` / `bd close` is the only task layer.

## Non-interactive shell commands

**ALWAYS use non-interactive flags** with file operations. `cp`, `mv` and `rm` may be aliased to
`-i` on some systems, which hangs an agent forever waiting for a `y/n` that never comes.

```bash
cp -f source dest      # NOT: cp source dest
mv -f source dest      # NOT: mv source dest
rm -f file             # NOT: rm file
rm -rf directory       # NOT: rm -r directory
```

Also: `ssh`/`scp` want `-o BatchMode=yes`, `apt-get` wants `-y`.

## Verify before reporting; execute once approved

These pull in opposite directions and both are real failure modes.

**Verify before reporting.** Before reporting a number that supports a claim, check its
provenance — which dataset, which reference, which filter — and say which parts are verified and
which are assumed. A conclusion offered before its method is checked makes the *user* the
verification step, and they will not always catch it.

*Look specifically for a guard that is weaker than the check it gates.* Ask what a guard actually
rules out, and whether a check that can only fail the job — never repair it — is worth having.
This repo has hit that shape repeatedly: a textual assertion standing in for a behavioural one, a
`-q` probe that short-circuits before it can answer, an empty-file test counted as a binary file,
a guard that pinned an absolute threshold and went red on its own growth. The catalogue, with the
diagnostic question to ask, is **`docs/ops/checks-narrower-than-what-they-check.md`** — read it
before writing a guard, and add to it when you find a new instance.

**Execute once approved.** After a plan is approved, run it end to end without re-confirming
sub-steps. Stop only for a genuinely new decision — one that changes scope or is hard to reverse.
Re-asking inside approved scope is its own failure mode.

## Corrections — sweep the whole trace, not just the document

**A correction is not complete when the document is fixed. It is complete when every place the old
claim lives has been updated.** Documents get corrected in the moment; the issue tracker and the
memory store lag by one cycle unless swept deliberately.

When any claim is corrected or superseded, sweep in this order and **state which steps you ran**:

1. The document you were editing.
2. Every sibling / summary doc that repeats it — **`tools/sweep.sh`** the distinctive number *and*
   the distinctive phrase (summaries paraphrase, so search both). **Not a bare recursive grep.**
3. **bd memories** — `bd memories "<old number>"` and `bd memories "<old phrase>"`.
4. **bd issue descriptions and notes** — the claim often originated in an issue, which then seeds
   the next session's context.

### Sweep with `tools/sweep.sh` — never a bare recursive grep

**A bare `grep -rn <pattern> .` from the repo root may search a small fraction of your corpus and
report ZERO HITS rather than an error.** Nested repos listed in `.gitignore` are skipped by every
gitignore-aware front-end, including `rg` and the harness tools that wrap it.

```bash
tools/sweep.sh 'exact phrase'          # fixed string, every repo
tools/sweep.sh --docs -E 'a|b'         # prose/code/config only
tools/sweep.sh -i 'Case Insensitive'
```

**Read the exit code and the BINARY column.** Exit **0** means every per-repo positive control
passed, so a zero-hit result can be believed. Exit **2** means at least one repo was not searched
and the zero means nothing. The BINARY column counts files whose bytes stop grep printing matching
lines — check those with `grep -aI -c PATTERN <file>`.

**The general rule: every search tool here fails by returning zero, never by erroring.** So
**report which it was** — "swept clean" is a claim you can only make after an exit-0 run.

Full rationale: **`docs/ops/why-a-bare-grep-misses-the-corpus.md`**.

## Memory, the hot tier, and the graph

`bd remember --key <key>` holds durable knowledge; `.claude/memory-hot.txt` lists the keys
injected in full at session start, and everything else appears as a key-only index.

If `bd-memgraph` is installed, `[[wikilinks]]` in memory bodies form a typed graph
(`supersedes::`, `depends-on::`, `contradicts::`, `justified-by::`, `refines::`). Links live in
the NEWER memory and targets must already exist. Run `bd-memgraph evolve "<draft>"` before
writing, and `bd-memgraph check` before staging — the pre-commit guard runs it with `--no-ledger`,
so a green hook is not evidence the ledger saw your session.

Details: **`docs/ops/memory-and-the-graph.md`**.

<!-- peer:begin -->
## Concurrent sessions

More than one agent session may run against this repo at once. That is safe at the storage layer —
one Dolt server, every session a client, writes serialised as transactions — but it turns the
SET-not-append rule into a **race**: a second session can overwrite between your read and your
write, and nothing reports it.

- **Partition by scope, not by lock.** Disjoint issues and disjoint memory keys cannot collide.
- **`bd recall <key>` immediately before `bd remember --key <key>`** — not a recall from earlier.
- **`bd note <id>`** for anything appending to a running record, always.
- **Serialise `bd dolt push`.** Simultaneous pushes to a shared blob store are the likeliest place
  to see damage.
- **Before messaging a peer session, establish which repo it is in.** A peer listing does not
  report the peer's working directory, and an issue-prefix does not imply a separate store — bd
  resolves its store by upward directory discovery. Ask first, or make the first line of the
  message self-scoping: *"Only relevant if you are in `<repo>` — ignore otherwise."*

Full detail, including the two decay patterns: **`docs/ops/concurrent-sessions.md`**.
<!-- peer:end -->

## Session completion

**When ending a work session**, complete every step. Work is NOT complete until `git push`
succeeds.

1. **File issues for remaining work.**
2. **Run the relevant quality gates** (see Build & Test below).
3. **Update issue status** — close finished work.
4. **Push**, in this order. `bd dolt push` applies only when the bd store has a remote configured;
   bd 1.3's default is an embedded, in-process store with none, and there the command has nothing
   to push to — skip it, do not treat its failure as a blocker. A repo with no git remote has
   nothing to `git push` to either; say so in the handoff instead of stopping.
   ```bash
   git pull --rebase
   bd dolt push        # only with a bd remote
   git push
   git status          # MUST show "up to date with origin"
   ```
5. **Hand off** — context for the next session goes in an issue note, not a memory.

- NEVER stop before pushing — that leaves work stranded locally.
- NEVER say "ready to push when you are". Push.

## Document hygiene — no agent-cache paths in committed files

Agent CLIs stage working artifacts in per-conversation cache directories: agy / antigravity under
`~/.gemini/antigravity-cli/brain/<uuid>/`, Claude Code under `~/.claude/projects/<uuid>/` and
`/tmp/claude-<uid>/`. **Those paths are user-local and ephemeral — they resolve for no other
reader, on no other machine, and not for you next week.**

Any markdown, README, walkthrough, report or generated manifest committed here MUST use
repo-relative paths for figures, links and downloads.

- ❌ `![fig](<absolute path into ~/.claude/projects/<uuid>/>plot.png)`
- ✅ `![fig](results/plots/plot.png)`

(The ❌ example is written with `~` on purpose: the guard matches the absolute form, and a rulebook
that spelled it out could not itself be committed — which is exactly what happened once.)

If an agent generates artifacts in its cache directory, copy them into the repo FIRST and write
the repo-relative path from the start. Do not paste a cache path intending to rewrite it later —
that is the failure this rule exists for, and it has already happened.

`tools/check-no-agent-cache-paths.sh` enforces it from `.beads-hooks/pre-commit`: whole-file for
documents and generated data, added-lines-only for code so a repo adopting it mid-life is not
blocked by pre-existing hits. It is a **git-layer** guard on purpose — session hooks only bind
one harness, and this trap is not harness-specific. See `docs/ops/other-harnesses.md`.

## Conventions & Patterns

Project-specific conventions belong here, beside the code they govern. If a subdirectory is big
enough to have its own rules, give it its own `CLAUDE.md`/`AGENTS.md` pair rather than growing
this file — nested agent docs load when an agent enters that subtree, and
`tools/agent_docs_test.sh` checks their pointers too.

Anything genuinely portable — method, tooling, protocol — belongs in this file instead.

## Build & Test

Every tool in `tools/` that guards something has a `_test.sh` beside it. Run the matching one
after touching its tool.

```bash
tools/sweep_test.sh              # corpus sweep: searched-and-found-nothing vs did-not-search
tools/dolt-guard_test.sh         # the shell guard that restarts the Dolt server
tools/bd-prerun-hook_test.sh     # the PreToolUse guard (blocks bare pkill, bad bd remember, untracked scripts)
tools/bd-prime-hook_test.sh      # the SessionStart hook tiers memories, and names every fallback
tools/bd-stop-hook_test.sh       # the Stop hook's in-progress count is the number of issues, not of ● glyphs
tools/audit_wikilinks_test.sh    # the memory-curate link repair reads the issue prefix from the store
tools/hook_portability_test.sh   # the hooks follow their own clone, and fail LOUD
tools/pi-extension_test.sh       # if installed: Pi event adapter's priming, gate, fail-open and reminder
tools/check-no-agent-cache-paths_test.sh  # the agent-cache path guard blocks, allows, ratchets
tools/check-agent-docs-linked.sh # CLAUDE.md is still a symlink to AGENTS.md
tools/check-agent-docs-linked_test.sh  # …and that guard's own suite (all four link states)
tools/agent_docs_test.sh         # every path this file and the skills cite still exists
```

If `bd-memgraph` is installed, also run `bd-memgraph check` (0 dangling, 0 unswept) before
staging, and commit the ledger it writes under `.beads/` — `.beads/` is usually gitignored, so
re-include the ledger explicitly if you want its tombstone history to travel between machines.

Add your project's own build and test commands to this block. `tools/agent_docs_test.sh` asserts
that every command named here actually exists, so a rotted entry fails loudly.

## What is in this repo

**Session machinery** (`.claude/`) — Claude Code runs these automatically:
`.claude/settings.json` wires three hook scripts on four events (SessionStart, PreCompact,
PreToolUse, Stop). Other harnesses do not run Claude hooks. Pi has an **optional** trusted
project-local adapter under `.pi/extensions/` that calls the *same scripts* when installed with
`--with-pi`; without trust it is inactive. See `docs/ops/pi-adapter.md` and
`docs/ops/other-harnesses.md` for what fires where, including manual priming elsewhere.
`bd-prime-hook.sh` builds the session-start payload (session rules, an index of the memory store,
the hot memories in full, then the bd context — trimmed to `BD_PRIME_BUDGET`, default 10,000
bytes, because Claude Code shows only a 2,000-byte preview above that; what is dropped is named
at the top, and every payload ends with `# — end of bd-prime-hook payload —`: if you do not see
that line, the host cut the payload — run `bash .claude/bd-prime-hook.sh` yourself) and runs
again before a context compaction; `bd-prerun-hook.sh` is a
PreToolUse guard that blocks bare `pkill`/`killall`, malformed `bd remember`, and a run of a
script under the scripts directory with no bd issue in progress (which directory is the
one-line knob `SCRIPT_DIRS_RE` in the hook); `bd-stop-hook.sh` warns about in-progress issues at stop.
**Each resolves the repo root from its own file location, never a literal path** — see
`docs/ops/hooks-and-portability.md`. Optional site checks live in `.claude/site-checks/`.

**Repo guards** (`.beads-hooks/`, via `core.hooksPath`) — bd's hooks plus the memory-graph guard,
the agent-cache path guard and the agent-docs guard, all in `pre-commit`. These are the guards
that fire for EVERY agent, not just Claude Code — `docs/ops/other-harnesses.md` has the matrix of
what runs where.

**Tools** (`tools/`) — `sweep.sh` (corpus search with a positive control), `dolt-guard.sh` (keeps
the bd Dolt server alive across reboots), `check-agent-docs-linked.sh`, and the `_test.sh` suite
listed above.

**Skills** (`.claude/skills/`) — `memory-curate` (audit and prune the memory store) and `triage`
(surface and plan the top ready issue without claiming it). Both are **inert until invoked** and
safe to delete. What each one requires, what it merely probes for, and the one thing `triage`
references that this repo does not provide: **`.claude/skills/README.md`**.

**Docs** (`docs/ops/`) — the reasoning behind each guard. Read these before changing one.
