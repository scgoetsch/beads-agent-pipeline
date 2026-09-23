# Changelog

## Unreleased

Second review, rechecked against a08c20d (WS-ispx). Regression tests were added first and failed
against the previous implementation; the fixes cover:

- Git-layer guards inspect staged blobs/modes, not working copies. The symlink guard has an
  explicit `--cached` mode for pre-commit; manual checks retain their working-tree behavior.
  Tests commit conflicting staged/working versions in both directions, including missing files.
- Settings merges preserve user hooks on shared events and inside mixed groups, plus prompt
  hooks and matchers. Only the exact standalone bd prime SessionStart registration is removed.
  The earlier replacement was warned about, but the warning came after user hooks were removed.
- Sweep discovery is unlimited by default. Explicit depth limits return 2 and cannot certify
  absence; discovery errors are surfaced. The size cap includes equality, with cap−1/cap/cap+1
  regression cases.
- Dolt lock-open failures now warn and return nonzero without attempting an unlocked start.
- PreToolUse tokenizes literal commands, recognizes common wrappers, interpreter options and
  quoted paths, and rejects zero age filters and pkill's `-o` (oldest). It remains a heuristic,
  not a shell sandbox; it never evaluates the command it checks.
- A normal-path bd prime failure is announced near the top of the budgeted session payload,
  even when the preceding export succeeded. Failed partial context is not emitted as valid.
- The installer accepts worktrees and submodules. Linked-worktree hooks use worktree-local
  config, preserving sibling hooks; tests include a bare parent and a submodule.
- Test scratch files are isolated and cleaned: the sweep suite no longer overwrites its EXIT
  trap, the prime suite never removes global /tmp names, and selftest checks every suite for leaks.
  The installer also uses mktemp for its rendered template. Without jq, selftest explicitly skips
  the settings-merge cases and still exercises the hook's fallback.

Validated on Linux/WSL2, bash 5.2, git 2.43, Python 3.12, bd 1.1.2 using temporary repos and stub
stores. This is suite coverage, not a new signed-in Claude Code or macOS/native Windows run.

- The SessionStart hook now fits the host. Claude Code keeps only a 2,000-byte preview of any
  one hook command's output above 10,000 bytes and files the rest (measured 2026-09-22 with
  synthetic hooks; the JSON `additionalContext` form is capped the same; anthropics/claude-code
  #70460). The hook emitted rules, then the 4.8 KB bd context, then the hot tier, then the
  index, and a real store with three hot keys produced 15.9 KB: the model got the banner and
  nothing after it, while every line of the run read as success. The hook now builds every
  section first and assembles them against `BD_PRIME_BUDGET` (default 10000; `0` = no cap):
  rules, site checks and the index always ship; the index comes before the hot bodies; hot
  bodies are kept in list order while they fit and the rest are NAMED at the top for
  `bd recall`; the bd context is the first thing dropped; the full-dump fallback is cut the
  same way with a line 2 saying so. `tools/bd-prime-hook_test.sh` gains a budget section
  (28 cases; 17 fail against the previous hook, the rest pin what must not change). Hot bodies
  are also ranked in the order of `memory-hot.txt` now: the list was deduplicated with jq's
  `unique`, which sorts, so the budget kept whichever key came first in the alphabet. From the
  peer review of this change: each site check's output is cut at 1,500 bytes with the cut marked,
  so a chatty check cannot push the rules past the cap; every payload ends with an end marker a
  reader can look for; `install.sh` measures the real payload in its verify step. Not adopted
  (recorded for whoever needs more than ~8 KB of hot bodies): splitting the payload across
  several hook commands, since the cap is per command — it multiplies the budget at the cost of
  running `bd export` per slice, a longer `settings.json` the installer must merge, and an
  unmeasured possibility of a cap on the sum. PreCompact runs the same hook and is assumed to
  have the same cap; it was not measured separately. The README, `docs/ops/memory-and-the-graph.md`
  (its "~39 KB" figure was wrong), the template `AGENTS.md`, the `memory-curate` skill and the
  runbook's section-7 sentinel say so.

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
