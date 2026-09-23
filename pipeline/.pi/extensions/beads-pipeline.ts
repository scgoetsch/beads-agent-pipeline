// Pi adapter for beads-agent-pipeline. Claude Code keeps its own .claude/settings.json hooks;
// this extension reuses their scripts rather than reimplementing their policies in TypeScript.
// This file is project-local and loads ONLY after Pi grants project trust.
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { resolve, sep } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const PREFIX = "⚠ beads-agent-pipeline (Pi):";
const LIMIT = 256_000; // Bound captured text even if a script regresses to an unbudgeted dump.
const TIMEOUT_MS = 30_000;
type ScriptResult = { code: number | null; stdout: string; stderr: string; fault?: string };
type NoticeContext = {
  cwd: string; hasUI: boolean; ui: { notify(message: string, level: "info" | "warning"): void };
  sessionManager?: { getSessionId?(): string };
};
// The bd store is shared by every session and all of them claim as the same actor, so the hooks
// scope "in progress" to what THIS session claimed, keyed by the session id.
// Pi's own id when available, so a resumed session keeps its record; else one per runtime.
const RUNTIME_KEY = `pi-${randomUUID()}`;
function sessionKey(ctx: NoticeContext): string {
  try {
    const id = ctx.sessionManager?.getSessionId?.();
    if (typeof id === "string" && id) return `pi-${id}`;
  } catch { /* fall through */ }
  return RUNTIME_KEY;
}

function inProject(cwd: string): boolean {
  const dir = resolve(cwd);
  return dir === root || dir.startsWith(root + sep);
}

function missingWarning(script: string): string {
  const path = resolve(root, ".claude", script);
  return `${PREFIX} ${script} NOT FOUND at ${path} — bd session rules and command guards are OFF. Re-run the beads-agent-pipeline installer and check .claude/settings.json.`;
}

function notice(ctx: NoticeContext, message: string, level: "info" | "warning" = "warning"): void {
  // Never throw from a tool_call handler: Pi treats thrown errors as a BLOCK. The Claude
  // guard intentionally fails open on infrastructure errors, but says so loudly.
  try {
    if (ctx.hasUI) { ctx.ui.notify(message, level); return; }
  } catch { /* fall through to stderr */ }
  console.error(message);
}

async function runScript(relative: string, stdin?: string): Promise<ScriptResult> {
  const script = resolve(root, relative);
  if (!existsSync(script)) return { code: null, stdout: "", stderr: "", fault: `${relative} NOT FOUND at ${script}` };
  return new Promise((done) => {
    let stdout = "", stderr = "", fault: string | undefined, finished = false;
    let child: ReturnType<typeof spawn>;
    try { child = spawn("bash", [script], { cwd: root, stdio: ["pipe", "pipe", "pipe"] }); }
    catch (error) { done({ code: null, stdout, stderr, fault: String(error) }); return; }
    let timer: ReturnType<typeof setTimeout>;
    const finish = (code: number | null) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      done({ code, stdout: stdout.slice(0, LIMIT), stderr: stderr.slice(0, LIMIT), fault });
    };
    const stop = (reason: string) => {
      if (finished) return;
      fault = reason;
      child.kill("SIGKILL");
      // A child can leave grandchild-held stdout/stderr pipes open. Do not wait for 'close'
      // forever: resolve the adapter's check now, visibly failing open if this was the gate.
      child.stdout.destroy(); child.stderr.destroy(); child.stdin.destroy();
      finish(null);
    };
    timer = setTimeout(() => stop(`timed out after ${TIMEOUT_MS} ms`), TIMEOUT_MS);
    child.stdout.on("data", (part: Buffer) => {
      if (finished) return;
      stdout += part.toString();
      if (stdout.length > LIMIT) stop(`stdout exceeded ${LIMIT} characters`);
    });
    child.stderr.on("data", (part: Buffer) => {
      if (finished) return;
      stderr += part.toString();
      if (stderr.length > LIMIT) stop(`stderr exceeded ${LIMIT} characters`);
    });
    child.on("error", (error) => stop(String(error)));
    child.on("close", (code) => finish(code));
    // If the child exits before consuming stdin, EPIPE must not crash Pi.
    child.stdin.on("error", () => {});
    if (stdin === undefined) child.stdin.end();
    else child.stdin.end(stdin);
  });
}

export default function beadsPipeline(pi: ExtensionAPI) {
  let prime = `${PREFIX} session not primed — check that the Pi extension loaded and session_start ran.`;

  async function refresh(ctx: NoticeContext, start: boolean): Promise<void> {
    if (!inProject(ctx.cwd)) {
      prime = `${PREFIX} extension from ${root} loaded outside its project (${ctx.cwd}); no bd checks ran.`;
      notice(ctx, prime);
      return;
    }
    let guardAlert = "";
    if (start) {
      const guard = await runScript("tools/dolt-guard.sh");
      if (guard.fault || guard.code !== 0) {
        guardAlert = `${PREFIX} Dolt guard FAILED (${guard.fault || `exit ${guard.code}`}): ${guard.stderr.trim() || "bd writes may not land"}`;
        notice(ctx, guardAlert);
      } else if (guard.stderr.trim()) {
        // The guard reports a restart or an inability to probe on stderr.
        notice(ctx, `${PREFIX} ${guard.stderr.trim()}`);
      }
    }
    const result = await runScript(".claude/bd-prime-hook.sh");
    if (result.fault || result.code !== 0 || !result.stdout.trim()) {
      const why = result.fault || `exit ${result.code}; ${result.stderr.trim() || "empty output"}`;
      prime = result.fault?.includes("NOT FOUND")
        ? `${missingWarning("bd-prime-hook.sh")} Session is NOT PRIMED.`
        : `${PREFIX} bd-prime-hook.sh unavailable (${why}) — session is NOT PRIMED. Re-run the beads-agent-pipeline installer and check .pi/extensions/ and .claude/.`;
      notice(ctx, prime);
    } else {
      prime = result.stdout;
      if (result.stderr.trim()) notice(ctx, `${PREFIX} bd-prime-hook.sh: ${result.stderr.trim()}`);
    }
    if (guardAlert) prime = `${guardAlert}\n${prime}`;
  }

  async function gate(command: string, ctx: NoticeContext): Promise<string | undefined> {
    try {
      if (!inProject(ctx.cwd)) {
        notice(ctx, `${PREFIX} guard disabled outside ${root}; command ALLOWED without checking.`);
        return;
      }
      const json = JSON.stringify({ tool_name: "Bash", tool_input: { command }, session_id: sessionKey(ctx), hook_event_name: "PreToolUse" });
      const result = await runScript(".claude/bd-prerun-hook.sh", json);
      if (result.code === 2 && !result.fault) return result.stderr.trim() || "Blocked by bd-prerun-hook.sh (exit 2).";
      if (result.fault || result.code !== 0) {
        const message = result.fault?.includes("NOT FOUND")
          ? missingWarning("bd-prerun-hook.sh")
          : `${PREFIX} bd-prerun-hook.sh FAILED (${result.fault || `exit ${result.code}`}); guards are OFF. ${result.stderr.trim()} Re-run the beads-agent-pipeline installer and check .claude/settings.json.`;
        notice(ctx, `${message} Command ALLOWED.`);
        return;
      }
      if (result.stderr.trim()) notice(ctx, `${PREFIX} ${result.stderr.trim()}`);
    } catch (error) {
      // A rejected child-process promise must not let Pi's own fail-safe handler policy
      // turn a guard infrastructure failure into a Bash block.
      notice(ctx, `${PREFIX} bd-prerun-hook.sh adapter FAILED (${String(error)}); guards are OFF. Command ALLOWED.`);
    }
  }

  pi.on("session_start", async (_event, ctx) => { await refresh(ctx, true); });
  pi.on("session_before_compact", async (_event, ctx) => { await refresh(ctx, false); });
  pi.on("before_agent_start", (event) => {
    // Pi rebuilds system-prompt sections for each run, including after compaction. bd is NOT
    // called here: use the cache from session_start (or the last session_before_compact).
    event.systemPromptOptions.sections.beads_pipeline = prime;
  });
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash") return;
    const command = (event.input as { command?: unknown }).command;
    if (typeof command !== "string") return;
    const reason = await gate(command, ctx);
    if (reason) return { block: true, reason };
  });
  pi.on("user_bash", async (event, ctx) => {
    const reason = await gate(event.command, ctx);
    if (reason) return { result: { output: reason, exitCode: 2, cancelled: false, truncated: false } };
  });
  // agent_settled ends EVERY agent run (each turn), not the session. The stop hook,
  // told it is a turn end ("Stop") and whose session this is, reports only this session's claimed
  // issues and only when that set changes; the close reminder is for session_shutdown below.
  async function reminder(ctx: NoticeContext, hookEvent: "Stop" | "SessionEnd"): Promise<void> {
    if (!inProject(ctx.cwd)) return;
    const payload = JSON.stringify({ hook_event_name: hookEvent, session_id: sessionKey(ctx) });
    const result = await runScript(".claude/bd-stop-hook.sh", payload);
    if (result.fault || result.code !== 0) {
      notice(ctx, result.fault?.includes("NOT FOUND")
        ? missingWarning("bd-stop-hook.sh")
        : `${PREFIX} bd-stop-hook.sh FAILED (${result.fault || `exit ${result.code}`}); no in-progress check ran. ${result.stderr.trim()}`);
    } else if (result.stdout.trim()) {
      // advisory only; NEVER continue a settled run
      notice(ctx, result.stdout.trim(), hookEvent === "SessionEnd" ? "warning" : "info");
    } else if (result.stderr.trim()) notice(ctx, `${PREFIX} ${result.stderr.trim()}`);
  }
  pi.on("agent_settled", async (_event, ctx) => { await reminder(ctx, "Stop"); });
  pi.on("session_shutdown", async (event, ctx) => {
    // quit and new end this session; reload, resume and fork carry it on under the same id.
    const reason = (event as { reason?: string }).reason;
    if (reason === "quit" || reason === "new") await reminder(ctx, "SessionEnd");
  });
}
