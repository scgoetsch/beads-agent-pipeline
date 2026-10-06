# Running this under Pi, Codex, agy, a Grok REPL, or another harness

**Claude Code runs the `.claude/settings.json` session hooks; Pi can run the optional adapter.**
Neither is a substitute for the git-layer guards. This page says which parts fire where.

## What fires where

| Layer | Claude Code | Pi (opt-in, trusted project) | Codex | agy / Grok / Cursor / plain shell |
| --- | --- | --- | --- | --- |
| Session start + memories | `.claude/settings.json` | `.pi/extensions/beads-pipeline.ts` calls the same script | bd primes it | **no** |
| `pkill` / memory-admission guard | Claude PreToolUse | Pi `tool_call` + `user_bash` | no | **no** |
| Unclosed-issue reminder (this session's claims) | Claude Stop (each turn) | Pi `agent_settled` (each turn) + `session_shutdown` (close) | no | **no** |
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

## Grok runs the Claude hooks, but they cannot block there

Grok Build scans `.claude/settings.json` by default (`compat.claude.hooks`) and, once the folder
is trusted, the three scripts do start. They are inert all the same, which is worse than not
running, because nothing says so:

- SessionStart and PreCompact stdout is discarded, so the prime payload never reaches the model.
- PreToolUse receives the call under `toolInput`, not `tool_input`, so `bd-prerun-hook.sh` reads
  an empty command and exits 0. The bare-`pkill` and keyless-`bd remember` guards never see the
  command. (`Bash` is an alias of Grok's `run_terminal_command`, so the hook does fire.)
- Stop non-JSON stdout is not returned to the model, so the close reminder is lost.
- Blocking under Grok needs exit 2, or `{"decision":"deny"}` on PreToolUse and
  `{"decision":"block"}` on Stop; timeouts and crashes fail open.

So a Grok session has only the git-layer guards, and the "**no**" column above is accurate even
though the scripts ran. Teaching the pre-run guard to read both keys is the fix; until then,
treat a Grok session as the plain-shell column.

## Memory stores: bd is the only one

`AGENTS.md` forbids a second memory store, and the rule binds every CLI, not only Claude. The
reason is the correction sweep: a withdrawn number copied into a store the sweep cannot reach
survives the document, memory and bead sweeps and reseeds a later session. `tools/sweep.sh`
reaches the repos; it does not reach `$HOME`.

Seen 2026-10-05: Grok's memory-v2 capture had been switched on by a managed remote setting
(nothing local enabled it), and was writing an index, topics and pending observations under
`~/.grok/memory-v2/workspaces/<repo>/`. Three of its claims were stale within an afternoon.
The store was inventoried, its unique facts moved into bd, and capture disabled with
`[memory] enabled = false` plus `[memory_v2] enabled = false` and `file_writes_enabled = false`
in `~/.grok/config.toml`, the local layer Grok's docs say overrides remote enabling. A fresh
session then advertised 50 slash commands instead of 52, the missing ones being `/memory`,
`/flush` and `/dream`: not finding the memory setting is the sign that it is off. Codex keeps
`~/.codex/memories/` (an empty scaffold when checked); agy keeps per-conversation artifacts, not
a memory store, and the cache-path guard covers those. If a CLI grows a store again, disable it
or add it to the "surfaces the sweep cannot reach" list in `AGENTS.md`.

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
bash .claude/bd-stop-hook.sh      # no payload: warn about EVERY in-progress issue in the store
```

The stop hook also reads an optional JSON payload on stdin, `{"hook_event_name":"Stop"|"SessionEnd",
"session_id":"..."}`, and with it reports only the issues that session claimed (recorded by
`bd-prerun-hook.sh` when it sees `bd update <id> --claim` in a payload carrying the same
`session_id`): at `Stop` only when that set changed, at `SessionEnd` always. A harness that can
supply a stable session id should, because the store is shared by every session on the machine.

`.claude/bd-prerun-hook.sh` is the one with a real interface: it reads a Claude Code tool-call
JSON object on **stdin** (`{"tool_name":"Bash","tool_input":{"command":"..."}}`) and signals a
block with **exit 2 plus a message on stderr**. Adapting it means translating your harness's
payload into that shape, not rewriting the guard.
