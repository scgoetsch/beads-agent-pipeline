# beads-agent-pipeline

[![self-test](https://github.com/scgoetsch/beads-agent-pipeline/actions/workflows/selftest.yml/badge.svg)](https://github.com/scgoetsch/beads-agent-pipeline/actions/workflows/selftest.yml)

Session machinery for coding agents, built around [cairn](https://github.com/scgoetsch/cairn), an
agent-facing issue tracker and memory store with the verbs of beads. One command installs it into
a git repo: the agent gets its rules, its issue queue and its durable memory at session start, and
the repo gets guards that fail **loudly** instead of silently.

> **0.2.0 does not read bd.** If your repo has the 0.1 pipeline on bd: **do not re-run the
> installer on that checkout before the store has moved** — follow
> [Moving a repo off bd](#moving-a-repo-off-bd) first (the installer refuses a repo whose store is
> still bd's). **A green install is not a migrated store.** `v0.1.0` remains the bd release.

```bash
git clone https://github.com/scgoetsch/beads-agent-pipeline
cd /path/to/your-project
/path/to/beads-agent-pipeline/install.sh
```

You need `git`, `python3` and [`cairn`](https://github.com/scgoetsch/cairn) 0.7.0 or later first
(the table under [Requirements](#requirements) has the rest), and the install is not finished
until you have run the lines under [After installing](#after-installing) — `cairn init`, the
export refresh, the first commit of `.cairn/`, the suite. If you would rather hand the whole thing
to an agent, see [the runbook](#letting-an-agent-install-it--the-runbook). Releases are tagged; the
changes in each are in [CHANGELOG.md](CHANGELOG.md). Problems go to
[the issue tracker](https://github.com/scgoetsch/beads-agent-pipeline/issues), with the command
and its output.

Existing tool and documentation files are not overwritten: ours lands beside a differing file as
`.new`. An existing `settings.json` is merged with a backup: user hooks survive, including on the
same events. An existing `AGENTS.md` is kept and nothing is written beside it — it is meant to
diverge from the template, and the log says where the template is. `--check` inspects,
`--dry-run` prints every action. Nothing outside the repo is written. Re-running repairs a
checkout whose config drifted; a tool that changed upstream lands as `.new` for you to adopt. In a
repo that had the 0.1 pipeline, the old tracker's hooks are the exception: they are removed in
place (see [the migration](#moving-a-repo-off-bd), step 7).

**`--with-pi` is opt-in**: it installs a project-local Pi extension that reuses the Claude hook
scripts for session priming, command guards, compaction refresh and settled reminders. Pi must
trust the project before the extension loads. No user-level code or Pi settings are installed;
existing extensions are preserved. See [Pi adapter](pipeline/docs/ops/pi-adapter.md) for event
coverage, fail-open warnings and the trust limitation. Git pre-commit guards remain the shared
enforcement layer.

**`--with-concurrent` is opt-in** (`--with-peer` until 2026-10-11; the old spelling is still
accepted with a note, and was renamed because "peer" collided with foreign-lab peer-review
tooling that can sit beside this pipeline in one session), because running several agent
sessions against one repo is an environment question, not a default. Without it the concurrency
doc is not installed and the matching section is stripped from `AGENTS.md`, so nothing cites a
file that is not there — a single-session user carries none of it in a session payload that hosts
already truncate. With it, you get the SET-not-append race rules, one working tree per session
(`tools/new-worktree.sh`), and the rule that bit us: **establish which repo a peer is in before
sending it repo-specific instructions**, because a peer listing does not report a peer's working
directory and an issue-prefix does not imply a separate store.

## The idea

Agents fail in a specific, boring way: **they do not crash, they return success and do nothing.**
A hook with a hardcoded path that resolves nowhere. A search that skipped 99% of the tree and
reported zero hits. A guard whose check is narrower than the thing it guards. All of these read as
"fine" — which is worse than an error, because nobody investigates a green light.

Everything here exists because one of those actually happened. Each guard ships with a `_test.sh`
that tries to make it fail, including a negative control, so a guard that silently matches nothing
cannot pass its own suite.

## What you get

**Session machinery** (`.claude/`) — three hook scripts on four Claude Code events. SessionStart
runs `cairn sync`, then emits the session rules, your hot memories in full, an index of the rest
and cairn's context, and
PreCompact emits the same again before a context compaction; PreToolUse is the guard below; Stop
warns about in-progress issues at session end. Each resolves the repo root from **its own file
location**, never a literal path, and `tools/hook_portability_test.sh` relocates them to a
throwaway root to prove it.

**The pre-execution guard** (Claude Code PreToolUse; optional Pi `tool_call` + `user_bash`)
blocks three things. Two were measured to cause real damage; the third is a discipline you may
not want, and it is one line to turn off:

- **Bare `pkill` / `killall`.** `pkill -f PATTERN` matches the full command line — including the
  shell running it — so it kills its own caller. It comes back as exit 143/144, reads like an
  ordinary failure, and takes anything that shell was supervising with it. Age filters and
  pidfiles are allowed through; `kill` with explicit PIDs is never blocked. Age values must be
  positive; `pkill -o` (oldest) is not an age filter. Literal `env`/`sudo`/`command` wrappers are
  handled. This is an accident-prevention heuristic, not a shell sandbox: aliases, variable-built
  commands and arbitrary shell programs are not comprehensively analyzed.
- **Memory writes that are really session state.** `cairn remember` without `--key`, or a body
  that is structurally a handoff memo, is refused with a pointer to `cairn note` instead (cairn's
  own `remember` adds a near-duplicate check on top). The test is
  structural, not lexical — an earlier vocabulary-based version blocked the memory that documented
  the rule while a rephrase walked straight through.
- **Running a script under `scripts/` with no issue `in_progress` claimed by this session.**
  Untracked analysis runs are how reproducibility gaps start, so the hook asks for a claimed issue
  first. It fails open if cairn is unavailable. The directory pattern is the knob `SCRIPT_DIRS_RE`: set it in
  `.claude/bd-prerun.conf` (a one-line, tracked file the hook sources) or in the environment as
  `BD_SCRIPT_DIRS_RE`; an empty value turns the gate off, and the hook file itself stays identical
  to the one shipped here.

**An optional project registry.** A repo that keeps one store for several projects can add a
`projects.tsv` (one row per project, active or inactive) and a `tools/projects.py` beside it; the
SessionStart hook then opens with a per-active-project brief instead of "run `cairn ready` NOW", and
rule 2 asks for a `project:<name>` label on every issue. Neither file ships here yet; without the
registry nothing changes, and a registry without the tool is reported, not skipped.

**The SessionStart hook** (cached at Pi `session_start` when opted in) first runs `cairn sync`,
which brings this clone's store up to the exports a pull brought in (or builds it in a fresh
clone; a refusal is said at the top). Then, in this order: the rules, a key-only index of the
store (replaced by an explicit INDEX OMITTED line if its keys alone exceed the host budget), the
memories listed in `.claude/memory-hot.txt` while space permits, and cairn's context. The hot list
ships empty, and empty means "index only", not "unconfigured". If the hook has to fall back to the
full `cairn prime` dump — no `jq`, no export — it says so on its first line rather than looking
like the tiered output. It also gives the session an identity in the store's audit trail: where
the host provides `CLAUDE_ENV_FILE` (Claude Code does), it exports `BEADS_ACTOR=<git
user.name>/claude/<8 chars of the session id>`, so `created_by`, claim assignees, comment authors
and every event of the history name the run, not just the human. One consequence is deliberate:
`cairn update --claim` is compare-and-swap on the assignee, so a second session is refused by name
and takes an issue over with `--assignee` first (logged). `BD_PRIME_SESSION_ACTOR=0` opts out; a
failed export is named at the top of the payload.

**The host has a budget, and the hook knows it.** Claude Code keeps only a 2,000-byte preview of
any one SessionStart hook command's output above 10,000 bytes and writes the rest to a file
(measured 2026-09-22 with synthetic hooks, 10,000 arriving whole and 12,000 not; the JSON
`additionalContext` form is capped the same; [anthropics/claude-code#70460](https://github.com/anthropics/claude-code/issues/70460)
states the same numbers and no setting to raise them). A 15.9 KB tiered payload lost its hot
tier and its index that way while every line of it read as success. So the hook budgets:
`BD_PRIME_BUDGET` (default 10000; `0` lifts the cap on a host that has none) bounds what it
emits, hot bodies that do not fit are named at the top instead of shipped (`cairn recall <key>`
fetches one), and an index too large for the remaining budget is replaced by one INDEX OMITTED line with
the count (`cairn memories <keyword>` searches the store directly). A loud PAYLOAD TRIMMED banner
means a HOT body was dropped; an omitted index or store context alone is expected, not an alarm. The
store's context is the first thing dropped, and the full-dump fallback is cut with a line saying so.
A listed index can use up to 4 KB of the host allowance; keep the hot list to essential guards.

**`tools/sweep.sh`** — corpus-wide search with a **positive control per repo**. It lifts real lines
out of each repo and greps for them through the identical code path; if they do not come back, that
repo was not searched and the sweep exits non-zero. Exit 0 is the only thing that licenses "it
isn't there". Measured 2026-09-21 in the workspace this came from: a plain `rg` at the root
reached 131 files; the corpus was 8,993 across 7 repos. Zero hits, no error. Re-measure in your
own tree — the ratio is the durable claim, and an absolute threshold ages out. Repository discovery
has no implicit depth limit; `--depth N` / `SWEEP_DEPTH=N` explicitly limits it and returns exit 2,
not a trustworthy zero (`0` means unlimited). Files exactly at the byte cap are included.

**`tools/check-no-agent-cache-paths.sh`** — refuses commits that embed a per-conversation agent
cache path (`~/.gemini/antigravity-cli/brain/<uuid>/`, `~/.claude/projects/<uuid>/`,
`/tmp/claude-<uid>/`). Those resolve for nobody else and on no other machine, so a figure linked
from one is a broken image for every other reader. It runs at the **git layer** on purpose: the
trap is not specific to one agent, so neither is the guard — it covers the agent that has no
session hooks at all. Documents and generated JSON are scanned whole-file; code on added lines
only, a ratchet rather than a flag day. Both inspect the **index**, not the working copy. The
symlink guard likewise uses `--cached` on commit, so partial staging cannot hide a bad artifact;
its manual invocation still checks the working tree.

**`tools/refresh-beads-exports.sh`** — the four files git carries of the store
(`.cairn/issues.jsonl`, `memories.jsonl`, `allocator.json`, `events.jsonl`; the database itself is
git-ignored), refreshed from cairn. The pre-commit runs it with `--cached` and refuses a commit
whose staged exports differ from the store, or whose history is not an append to HEAD's; a cairn
that cannot run is "not compared", said on stderr, and the commit goes through. It refuses to
write over the files from a store that is behind them or has diverged (another clone's work came
in: `cairn sync` first; two clones wrote: there is no merge). The pre-commit also runs `cairn
check`, and `post-merge` / `post-checkout` run `cairn sync`.

**`tools/new-worktree.sh`** — a second working tree that shares this checkout's store through an
untracked `.cairn/redirect`, written before the checkout so the post-checkout sync cannot build a
stray store there.

**Skills** — `memory-curate` (audit, dedupe and tier the memory store) and `triage` (surface and
plan the top ready issue, read-only, without claiming it). Both are **inert until you invoke
them** — a skill is a prompt, not a hook — so they install by default and cost nothing at runtime,
and `rm -rf .claude/skills/<name>` removes one cleanly. They do carry assumptions (a cairn store;
`/loop` and `/schedule` are harness features, not requirements; `triage` mentions a maker/checker
verifier that is yours to define), all written down in `.claude/skills/README.md`.

**Per-repo policy stays out of the shipped files.** The pre-run hook's scripts gate is tuned or
switched off in `.claude/bd-prerun.conf`; the agent-docs test's exemptions and path anchors go in
`tools/agent_docs_test.conf`. Neither file ships, both are sourced when present, and with them a
repo's installed copies can stay byte-identical with this payload, so a later fix is a copy rather
than a merge.

**A curation gate** — `.claude/site-checks/memory-curation-gate.sh`, the one site check that
ships. The store has no consolidation cadence of its own, so this prints one line at session start once
the store is 30 days or 10 memories past the last curation (`BD_CURATION_MAX_DAYS` /
`BD_CURATION_MAX_NEW`), naming the numbers and the skill to run. The installer writes the stamp it
reads, `.claude/memory-curation.txt`, once; `memory-curate` rewrites it after every run. A stamp or
count it cannot read is reported, never skipped.

**An `AGENTS.md` template** that is symlinked from `CLAUDE.md` — one file, two names, so they
cannot drift. The workspace this came from had them as two real files that diverged by ~180 lines
before anyone noticed, and the part missing from the copy one tool read was the protocol for
keeping claims consistent. A guard asserts the link and its target on every commit; the two ways
it breaks (a tool replacing the link, and a checkout without symlink support) and the fallback for
a filesystem that has no symlinks are in `docs/ops/agent-docs-symlink.md`. It includes the
section most people need and few write: an explicit statement that these rules **supersede** the
harness's own injected instructions about where tasks and memory live, because harnesses will
contradict them repeatedly.

**Docs** (`docs/ops/`) — the reasoning behind each guard, including the measurements. Start with
`checks-narrower-than-what-they-check.md`: fourteen instances of the one defect class every guard
here is built against, with the diagnostic question to ask of your own checks.

## Letting an agent install it — the runbook

`AGENTS.md` in this directory (and `CLAUDE.md`, a symlink to it) is a runbook an agent follows top
to bottom on a machine that has never seen cairn: install the prerequisites, self-test the pipeline,
install it into a project, create the store and commit what git carries of it, prove every guard
through `git commit`, rebuild the store in a second clone, exercise the session hooks, and report
in a fixed shape. Eight phases; the first seven end in a gate, the
eighth is the report. It is the procedure that was run by hand on the first fresh box, and running
it as written is what found most of the bugs in this repository's history — so it is also the
acceptance test for a new platform.

**On the box itself.** Clone, start your harness inside the clone, and tell it what to do:

```bash
git clone https://github.com/scgoetsch/beads-agent-pipeline ~/beads-agent-pipeline
cd ~/beads-agent-pipeline
claude          # or codex, agy, grok — each reads AGENTS.md (CLAUDE.md is the same file) on startup
```

Then one instruction: *"Follow AGENTS.md end to end. Install into `~/proj/<name>`. Stop at any
gate that fails and report it verbatim. Finish with the report in section 8."* Start the harness
inside the clone, not somewhere above it — that is where it looks. Name the project directory
yourself: the runbook tells the agent never to work in a tree another session is using.

**From another machine.** The first run was driven over ssh from a session on a different box,
which works because every step is a shell command with a checkable result. Give the agent the
alias (`ssh <box>`) and the same instruction; tell it `~/.local/bin` is not on PATH in the
non-login shells ssh gives it, which the runbook also says. Anything that needs a password —
`sudo` for `apt`, typically — is the one thing it cannot do for you; give it a box where the
prerequisites are already there, or run those two lines yourself first.

**Permissions.** Interactive is the default and the right choice the first time: the run asks you
to approve a `git clone` of cairn, a `curl | bash` install of Claude Code and an `apt-get`. An unattended run
needs your harness's unattended permission mode, which grants the agent a full shell — read the
runbook once before you grant that, so you know what it will do with it.

**What you get back.** The section-8 report — versions, `RESULT:` lines, the three git proofs,
and every gate that did not match, with its output. Read the deviations. Each is either a platform
difference worth recording in the runbook or a bug in this repository; file it at
https://github.com/scgoetsch/beads-agent-pipeline/issues with the command and its output. Two
gates failed the first time the runbook was run as written (the settings.json re-merge counted
as a problem; an empty memory store treated as a failed export); both were real and both are now
fixed and tested.

**What it will not do.** Sign in to Claude Code for you. On a box that is not signed in, the
session hooks are verified by running each script by hand; on one that is, section 7 proves they
fire with a `claude -p` sentinel check. Install the concurrent-sessions layer, unless you ask
for `--with-concurrent`.
Bypass a guard: the runbook forbids `git commit --no-verify`, and an agent that reaches for it has
found a bug, not a shortcut.

## Verify it

```bash
./selftest.sh
```

Installs into throwaway git repos and, there: runs every shipped guard's suite; proves the
git-layer guards through real `git commit`s (a cache path refused, a broken symlink refused, the
whole payload committing clean under its own hooks); proves that no installed hook runs the old
tracker; installs with `cairn` hidden from PATH and checks the hooks are wired anyway; proves the
refusal of a repo whose store has not moved, and the in-place removal of the old tracker's blocks on
a 0.1-era fixture
(under a scratch `HOME` for the `~/.bashrc` part); requires a re-run to be a no-op; checks it never
clobbers your files, names any installed file your `.gitignore` would eat, and writes nothing
under `--dry-run` or `--check`. The opt-in Pi install runs an event suite through its TypeScript
handler when Node ≥22.19 is present (otherwise explicitly SKIP); a real Pi smoke is still needed to
prove the extension loads and intercepts a model tool call. Nothing outside the temp directories
is touched. It needs the same things the pipeline needs; without `jq` the SessionStart suite tests
the fallback instead of the tiering and says so, and the probes that need a real cairn store say
SKIP without cairn.

**On a clean box, in Docker:**

```bash
test/selftest-in-container.sh          # bare (git + python3 only), then full (+ cairn, jq, rg)
test/selftest-in-container.sh bare     # one target; --build-only skips the run
```

`test/Dockerfile` builds two Ubuntu 24.04 images: `bare` has nothing the pipeline lists beyond
git, python3 and bash, so the installer's "required command absent" exit and every optional
fallback get exercised; `full` adds cairn (a clone at the commit the workflow pins), jq and
ripgrep. Each run mounts this checkout read-only, copies it inside, and runs `./selftest.sh` there
as a non-root user. The first run of this harness found real defects the host had hidden, among
them a sweep binary-file case that depends on a UTF-8 locale a container does not have.

**On every push, in GitHub Actions** (`.github/workflows/selftest.yml`): the same `./selftest.sh`
on `ubuntu-latest`, on `macos-latest` (bash from Homebrew, since the stock `/bin/bash` is 3.2) and
on `windows-latest` (Git Bash). cairn comes from github.com/scgoetsch/cairn at the commit the
workflow pins (`CAIRN_REF`, the commit of cairn's tag v0.8.0), into a directory of its own so the
self-test's no-cairn probe can hide it. Each job writes its box line, the RESULT line and every
FAIL to the run summary and keeps the log as an artifact; after a failure it also keeps the
installer's own output and every suite's full log, since the self-test shows only a failing
suite's last 35 lines. All three jobs are gates. The causes the matrix found on the 0.1 pipeline —
BSD `wc` padding, two spellings of one directory, GNU-only `date` flags, the CR LF a native
Windows Python and jq append, a Git Bash `ln -s` that copies, symlinked binaries that lose their
DLLs, and what each box's grep calls binary — are each in the CHANGELOG. Three suites SKIP a case
by name where the box cannot build it (a real `timeout`, a `chmod -x` that takes effect, a tab in
a filename), and `audit_wikilinks_test.sh` SKIPs whole under a native Windows Python, which cannot
run its shell stub for cairn.

## Requirements

**Tested on:** Linux (Ubuntu, bash 5, GNU coreutils/findutils/sed) with cairn 0.7.0, by
`./selftest.sh`. The 0.1 pipeline passed the same self-test on macOS 26 and native Windows (Server
2025, Git Bash) in the Actions matrix, and its opt-in Pi adapter was exercised with a real trusted
Pi CLI 0.87.1 on Linux/WSL2; 0.2.0's matrix runs are what the workflow badge shows. This is not a
fresh signed-in Claude Code run. On macOS you will want bash from Homebrew. Run `./selftest.sh`
first on any other platform and file what fails.

| | | |
| --- | --- | --- |
| [Claude Code](https://claude.com/claude-code) | needed **for Claude session hooks only** | `.claude/settings.json` wires four scripts on six Claude events; these do not load under Pi (the Pi adapter runs the prime, prerun and stop hooks, not `bd-cue-hook.sh`). Everything at the git layer, every tool and `AGENTS.md` work under any harness or none — `pipeline/docs/ops/other-harnesses.md` has the matrix. |
| [Pi](https://github.com/badlogic/pi-mono) (Node ≥22.19) | required **only with `--with-pi`** | The optional project extension calls those same scripts through Pi's event API. Project trust is required; `--no-approve` or `--no-extensions` skips the adapter. Do not infer guard coverage from `AGENTS.md` alone. |
| `git`, `python3` (3.9+) | required | everything is git-scoped; the PreToolUse guard parses hook JSON; cairn is stdlib-only Python |
| [`cairn`](https://github.com/scgoetsch/cairn) 0.7.0+ | required | the issue tracker and memory store: a SQLite database in `.cairn/`, git-ignored, plus four tracked files beside it. Install: `git clone https://github.com/scgoetsch/cairn && ln -s "$PWD/cairn/bin/cairn" ~/.local/bin/cairn`. 0.7.0 is the first that keeps the tracked files in `.cairn/`; the installer checks `cairn --version` |
| `jq` | optional | without it, session start falls back to the full `cairn prime` dump |
| `iconv` | optional | without it, `sweep.sh` cannot flag bad-UTF-8 files as unsearchable |
| `rg` | optional | only `sweep_test.sh`'s demonstration of the bare-grep hazard uses it; the sweep itself does not |
| `timeout` | optional | bounds each `.claude/site-checks/` script at session start; without it (stock macOS) the checks run unbounded, the session payload says so, and a hung check can stall session start |

`install.sh --check` reports what is present. It states the Claude harness rather than probing
for it: a `claude` on PATH does not prove session hooks fire. With `--with-pi` it checks for the
Pi executable but only a real trusted Pi session can prove the extension loaded.

**Installing Claude Code**, if you want the session hooks:

```bash
curl -fsSL https://claude.ai/install.sh | bash     # native build
claude doctor                                       # check the install
```

`claude install <stable|latest|version>` manages the native build and `claude update` upgrades it.
The native installer puts a versioned binary under `~/.local/share/claude/versions/` and symlinks
`~/.local/bin/claude` at it. If you would rather not install it, everything except the session
hooks still works — see `docs/ops/other-harnesses.md`, which also shows how to prime a session by
hand.

## What this is not

- **Not a tracker.** cairn is the store; this is configuration, hooks and guards around it.
- **Not tied to one agent harness — but be precise about it.** The default session hooks are
  Claude Code's `settings.json` format. Pi needs the opt-in trusted project extension; agy, a Grok
  REPL and Cursor run neither. Everything at the git layer (`.beads-hooks/pre-commit`: `cairn
  check`, agent-cache paths, agent-docs symlink, export freshness; `post-merge`/`post-checkout`:
  `cairn sync`), every tool and `AGENTS.md` itself work anywhere. That split is
  deliberate: a session hook binds one harness, `git commit` binds all of them, so anything that
  must not escape the repo is enforced there. Full matrix of what fires where, and how to prime a
  session by hand: `docs/ops/other-harnesses.md`.
- **Not a CI system.** The guards run at commit time and session time, on one machine.
- **Not opinionated about your domain.** Project conventions go in *your* `AGENTS.md`, beside the
  code they govern.

## After installing

```bash
cairn init -p <PREFIX>                 # if there is no cairn store yet; the prefix is yours to choose
tools/refresh-beads-exports.sh         # writes the four tracked files into .cairn/
git add .cairn/.gitignore .cairn/config.json .cairn/issues.jsonl .cairn/memories.jsonl \
        .cairn/allocator.json .cairn/events.jsonl
git commit -m "cairn store" -- .cairn/
tools/agent_docs_test.sh               # then the rest of the suite listed in AGENTS.md
```

A store is not finished until another clone can `cairn sync` from it: git carries
`.cairn/config.json` and the four files, never the database. Then open `AGENTS.md` and make it
yours. It is a starting point, not a fixed file.

Every clone runs `git config core.hooksPath .beads-hooks` once (or the installer, which sets it):
it is local config and no clone inherits it, so until then nothing in `.beads-hooks/` runs and
only the session-start hook syncs the store.

## Moving a repo off bd

For a repo that has the 0.1 pipeline and its store in bd. **Store first, hooks second; in this
order, stopping at the first failure.** The installer refuses step 7 until steps 1–6 have made a
writable cairn store (`cairn init` writes `.cairn/cairn.db`), so it cannot be run out of order by
accident — but a green install proves only the install, not the move. cairn's README, "Moving a
bd store over" and "Migrating from other bd versions", is the reference for each cairn verb below;
read it once before step 3.

**What the steps need.** A `dolt` binary: bd embeds Dolt and ships none, and any dolt release that
reads the store works (cairn measured 2.4.2 on bd 1.1.2). `<dolt>` below is that binary's path.
The Dolt repository is read from a copy, never in place. A `.beads/` holding both an embedded
(`embeddeddolt/`) and a server-mode (`dolt/`) store is refused until you name the repository
(cairn's README says how).

1. **Freeze writers**: no other session, no `bd dolt push`, no other clone writing.
2. **`bd export --all`** (to a file outside the tree, e.g. `bd export --all -o /tmp/bd.jsonl`).
3. **`cairn seed-from-dolt .beads --dolt <dolt>`** (every id ever issued, deleted ones too), on a
   copy, `-o seed.json`. A seed not read from Dolt can reissue deleted ids.
4. **`cairn history-from-dolt`** against that export; keep the manifest:
   `cairn history-from-dolt .beads --dolt <dolt> --export /tmp/bd.jsonl -o history.jsonl --manifest manifest.json`,
   adding `--interactions .beads/interactions.jsonl` **only when that file exists** (a missing file
   fails the read). **If it fails, stop**: an `init` without `--events` is a content migration that
   silently drops the history. `-o` refuses an existing file, so remove a failed attempt's output
   before running it again. Where cairn's `dev/verify-dolt-history.py` is available, run it on the
   result: the check in step 5 compares the end state, not every intermediate memory body and
   issue text the history claims to carry.
5. **`cairn init -p <prefix> --from <export> --seed <seed> --events <history>`** (plus `--ledger
   .beads/memgraph-ledger.json`, `--hot .claude/memory-hot.txt`, when present); require its
   byte-identical or equal-content line. `<prefix>` is the prefix of the issues in the export:
   `init` refuses an issue under another one. If the repo ever ran `cairn shadow sync`, its
   `.cairn/cairn.db` is a shadow: `init` refuses an existing database, so move the shadow aside
   first (`mkdir -p ../shadow-db && mv -f .cairn/cairn.db* ../shadow-db/`).
6. **`cairn check`, and take the old exports out of `.beads/`.** bd's own `issues.jsonl` (and any
   `memories.jsonl`, `allocator.json`, `events.jsonl` there) is usually tracked, and cairn refuses
   exports split between `.beads/` and `.cairn/` (`cairn sync`: "the tracked exports are split";
   the export refresh refuses too). A file left on disk is still a split, so remove them, not just
   untrack them: `git rm -q -f --ignore-unmatch .beads/issues.jsonl .beads/memories.jsonl
   .beads/allocator.json .beads/events.jsonl && rm -f .beads/issues.jsonl .beads/memories.jsonl
   .beads/allocator.json .beads/events.jsonl` (git history keeps them; the installer prints the
   same line for any that are left). **Do not commit yet**: until step 7, bd's own git hooks are
   still in `.beads-hooks/`, and a commit runs them — its pre-commit re-exports and stages
   `.beads/issues.jsonl` (the split again), and `--no-verify` would not help, because it does not
   skip `prepare-commit-msg`, which bd also installs.
7. **Then install the cairn-only pipeline, and commit the store with it.** `install.sh` removes
   bd's managed blocks from every git hook in `.beads-hooks/` in place, bd's harness entries (`bd
   prime` in `.claude/settings.json` and `settings.local.json`, the Codex and Cursor hooks), and
   the `~/.bashrc` block for this repo; writes `.cairn/redirect` in sibling worktrees; backs up
   each file it edits under `.git/beads-agent-pipeline-backup/<timestamp>/`. A bd-era pipeline
   file you edited keeps your copy and gets ours as `.new` — **adopt the `.new` of every file the
   installer names as bd-era** (`mv -f <file>.new <file>`), or bd keeps running there, and run the
   installer again; only once none is live does it print the `git rm` of what is no longer shipped
   (`.claude/store-cli`, `tools/dolt-guard.sh`, the `store-cli-*` tools). Delete bd's managed block
   in `AGENTS.md` if it names one. Then write the four files and commit them with `config.json`
   and `.gitignore` (and the install): `tools/refresh-beads-exports.sh && git add .cairn/.gitignore
   .cairn/config.json .cairn/issues.jsonl .cairn/memories.jsonl .cairn/allocator.json
   .cairn/events.jsonl`, then commit. The pipeline's pre-commit now runs `cairn check` and the
   export freshness guard, and nothing of bd's.
8. **Leave `.beads/` on disk until a person has read the manifest**; other clones need cairn
   0.7.0+ and `cairn sync`.

This is the design's sequence with two changes the implementation found: the old exports have to
leave `.beads/` (step 6), and the first commit comes after the hooks have changed (steps 6–7),
because bd's hooks would put the split back. A one-verb migration may replace this list later.

### What breaks

For a bd user who pulls 0.2.0 and re-runs `install.sh`:

- **The install requires cairn**, and refuses a repo whose store is still bd's; nothing is
  installed until the store has moved.
- **Their store is still bd**, and nothing here reads it. Adopted `.new` hooks do not read it
  either; an un-adopted bd-era hook can still run bd.
- **`bd dolt push` is gone from session completion.** Two machines share the store through git of
  the four files and `cairn sync`, and two clones that both wrote are refused, with no merge:
  decide which machine writes.
- **CI as written fails**: it installed bd, and the pipeline now needs cairn.
- **There is no switch back inside the pipeline.** `.claude/store-cli` is ignored; going back is
  checking out `v0.1.0` and the bd store the move left on disk.
- **`bd` itself still works if it is on PATH** — it is the user's own tool, and nothing here blocks
  it. Run in this repo, it reads and writes a bd store that cairn never reads.

## Known limitations

- **No upgrade path.** The installer never overwrites a file you have (the old tracker's managed
  blocks aside, in a repo that had the 0.1 pipeline). When a shipped tool changes upstream, re-running the installer lands it as
  `tools/<name>.new` with a `DIFFERS` line; diff it, `mv -f` it into place, `chmod 755`. Tracked; a
  hash manifest is the likely fix.
- **The names are still beads'.** `bd-prime-hook.sh`, `bd-prerun-hook.sh`, `bd-stop-hook.sh`, `bd-cue-hook.sh`,
  `.beads-hooks/`, `.pi/extensions/beads-pipeline.ts`, `BEADS_ACTOR`, the `BD_*` knobs,
  `.git/bd-session-claims/` and `tools/refresh-beads-exports.sh` keep their names in this release:
  renaming them is a settings-merge and `core.hooksPath` migration of its own, for a later one.
- **cairn is pinned by commit, not version.** CI and the container name the commit of cairn's tag v0.8.0
  rather than the tag, which could be moved, and the installer checks only `cairn --version` ≥ 0.7.0.
- **Platform coverage is what the Actions matrix runs: Ubuntu 24.04, macOS and Windows Server 2025
  under Git Bash, plus the Docker self-test on a bare Ubuntu.** Not covered: a Windows box that
  cannot create symlinks (the runner can; the installer's pointer-file fallback is exercised on
  Linux instead), PowerShell or cmd as the shell, and zsh.
- **This repository does not run its own git-layer guards on its own commits** — `core.hooksPath`
  is not set here. The self-test proves the installed payload commits clean under the guards; the
  root files (`README.md`, `AGENTS.md`, `selftest.sh`) are checked only by a manual sweep.

## What it touches, and how to remove it

Inside the target repo: `.claude/` (three hook scripts, `memory-hot.txt`, `settings.json` merged
with a backup at `settings.json.bak.<epoch>`, `skills/`, `site-checks/`), optional `.pi/extensions/`
(with `--with-pi` only), `tools/`, `docs/ops/`, `.beads-hooks/` (`pre-commit`, `post-merge`,
`post-checkout`), `AGENTS.md` (only if absent) and the `CLAUDE.md` symlink, plus `core.hooksPath`
in git config. In a repo that had the 0.1 pipeline: the old tracker's blocks and harness hooks are removed in place, each
edited file backed up under `.git/beads-agent-pipeline-backup/<timestamp>/`, and sibling worktrees
get an untracked `.cairn/redirect`. Linked worktrees are supported: the installer enables
`extensions.worktreeConfig` when needed, migrates the main checkout's `core.bare`/`core.worktree`
values to its `config.worktree`, and sets the target's hooks path with `--worktree`, leaving
sibling hook settings alone. Submodules use their own config. Outside the repo: nothing, except
that the old `~/.bashrc` dolt-guard block for this repo, if one is there, is removed (backup
beside it). For a linked worktree use `git config --worktree --unset core.hooksPath` when removing
it. To remove everything:

```bash
git config --unset core.hooksPath          # or point it back where it was
rm -rf .claude/bd-*-hook.sh .claude/memory-hot.txt .claude/skills .claude/site-checks \
       tools docs/ops .beads-hooks
rm -f .pi/extensions/beads-pipeline.ts  # only if you opted in; leave other Pi extensions alone
# the OLDEST backup (epoch suffix, so it sorts first) is your pre-install settings.json, if any
cp -f "$(ls .claude/settings.json.bak.* | sort | sed -n 1p)" .claude/settings.json \
  && rm -f .claude/settings.json.bak.*
```

`AGENTS.md` and `CLAUDE.md` are yours by then; keep or delete as you like. `cairn` and its store
(`.cairn/`) are untouched by any of this.

## License

MIT. See [LICENSE](LICENSE).
