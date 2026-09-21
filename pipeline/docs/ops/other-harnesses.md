# Running this under agy, Codex, a Grok REPL, or anything that is not Claude Code

**The session hooks are Claude Code's. Everything else here is not.** This page says exactly
which parts fire where, so you are never guessing about what is protecting you.

## What fires where

| Layer | Mechanism | Claude Code | Codex | agy / antigravity, Grok REPL, Cursor, a plain shell |
| --- | --- | --- | --- | --- |
| Session rules + memories at start | `.claude/settings.json` → `bd-prime-hook.sh` | yes | bd primes it | **no** |
| `pkill` / memory-admission guard | `.claude/settings.json` → `bd-prerun-hook.sh` (PreToolUse) | yes | no | **no** |
| Unclosed-issue reminder | `.claude/settings.json` → `bd-stop-hook.sh` | yes | no | **no** |
| Memory-graph check | `.beads-hooks/pre-commit` | **yes** | **yes** | **yes** |
| Agent-cache path guard | `.beads-hooks/pre-commit` | **yes** | **yes** | **yes** |
| Agent-docs symlink guard | `.beads-hooks/pre-commit` | **yes** | **yes** | **yes** |
| bd's own hooks | `.beads-hooks/*` | **yes** | **yes** | **yes** |
| `tools/*.sh` | plain shell | **yes** | **yes** | **yes** |
| `AGENTS.md` as the rules | the file itself | via the `CLAUDE.md` symlink | reads `AGENTS.md` | reads `AGENTS.md` if it looks for that name |
| Dolt server after a reboot | `~/.bashrc` → `dolt-guard.sh` | **yes** | **yes** | **yes** (any login shell) |

bd primes itself in Claude Code and Codex when it resolves a beads workspace. Everywhere else,
priming is something you or your harness does.

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

## If your harness is not Claude Code

You still get every git-layer guard and every tool with no work. To get the rest:

1. **Point your agent at `AGENTS.md`.** That is the whole rule set. Harnesses that look for
   `AGENTS.md` find it directly; `CLAUDE.md` is a symlink to the same file, so either name works.
2. **Prime the session yourself.** `bash .claude/bd-prime-hook.sh` prints exactly what Claude Code
   injects at session start — rules, bd context, hot memories, the index. Pipe it into your
   agent's context, or run `bd prime` for the unfiltered version.
3. **You do not get the PreToolUse guard.** The `pkill` trap and the memory-admission gate are
   pre-execution checks and there is nothing to hook. Two consequences worth knowing: a bare
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
