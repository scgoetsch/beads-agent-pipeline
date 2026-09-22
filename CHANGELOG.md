# Changelog

## Unreleased

- The SessionStart hook's suite no longer refuses to run without `jq`; it tests the hook's
  fallback banner instead, which is the behaviour on that box, and a nested run with `jq` hidden
  keeps that branch honest. `./selftest.sh` used to fail on a box the README calls supported.
- README: a reader following the quickstart is now told what to install first and what to run
  after; "Known limitations" and "What it touches, and how to remove it" sections; the requirements
  table lists `rg`, `ss` and `timeout` and describes the four hook events; "any git repo" no longer
  claimed; stale wording on how the session hooks are verified; "Verify it" says what the self-test
  actually proves; three lines re-wrapped.
- `install.sh --check` names the four hook events instead of "three hooks".

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
