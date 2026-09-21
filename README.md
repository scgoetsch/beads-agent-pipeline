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

Nothing is overwritten. An existing `AGENTS.md`, `settings.json` or `tools/` file is kept and ours
lands beside it as `.new`. `--check` inspects, `--dry-run` prints every action, `--no-shell` skips
the one thing written outside the repo. Re-running repairs a checkout whose config drifted.

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

**The PreToolUse guard** blocks two things measured to cause real damage:

- **Bare `pkill` / `killall`.** `pkill -f PATTERN` matches the full command line — including the
  shell running it — so it kills its own caller. It comes back as exit 143/144, reads like an
  ordinary failure, and takes anything that shell was supervising with it. Age filters and
  pidfiles are allowed through; `kill` with explicit PIDs is never blocked.
- **Memory writes that are really session state.** `bd remember` without `--key`, or a body that
  is structurally a handoff memo, is refused with a pointer to `bd note` instead. The test is
  structural, not lexical — an earlier vocabulary-based version blocked the memory that documented
  the rule while a rephrase walked straight through.

**`tools/sweep.sh`** — corpus-wide search with a **positive control per repo**. It lifts real lines
out of each repo and greps for them through the identical code path; if they do not come back, that
repo was not searched and the sweep exits non-zero. Exit 0 is the only thing that licenses "it
isn't there". Measured 2026-09-21 in the workspace this came from: a plain `rg` at the root
reached 131 files; the corpus was 8,993 across 7 repos. Zero hits, no error. Re-measure in your
own tree — the ratio is the durable claim, and an absolute threshold ages out.

**`tools/dolt-guard.sh`** — restarts bd's Dolt server after a reboot. Without it, `bd` reads keep
working while writes silently fail to land, which is the worst possible shape for a data store.

**Skills** — `memory-curate` (audit, dedupe and tier the memory store) and `triage` (surface and
plan the top ready issue, read-only, without claiming it).

**An `AGENTS.md` template** that is symlinked from `CLAUDE.md` so the two can never drift, with a
guard for the one way that breaks. It includes the section most people need and few write: an
explicit statement that these rules **supersede** the harness's own injected instructions about
where tasks and memory live, because harnesses will contradict them repeatedly.

**Docs** (`docs/ops/`) — the reasoning behind each guard, including the measurements. Start with
`checks-narrower-than-what-they-check.md`: eleven instances of the one defect class every guard
here is built against, with the diagnostic question to ask of your own checks.

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
| `git`, `python3` | required | everything is git-scoped; the PreToolUse guard parses hook JSON |
| [`bd`](https://github.com/gastownhall/beads) + [`dolt`](https://github.com/dolthub/dolt) | required | the issue tracker and memory store |
| `jq` | optional | without it, session start falls back to the full `bd prime` dump |
| `iconv` | optional | without it, `sweep.sh` cannot flag bad-UTF-8 files as unsearchable |
| [`bd-memgraph`](https://github.com/scgoetsch/bd-memgraph) | optional | typed `[[wikilinks]]` over your memories, plus a pre-commit graph guard |

`install.sh --check` reports exactly what is present and what each absence costs.

## What this is not

- **Not a bd replacement or fork.** bd is unmodified; this is configuration, hooks and guards
  around it.
- **Not tied to one agent harness.** The hooks are Claude Code's `settings.json` format, but the
  tools, guards and `AGENTS.md` discipline are plain shell and apply anywhere.
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

## License

MIT. See [LICENSE](LICENSE).
