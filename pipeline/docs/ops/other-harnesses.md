# Running this under Pi, Codex, agy, a Grok REPL, or another harness

**Claude Code runs the `.claude/settings.json` session hooks; Pi can run the optional adapter.**
Neither is a substitute for the git-layer guards. This page says which parts fire where.

## What fires where

| Layer | Claude Code | Pi (opt-in, trusted project) | Codex | agy / Grok / Cursor / plain shell |
| --- | --- | --- | --- | --- |
| Session start + memories | `.claude/settings.json` | `.pi/extensions/beads-pipeline.ts` calls the same script | bd primes it | **no** |
| `pkill` / memory-admission guard | Claude PreToolUse | Pi `tool_call` + `user_bash` | no | **no** |
| Unclosed-issue reminder | Claude Stop | Pi `agent_settled` | no | **no** |
| Pre-compaction refresh | Claude PreCompact | Pi `session_before_compact` | no | **no** |
| Git guards (`.beads-hooks/`) | **yes** | **yes** | **yes** | **yes** (if wired in this clone) |
| `tools/*.sh` | **yes** | **yes** | **yes** | **yes** |
| `AGENTS.md` | via symlink | reads `AGENTS.md` | reads `AGENTS.md` | if the harness looks for it |
| Dolt guard after reboot | `~/.bashrc` in interactive bash | Pi adapter explicitly at start | `~/.bashrc` in interactive bash | `~/.bashrc` in interactive bash only |

Pi's project extension loads **only after project trust**; `pi --no-approve` skips it. If the
project is untrusted, its own extension cannot warn that it was skipped. Running the installer
with `--with-pi` and reading `AGENTS.md` is not proof of live hook coverage: run the event suite
and the real smoke described in **`docs/ops/pi-adapter.md`**. Under Pi, non-interactive Bash does
not reliably source `~/.bashrc`. The adapter starts the Dolt guard explicitly.

## The principle: enforce at the layer everything passes through

A session hook only binds the harness that implements it. **`git commit` binds all of them** —
every agent, every REPL, and you. So anything that must not escape the repo belongs in
`.beads-hooks/`, not in a session hook, even when a session hook could also catch it.

`tools/check-no-agent-cache-paths.sh` is the clearest case. Agents stage working artifacts in
per-conversation cache directories — agy/antigravity under `~/.gemini/antigravity-cli/brain/<uuid>/`,
Claude Code under `~/.claude/projects/<uuid>/` and `/tmp/claude-<uid>/` — and those absolute paths
leak into committed markdown, reports and generated JSON. They resolve for nobody else. The trap
is not specific to one agent, and neither is the guard: it runs on commit, so it covers the agent
that has no session hooks at all.

## If your harness is neither Claude Code nor a trusted Pi with the adapter

You still get every git-layer guard and every tool with no work. To get the rest:

1. **Point your agent at `AGENTS.md`.** That is the whole rule set. Harnesses that look for
   `AGENTS.md` find it directly; `CLAUDE.md` is a symlink to the same file, so either name works.
2. **Prime the session yourself.** `bash .claude/bd-prime-hook.sh` prints exactly what Claude Code
   injects at session start — rules, bd context, hot memories, the index. Pipe it into your
   agent's context, or run `bd prime` for the unfiltered version.
3. **You do not get the pre-execution guard.** The `pkill` trap and the memory-admission gate are
   pre-execution checks and your harness has no adapter here. Two consequences worth knowing: a bare
   `pkill -f <pattern>` can kill the agent's own shell (the pattern matches the command line that
   contains it), and `bd remember` without `--key` will happily create an undedupable memory.
   `.claude/bd-prerun-hook.sh` documents both; read it once and keep the rules by hand.
4. **Run the suites yourself** — they are plain shell, listed in AGENTS.md under Build & Test.

## Adding hooks for another harness

If your harness has a session-start or pre-tool mechanism, point it at the same scripts rather
than reimplementing them. Each resolves the repo root from its own file location, takes no
arguments, and writes its payload to stdout:

```bash
bash .claude/bd-prime-hook.sh     # session start: rules + bd context + memories
bash .claude/bd-stop-hook.sh      # session end: warn about in-progress issues
```

`.claude/bd-prerun-hook.sh` is the one with a real interface: it reads a Claude Code tool-call
JSON object on **stdin** (`{"tool_name":"Bash","tool_input":{"command":"..."}}`) and signals a
block with **exit 2 plus a message on stderr**. Adapting it means translating your harness's
payload into that shape, not rewriting the guard.
