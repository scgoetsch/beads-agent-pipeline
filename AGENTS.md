# Agent runbook — set this pipeline up on a fresh box, and prove it

This file is for an agent (Claude Code, Codex, agy, a Grok REPL) or a human landing on a machine
that has never seen `bd` or this pipeline, with the job "install it into a project and show that it
works". It is not the template that gets installed — that is `pipeline/AGENTS.md`. `CLAUDE.md` in
this directory is a symlink to this file, so every harness reads the same runbook.

Follow it top to bottom. **Every phase ends with a gate.** A gate that fails means stop and report
what you saw; it does not mean find another way through. The whole point of this pipeline is that
guards fail loudly, and an agent that works around a loud failure has defeated it.

Measured, end to end, on 2026-09-22: Ubuntu Server 26.04.1, bd 1.3.0, Claude Code 2.1.278,
bd-memgraph at HEAD. Version numbers below are what that run produced; yours may be newer.

## 0. Ground rules for the run

- **One writer per tree.** If another session is working in the target project, do not touch it.
  Use a project directory of your own.
- **Non-login shells may not have `~/.local/bin` on PATH**, and that is where `bd` and `claude`
  land. Start every shell you open with `export PATH="$HOME/.local/bin:$PATH"`.
- **Non-interactive flags everywhere**: `apt-get -y`, `cp -f`, `ssh -o BatchMode=yes`. A prompt
  you cannot answer looks like a hang.
- **Never `git commit --no-verify`.** If a guard blocks a commit in this runbook, either the guard
  is doing its job (phase 5 makes that happen on purpose) or the pipeline has a bug. Report which.
- **Report what was measured**, not what was intended: paste `RESULT:` lines and exit codes.

## 1. Prerequisites

```bash
export PATH="$HOME/.local/bin:$PATH"
command -v git python3 jq iconv || sudo apt-get install -y git python3 jq   # iconv ships with glibc

# bd — the official installer. Downloads the latest release, verifies its checksum.
curl -fsSL https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh | bash
bd --version                                     # e.g. "bd version 1.3.0"

# bd-memgraph — optional; typed [[wikilinks]] over memories and a pre-commit graph guard.
git clone https://github.com/scgoetsch/bd-memgraph ~/bd-memgraph
ln -sf ~/bd-memgraph/bd-memgraph.py ~/.local/bin/bd-memgraph
bd-memgraph --help | head -1                     # "usage: bd-memgraph ..."

# Claude Code — needed ONLY for the three session hooks. Sign-in is not needed for this runbook.
curl -fsSL https://claude.ai/install.sh | bash
claude doctor                                    # must end "No installation issues found."
```

The bd installer may print `~/.local/bin is not in your PATH` when run from a non-login shell. On
Ubuntu, `~/.profile` adds it at the next login once the directory exists; the `export` above covers
the current shell.

**Gate 1:** `bash -lc 'command -v bd claude bd-memgraph'` prints three paths.

## 2. Clone the pipeline and run its own self-test first

```bash
git clone https://github.com/scgoetsch/beads-agent-pipeline ~/beads-agent-pipeline
cd ~/beads-agent-pipeline && ./selftest.sh
```

The self-test installs into throwaway repos under `mktemp` and touches nothing else. It runs every
shipped guard, checks idempotence, and proves through `git commit` that the git-layer guard fires.
On a box **without** bd it still runs, takes its bare-box branch, and must still pass.

**Gate 2:** the last line is `RESULT: N passed, 0 failed` (N was 70 at commit accf2f2). If anything
fails, stop: the pipeline is broken on this platform and installing it proves nothing.

## 3. Install into a project

The target is the directory you were told to install into. If it is already a git repo, skip the
four lines that create one below and start at `--check`; the installer keeps whatever is there
(an existing `AGENTS.md` is never touched — the template lands only where there is none). If it
does not exist yet, create it. Either way, not a tree another session is working in:

```bash
mkdir -p ~/proj/fresh && cd ~/proj/fresh
git init -q && git config user.email you@example.com && git config user.name you
printf '# fresh\n' > README.md && git add README.md && git commit -qm init

~/beads-agent-pipeline/install.sh --check ~/proj/fresh     # inspects, writes nothing
~/beads-agent-pipeline/install.sh ~/proj/fresh             # installs
```

Read the install output, do not just check its exit code. The `verify` block at the end must show
`core.hooksPath=... — git runs that file`, `no installed file is gitignored here`, `agent-docs
symlink guard passes` and `hook portability suite passes`. Anything marked `!` needs a decision
before you go on.

The installer also adds a block to `~/.bashrc` that sources `tools/dolt-guard.sh` — one project per
`.bashrc`; a second install replaces it. Pass `--no-shell` if that is not wanted.

**Gate 3:** exit 0; `git -C ~/proj/fresh config core.hooksPath` resolves to `.beads-hooks`;
`ls -la ~/proj/fresh/CLAUDE.md` shows `CLAUDE.md -> AGENTS.md`.

## 4. Initialise bd, then re-run the installer

```bash
cd ~/proj/fresh
bd init --prefix FT                 # your own prefix
bd hooks install --shared           # --shared matters; without it git ignores the hooks
~/beads-agent-pipeline/install.sh ~/proj/fresh     # re-run once: takes back settings.json
~/beads-agent-pipeline/install.sh ~/proj/fresh     # re-run again: must be a no-op
```

What current bd (1.3) does here, so none of it reads as a problem:

- `bd init` **makes a commit** of its own, carrying `AGENTS.md` (with bd's managed block appended)
  and `.claude/settings.json`. It also writes `.agents/`, `.codex/`, `.cursor/` integration files.
- `bd hooks install --shared` rewrites its own stanza in `.beads-hooks/pre-commit` to its version
  and sets `core.hooksPath` to an **absolute** path. Both are fine; the installer compares the
  resolved directory and the file outside bd's markers, and leaves both alone.
- `bd init` registers bd's own `bd prime` SessionStart hook in `.claude/settings.json`. The
  **first** re-run replaces it with ours (ours runs `bd prime` itself) and says so:
  `+ .claude/settings.json — merged our hooks in` and `replaced bd's own SessionStart hook`. That
  is one change, not a problem, and exit 0. After it, `bd setup claude --check` reports "No hooks
  installed" — expected; do not run `bd setup claude` to "fix" it, that re-adds the duplicate.

**Gate 4:** the first re-run exits 0 with exactly that one `+` line (a `!` line means something of
yours was replaced — read it); the **second** re-run prints `nothing to do — this checkout was
already set up.` and exits 0.

## 5. Prove the guards through git — not by running the scripts

First the suites, from inside the project:

```bash
cd ~/proj/fresh
for s in tools/*_test.sh; do printf '%-42s' "$s"; ./$s >/tmp/suite.log 2>&1 && echo PASS || { echo FAIL; tail -15 /tmp/suite.log; }; done
```

Then the three commits that matter. Do them in this order and check `git log` after each:

```bash
# 5a. A document carrying an agent-cache path MUST be refused. (Built from $HOME so that this
#     runbook does not itself contain the literal the guard rejects.)
printf 'see ![f](%s)\n' "$HOME/.claude/projects/abc/p.png" > bad.md
git add bad.md && git commit -qm "must be refused"; echo "exit $?"      # exit 1, "forbidden agent-cache path"
git reset -q bad.md && rm -f bad.md

# 5b. Replacing the CLAUDE.md symlink with a regular file MUST be refused.
rm CLAUDE.md && cp AGENTS.md CLAUDE.md
git add CLAUDE.md && git commit -qm "must be refused"; echo "exit $?"   # exit 1, "REGULAR FILE, not a symlink"
rm CLAUDE.md && ln -s AGENTS.md CLAUDE.md && git add CLAUDE.md

# 5c. The whole installed payload MUST commit under its own guards.
git add -A && git commit -qm "pipeline installed"; echo "exit $?"      # exit 0
```

5c is the one that catches pipeline bugs: a template example spelled out in full, or a test suite
holding the literal it tests with, was once refused by the very guard it ships with. If 5c fails,
that is a bug in this repository — report it with the guard's message; do not bypass it.

**Gate 5:** every suite PASS; 5a and 5b exit 1 with `git log` unchanged; 5c exits 0.

## 6. bd works, and a new shell is quiet

```bash
bd remember --key runbook-probe "probe $(date -Is)" && bd recall runbook-probe && bd forget runbook-probe
bd dolt status                                    # bd 1.3 default: "embedded (in-process, no server)"
bash -ic 'cd ~/proj/fresh; echo shell-ok' 2>&1 | grep -v "job control"
```

The third line must print `shell-ok` and **nothing from `dolt-guard:`**. On an embedded store there
is no server to guard and the guard stays silent; a `FAILED to start dolt server` line here is a
bug (it was one, fixed 2026-09-22). Note `bash -ic`, not `bash -lc`: Ubuntu's `~/.bashrc` returns
at its first line for non-interactive shells, so `-lc` proves nothing about the guard.

**Gate 6:** the round trip prints the probe back; the shell prints only `shell-ok`.

## 7. Session hooks — what can and cannot be verified without a signed-in Claude Code

`.claude/settings.json` now wires SessionStart, PreCompact, PreToolUse and Stop. They fire inside a
Claude Code session in this directory and nowhere else; under any other harness they do nothing, and
the git layer above is what covers you. Without signing in you can still run each hook by hand:

```bash
bash .claude/bd-prime-hook.sh | head -3          # "# 🚨 MANDATORY SESSION RULES ..." — and no "bd-prime-hook:" fallback banner
bash .claude/bd-prime-hook.sh | wc -c            # single-digit KB on a small store; the raw `bd prime` dump is what it replaces
jq -nc '{tool_name:"Bash",tool_input:{command:"pkill -f x"}}' | bash .claude/bd-prerun-hook.sh; echo "exit $?"   # exit 2
jq -nc '{tool_name:"Bash",tool_input:{command:"ls"}}'        | bash .claude/bd-prerun-hook.sh; echo "exit $?"   # exit 0
bash .claude/bd-stop-hook.sh; echo "exit $?"     # exit 0
```

If you can sign in: open `claude` in `~/proj/fresh` and the first thing in the session must be the
`MANDATORY SESSION RULES` block. If it is the raw `bd prime` dump instead, the merge in phase 4 did
not take; `jq '.hooks.SessionStart' .claude/settings.json` should name `bd-prime-hook.sh`.

**Gate 7:** the by-hand runs match the comments above.

## 8. Report, and file what you hit

Report in this shape — numbers, not adjectives:

```
box: <os, kernel>   bd <ver>   claude <ver or "not installed">   bd-memgraph <yes/no>
pipeline: <commit>  selftest: RESULT: N passed, 0 failed
project: <path>     install: exit 0, <n> change(s); re-run after bd init: nothing to do
suites in project:  <k>/<k> PASS
git proofs:         5a refused / 5b refused / 5c committed
shell:              quiet (embedded)  |  session hooks: by hand OK / fired in Claude Code (if signed in)
deviations:         <every gate that did not match, verbatim output>
```

Anything that deviated is either a platform difference worth recording or a bug in this
repository. File it at https://github.com/scgoetsch/beads-agent-pipeline/issues with the exact
command and its output. The bugs this runbook now warns about — the guard refusing its own
template, the shell guard crying wolf on an embedded store, the hooks not being wired without bd —
were all found by exactly this procedure on a fresh box.

## Updating a project later

The installer never overwrites a file you already have. When you pull a newer pipeline and re-run
it, a changed tool lands as `tools/<name>.new` with a `DIFFERS` line; diff it, then `mv -f` it into
place and `chmod 755`. There is no automatic upgrade path yet. `AGENTS.md` is yours and is never
offered as `.new`; the template is `pipeline/AGENTS.md` in the pipeline checkout.
