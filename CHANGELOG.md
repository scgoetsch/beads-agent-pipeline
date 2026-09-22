# Changelog

## Unreleased

From the 2026-09-22 line-by-line inspection (agy, reviewed by grok-peer, each finding verified
against c37eced before it was fixed). Each fix ships with a check that fails on the previous code.

- The Stop hook's reminder counted lines containing `●` — bd's priority bullet on every row and its
  BLOCKED glyph in the legend under every non-empty listing — so one in-progress issue read
  "You have 2 in-progress issue(s)". Both hooks now count issue rows (`bd --json list`, or the `◐`
  rows without jq); the PreToolUse suite's fixture is bd's real output shape, and
  `tools/bd-stop-hook_test.sh` is new.
- `check-agent-docs-linked.sh` returned success for a regular `CLAUDE.md` with no `AGENTS.md`
  beside it (the state where every non-Claude harness finds nothing), and capped bd's block at a
  fixed 70 lines that would have blocked every commit the day bd's template grew. It now fails
  the lone regular file, and asks `bd setup --print` how long bd's block is (floor 56, plus slack).
- `check-no-agent-cache-paths.sh`'s code ratchet stopped at scripting languages — a cache path
  added to `main.go` or `src/lib.rs` committed clean — and its regex knew neither
  `/var/home/<user>` (ostree) nor macOS's `$TMPDIR` (`/var/folders/…/T/claude-<uid>/`). Compiled
  languages, TeX/Typst/AsciiDoc/Rmd/qmd documents, and both path forms are covered.
- The SessionStart hook skipped every site check in silence on a box without `timeout`: the
  "command not found" went to a discarded stderr. It now runs them unbounded and says so at the top
  of the payload, and a check's stderr reaches the payload too.
- macOS: `sweep.sh` probes for GNU `xargs -r` instead of assuming it (BSD xargs rejected the flag
  and every sweep died); `dolt-guard.sh` falls back from `ss` to `lsof` and `netstat` and says so
  when none exists, and proceeds without `flock` instead of reporting a timeout that never
  happened. Still untested there; see "Known limitations".
- `audit_wikilinks.py` is executable, in the repo and as installed (skill and site-check scripts
  get 755); the template `AGENTS.md` names all four hook events and the `scripts/` gate;
  `agent_docs_test.sh` cases are numbered in the order they run.

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
