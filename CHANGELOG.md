# Changelog

## v0.2.0 — unreleased (not tagged)

**The store is [cairn](https://github.com/scgoetsch/cairn) (0.7.0 or later), and only cairn. This
release does not read bd.** Do not re-run the installer on a checkout whose store is still bd's
before the store has moved: the installer refuses one that has a live bd store and no writable
cairn store, and the move is the numbered sequence in the README ("Moving a repo off bd"). A
green install is not a migrated store. `v0.1.0` stays where it is as the bd release. The version
is a minor bump because the interface is not stable yet: the hook names and the migration path
are expected to change again (renames; a migration verb in cairn).

### What breaks, for a bd user who pulls this and re-runs `install.sh`

- The install requires `cairn` on PATH; `bd`, `dolt` and `bd-memgraph` are no longer used.
- A store that is still bd's is refused, and nothing is installed, until it has moved.
- The session hooks, git hooks and tools read cairn only. A `.claude/store-cli` is ignored, and a
  bd-era hook you edited is kept with ours beside it as `.new`; until you adopt it, it can still
  run bd (the installer names each such file).
- `bd dolt push` is gone from session completion. Two machines share the store through git (the
  four files in `.cairn/`) and `cairn sync`; two clones that both wrote are refused, with no
  merge.
- The ~/.bashrc dolt-guard block is removed (only the one for the target repo); `--no-shell`
  does nothing and is accepted with a note.
- CI installs cairn instead of bd; the no-bd job and the bd version input are gone.
- There is no switch back inside the pipeline: rolling back is checking out `v0.1.0` and bd's
  store, which the move leaves on disk.

### Changed

- **Session hooks, cairn only** (`bd-prime-hook.sh`, `bd-prerun-hook.sh`, `bd-stop-hook.sh`,
  names kept this release). Gone: the `.claude/store-cli` switch, every bd branch, the
  frozen-store gate and its `# frozen-store-ok` escape, the bd-to-cairn verb map, and the session
  start's check of the store-cli tools. Kept: the bare `pkill`/`killall` gate, the keyless and
  handoff-shaped `cairn remember` gate, the untracked-scripts gate, per-session claim recording,
  the stop reminder, the prime budget, hot tier, key index and the `BEADS_ACTOR` export. The prime
  hook runs `cairn sync` first, and says at the top of the payload (fallbacks included) when
  cairn is not on PATH or the repo has no `.cairn/` yet. No typed-`bd` guard: bd run in the repo
  is the user's own tool, and makes a store cairn never reads.
- **Git hooks.** `pre-commit`: `cairn check` when `.cairn/` exists (marker `store check`), the
  agent-cache path guard, the agent-docs guard, the export freshness guard; no bd block.
  `post-merge` and `post-checkout`: `cairn sync` where `.cairn/` exists, never failing git.
- **The installer** requires cairn ≥ 0.7.0 (`cairn --version`), refuses a live bd store with no
  writable cairn store (in install, `--check` and `--dry-run`), and, in a repo that had bd:
  removes bd's `BEGIN/END BEADS INTEGRATION` blocks **in place** from every hook in
  `.beads-hooks/` (a hook left with only comments is replaced by ours or removed); removes hook
  entries that run bd from `.claude/settings.json`, `.claude/settings.local.json`,
  `.codex/hooks.json` and `.cursor/hooks.json`; removes the dolt-guard block from `~/.bashrc` only
  when it sources this repo's guard; names bd-era files it no longer ships and the old tracker's
  exports left in `.beads/` (cairn refuses exports split between `.beads/` and `.cairn/`); writes
  `.cairn/redirect` in sibling worktrees that have neither a redirect nor a store. Every file it
  edits is backed up under `<git common dir>/beads-agent-pipeline-backup/<timestamp>/`
  (`~/.bashrc` beside itself). The settings merge replaces the pipeline's own 0.1 hook groups
  instead of adding the new ones beside them. Next steps print `cairn init -p <PREFIX>`, the
  export refresh and the first commit of `.cairn/`.
- **Tools upstreamed from the workspace this came from, cairn only:**
  `tools/refresh-beads-exports.sh` (the four tracked files in `.cairn/`: current, stale, could not
  run; refuses a store that is behind or diverged from them, or a history that is not an append;
  writes a missing file even when empty, so a fresh store's first commit carries all four) and
  `tools/new-worktree.sh` (a second working tree that shares the store through `.cairn/redirect`),
  each with its suite.
- **Skills and the curation gate.** `memory-curate` is cairn-native; `audit_wikilinks.py` reads
  the issue prefix from `.cairn/config.json`; `triage` uses cairn's verbs; the curation gate
  counts `.cairn/memories.jsonl`.
- **Agent docs.** The `AGENTS.md` template is cairn-native (the store and its tracked exports,
  session identity, the issue tracker), with no managed block. `check-agent-docs-linked.sh` keeps
  the symlink and pointer-file checks and names an old `BEGIN BEADS INTEGRATION` block instead of
  measuring it; `agent_docs_test.sh` allows `.cairn/`.
- **Pi adapter** no longer calls the dolt guard at session start.
- **docs/ops/**: the store halves are rewritten for cairn (concurrency on a SQLite store, the
  graph cairn keeps, what fires where); the defect catalogue keeps its history.
- **The self-test** proves a cairn-only install (no hook runs `bd hooks run`, carries a BEGIN
  BEADS block or reads `.claude/store-cli`), the refusal, the in-place removal on a bd-era
  fixture, and hides cairn from PATH for the required-command branch. CI and the container image
  install cairn from github.com/scgoetsch/cairn at a pinned commit (cairn has no release tags yet).

### Removed

`tools/dolt-guard.sh`, `tools/store-cli-git-hooks.sh`, `tools/store-cli-harness-hooks.sh` (each
with its test), `tools/pre-commit-store-cli_test.sh`, the `~/.bashrc` block, the bd-memgraph
pre-commit stanza and optional dependency, the memgraph-ledger check, and the bd sections of the
README and the root runbook.

### Also since v0.1.0, and still true

The work between 0.1.0 and the move, condensed; the full record of each is in git history.

- Sessions get an identity in the store's audit trail: `BEADS_ACTOR=<git user.name>/claude/<8>`
  through `CLAUDE_ENV_FILE`, and `--claim` is compare-and-swap on it. A claim the session record
  missed (an id in a variable, `ready --claim`) still counts when the assignee is the session's
  own session-scoped actor; in-progress listings pass `--limit 0`.
- The stop reminder and the scripts gate are session-scoped (Claude Code's Stop and Pi's
  `agent_settled` fire every turn); the reminder speaks only when the set changes.
- The SessionStart hook fits the host: `BD_PRIME_BUDGET` (default 10,000 bytes), omitted hot
  bodies named, an index too large for the budget replaced by one INDEX OMITTED line, every
  fallback named on its first line.
- Site checks: a check that exits nonzero without output, one killed at the bound, and one without
  its executable bit are each named, never read as health. The memory curation gate ships as the
  first site check.
- PreToolUse tokenizes literal commands, unwraps common wrappers, drops data heredocs, and judges
  text it cannot tokenize line by line instead of failing open.
- `--with-peer` is `--with-concurrent` (the old spelling is accepted with a note). `--with-pi`
  installs an opt-in, trusted project-local Pi adapter that reuses the hook scripts.
- The self-test runs in GitHub Actions on ubuntu, macos and windows, and on a clean Ubuntu in
  Docker; the causes the matrix found (BSD `wc` padding, two spellings of one directory, GNU-only
  `date` flags, the CR LF a native Windows Python and jq append, a Git Bash `ln -s` that copies,
  binaries that lose their DLLs) are fixed. `CLAUDE.md` works on a filesystem without symlinks as
  git's own pointer file, staged as a link.
- Git-layer guards inspect the index, not the working copy; the settings merge preserves user
  hooks on shared events and in mixed groups; worktrees and submodules install with their own
  config; sweep discovery is unlimited by default.

## v0.1.0 — 2026-09-22

First release. Session machinery for coding agents around `bd`: a SessionStart hook that replaces
the raw `bd prime` dump with rules, context, a hot tier and a key-only index; a PreToolUse guard
(bare `pkill`/`killall`, `bd remember` as session state, untracked `scripts/` runs); git-layer
guards for agent-cache paths and the `CLAUDE.md` → `AGENTS.md` symlink; a corpus sweep with a
positive control per repo; an `AGENTS.md` template; an installer that never overwrites your
content; a self-test that installs into throwaway repos and proves every guard through
`git commit`; and an agent runbook (`AGENTS.md` at the repo root) for a fresh box.

**Tested on:** Ubuntu 26.04 / bash 5 / GNU coreutils, with bd 1.1.2 and 1.3.0, Claude Code
2.1.278. macOS and Windows/WSL are untested; the bash-4-only and GNU-only constructs that were
found have been replaced, but nobody has run it there.

**Found and fixed by running the runbook on a fresh box** (2026-09-21..22), each with a test that
fails against the previous code:

- The git-layer guards were installed but never wired without `bd` on the box.
- `dolt` was listed as required; nothing calls it. The self-test failed on the origin machine.
- With bd 1.3.0: every commit was blocked by a stale pattern in the symlink guard; the shell guard
  cried wolf in every shell on an embedded store; the installer fought bd over `core.hooksPath`,
  its pre-commit stanza and `settings.json`.
- The cache-path guard rejected the pipeline's own template and its own suite.
- The SessionStart hook silently fell back to the full dump on an empty hot list (how it ships),
  on an empty store, and used fixed scratch paths under `/tmp`.
- `memory-curate`'s link repair shipped with the author's issue prefix hardcoded; it now reads
  the store's.
- The `pkill` allowlist was judged over the whole command line; an admitted `bd remember` skipped
  the `scripts/` gate; `/root/` was not a home the cache-path regex knew.
- Documentation an agent obeys contradicted the code in six places.

**Known limitations, tracked:**

- No upgrade path: a changed tool reaches an installed project as `tools/<name>.new` to adopt by
  hand.
- One project per `~/.bashrc` for the shell guard.
- The pipeline repository does not run its own git-layer guards on its own commits.
