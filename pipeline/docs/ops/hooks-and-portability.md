# The hooks, and the one way they break silently

`.claude/settings.json` is version-controlled. Whatever path the hooks name travels to every
clone of your repo — so **never put an absolute path in it**.

## The failure this prevents

An earlier version of these hooks began with:

```bash
cd /home/alice/workspace || exit 0
```

On the machine that wrote it, that worked. On every other clone the `cd` failed, the `|| exit 0`
swallowed it, and the session started with **no rules, no memories, no command guards, and no
error anywhere**. A second operator would have run a plain agent session in a directory that
merely contained the files, and nothing would have told them.

That is the shape worth internalising: *the guard did not crash, it returned success and did
nothing*. A component whose job is to state the rules is the worst possible place for it.

The fix is that each hook resolves the repo root from **its own file location**:

```bash
WS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)
```

and `settings.json` calls them through `${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}`.
`tools/hook_portability_test.sh` relocates the hooks to a throwaway root and asserts they follow;
it also greps every executable line for an absolute home path, and fails on one. A test that only
ran the hooks in place would pass against the very bug it exists to catch.

## Fail open or fail loud — pick deliberately, per hook

These hooks do not all fail the same way, and that is on purpose:

| Hook | On "cannot resolve root" | Why |
| --- | --- | --- |
| `bd-prime-hook.sh` (SessionStart) | prints a loud alarm, exits 0 | its stdout *is* the session payload, so the alarm is the one thing guaranteed to be read |
| `bd-prerun-hook.sh` (PreToolUse) | warns on stderr, exits 0 | exit 2 here blocks every Bash call and bricks the session — worse than the outage |
| `bd-stop-hook.sh` (Stop, SessionEnd) | warns on stderr, exits 0 | nothing to protect at that point |

Open is a legitimate choice. **Open and silent is not.**

## The two ways hook installation breaks

Both are silent:

- **`bd hooks install` without `--shared`** writes to `.git/hooks/`, which git ignores while
  `core.hooksPath` is set. bd's hooks then stop firing with no error. Always pass `--shared`.
- **`core.hooksPath` disagreeing with where bd installed.** bd supports `.git/hooks` (default),
  `.beads/hooks` (`--beads`) and `.beads-hooks` (`--shared`); any is fine *so long as
  `core.hooksPath` names the one bd actually used*. A mismatch leaves the hooks ignored.

Re-running the installer is how you repair either. It is idempotent.

## Site checks

`.claude/site-checks/*.sh` is an extension point: any executable script there runs at session
start, and **anything it prints becomes an alarm at the top of the payload**. The contract is that
a healthy check prints nothing. A check that chatters every session trains its reader to skip the
block, and is then worthless on the day it has something to say.

Each check is bounded by `timeout` where the box has one; without it the checks run unbounded and
the payload says so at the top, because a check skipped in silence is the shape this file exists to
prevent. Its exit status is ignored, and whatever it prints — on either stream — is the alarm: a
check that dies with "command not found" on stderr is reported, not skipped.
