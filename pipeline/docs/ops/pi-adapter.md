# Pi adapter: opt-in session hooks

`install.sh --with-pi <repo>` copies `.pi/extensions/beads-pipeline.ts`. Pi loads this
**project-local extension only after project trust is granted**. Run Pi from that repository,
then approve its project resources (or use `pi --approve` for one trusted invocation). Pi's
`--no-approve` and `--no-extensions` disable auto-loading; `AGENTS.md` still loads but is **not**
proof that command guards are running. An untrusted project's own extension cannot warn that it
was skipped. The template's AGENTS.md warns about this explicitly. Do not add global, unreviewed
code to `~/.pi/agent/extensions/` to work around trust.

The adapter does not fork the policy in JavaScript. It calls the installed `.claude/*.sh` scripts:

| Pi event | Action |
| --- | --- |
| `session_start` | Run `tools/dolt-guard.sh` (Pi's non-interactive Bash does not source `~/.bashrc`), then `bd-prime-hook.sh`; cache its budgeted stdout. |
| `before_agent_start` | Put cached context in a system-prompt section, once per agent run. **Do not rerun bd here.** The section is not summarized away by compaction. |
| `session_before_compact` | Refresh the cache with `bd-prime-hook.sh`, as Claude Code's PreCompact does; the next run uses the fresh section. |
| `tool_call` (`bash`) and `user_bash` (`!`) | Send `{"tool_name":"Bash","tool_input":{"command":"..."}}` on stdin to `bd-prerun-hook.sh`. Exit 2 blocks (for `!`, return an error result); exit 0 allows. Missing, failing or timed-out hook **allows with a visible warning**, never silently. |
| `agent_settled` | Show nonempty `bd-stop-hook.sh` output as a UI notice (stderr in print mode). Never use `agent_before_settle` / `continue:true`: an open issue would loop. |

From a pipeline source checkout (`pipeline/`) **or an installed opt-in project**, after
configuring model authentication:

```bash
tools/pi-extension_test.sh  # hermetic; requires the adapter in this checkout
tools/pi-extension_smoke.sh # live: model request in a throwaway trusted project
```

The `_test.sh` feeds simulated Pi events through the actual TypeScript handler and checks both
block and fail-open paths, priming, compaction refresh and settled notice; it also runs in the
fresh install in `selftest.sh`. The separate live smoke copies **this checkout's** adapter and
pretool guard into a throwaway repo (so a stale installed copy cannot pass by testing source),
replaces its bd/Dolt helpers with no-op fixtures, puts a harmless `pkill` stub on PATH and
invokes the **real Pi CLI** with `--approve`. It checks the JSON event stream for a blocked model Bash call
and refuses to pass if the stub runs. It sends one short prompt to your configured provider and
needs model authentication and `timeout`; if the model never calls Bash, it reports
**INCONCLUSIVE**, not a pass. The smoke does **not** trust your actual working project or touch
its store; inspect its extension before ever trusting it in your real repo.

**Limits:** Pi only intercepts calls through the events above. `pi.exec()` from *other extensions*
bypasses `tool_call`; custom tools, tools other than `bash`, and constructed shell/alias commands
are not comprehensively checked. This is an accident guard, **not a sandbox**. Git pre-commit
hooks remain the harness-independent enforcement layer for committed artifacts; they work only
if `core.hooksPath` is wired on that clone. A copied `.pi/extensions/` file, a trusted project,
or an installed `pi` binary alone does not prove the tool-call handler fired.

Installer policy is the same as for the other files: a differing existing Pi adapter is **kept**
and the new version lands as `.new`; unrelated `.pi/extensions/` files and Pi settings are not
modified. There is no global install and no change to project-trust settings. Re-run the adapter
suite and a real smoke after adopting a `.new` file.
