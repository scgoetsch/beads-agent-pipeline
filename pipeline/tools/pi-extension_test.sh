#!/usr/bin/env bash
# Hermetic Pi adapter suite: feed real Pi event shapes to the actual TypeScript factory, using
# disposable sibling scripts. Never executes pkill, a real bd store, or the user's .pi resources.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
if [ ! -f .pi/extensions/beads-pipeline.ts ]; then
  echo 'SKIP pi-extension_test.sh: Pi extension not installed (use install.sh --with-pi)'
  exit 0
fi
if ! command -v node >/dev/null 2>&1 || ! node -e 'const [v,m]=process.versions.node.split(".").map(Number);process.exit(v>22||v===22&&m>=19?0:1)' 2>/dev/null; then
  echo 'SKIP pi-extension_test.sh: Node >=22.19 absent; Pi cannot run on this box'
  exit 0
fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/ws/.pi/extensions" "$T/ws/.claude" "$T/ws/tools"
cp -f .pi/extensions/beads-pipeline.ts "$T/ws/.pi/extensions/beads-pipeline.ts"
# Count actual child invocations, so a stubbed factory that claims it primed without running
# the script cannot pass. These are never the scripts of the user's live project.
for pair in '.claude/bd-prime-hook.sh:prime' '.claude/bd-prerun-hook.sh:gate' \
            '.claude/bd-stop-hook.sh:stop' 'tools/dolt-guard.sh:dolt'; do
  f=${pair%%:*}; name=${pair#*:}
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q >> "$BAP_TEST_ROOT/%s.calls"\n' "$name" "$name" > "$T/ws/$f"
done
# Customize each executable's behavior after the invocation log above.
printf 'n=$(wc -l < "$BAP_TEST_ROOT/prime.calls")\nprintf "# PRIMED %%s\\n" "$n"\n' >> "$T/ws/.claude/bd-prime-hook.sh"
printf '%s\n' 'IFS= read -r payload || :' 'printf "%s\n" "$payload" >> "$BAP_TEST_ROOT/gate.inputs"' \
  'case "$payload" in' \
  '  *pkill*) echo "BARE pkill BLOCKED" >&2; exit 2 ;;' \
  '  *BROKEN*) echo "guard failed" >&2; exit 1 ;;' \
  '  *WARN*) echo "advisory allowed" >&2; exit 0 ;;' \
  '  *BIG*) python3 -c '\''print("x" * 300000)'\''; exit 0 ;;' \
  'esac' >> "$T/ws/.claude/bd-prerun-hook.sh"
printf '%s\n' 'IFS= read -r payload || :' 'printf "%s\n" "$payload" >> "$BAP_TEST_ROOT/stop.inputs"' \
  'case "$payload" in *SessionEnd*) echo "close reminder" ;; *) echo "in-progress reminder" ;; esac' \
  >> "$T/ws/.claude/bd-stop-hook.sh"
chmod +x "$T/ws/.claude/"*.sh "$T/ws/tools/"*.sh
BAP_TEST_ROOT="$T/ws" node --input-type=module - "$T/ws/.pi/extensions/beads-pipeline.ts" "$T/ws" <<'JS' || exit 1
import assert from 'node:assert/strict';
import { existsSync, renameSync } from 'node:fs';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const file = resolve(process.argv[2]), root = resolve(process.argv[3]);
const { default: factory } = await import(pathToFileURL(file).href);
const handlers = new Map(), notices = [];
const pi = { on(name, fn) { handlers.set(name, fn); return () => handlers.delete(name); } };
factory(pi);
const ctx = { cwd: root, hasUI: true, ui: { notify(s, level) { notices.push({ text: s, level }); } },
  sessionManager: { getSessionId: () => 'test-session' } };
const fire = (name, event = {}, context = ctx) => {
  assert(handlers.has(name), `missing ${name} event`);
  return handlers.get(name)(event, context);
};
const calls = (name) => existsSync(`${root}/${name}.calls`) ? readFileSync(`${root}/${name}.calls`, 'utf8').trim().split('\n').length : 0;
const prompt = () => ({ systemPromptOptions: { sections: {} } });

await fire('session_start', { reason: 'startup' });
assert.equal(calls('dolt'), 1); assert.equal(calls('prime'), 1);
for (let n = 0; n < 2; n++) {
  const event = prompt(); await fire('before_agent_start', event);
  assert.match(event.systemPromptOptions.sections.beads_pipeline, /PRIMED 1/);
}
assert.equal(calls('prime'), 1, 'before_agent_start must not re-run bd');
await fire('session_before_compact', { reason: 'threshold' });
assert.equal(calls('prime'), 2);
const after = prompt(); await fire('before_agent_start', after);
assert.match(after.systemPromptOptions.sections.beads_pipeline, /PRIMED 2/);
assert.equal(calls('dolt'), 1, 'compaction should not rerun the startup guard');

const blocked = await fire('tool_call', { toolName: 'bash', input: { command: 'pkill -f sentinel' } });
assert.ok(blocked, JSON.stringify(notices)); assert.equal(blocked.block, true); assert.match(blocked.reason, /BARE pkill BLOCKED/);
const payloads = readFileSync(`${root}/gate.inputs`, 'utf8').trim().split('\n').map(JSON.parse);
assert.deepEqual(payloads[0], { tool_name: 'Bash', tool_input: { command: 'pkill -f sentinel' },
  session_id: 'pi-test-session', hook_event_name: 'PreToolUse' });
assert.equal(await fire('tool_call', { toolName: 'read', input: { path: 'test' } }), undefined);
assert.equal(await fire('tool_call', { toolName: 'bash', input: { command: 'echo safe' } }), undefined);
const typed = await fire('user_bash', { command: 'pkill -f sentinel', cwd: root, excludeFromContext: false });
assert.equal(typed.result.exitCode, 2); assert.match(typed.result.output, /BARE pkill BLOCKED/);
assert.equal(await fire('user_bash', { command: 'echo safe', cwd: root }), undefined);
assert.equal(await fire('tool_call', { toolName: 'bash', input: { command: 'BROKEN' } }), undefined);
assert.match(notices.at(-1).text, /guards are OFF.*Command ALLOWED/);
assert.equal(await fire('tool_call', { toolName: 'bash', input: { command: 'WARN' } }), undefined);
assert.match(notices.at(-1).text, /advisory allowed/);
assert.equal(await fire('tool_call', { toolName: 'bash', input: { command: 'BIG' } }), undefined);
assert.match(notices.at(-1).text, /stdout exceeded.*Command ALLOWED/);
renameSync(`${root}/.claude/bd-prerun-hook.sh`, `${root}/.claude/guard.hidden`);
assert.equal(await fire('tool_call', { toolName: 'bash', input: { command: 'pkill -f sentinel' } }), undefined);
assert.match(notices.at(-1).text, /NOT FOUND.*Command ALLOWED/);
renameSync(`${root}/.claude/guard.hidden`, `${root}/.claude/bd-prerun-hook.sh`);
const oldPath = process.env.PATH;
process.env.PATH = '/nonexistent-bash';
try {
  assert.equal(await fire('user_bash', { command: 'echo harmless', cwd: root }), undefined);
  assert.match(notices.at(-1).text, /FAILED.*Command ALLOWED/);
} finally { process.env.PATH = oldPath; }
const foreign = { ...ctx, cwd: '/tmp/foreign-project' };
assert.equal(await fire('tool_call', { toolName: 'bash', input: { command: 'pkill -f sentinel' } }, foreign), undefined);
assert.match(notices.at(-1).text, /outside/);
await fire('agent_settled');
assert.equal(calls('stop'), 1); assert.match(notices.at(-1).text, /in-progress reminder/);
assert.equal(notices.at(-1).level, 'info', 'a turn end is not a warning');
const stopIn = () => readFileSync(`${root}/stop.inputs`, 'utf8').trim().split('\n').map(JSON.parse);
assert.deepEqual(stopIn().at(-1), { hook_event_name: 'Stop', session_id: 'pi-test-session' });
assert.equal(handlers.has('agent_before_settle'), false, 'no auto-continuation loop');
// the close reminder belongs to the session's end, not to every settled turn.
for (const reason of ['reload', 'resume', 'fork']) await fire('session_shutdown', { reason });
assert.equal(calls('stop'), 1, 'reload/resume/fork continue the session: no close reminder');
await fire('session_shutdown', { reason: 'quit' });
assert.equal(calls('stop'), 2); assert.match(notices.at(-1).text, /close reminder/);
assert.equal(notices.at(-1).level, 'warning');
assert.deepEqual(stopIn().at(-1), { hook_event_name: 'SessionEnd', session_id: 'pi-test-session' });
await fire('session_shutdown', { reason: 'new' }); assert.equal(calls('stop'), 3);
// With no Pi session id the adapter still sends one stable key, never none.
const anon = { ...ctx, sessionManager: undefined };
await fire('agent_settled', {}, anon); await fire('agent_settled', {}, anon);
const [k1, k2] = stopIn().slice(-2).map((p) => p.session_id);
assert.match(k1, /^pi-/); assert.equal(k1, k2);
renameSync(`${root}/.claude/bd-stop-hook.sh`, `${root}/.claude/stop.hidden`);
await fire('agent_settled'); assert.match(notices.at(-1).text, /bd-stop-hook.sh NOT FOUND.*guards are OFF/);
renameSync(`${root}/.claude/stop.hidden`, `${root}/.claude/bd-stop-hook.sh`);
renameSync(`${root}/.claude/bd-prime-hook.sh`, `${root}/.claude/prime.hidden`);
await fire('session_start', { reason: 'new' });
const missing = prompt(); await fire('before_agent_start', missing);
assert.match(missing.systemPromptOptions.sections.beads_pipeline, /bd-prime-hook.sh NOT FOUND.*NOT PRIMED/);
renameSync(`${root}/.claude/prime.hidden`, `${root}/.claude/bd-prime-hook.sh`);
await fire('session_before_compact', { reason: 'manual' });
const restored = prompt(); await fire('before_agent_start', restored);
assert.match(restored.systemPromptOptions.sections.beads_pipeline, /PRIMED 3/);
console.log('RESULT: Pi event adapter blocks, allows, warns and caches/refreshes as specified');
JS

# ── Session-scope regression: the REAL hooks, driven by the adapter, over a shared store that
# holds other sessions' in-progress work. Two ordinary turns must stay quiet; this session's own
# claim must license its scripts and be reported once; the close reminder waits for a real quit.
W="$T/ws2"; mkdir -p "$W/.pi/extensions" "$W/.claude" "$W/tools" "$T/bin2"
cp -f .pi/extensions/beads-pipeline.ts "$W/.pi/extensions/"
cp -f .claude/bd-stop-hook.sh .claude/bd-prerun-hook.sh "$W/.claude/"
printf '#!/usr/bin/env bash\necho "# PRIMED"\n' > "$W/.claude/bd-prime-hook.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/tools/dolt-guard.sh"
cat > "$T/bin2/bd" <<'BD'
#!/usr/bin/env bash
# Stub store: $BAP_STORE holds "<id><TAB><title>" per in-progress issue.
case "$*" in
  *--json*in_progress*) python3 -c 'import json, sys
rows = [l.rstrip("\n").split("\t", 1) for l in open(sys.argv[1]) if l.strip()]
print(json.dumps([{"id": r[0], "title": r[-1], "status": "in_progress"} for r in rows]))' "$BAP_STORE" ;;
  *in_progress*) while IFS=$'\t' read -r id t; do [ -n "$id" ] && echo "◐ $id ● P2 [task] $t"; done < "$BAP_STORE" ;;
esac
exit 0
BD
chmod +x "$T/bin2/bd" "$W/.claude/"*.sh "$W/tools/"*.sh
printf 'other-1\tanother session\nother-2\tstale since June\nother-3\tanother project\n' > "$T/store"
BAP_STORE="$T/store" BD_SESSION_CLAIMS_DIR="$T/claims2" PATH="$T/bin2:$PATH" \
  node --input-type=module - "$W/.pi/extensions/beads-pipeline.ts" "$W" "$T/store" <<'JS2'
import assert from 'node:assert/strict';
import { appendFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const [file, root, store] = process.argv.slice(2).map((p) => resolve(p));
const { default: factory } = await import(pathToFileURL(file).href);
const handlers = new Map(), notices = [];
factory({ on(name, fn) { handlers.set(name, fn); } });
const ctx = { cwd: root, hasUI: true, ui: { notify(text, level) { notices.push({ text, level }); } },
  sessionManager: { getSessionId: () => 'turns' } };
const fire = (name, event = {}) => handlers.get(name)(event, ctx);
const bash = (command) => fire('tool_call', { toolName: 'bash', input: { command } });

await fire('session_start', { reason: 'startup' });
const base = notices.length;
await fire('agent_settled'); await fire('agent_settled');
assert.equal(notices.length, base, `two ordinary turns over other sessions' work must be quiet: ${JSON.stringify(notices.slice(base))}`);
const blocked = await bash('python3 scripts/run.py');
assert.equal(blocked?.block, true, 'unrelated in-progress issues must not license this session');
assert.match(blocked.reason, /No issue claimed by THIS session/);
assert.equal(await bash('bd update ws-9 --claim'), undefined, 'claiming is allowed');
appendFileSync(store, 'ws-9\tmy claimed work\n');          // ...and the claim ran
await fire('agent_settled');
assert.equal(notices.length, base + 1, 'the session\'s own claim is reported once');
assert.equal(notices.at(-1).level, 'info');
assert.match(notices.at(-1).text, /ws-9/); assert.doesNotMatch(notices.at(-1).text, /other-|SESSION CLOSE/);
await fire('agent_settled');
assert.equal(notices.length, base + 1, 'unchanged on the next turn: no repeat');
assert.equal(await bash('python3 scripts/run.py'), undefined, 'its own claim licenses its scripts');
await fire('session_shutdown', { reason: 'reload' });
assert.equal(notices.length, base + 1, 'a reload is not a close');
await fire('session_shutdown', { reason: 'quit' });
const close = notices.at(-1);
assert.equal(close.level, 'warning'); assert.match(close.text, /SESSION CLOSE REMINDER/);
assert.match(close.text, /ws-9/); assert.doesNotMatch(close.text, /other-/);
console.log('RESULT: real hooks via Pi: quiet turns, one scoped notice, session-scoped scripts gate, close reminder on quit');
JS2
