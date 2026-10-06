# Changelog

## Unreleased

- **Last causes from the matrix after the previous batch** (macOS 134/1, Windows 128/7). A
  native Windows jq ends each line with CR LF too, so the prime hook read a hot key back as
  `key\r`, matched nothing, and emitted no hot body; every jq output it reads back is stripped,
  and `memory-hot.txt` is read the same way for a file saved CR LF. `-ef` cannot equate two
  spellings of one directory across MSYS mounts (`/tmp/…` against `/c/Users/…/Temp/…`, different
  devices), so the hook's hooksPath check and the installer's `hooks_wired` fall back to
  `cygpath -m` where it exists — the self-test's absolute-hooksPath case had the installer
  rewriting a value it should have left alone. The dolt-guard suite's stub listeners run from `/`
  (exec'd so the recorded pid is theirs) and cleanup retries the removal, since Windows will not
  delete a directory a live process holds as its cwd and releases a killed one's handles a beat
  later; the suite had leaked its scratch directory there. `agent_docs_test.sh` walks the tree in
  Python instead of shelling out to `find`, which a native Windows Python resolved to System32's.
  The Pi event suite's own prime stub formatted a `wc -l` count, padded on BSD, so its `PRIMED 1`
  assertion failed on macOS; stripped.
- **The hooks read Python back without the CR a native Windows Python appends**, plus the
  next causes the matrix measured after the previous batch. A native Windows Python ends every
  stdout line with CR LF even into a pipe (the workflow's box line now shows it), so the prerun
  hook read an empty session id as a lone CR and treated every call as session-scoped with no
  claims — every `allows` case blocked — and the stop hook's rows and the prime hook's project
  brief carried the CR too; all three strip it. The prime hook's `core.hooksPath` check compares
  directories by inode (`-ef`), not spelling: git reports `C:/…` where the shell says `/c/…`, and
  macOS has `/var` beside `/private/var`. The project brief runs unbounded where there is no
  `timeout`, as the site checks already do. `tools/dolt-guard.sh` stamps its log with strftime,
  not `date -Is`, which BSD date rejects. Its suite starts listeners without `setsid` where there
  is none, keeps their pids in a file instead of `pgrep` (absent on MSYS), asserts exactly-once
  starts and the lock only where `flock` exists, and builds its no-flock PATH from wrappers that
  include `lsof` and `netstat` for the boxes that probe with them. `agent_docs_test.sh` strips the
  CR from its Python output; `check-no-agent-cache-paths_test.sh` skips its tab-in-a-filename
  case when git cannot stage the name, not only when the filesystem refuses it. The Pi extension
  compares real paths: Node resolves a module's real path while the cwd it is handed may be the
  logical spelling, so on macOS it had declared itself loaded outside its own project and run
  nothing. `bd-prime-hook_test.sh` prints the payload head under a failing check.
  `audit_wikilinks_test.sh` SKIPs, saying why, under a native Windows Python: its stub `bd` is a
  shell script, and CreateProcess runs no shell script and finds only `bd.exe` on PATH — which is
  what users have, so the script itself works there and only the fixture cannot.
- **One file, two names, on a filesystem without symlinks.** Git Bash's `ln -s` copies the
  target by default and reports success, so the first native Windows install produced two
  independent files with no error. The installer now runs it with `MSYS=winsymlinks:nativestrict`
  (a real link where Windows allows one, a failure otherwise) and on failure writes git's own
  on-disk form of the link — `CLAUDE.md` holding the text `AGENTS.md` — staged as a symlink
  (`update-index --cacheinfo 120000`), so the commit carries a real symlink and a clone with
  symlinks gets one; a re-run recognises that state as linked. `tools/check-agent-docs-linked.sh`
  accepts the pointer form when git agrees it is a link (index mode 120000, or
  `core.symlinks=false`), its `--cached` snapshot no longer needs a symlink of its own, and its
  messages say how to stage the pointer form. Its suite gains the pointer-file state (six cases)
  and, on a box that cannot link at all, says so and runs that section alone; the self-test
  forces the fallback (`BAP_INSTALL_NO_SYMLINKS=1`, `core.symlinks=false`) so a Linux box
  exercises it too: pointer on disk, 120000 in the index, guard passes, commit passes, the
  commit's tree carries a symlink, and a fresh clone has the real link. `docs/ops/agent-docs-symlink.md`
  describes the form.
- **The suites and the self-test hold on macOS and Git Bash where they held only on Linux**,
  measured by the Actions matrix on 2026-10-06 and fixed at the cause. BSD `wc` pads its count,
  so every `wc -l` / `wc -c` comparison in `selftest.sh`, `dolt-guard_test.sh`,
  `audit_wikilinks_test.sh` and `bd-prime-hook_test.sh` strips it. `hook_portability_test.sh`
  compares the relocated clone's path in canonical form (`pwd -P`, and `cygpath -m` under MSYS):
  `mktemp` says `/var/…` on macOS and `/tmp/…` on Git Bash while the hooks resolve
  `/private/var/…` and `/c/Users/…/Temp/…`; it also feeds `settings.json` to Python on stdin
  rather than as a path inside `-c`, which a native Windows Python cannot open. The
  memory-curation gate computes the day gap in shell arithmetic (civil date to day number,
  checked against GNU date) instead of `date -d`, which BSD date lacks, so the gate runs on
  macOS. `dolt-guard_test.sh` starts its listener without `setsid` where the box has none (stock
  macOS, Git Bash) instead of dying at "could not bind test port". The four suites that built a
  private PATH out of symlinks to tools write exec wrappers instead: MSYS `ln -s` copies a binary
  away from its DLLs and the copy exits 127. `bd-prime-hook_test.sh` SKIPs, by name, the cases
  that need a real `timeout` or a `chmod -x` that takes effect; `check-no-agent-cache-paths_test.sh`
  SKIPs its tab-in-a-filename case where the filesystem refuses the name; `bd-prerun-hook_test.sh`
  prints the hook's stderr under a failing case. `sweep.sh` now decides what grep will not search
  by asking the scanner itself — the same binary, flags and locale, a pattern every line matches,
  printed lines counted against the file's — instead of running iconv over the bytes: GNU grep on
  glibc and ugrep suppress a line carrying a malformed byte under a UTF-8 locale (and exit 0
  regardless), BSD grep and GNU grep on the MSYS runtime print it, so the iconv predicate
  overclaimed "NOT SEARCHED" on every box of the second kind. `sweep_test.sh` measures that
  before its binary-file case and SKIPs it, loudly and counted, where the box's grep has no such
  hazard — as it already said it did where no UTF-8 locale exists, except that SKIP then went on
  and ran the case anyway.
- **The self-test runs in GitHub Actions on ubuntu, macos and windows.**
  `.github/workflows/selftest.yml` runs `./selftest.sh` on every push: `ubuntu-latest` with bd and
  without, `macos-latest` with bash from Homebrew (the stock `/bin/bash` is 3.2) and
  `windows-latest` under Git Bash. bd is installed from the release archive the workflow names,
  verified against the release's `checksums.txt`, into a directory of its own so the no-bd probe
  can hide it; the official installer refuses Git Bash and floats to the current release. Each
  job puts its box line, the RESULT line and every FAIL in the run summary, keeps the log, and
  after a failure keeps the installer's output and every suite's full log. First run, 2026-10-06,
  bd 1.3.1: Ubuntu 127 passed with bd and without; macOS 26 fails 20 and Windows Server 2025
  fails 29, so those two jobs are continue-on-error until green. The failures sort into a few
  causes — BSD `wc -l` pads its output and every `$(… | wc -l)` comparison reads the padding,
  `mktemp -d` paths are compared against their physical spelling (`/private/var`,
  `/c/Users/…/Temp`), the curation gate needs GNU `date -d`, the sweep's binary-file case fails
  under BSD and MSYS grep, and on Windows MSYS `ln -s` copies, native Python cannot open MSYS
  paths and the hook suites' bare PATH loses a directory the hooks need. The installer's exit 1
  on both boxes is those causes once more: its verify step runs the portability suite (and the
  agent-docs guard), and that exit cascades into six self-test assertions. The bd-prime-hook
  suite has further cases on both boxes and the Pi event suite fails on macOS under Node 24, not
  yet read. `.gitattributes` pins LF for every text file: Git for Windows ships
  `core.autocrlf=true` in its system config (the runner's box line shows it), and a CRLF bash
  script dies on its first line; the checkout there is `i/lf w/lf`.
- **The self-test runs on a clean box.** `test/selftest-in-container.sh` builds two Ubuntu 24.04
  images from `test/Dockerfile` — `bare` (git, python3, bash and nothing else the pipeline lists)
  and `full` (bd from its official installer at the current release, jq, ripgrep, iproute2,
  bd-memgraph) — and runs `./selftest.sh` inside each as a non-root user with the checkout
  mounted read-only. The "bare-box branch must still pass" line had only ever been a claim; the
  first run found two defects the host hid. `tools/sweep_test.sh`'s binary-file case depended
  on the active locale: under C/POSIX a malformed UTF-8 byte is ordinary text, grep searches the
  file, and three assertions inverted for a reason unrelated to the detector; the case now pins
  C.UTF-8 and SKIPs loudly where no UTF-8 locale exists, and `sweep.sh`'s header says the
  BINARY column follows the locale. `tools/dolt-guard.sh` had no probe at all on a box without
  `ss`, `lsof` or `netstat` and said so every shell; on Linux it now reads `/proc/net/tcp`. The
  first version of that probe let awk exit on its first match, which sends SIGPIPE to the writer
  and under `set -o pipefail` reads a live listener as "not listening"; it now drains its input.
  Its suite no longer needs `ss` itself (a connect probe), proves the kernel table is read in both
  directions, and carries awk on the no-flock PATH. Bare: 117 passed; full with bd 1.3.1: 126 passed.
- **The remaining tools, skills and shared docs are one file with an installed copy too.**
  Same rule as the hooks: policy lives outside the file. `tools/agent_docs_test.sh` sources an
  optional `tools/agent_docs_test.conf` for a repo's own exemptions (`ALLOW_EXTRA`) and path
  anchors (`ROOTS_EXTRA`), so a repo with mounts, data-file conventions or extra top-level
  directories no longer edits the test. `tools/sweep.sh` prunes `.pixi/`, `.venv/` and
  `node_modules/` from repository discovery and says so in its header: conda/pixi installs carry
  malformed `.git` test fixtures that turned a clean zero into false control failures; the suite
  builds that fixture and requires the exclusion. Its real-tree hazard check asserts that a root
  `rg` sees LESS THAN HALF of the corpus instead of "<5%", which was a count in disguise and went
  red the month a root repo grew four subtrees. `tools/check-agent-docs-linked.sh --cached` now
  refuses a staged DELETION of a previously tracked `CLAUDE.md` symlink, which silently unhooked
  Claude Code; one new case. `tools/check-no-agent-cache-paths_test.sh` forces its `git rm
  --cached` so a modified working copy cannot break the fixture. The `triage` skill reads an
  optional project registry (a projects.tsv with a projects.py tool: active projects grouped,
  one `project:` label per bead) and falls back to `bd ready` without one; the skills README says
  the registry tool is not shipped. `docs/ops/other-harnesses.md` gains two sections from a
  2026-10-05 inventory: Grok runs the Claude hooks but cannot block through them (stdout
  discarded, `toolInput` not `tool_input`, exit 2 required), and bd is the only memory store
  for every CLI, with the Grok memory-v2 case and its off switches.
- **The installed hooks and the shipped ones are one file again.** A workspace that had carried
  the pipeline for a month had diverged from it by 68, 168 and 20 lines in the three session hooks,
  and every later fix had to be ported by hand in one direction or the other. Three changes make
  the copies byte-identical, with policy outside the files:
  - The scripts gate's directory pattern `SCRIPT_DIRS_RE` is read from `.claude/bd-prerun.conf`
    (sourced, tracked) or `BD_SCRIPT_DIRS_RE` in the environment, and an EMPTY value turns the gate
    off, bd call included. Editing the hook to drop the rule was the one way to fork it. Thirteen
    new cases in `tools/bd-prerun-hook_test.sh` (both knobs, precedence, the other guards
    unaffected, another directory name); the portability and Pi suites pin the gate on, since a
    clone's conf may turn it off.
  - The SessionStart hook knows about an optional project registry: with a `projects.tsv` and a
    `tools/projects.py` in the repo it prints a per-active-project brief under the rules and words
    rules 1 and 2 for project-scoped work; without the registry it is unchanged. A registry
    without the tool, or a tool that fails, is said out loud. Nine new cases in
    `tools/bd-prime-hook_test.sh`. The two files are not part of the payload yet.
  - The NOT FOUND messages in `.claude/settings.json` and the Pi adapter now say "restore the
    tracked script or re-run the installer", which is right in a clone that tracks its hooks and
    in a fresh install alike; the Pi suite asserts the wording.
- **A memory curation gate ships as the first site check.** bd has no consolidation cadence: a
  store curated once on 2026-09-18 grew for weeks with nothing prompting the next audit, which
  the comparison with an agent CLI whose consolidation runs automatically made plain
  (2026-10-06). `.claude/site-checks/memory-curation-gate.sh` prints one line at session start
  once the store is 30 days or 10 memories past the stamp in `.claude/memory-curation.txt`
  (`BD_CURATION_MAX_DAYS` / `BD_CURATION_MAX_NEW`); it counts from a tracked
  `.beads/memories.jsonl` when one exists, else from `bd memories`, and says so when it cannot
  count. The installer writes the stamp once (today, current count) and never overwrites it; the
  `memory-curate` skill ends every mode, audit included, by rewriting it, replacing its old
  advice to wrap `audit` in `/loop`. `tools/memory-curation-gate_test.sh`: 35 checks, including
  the no-export branch through a stub `bd` and every loud path. The self-test asserts the stamp.
- **`dolt-guard.sh` no longer leaks its lock into the server it starts.** The guard ran
  `bd dolt start` with its `flock` descriptor still open, so the daemonised `dolt sql-server`
  inherited it and held the lock for its whole life. A shell already waiting on the lock (two
  shells opening together at boot, or parallel tool calls) burned the full 30 s and then logged
  `FAILED: timed out waiting for another shell to start dolt` while the server was up — a false
  alarm from the guard whose job is to make that line trustworthy. The descriptor is now closed
  for the child only. Seen on 2026-10-02 after a WSL restart. Four new checks in the race case of
  `tools/dolt-guard_test.sh` (every racer returns 0, none says FAILED, the losers are released
  promptly, the lock is free afterwards); all four fail on the old guard, and the suite drops
  from about 33 s to 5 s because it had been sitting through the same timeout.
- Two silent paths in the SessionStart hook's site checks are named. A check that the 20 s bound
  killed had usually printed nothing yet, and `timeout`'s exit 124 went to the discarded stderr, so
  the kill read as a healthy check; the payload now says KILLED, before any partial output, so the
  size cap cannot drop the note. A script in `site-checks/` without its executable bit was skipped
  by `[ -x ] || continue` with no line saying so; it is now reported as NOT RUN with the chmod to
  run. `BD_PRIME_CHECK_TIMEOUT` (default 20) sets the bound. Found by the 2026-09-30 review of a
  check that runs `cairn` (both reviewers); nine new suite cases.
- **An index too large for the budget is omitted, not sliced; the trim alarm is for real loss.**
  On a 385-memory store the bounded index listed the alphabetical first 85 keys — about 4 KB that
  told the reader almost nothing and crowded out the HOT tier. It is now replaced by one explicit
  `INDEX OMITTED` line with the count and a pointer to `bd memories` search. The loud
  `PAYLOAD TRIMMED` banner now fires only when a HOT body is dropped; an omitted index or bd
  context is expected on a large store and gets at most one quiet line. On that store the payload
  went from 9.7 KB with 5 of 12 HOT bodies and an alarm every session to 8.2 KB with all 6 of a
  trimmed list and no alarm. Three new cases in `tools/bd-prime-hook_test.sh`.
- **Session-scoped stop reminder and scripts gate.** Claude Code's Stop and Pi's `agent_settled`
  fire after EVERY turn, and the bd store is shared by every session on a machine, all claiming as
  the same actor. The stop hook therefore repeated every in-progress issue in the store after each
  turn, and the untracked-scripts gate was licensed by any session's (often stale) claim, so it
  could never fire. `bd-prerun-hook.sh` now records each session's `bd update <id> --claim` (or
  `--status in_progress`) under the hook payload's `session_id` in `.git/bd-session-claims/`; the
  scripts gate needs an issue THIS session claimed, and `bd-stop-hook.sh`, given a session id,
  reports only that session's claimed in-progress issues -- at a turn end (`Stop`) only when the
  set changes, at `SessionEnd` always. Without a session id both keep the old global behaviour.
  The Pi adapter sends Pi's session id, treats `agent_settled` as a turn end and
  `session_shutdown` (quit/new) as the close. A new Pi regression test drives the real hooks over
  a store full of other sessions' work.
- **PreToolUse no longer fails open on text it cannot tokenize.** An unbalanced quote (an
  apostrophe in an unquoted heredoc body is the everyday case) made the tokenizer raise and the
  hook exit 0, switching off the pkill guard, memory admission and the scripts gate at once.
  Heredoc bodies that feed data are now removed before any check (shell-fed bodies are kept and
  checked); text that still cannot be tokenized is judged by the line-based checks; and the
  memory gate identifies `bd remember` calls by tokens, so quoted prose in other commands no
  longer trips it while `env`/`bash -c`/`$(...)`-wrapped calls no longer escape it.

- Opt-in `--with-pi` installs a trusted project-local Pi extension. It reuses the Claude hook
  scripts for startup and compaction priming, model Bash and `!` command guards, Dolt startup,
  and settled-run reminders; cached priming is injected per run without re-running bd. Broken
  pretool scripts fail open **with a visible warning**, rather than taking Pi's default
  throw-to-block path. No user Pi extensions or settings are overwritten.
- `tools/pi-extension_test.sh` exercises the actual TypeScript handler with event fixtures;
  `tools/pi-extension_smoke.sh` proves a real trusted Pi CLI invocation blocks bare `pkill` while
  a harmless stub prevents accidental execution. Untrusted project extensions cannot warn from
  inside the skipped extension; the AGENTS template and docs state the trust gate explicitly.

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
