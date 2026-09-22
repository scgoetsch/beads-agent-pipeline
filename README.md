# beads-agent-pipeline

Session machinery for coding agents, built around [beads](https://github.com/gastownhall/beads)
(`bd`). One command installs it into any git repo: the agent gets its rules, its issue queue and
its durable memory at session start, and the repo gets guards that fail **loudly** instead of
silently.

```bash
git clone https://github.com/scgoetsch/beads-agent-pipeline
cd /path/to/your-project
/path/to/beads-agent-pipeline/install.sh
```

Nothing is overwritten. An existing `settings.json` is merged; an existing `tools/` or `docs/` file
is kept and ours lands beside it as `.new`. An existing `AGENTS.md` is kept and nothing is written
beside it — it is meant to diverge from the template, and the log says where the template is.
`--check` inspects, `--dry-run` prints every action, `--no-shell` skips the one thing written
outside the repo. Re-running repairs a checkout whose config drifted.

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

**Session machinery** (`.claude/`) — a SessionStart hook that emits the session rules, the bd
context, your hot memories in full and an index of the rest; a PreToolUse guard; a Stop hook that
warns about unclosed issues. Each resolves the repo root from **its own file location**, never a
literal path, and `tools/hook_portability_test.sh` relocates them to a throwaway root to prove it.

**The PreToolUse guard** blocks three things. Two were measured to cause real damage; the third is
a discipline you may not want, and it is one line to turn off:

- **Bare `pkill` / `killall`.** `pkill -f PATTERN` matches the full command line — including the
  shell running it — so it kills its own caller. It comes back as exit 143/144, reads like an
  ordinary failure, and takes anything that shell was supervising with it. Age filters and
  pidfiles are allowed through; `kill` with explicit PIDs is never blocked.
- **Memory writes that are really session state.** `bd remember` without `--key`, or a body that
  is structurally a handoff memo, is refused with a pointer to `bd note` instead. The test is
  structural, not lexical — an earlier vocabulary-based version blocked the memory that documented
  the rule while a rephrase walked straight through.
- **Running a script under `scripts/` with no bd issue `in_progress`.** Untracked analysis runs
  are how reproducibility gaps start, so the hook asks for a claimed issue first. It fails open
  if bd is unavailable. The directory name is the one-line knob `SCRIPT_DIRS_RE` in
  `.claude/bd-prerun-hook.sh`; set it to something that matches nothing to drop the rule.

**The SessionStart hook** replaces bd's raw `bd prime` dump (76 KB on a 40-memory store, past
what hosts keep of a session payload) with the rules, the bd context, the memories listed in
`.claude/memory-hot.txt` in full, and a key-only index of the rest. The hot list ships empty, and
empty means "index only", not "unconfigured". If the hook has to fall back to the full dump — no
`jq`, no export — it says so on its first line rather than looking like the tiered output.

**`tools/sweep.sh`** — corpus-wide search with a **positive control per repo**. It lifts real lines
out of each repo and greps for them through the identical code path; if they do not come back, that
repo was not searched and the sweep exits non-zero. Exit 0 is the only thing that licenses "it
isn't there". Measured 2026-09-21 in the workspace this came from: a plain `rg` at the root
reached 131 files; the corpus was 8,993 across 7 repos. Zero hits, no error. Re-measure in your
own tree — the ratio is the durable claim, and an absolute threshold ages out.

**`tools/check-no-agent-cache-paths.sh`** — refuses commits that embed a per-conversation agent
cache path (`~/.gemini/antigravity-cli/brain/<uuid>/`, `~/.claude/projects/<uuid>/`,
`/tmp/claude-<uid>/`). Those resolve for nobody else and on no other machine, so a figure linked
from one is a broken image for every other reader. It runs at the **git layer** on purpose: the
trap is not specific to one agent, so neither is the guard — it covers the agent that has no
session hooks at all. Documents and generated JSON are scanned whole-file; code on added lines
only, a ratchet rather than a flag day.

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
a filesystem that has no symlinks are in `docs/ops/agent-docs-symlink.md`. It includes the section most people need and few write: an
explicit statement that these rules **supersede** the harness's own injected instructions about
where tasks and memory live, because harnesses will contradict them repeatedly.

**Docs** (`docs/ops/`) — the reasoning behind each guard, including the measurements. Start with
`checks-narrower-than-what-they-check.md`: twelve instances of the one defect class every guard
here is built against, with the diagnostic question to ask of your own checks.

## Letting an agent install it — the runbook

`AGENTS.md` in this directory (and `CLAUDE.md`, a symlink to it) is a runbook an agent follows top
to bottom on a machine that has never seen bd: install the prerequisites, self-test the pipeline,
install it into a project, initialise bd, prove every guard through `git commit`, exercise the
session hooks, and report in a fixed shape. Eight phases, a gate after each. It is the procedure
that was run by hand on the first fresh box, and running it as written is what found most of the
bugs in this repository's history — so it is also the acceptance test for a new platform.

**On the box itself.** Clone, start your harness inside the clone, and tell it what to do:

```bash
git clone https://github.com/scgoetsch/beads-agent-pipeline ~/beads-agent-pipeline
cd ~/beads-agent-pipeline
claude          # reads CLAUDE.md on startup; Codex reads AGENTS.md — same file
```

Then one instruction: *"Follow AGENTS.md end to end. Install into `~/proj/<name>`. Stop at any
gate that fails and report it verbatim. Finish with the report in section 8."* A harness that does
not read either file on startup (agy, a Grok REPL) needs *"read `~/beads-agent-pipeline/AGENTS.md`
first"* in front of that, and the absolute path — some of them do not know their working
directory. Name the project directory yourself: the runbook tells the agent never to work in a
tree another session is using.

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

**What it will not do.** Sign in to Claude Code, so the session hooks are verified by running
each script by hand rather than by watching them fire — section 7 says which is which. Install the
peer layer, unless you ask for `--with-peer`. Bypass a guard: the runbook forbids
`git commit --no-verify`, and an agent that reaches for it has found a bug, not a shortcut.

## Verify it

```bash
./selftest.sh
```

Installs into a throwaway git repo, runs every shipped guard there, checks idempotence, checks
that it refuses to clobber your files, and checks that `--dry-run` and `--check` write nothing.
Nothing outside the temp directory is touched.

## Requirements

| | | |
| --- | --- | --- |
| [Claude Code](https://claude.com/claude-code) | required **for the session hooks only** | `.claude/settings.json` wires SessionStart, PreToolUse and Stop, and those three fire in Claude Code and nowhere else. Everything at the git layer, every tool and `AGENTS.md` work under any harness or none — `docs/ops/other-harnesses.md` has the matrix. Install below |
| `git`, `python3` | required | everything is git-scoped; the PreToolUse guard parses hook JSON |
| [`bd`](https://github.com/gastownhall/beads) | required | the issue tracker and memory store. bd runs its own Dolt server (`bd dolt start`); a separate `dolt` binary is not needed and nothing here calls one |
| `jq` | optional | without it, session start falls back to the full `bd prime` dump |
| `iconv` | optional | without it, `sweep.sh` cannot flag bad-UTF-8 files as unsearchable |
| [`bd-memgraph`](https://github.com/scgoetsch/bd-memgraph) | optional | typed `[[wikilinks]]` over your memories, plus a pre-commit graph guard. One python3 file, no dependencies: clone it and symlink `bd-memgraph.py` onto your PATH. Without it the shipped pre-commit stanza self-skips and nothing else changes. |

`install.sh --check` reports exactly what is present and what each absence costs. It states the
harness rather than probing for it, because the hooks are run *by* the harness and a `claude` on
your PATH does not prove they will fire.

**Installing Claude Code**, if you want the session hooks:

```bash
curl -fsSL https://claude.ai/install.sh | bash     # native build
claude doctor                                       # check the install
```

`claude install <stable|latest|version>` manages the native build and `claude update` upgrades it.
The native installer puts a versioned binary under `~/.local/share/claude/versions/` and symlinks
`~/.local/bin/claude` at it. If you would rather not install it, everything except those three
hooks still works — see `docs/ops/other-harnesses.md`, which also shows how to prime a session by
hand.

## What this is not

- **Not a bd replacement or fork.** bd is unmodified; this is configuration, hooks and guards
  around it.
- **Not tied to one agent harness — but be precise about it.** The three SESSION hooks are Claude
  Code's `settings.json` format and do nothing under agy, a Grok REPL or Cursor. Everything at the
  git layer (`.beads-hooks/pre-commit`: memory graph, agent-cache paths, agent-docs symlink, bd's
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

## License

MIT. See [LICENSE](LICENSE).
