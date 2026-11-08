# Agent runbook — set this pipeline up on a fresh box, and prove it

This file is for an agent (Claude Code, Codex, agy, a Grok REPL) or a human landing on a machine
that has never seen `cairn` or this pipeline, with the job "install it into a project and show that
it works". It is not the template that gets installed — that is `pipeline/AGENTS.md`. `CLAUDE.md`
in this directory is a symlink to this file, so every harness reads the same runbook.

**This runbook is for a project with no store yet, or one already on cairn.** A project whose
store is still the old tracker's is not installed into: the installer refuses it, and the move
comes first (README.md, "Moving a repo off bd"). A green install is not a migrated store.

Follow it top to bottom. **Every phase ends with a gate.** A gate that fails means stop and report
what you saw; it does not mean find another way through. The whole point of this pipeline is that
guards fail loudly, and an agent that works around a loud failure has defeated it.

Measured end to end on the 0.1 runbook on 2026-09-22 (Ubuntu Server 26.04.1, Claude Code 2.1.278).
The cairn phases below were measured on 2026-11-08 with cairn 0.7.0 (`./selftest.sh` and a
throwaway project); version numbers are what those runs produced, yours may be newer.

## 0. Ground rules for the run

- **One writer per tree.** If another session is working in the target project, do not touch it.
  Use a project directory of your own.
- **Non-login shells may not have `~/.local/bin` on PATH**, and that is where `cairn` and `claude`
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
python3 --version                                # 3.9 or later: cairn is stdlib-only Python

# cairn — a clone and a symlink; nothing to pip install. 0.7.0 or later.
git clone https://github.com/scgoetsch/cairn ~/cairn
mkdir -p ~/.local/bin && ln -sf ~/cairn/bin/cairn ~/.local/bin/cairn
cairn --version                                  # e.g. "cairn 0.7.0"

# Claude Code — the default three session hooks fire only inside it. Pi support is opt-in.
curl -fsSL https://claude.ai/install.sh | bash
claude doctor                                    # must end "No installation issues found."
```

**Gate 1:** `bash -lc 'command -v cairn claude'` prints two paths and `cairn --version` is 0.7.0
or later. Only `cairn` (with `git` and `python3`) is required by the pipeline itself. If the
instruction you were given said to skip Claude Code, the gate is the path that remains — and the
report in section 8 must say so, because section 7 then has nothing to run.

## 2. Clone the pipeline and run its own self-test first

```bash
git clone https://github.com/scgoetsch/beads-agent-pipeline ~/beads-agent-pipeline
cd ~/beads-agent-pipeline && ./selftest.sh
```

`test/selftest-in-container.sh` runs the same self-test on a clean Ubuntu in Docker, with and
without cairn, when the box has Docker; prefer it when the box already carries everything, since a
box that has every tool cannot show you what a bare one does. The same self-test runs in GitHub
Actions on every push (`.github/workflows/selftest.yml`): Ubuntu, macOS and Windows, each box's
RESULT line in the run summary. All three jobs are gates; a box the matrix does not have
(PowerShell, a Windows box that cannot make symlinks) is yours to run it on.

The self-test installs into throwaway repos under `mktemp` and touches nothing else. It runs every
shipped guard, checks idempotence, proves through `git commit` that the git-layer guard fires, and
proves the installer refuses a repo whose store is still the old tracker's. With cairn hidden from
PATH it still runs that branch, and must still pass.

**Gate 2:** the last line is `RESULT: N passed, 0 failed` — N grows with every release; `0 failed`
is the gate. If anything fails, stop: the pipeline is broken on this platform and installing it
proves nothing.

## 3. Install into a project

The target is the directory you were told to install into. If it is already a git repo, skip the
three lines that create one below and start at `--check`; the installer keeps whatever is there
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
the four pre-commit guards present, `core.hooksPath=... — git runs that file`, `no installed file
is gitignored here`, `agent-docs symlink guard passes` and `hook portability suite passes`.
Anything marked `!` needs a decision before you go on. A line beginning `REFUSED:` means the
project's store is still the old tracker's: stop, and report it.

The installer writes nothing outside the project. For a Pi project, pass `--with-pi`, then
explicitly approve the project in Pi and run the installed `tools/pi-extension_test.sh` plus the
live smoke in `pipeline/docs/ops/pi-adapter.md`. The default install does **not** load the Pi
adapter; reading `AGENTS.md` in Pi is no proof that the tool-call guard runs. The rest of this
runbook measures the default Claude path.

**Gate 3:** exit 0; `git -C ~/proj/fresh config core.hooksPath` resolves to `.beads-hooks`;
`ls -la ~/proj/fresh/CLAUDE.md` shows `CLAUDE.md -> AGENTS.md`.

## 4. Create the store, commit what git carries of it, then re-run the installer

```bash
cd ~/proj/fresh
cairn init -p ft                     # your own prefix
tools/refresh-beads-exports.sh       # writes the four tracked files into .cairn/
git add .cairn/.gitignore .cairn/config.json .cairn/issues.jsonl .cairn/memories.jsonl \
        .cairn/allocator.json .cairn/events.jsonl
git commit -qm "cairn store" -- .cairn/; echo "exit $?"      # exit 0; the pre-commit runs cairn check
~/beads-agent-pipeline/install.sh ~/proj/fresh               # re-run: must be a no-op
```

A store is not finished until another clone can `cairn sync` from it: the database
(`.cairn/cairn.db`) is git-ignored, and those four files plus `config.json` are what git carries.

**Gate 4:** the commit exits 0 and `git show --stat HEAD` lists the six `.cairn/` files; the re-run
prints `nothing to do — this checkout was already set up.` and exits 0.

## 5. Prove the guards through git — not by running the scripts

First the suites, from inside the project:

```bash
cd ~/proj/fresh
for s in tools/*_test.sh; do printf '%-42s' "$s"; ./$s >/tmp/suite.log 2>&1 && echo PASS || { echo FAIL; tail -15 /tmp/suite.log; }; done
```

Then the four commits that matter. Do them in this order and check `git log` after each:

```bash
# 5a. A document carrying an agent-cache path MUST be refused. (Built from $HOME so that this
#     runbook does not itself contain the literal the guard rejects.)
printf 'see ![f](%s)\n' "$HOME/.claude/projects/abc/p.png" > bad.md
git add bad.md && git commit -qm "must be refused"; echo "exit $?"      # exit 1, "forbidden agent-cache path"
git reset -q bad.md && rm -f bad.md

# 5b. Replacing the CLAUDE.md symlink with a regular file MUST be refused.
rm CLAUDE.md && cp AGENTS.md CLAUDE.md
git add CLAUDE.md && git commit -qm "must be refused"; echo "exit $?"   # exit 1, "staged CLAUDE.md is a REGULAR FILE"
rm CLAUDE.md && ln -s AGENTS.md CLAUDE.md && git add CLAUDE.md

# 5c. A store write without its exports MUST be refused.
cairn create --title="runbook probe" --type=task -p 4 --silent
git commit -qm "must be refused" --allow-empty; echo "exit $?"         # exit 1, "issues.jsonl is STALE"
tools/refresh-beads-exports.sh && git add .cairn/issues.jsonl .cairn/memories.jsonl .cairn/allocator.json .cairn/events.jsonl

# 5d. The whole installed payload MUST commit under its own guards.
git add -A && git commit -qm "pipeline installed"; echo "exit $?"      # exit 0
```

5d is the one that catches pipeline bugs: a template example spelled out in full, or a test suite
holding the literal it tests with, was once refused by the very guard it ships with. If 5d fails,
that is a bug in this repository — report it with the guard's message; do not bypass it.

**Gate 5:** every suite PASS; 5a, 5b and 5c exit 1 with `git log` unchanged; 5d exits 0.

## 6. The store works, and another clone rebuilds it from git

```bash
cairn remember --key runbook-probe "probe $(date -Is) about tools/sweep.sh" && cairn recall runbook-probe && cairn forget runbook-probe
tools/refresh-beads-exports.sh && git commit -qm "probe" -- .cairn/
git clone -q ~/proj/fresh /tmp/fresh-clone && cd /tmp/fresh-clone && git config core.hooksPath .beads-hooks
cairn sync && cairn list --all | grep -c 'runbook probe'               # "Synced ...", then 1
cd ~/proj/fresh && rm -rf /tmp/fresh-clone
```

**Gate 6:** the round trip prints the probe back; the clone's `cairn sync` builds a store and the
issue created in 5c is in it.

## 7. Session hooks — what can and cannot be verified without a signed-in Claude Code

`.claude/settings.json` now wires SessionStart, PreCompact, PreToolUse and Stop. They fire inside a
Claude Code session in this directory and nowhere else; under any other harness they do nothing, and
the git layer above is what covers you. Without signing in you can still run each hook by hand:

```bash
bash .claude/bd-prime-hook.sh | head -3          # "# 🚨 MANDATORY SESSION RULES ..." — and no "bd-prime-hook:" fallback banner
bash .claude/bd-prime-hook.sh | wc -c            # single-digit KB on a small store
jq -nc '{tool_name:"Bash",tool_input:{command:"pkill -f x"}}' | bash .claude/bd-prerun-hook.sh; echo "exit $?"   # exit 2
jq -nc '{tool_name:"Bash",tool_input:{command:"ls"}}'        | bash .claude/bd-prerun-hook.sh; echo "exit $?"   # exit 0
bash .claude/bd-stop-hook.sh; echo "exit $?"     # exit 0
```

If you can sign in, prove the hook fires without an interactive session — a sentinel memory, a
print-mode run, and a question only the hook's output can answer:

```bash
cairn remember --key runbook-sentinel-7731 "the session-hook probe" >/dev/null
claude -p 'Answer with exactly two lines and nothing else. Line 1: the first line of any SessionStart hook output you received at the start of this session, verbatim (or the words NO HOOK OUTPUT). Line 2: the memory key containing 7731 as listed in that hook output (or NOT LISTED).'
cairn forget runbook-sentinel-7731 >/dev/null
```

Measured 2026-09-22 with Claude Code 2.1.278 (on the 0.1 pipeline): line 1 is
`SessionStart:startup hook success: # 🚨 MANDATORY SESSION RULES — READ BEFORE RESPONDING 🚨` and
line 2 is `runbook-sentinel-7731`. If line 1 is `cairn prime`'s own layout instead, the settings
merge did not take — `jq '.hooks.SessionStart' .claude/settings.json` should name
`bd-prime-hook.sh`. If line 1 is right and line 2 is `NOT LISTED`, the host cut the payload:
Claude Code keeps only a 2,000-byte preview of a hook output above 10,000 bytes, and the hook trims
itself to `BD_PRIME_BUDGET` (default 10000) to stay under that — `bash .claude/bd-prime-hook.sh |
wc -c` says how big it is, and a first line reading `PAYLOAD TRIMMED` says what it dropped.

**Gate 7:** the by-hand runs match the comments above.

## 8. Report, and file what you hit

Report in this shape — numbers, not adjectives:

```
box: <os, kernel>   cairn <ver>   claude <ver or "not installed">
pipeline: <commit>  selftest: RESULT: N passed, 0 failed
project: <path>     install: exit 0, <n> change(s); re-run after cairn init: nothing to do
suites in project:  <k>/<k> PASS
git proofs:         5a refused / 5b refused / 5c refused / 5d committed
store:              round trip OK / clone synced  |  session hooks: by hand OK / fired in Claude Code (if signed in)
deviations:         <every gate that did not match, verbatim output>
```

Anything that deviated is either a platform difference worth recording or a bug in this
repository. File it at https://github.com/scgoetsch/beads-agent-pipeline/issues with the exact
command and its output. The bugs this runbook warns about — the guard refusing its own template,
the hooks not being wired without the store CLI — were found by exactly this procedure on a fresh
box.

## Updating a project later

The installer never overwrites a file you already have. When you pull a newer pipeline and re-run
it, a changed tool lands as `tools/<name>.new` with a `DIFFERS` line; diff it, then `mv -f` it into
place and `chmod 755`. There is no automatic upgrade path yet. `AGENTS.md` is yours and is never
offered as `.new`; the template is `pipeline/AGENTS.md` in the pipeline checkout. A project that
had the 0.1 pipeline (on the old tracker) follows README.md, "Moving a repo off bd", before it
re-runs the installer.
