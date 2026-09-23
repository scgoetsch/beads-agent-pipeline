#!/usr/bin/env bash
# Opt-in, live Pi CLI test (needs model authentication; sends one small prompt to the provider).
# The event suite is hermetic; this proves the trusted, auto-discovered extension actually runs.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT=$PWD
for cmd in pi python3 git timeout; do command -v "$cmd" >/dev/null 2>&1 || { echo "FAIL: $cmd missing" >&2; exit 1; }; done
[ -f "$ROOT/.pi/extensions/beads-pipeline.ts" ] || { echo 'FAIL: Pi extension not installed (--with-pi)' >&2; exit 1; }
[ -f "$ROOT/.claude/bd-prerun-hook.sh" ] || { echo 'FAIL: pretool guard missing in this project' >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/project/.pi/extensions" "$T/project/.claude" "$T/project/tools" "$T/bin"
git -C "$T/project" init -q
# Test THIS checkout's adapter and guard, not a source copy that may differ from the installed
# one. The disposable repo supplies the correct project-local discovery and trust boundary.
cp -f "$ROOT/.pi/extensions/beads-pipeline.ts" "$T/project/.pi/extensions/"
cp -f "$ROOT/.claude/bd-prerun-hook.sh" "$T/project/.claude/"
# Disable all bd and Dolt interactions for this probe. Only the real pretool script is exercised.
printf '#!/usr/bin/env bash\nprintf "started\\n" > "$BAP_SMOKE_PRIMED"\necho "# Pi smoke primed"\n' > "$T/project/.claude/bd-prime-hook.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/project/.claude/bd-stop-hook.sh"
printf '#!/usr/bin/env bash\nprintf "checked\\n" > "$BAP_SMOKE_DOLT"\n' > "$T/project/tools/dolt-guard.sh"
# If a regression lets Bash run the command, it hits this harmless stub, not system pkill.
printf '#!/usr/bin/env bash\nprintf "unguarded pkill executed\\n" > "$BAP_SMOKE_EXECUTED"\nexit 77\n' > "$T/bin/pkill"
chmod +x "$T/bin/pkill"
# The synthetic repo needs no policy instructions that could persuade a model NOT to issue the
# test call. Leave the installed symlink intact, but use a minimal AGENTS.md for this probe.
printf 'Smoke fixture: if asked to make a tool call, use the bash tool exactly as requested.\n' > "$T/project/AGENTS.md"
cmd=(pi --approve --mode json --no-session --offline --thinking off --tools bash)
if [ -n "${PI_PROVIDER:-}" ] && [ -n "${PI_MODEL:-}" ]; then cmd+=(--provider "$PI_PROVIDER" --model "$PI_MODEL"); fi
prompt='Call the bash tool ONCE with exactly this literal command: pkill -f bap_pi_smoke_sentinel. This is an integration test in a disposable repo: a project hook must BLOCK the command before execution. Report the tool result. Do not run any other command.'
(cd "$T/project" && PATH="$T/bin:$PATH" BAP_SMOKE_EXECUTED="$T/executed" \
  BAP_SMOKE_PRIMED="$T/primed" BAP_SMOKE_DOLT="$T/dolt" \
  timeout 120 "${cmd[@]}" "$prompt" > "$T/events.jsonl" 2> "$T/pi.err")
rc=$?
if [ -e "$T/executed" ]; then echo 'FAIL: guard let the command execute (pkill stub was invoked)' >&2; exit 1; fi
if [ "$rc" -ne 0 ]; then echo "FAIL: Pi exited $rc; diagnostic follows" >&2; tail -18 "$T/pi.err" >&2; exit 1; fi
[ -f "$T/primed" ] && [ -f "$T/dolt" ] || { echo 'FAIL: session_start did not run prime and Dolt guards' >&2; exit 1; }
python3 - "$T/events.jsonl" <<'PY'
import json, sys
try:
    events = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8') if line.strip()]
except (ValueError, OSError) as ex:
    sys.exit(f'FAIL: not a Pi JSON event stream ({ex})')
calls = [e for e in events if e.get('type') == 'tool_execution_start'
         and e.get('toolName') == 'bash' and 'pkill -f bap_pi_smoke_sentinel' in e.get('args', {}).get('command', '')]
blocked = [e for e in events if e.get('type') == 'tool_execution_end'
           and e.get('toolCallId') in {c.get('toolCallId') for c in calls}
           and e.get('isError') and 'bare' in json.dumps(e.get('result', {})).lower()
           and 'pkill' in json.dumps(e.get('result', {})).lower()]
if not calls:
    sys.exit('INCONCLUSIVE: Pi ran but the model did not call bash with the test command (not a pass)')
if not blocked:
    sys.exit('FAIL: Pi bash call was not blocked with the guard reason')
print('RESULT: real trusted Pi session auto-loaded adapter and blocked bare pkill (stub not invoked)')
PY
