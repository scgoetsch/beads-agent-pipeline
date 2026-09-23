# beads-agent-pipeline

Session machinery for coding agents, built around [beads](https://github.com/gastownhall/beads)
(`bd`). One command installs it into a git repo: the agent gets its rules, its issue queue and
its durable memory at session start, and the repo gets guards that fail **loudly** instead of
silently.

```bash
git clone https://github.com/scgoetsch/beads-agent-pipeline
cd /path/to/your-project
/path/to/beads-agent-pipeline/install.sh
```

You need `git`, `python3` and [`bd`](https://github.com/gastownhall/beads) first (the table under
[Requirements](#requirements) has the rest), and the install is not finished until you have run
the three lines under [After installing](#after-installing) — `bd init`, `bd hooks install
--shared`, the suite. If you would rather hand the whole thing to an agent, see
[the runbook](#letting-an-agent-install-it--the-runbook). Releases are tagged; the changes in
each are in [CHANGELOG.md](CHANGELOG.md). Problems go to
[the issue tracker](https://github.com/scgoetsch/beads-agent-pipeline/issues), with the command
and its output.

Existing tool and documentation files are not overwritten: ours lands beside a differing file as
`.new`. An existing `settings.json` is merged with a backup: user hooks survive, including on the
same events, and only bd's standalone `bd prime` SessionStart registration is replaced. An existing `AGENTS.md` is kept and nothing is written
beside it — it is meant to diverge from the template, and the log says where the template is.
`--check` inspects, `--dry-run` prints every action, `--no-shell` skips the one thing written
outside the repo: a marker-managed block in `~/.bashrc` that sources `tools/dolt-guard.sh` — one
project per `.bashrc`, and a no-op on an embedded bd store (see the guard below). Re-running
repairs a checkout whose config drifted; a tool that changed upstream lands as `.new` for you to
adopt.

**`--with-pi` is opt-in**: it installs a project-local Pi extension that reuses the Claude hook
scripts for session priming, command guards, compaction refresh and settled reminders. Pi must
trust the project before the extension loads. No user-level code or Pi settings are installed;
existing extensions are preserved. See [Pi adapter](pipeline/docs/ops/pi-adapter.md) for event
coverage, fail-open warnings and the trust limitation. Git pre-commit guards remain the shared
enforcement layer.

**`--with-peer` is opt-in**, because running several agent sessions against one repo is an
environment question, not a default. Without it the concurrency doc is not installed and the
matching section is stripped from `AGENTS.md`, so nothing cites a file that is not there — a
single-session user carries none of it in a session payload that hosts already truncate. With it,
you get the SET-not-append race rules, `bd dolt push` serialisation, and the rule that bit us:
**establish which repo a peer is in before sending it repo-specific instructions**, because a peer
listing does not report a peer's working directory and an issue-prefix does not imply a separate
store. One piece of concurrency machinery ships either way — the `flock` in `tools/dolt-guard.sh`
that stops two shells racing to start the Dolt server, which costs a single-session user nothing.

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
emits the session rules, the bd context, your hot memories in full and an index of the rest, and
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
- **Memory writes that are really session state.** `bd remember` without `--key`, or a body that
  is structurally a handoff memo, is refused with a pointer to `bd note` instead. The test is
  structural, not lexical — an earlier vocabulary-based version blocked the memory that documented
  the rule while a rephrase walked straight through.
- **Running a script under `scripts/` with no bd issue `in_progress`.** Untracked analysis runs
  are how reproducibility gaps start, so the hook asks for a claimed issue first. It fails open
  if bd is unavailable. The directory name is the one-line knob `SCRIPT_DIRS_RE` in
  `.claude/bd-prerun-hook.sh`; set it to something that matches nothing to drop the rule.

**The SessionStart hook** (cached at Pi `session_start` when opted in) replaces bd's raw
`bd prime` dump (76 KB on a 40-memory store) with, in this order, the rules, a key-only index of
the store, the memories listed in
`.claude/memory-hot.txt` in full, and the bd context. The hot list ships empty, and empty means
"index only", not "unconfigured". If the hook has to fall back to the full dump — no `jq`, no
export — it says so on its first line rather than looking like the tiered output.

**The host has a budget, and the hook knows it.** Claude Code keeps only a 2,000-byte preview of
any one SessionStart hook command's output above 10,000 bytes and writes the rest to a file
(measured 2026-09-22 with synthetic hooks, 10,000 arriving whole and 12,000 not; the JSON
`additionalContext` form is capped the same; [anthropics/claude-code#70460](https://github.com/anthropics/claude-code/issues/70460)
states the same numbers and no setting to raise them). A 15.9 KB tiered payload lost its hot
tier and its index that way while every line of it read as success. So the hook budgets:
`BD_PRIME_BUDGET` (default 10000; `0` lifts the cap on a host that has none) bounds what it
emits, hot bodies that do not fit are named at the top instead of shipped (`bd recall <key>`
fetches one), the bd context is the first thing dropped, and the full-dump fallback is cut the
same way with a line saying so. On Claude Code that leaves roughly 8 KB for hot bodies; keep the
hot list to guards, not to everything you would like an agent to know.

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

**`tools/dolt-guard.sh`** — restarts bd's Dolt server after a reboot. Without it, `bd` reads keep
working while writes silently fail to land, which is the worst possible shape for a data store.
It applies to a server-mode store only: bd 1.3's default is an embedded, in-process store with no
server (`bd dolt status` says so), and there the guard has nothing to guard and stays silent.

**Skills** — `memory-curate` (audit, dedupe and tier the memory store) and `triage` (surface and
plan the top ready issue, read-only, without claiming it). Both are **inert until you invoke
them** — a skill is a prompt, not a hook — so they install by default and cost nothing at runtime,
and `rm -rf .claude/skills/<name>` removes one cleanly. They do carry assumptions (bd initialised;
`/loop` and `/schedule` are harness features, not requirements; `triage` mentions a maker/checker
verifier that is yours to define), all written down in `.claude/skills/README.md`.

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
to bottom on a machine that has never seen bd: install the prerequisites, self-test the pipeline,
install it into a project, initialise bd, prove every guard through `git commit`, exercise the
session hooks, and report in a fixed shape. Eight phases; the first seven end in a gate, the
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
to approve two `curl | bash` installs (bd's and Claude Code's) and an `apt-get`. An unattended run
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
fire with a `claude -p` sentinel check. Install the peer layer, unless you ask for `--with-peer`.
Bypass a guard: the runbook forbids `git commit --no-verify`, and an agent that reaches for it has
found a bug, not a shortcut.

## Verify it

```bash
./selftest.sh
```

Installs into throwaway git repos and, there: runs every shipped guard's suite; proves the
git-layer guards through real `git commit`s (a cache path refused, a broken symlink refused, the
whole payload committing clean under its own hooks); installs with `bd` hidden from PATH and
checks the hooks are wired anyway; re-runs after what `bd init` and `bd hooks install --shared`
do and requires a no-op; checks it never clobbers your files, names any installed file your
`.gitignore` would eat, reports the memory-graph ledger's state, and writes nothing under
`--dry-run` or `--check`. The opt-in Pi install runs an event suite through its TypeScript
handler when Node ≥22.19 is present (otherwise explicitly SKIP); a real Pi smoke is still
needed to prove the extension loads and intercepts a model tool call. Nothing outside the temp
directories is touched. It needs the same things the pipeline needs; without `jq` the
SessionStart suite tests the fallback instead of the tiering and says so.

## Requirements

**Tested on:** Ubuntu 26.04 (bash 5, GNU coreutils/findutils/sed), with bd 1.1.2 and 1.3.0. The
self-test also passes on Linux/WSL2 (bash 5.2, git 2.43, Python 3.12, bd 1.1.2). The opt-in Pi
adapter was exercised with a real trusted Pi CLI 0.87.1 (`@earendil-works/pi-coding-agent`) on
Linux/WSL2, plus an event suite. This is not a fresh signed-in Claude Code run. **macOS and
native Windows are untested**; on macOS you will want bash from Homebrew. Run `./selftest.sh` first
on any other platform and file what fails.

| | | |
| --- | --- | --- |
| [Claude Code](https://claude.com/claude-code) | needed **for Claude session hooks only** | `.claude/settings.json` wires three scripts on four Claude events; these do not load under Pi. Everything at the git layer, every tool and `AGENTS.md` work under any harness or none — `pipeline/docs/ops/other-harnesses.md` has the matrix. |
| [Pi](https://github.com/badlogic/pi-mono) (Node ≥22.19) | required **only with `--with-pi`** | The optional project extension calls those same scripts through Pi's event API. Project trust is required; `--no-approve` or `--no-extensions` skips the adapter. Do not infer guard coverage from `AGENTS.md` alone. |
| `git`, `python3` | required | everything is git-scoped; the PreToolUse guard parses hook JSON |
| [`bd`](https://github.com/gastownhall/beads) | required | the issue tracker and memory store. bd manages its own Dolt: 1.3's default is an embedded, in-process store, and a server mode exists (`bd dolt start`). No separate `dolt` binary is needed and nothing here calls one |
| `jq` | optional | without it, session start falls back to the full `bd prime` dump |
| `iconv` | optional | without it, `sweep.sh` cannot flag bad-UTF-8 files as unsearchable |
| `rg` | optional | only `sweep_test.sh`'s demonstration of the bare-grep hazard uses it; the sweep itself does not |
| `ss` | optional | `dolt-guard.sh`'s listener probe, server-mode stores only; it falls back to `lsof`, then `netstat`, and says so when none of the three is present. Embedded stores never reach it |
| `timeout` | optional | bounds each `.claude/site-checks/` script at session start; without it (stock macOS) the checks run unbounded, the session payload says so, and a hung check can stall session start |
| [`bd-memgraph`](https://github.com/scgoetsch/bd-memgraph) | optional | typed `[[wikilinks]]` over your memories, plus a pre-commit graph guard. One python3 file, no dependencies: clone it and symlink `bd-memgraph.py` onto your PATH. Without it the shipped pre-commit stanza self-skips and nothing else changes. |

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

- **Not a bd replacement or fork.** bd is unmodified; this is configuration, hooks and guards
  around it.
- **Not tied to one agent harness — but be precise about it.** The default session hooks are
  Claude Code's `settings.json` format. Pi needs the opt-in trusted project extension; agy, a Grok
  REPL and Cursor run neither. Everything at the git layer (`.beads-hooks/pre-commit`: memory graph, agent-cache paths, agent-docs symlink, bd's
  own hooks), every tool, the shell guard and `AGENTS.md` itself work anywhere. That split is
  deliberate: a session hook binds one harness, `git commit` binds all of them, so anything that
  must not escape the repo is enforced there. Full matrix of what fires where, and how to prime a
  session by hand: `docs/ops/other-harnesses.md`.
- **Not a CI system.** The guards run at commit time and session time, on one machine.
- **Not opinionated about your domain.** Project conventions go in *your* `AGENTS.md`, beside the
  code they govern.

## After installing

```bash
bd init --prefix <XX>        # choose your own issue prefix
bd hooks install --shared    # --shared matters: without it git ignores them
tools/agent_docs_test.sh     # then the rest of the suite listed in AGENTS.md
```

Then open `AGENTS.md` and make it yours. It is a starting point, not a fixed file.

What current bd (1.3) does at that point, measured on a fresh box, so none of it surprises you:
`bd init` appends its own managed block to `AGENTS.md`, adds its SessionStart hook to
`.claude/settings.json`, and **makes a commit** carrying those two files (the rest of what was
installed stays for you to commit). `bd hooks install --shared` rewrites its own stanza in
`.beads-hooks/pre-commit` and sets `core.hooksPath` to an absolute path; both are fine, and
re-running the installer leaves both alone. Our SessionStart hook runs `bd prime` itself, so the
installer replaces bd's; after that `bd setup claude --check` reports "No hooks installed", which
is expected — re-running `bd setup claude` would only re-add a duplicate.

## Known limitations

- **No upgrade path.** The installer never overwrites a file you have. When a shipped tool changes
  upstream, re-running the installer lands it as `tools/<name>.new` with a `DIFFERS` line; diff it,
  `mv -f` it into place, `chmod 755`. Tracked; a hash manifest is the likely fix.
- **One project per `~/.bashrc`.** The shell-guard block names one `tools/dolt-guard.sh`; a second
  install replaces it. Irrelevant on an embedded store, where the guard is a no-op anyway.
- **Platform coverage is Linux, including WSL2 suites, not native Windows or macOS.**
  `xargs -r` is probed for and `ss`/`flock` degrade with a message, but those fallbacks have not
  been run on macOS. `tools/dolt-guard.sh` is bash: it finds its repo through `BASH_SOURCE` and
  uses `{fd}` redirections (bash ≥ 4.1), so it is inert under zsh and will not parse in macOS's
  `/bin/bash` 3.2; the installer writes only `~/.bashrc`.
- **This repository does not run its own git-layer guards on its own commits** — `core.hooksPath`
  is not set here. The self-test proves the installed payload commits clean under the guards; the
  root files (`README.md`, `AGENTS.md`, `selftest.sh`) are checked only by a manual sweep.

## What it touches, and how to remove it

Inside the target repo: `.claude/` (three hook scripts, `memory-hot.txt`, `settings.json` merged
with a backup at `settings.json.bak.<epoch>`, `skills/`, `site-checks/`), optional `.pi/extensions/`
(with `--with-pi` only), `tools/`, `docs/ops/`, `.beads-hooks/pre-commit`, `AGENTS.md` (only if absent) and the `CLAUDE.md` symlink, plus
`core.hooksPath` in git config. Linked worktrees are supported: the installer enables
`extensions.worktreeConfig` when needed, migrates the main checkout's `core.bare`/`core.worktree`
values to its `config.worktree`, and sets the target's hooks path with `--worktree`, leaving sibling
hook settings alone. Submodules use their own config. Outside it: the one `~/.bashrc` block.
For a linked worktree use `git config --worktree --unset core.hooksPath` when removing it.
To remove everything:

```bash
git config --unset core.hooksPath          # or point it back where it was
rm -rf .claude/bd-*-hook.sh .claude/memory-hot.txt .claude/skills .claude/site-checks \
       tools docs/ops .beads-hooks
rm -f .pi/extensions/beads-pipeline.ts  # only if you opted in; leave other Pi extensions alone
# the OLDEST backup (epoch suffix, so it sorts first) is your pre-install settings.json, if any
cp -f "$(ls .claude/settings.json.bak.* | sort | sed -n 1p)" .claude/settings.json \
  && rm -f .claude/settings.json.bak.*
sed -i.bak '/# >>> bd dolt-guard >>>/,/# <<< bd dolt-guard <<</d' ~/.bashrc
```

`AGENTS.md` and `CLAUDE.md` are yours by then; keep or delete as you like. `bd` and its store are
untouched by any of this.

## License

MIT. See [LICENSE](LICENSE).
