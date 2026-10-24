// Worker approval bridge for Pi workers (docs/worker-approval-bridge.md).
//
// A cooperative guard extension asks before running a flagged bash command by
// emitting a request on Pi's shared extension event bus instead of opening its
// own dialog in the unattended worker pane. This module, loaded by the
// per-task extension bin/fm-spawn.sh writes, is the Labmate side of that
// contract:
//   1. it records the request durably under the task's home state and opens a
//      keyed needs-decision in the task's status log, so the coordinator sees
//      the exact command, working directory, task, and incarnation at once;
//   2. it claims the request synchronously, so the guard knows a coordinator
//      is present and keeps the tool call waiting instead of prompting;
//   3. it releases that one tool call only when a response record bound to the
//      same request, task, incarnation, and command digest arrives, and tells
//      the guard "abort" on deny, cancel, retire, or any invalid record.
// Without a cooperative guard nothing is claimed and no command is ever
// released by this module. It then only DETECTS a native prompt: when Pi
// reports a blocking extension dialog while a bash tool call is pending, it
// opens a keyed blocker naming the command so the coordinator learns at once
// that the pane needs a keypress, and closes it when the dialog closes.
// bin/fm-worker-approval-lib.sh owns the record format and the binding rule;
// nothing here restates them.
//
// Bus contract (channel names are stable public API for guard authors):
//   firstmate:worker-approval-request   guard -> bridge
//     { requestId, toolCallId, toolName: "bash", command, cwd,
//       guard?, severity?, reasons?, signal? }
//   firstmate:worker-approval-claimed   bridge -> guard, emitted synchronously
//                                       inside the request emit
//     { requestId, approvalId, taskId }
//   firstmate:worker-approval-response  bridge -> guard, once the coordinator
//                                       answered or the request ended
//     { requestId, approvalId, verdict: "run" | "abort", reason }
// A guard that receives no claim within its short grace keeps its own prompt;
// a claimed guard waits for the response and never treats silence as consent.
// Only the request's own toolCallId and an exactly equal command are claimed:
// the bridge binds to the tool call Pi announced through tool_execution_start,
// which precedes every tool_call gate, so a guard cannot be answered for a
// command Pi is not about to run.

import { createHash } from "node:crypto";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

export const WORKER_APPROVAL_REQUEST_EVENT = "firstmate:worker-approval-request";
export const WORKER_APPROVAL_CLAIMED_EVENT = "firstmate:worker-approval-claimed";
export const WORKER_APPROVAL_RESPONSE_EVENT = "firstmate:worker-approval-response";

const SCHEMA = "fm-worker-approval.v1";
const KEY_PREFIX = "approval-";
const NATIVE_KEY_PREFIX = "native-prompt-";
// Status lines are presented through a 220-character cap (bin/fm-line-cap-lib.sh);
// the stamp this module writes is already inside the line, so cap the whole
// line a little under that bound.
const STATUS_LINE_MAX = 200;
const DEFAULT_POLL_MS = 1000;

export interface WorkerApprovalOptions {
  /** The task id whose status log and approvals directory this worker owns. */
  taskId: string;
  /** The busy incarnation gen fm-spawn armed for this launch (bin/fm-busy-lib.sh). */
  gen: string;
  /** Absolute home state directory holding state/<task>.status and the approvals directory. */
  stateDir: string;
  /** Absolute path of state/<task>.status. */
  statusFile: string;
  /** Response poll interval in milliseconds; tests shorten it. */
  pollMs?: number;
}

interface ApprovalRequest {
  requestId: string;
  toolCallId: string;
  toolName: string;
  command: string;
  cwd: string;
  guard?: string;
  severity?: string;
  reasons?: string[];
  signal?: AbortSignal;
}

interface Claim {
  approvalId: string;
  requestId: string;
  gen: string;
  commandSha256: string;
  settled: boolean;
  timer: ReturnType<typeof setInterval> | undefined;
}

interface PendingCall {
  toolCallId: string;
  command: string;
  claim: Claim | undefined;
  nativeKey: string | undefined;
}

type EventBusLike = {
  emit?: (channel: string, data: unknown) => void;
  on?: (channel: string, handler: (data: unknown) => void) => unknown;
};

type ExtensionApiLike = {
  on: (event: string, handler: (event: any, ctx?: any) => unknown) => unknown;
  events?: EventBusLike;
};

function sha256(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

function epoch(): number {
  return Math.floor(Date.now() / 1000);
}

function oneLine(text: string): string {
  // eslint-disable-next-line no-control-regex
  return text.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim();
}

function statusLine(verb: string, key: string, note: string): string {
  const head = `${verb} [at=${epoch()}] [key=${key}]: `;
  const room = Math.max(0, STATUS_LINE_MAX - head.length);
  let body = oneLine(note);
  if (body.length > room) body = room > 3 ? `${body.slice(0, room - 3)}...` : body.slice(0, room);
  return `${head}${body}`;
}

function appendStatus(statusFile: string, line: string): void {
  try {
    appendFileSync(statusFile, `${line}\n`);
  } catch {
    // A status append is a notification; a failed one must never turn into a
    // released command, so the caller's safety decision does not depend on it.
  }
}

function writeRecord(path: string, header: Record<string, string>, body: string): void {
  const lines = Object.entries(header).map(([k, v]) => `${k}=${oneLine(v)}`);
  const content = `${lines.join("\n")}\n--\n${body}`;
  const tmp = `${path}.tmp-${process.pid}-${Date.now()}`;
  writeFileSync(tmp, content, { mode: 0o600 });
  renameSync(tmp, path);
}

function readHeader(path: string): Record<string, string> | undefined {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    return undefined;
  }
  const header: Record<string, string> = {};
  for (const line of text.split("\n")) {
    if (line === "--") break;
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    const key = line.slice(0, eq);
    if (!(key in header)) header[key] = line.slice(eq + 1);
  }
  return header;
}

function validRequestId(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9._-]{1,64}$/.test(value);
}

function parseRequest(data: unknown): ApprovalRequest | undefined {
  if (!data || typeof data !== "object") return undefined;
  const r = data as Record<string, unknown>;
  if (!validRequestId(r.requestId)) return undefined;
  if (typeof r.toolCallId !== "string" || r.toolCallId.length === 0) return undefined;
  if (r.toolName !== "bash") return undefined;
  if (typeof r.command !== "string") return undefined;
  const reasons = Array.isArray(r.reasons) ? r.reasons.filter((x): x is string => typeof x === "string") : undefined;
  const signal = r.signal && typeof (r.signal as AbortSignal).addEventListener === "function" ? (r.signal as AbortSignal) : undefined;
  return {
    requestId: r.requestId,
    toolCallId: r.toolCallId,
    toolName: "bash",
    command: r.command,
    cwd: typeof r.cwd === "string" ? r.cwd : "",
    guard: typeof r.guard === "string" ? r.guard : undefined,
    severity: typeof r.severity === "string" ? r.severity : undefined,
    reasons,
    signal,
  };
}

// FM_WORKER_APPROVAL_POLL_MS shortens the response poll for tests; an unset or
// malformed value keeps the default.
function configuredPollMs(explicit: number | undefined): number {
  if (explicit !== undefined) return explicit;
  const raw = process.env.FM_WORKER_APPROVAL_POLL_MS;
  if (raw && /^[0-9]+$/.test(raw) && Number(raw) > 0) return Number(raw);
  return DEFAULT_POLL_MS;
}

export function installWorkerApproval(pi: ExtensionApiLike, options: WorkerApprovalOptions): void {
  const { taskId, gen, stateDir, statusFile } = options;
  const pollMs = configuredPollMs(options.pollMs);
  const approvalsDir = join(stateDir, `${taskId}.approvals`);
  const pending = new Map<string, PendingCall>();

  const emit = (channel: string, data: unknown): void => {
    pi.events?.emit?.(channel, data);
  };

  const settle = (claim: Claim, verdict: "run" | "abort", reason: string): void => {
    if (claim.settled) return;
    claim.settled = true;
    if (claim.timer) clearInterval(claim.timer);
    claim.timer = undefined;
    emit(WORKER_APPROVAL_RESPONSE_EVENT, {
      requestId: claim.requestId,
      approvalId: claim.approvalId,
      verdict,
      reason,
    });
  };

  const closeWithRecord = (claim: Claim, kind: "cancelled" | "retired", reason: string): void => {
    const path = join(approvalsDir, `${claim.approvalId}.${kind}`);
    if (!existsSync(path)) {
      try {
        writeRecord(path, { schema: SCHEMA, request: claim.approvalId, task: taskId, gen: claim.gen, reason, at: String(epoch()) }, "");
      } catch {
        // The verdict below is still abort; the missing record only means the
        // coordinator sees the request as pending until it checks the gen.
      }
    }
    appendStatus(statusFile, statusLine("resolved", `${KEY_PREFIX}${claim.approvalId}`, `${kind}: ${reason}`));
  };

  const cancel = (claim: Claim, reason: string): void => {
    if (claim.settled) return;
    closeWithRecord(claim, "cancelled", reason);
    settle(claim, "abort", reason);
  };

  const checkResponse = (claim: Claim): void => {
    if (claim.settled) return;
    const responsePath = join(approvalsDir, `${claim.approvalId}.response`);
    if (existsSync(responsePath)) {
      const header = readHeader(responsePath);
      const bound =
        header !== undefined &&
        header.schema === SCHEMA &&
        header.request === claim.approvalId &&
        header.task === taskId &&
        header.gen === claim.gen &&
        header.command_sha256 === claim.commandSha256;
      if (!bound) {
        appendStatus(
          statusFile,
          `note [at=${epoch()}]: warning: ignored a worker approval response that does not bind to request ${claim.approvalId} (task, incarnation, or command digest differ); the command stays refused`,
        );
        settle(claim, "abort", "response record does not bind to this request");
        return;
      }
      if (header.verdict === "approve") {
        settle(claim, "run", `approved by the coordinator${header.note ? `: ${header.note}` : ""}`);
      } else {
        settle(claim, "abort", `denied by the coordinator${header.note ? `: ${header.note}` : ""}`);
      }
      return;
    }
    for (const kind of ["cancelled", "retired"] as const) {
      if (existsSync(join(approvalsDir, `${claim.approvalId}.${kind}`))) {
        settle(claim, "abort", `request ${kind} before an answer`);
        return;
      }
    }
  };

  const onRequest = (data: unknown): void => {
    const request = parseRequest(data);
    if (!request) return;
    const call = pending.get(request.toolCallId);
    // Claim only the exact pending tool call Pi announced; anything else is
    // left unclaimed so a guard keeps its own standalone behavior.
    if (!call || call.command !== request.command) return;
    if (call.claim) {
      emit(WORKER_APPROVAL_CLAIMED_EVENT, { requestId: request.requestId, approvalId: call.claim.approvalId, taskId });
      if (call.claim.settled) checkResponse(call.claim);
      return;
    }
    const approvalId = sha256([taskId, gen, request.toolCallId, request.cwd, request.command].join("\n")).slice(0, 16);
    const claim: Claim = {
      approvalId,
      requestId: request.requestId,
      gen,
      commandSha256: sha256(request.command),
      settled: false,
      timer: undefined,
    };
    try {
      mkdirSync(approvalsDir, { recursive: true, mode: 0o700 });
      writeRecord(
        join(approvalsDir, `${approvalId}.request`),
        {
          schema: SCHEMA,
          request: approvalId,
          task: taskId,
          gen,
          tool_call: request.toolCallId,
          tool: "bash",
          cwd: request.cwd,
          guard: request.guard ?? "unknown",
          severity: request.severity ?? "unknown",
          reasons: (request.reasons ?? []).join("; "),
          requested_at: String(epoch()),
          command_sha256: claim.commandSha256,
        },
        request.command,
      );
    } catch {
      // No durable record means the coordinator can never answer; leave the
      // request unclaimed so the guard falls back to its own prompt instead
      // of waiting forever on a channel that does not exist.
      return;
    }
    call.claim = claim;
    appendStatus(
      statusFile,
      statusLine(
        "needs-decision",
        `${KEY_PREFIX}${approvalId}`,
        `fm-worker-approval: ${request.guard ?? "guard"} ${request.severity ?? "unknown"} risk; respond approve|deny; cmd: ${request.command}`,
      ),
    );
    emit(WORKER_APPROVAL_CLAIMED_EVENT, { requestId: request.requestId, approvalId, taskId });
    if (request.signal) {
      if (request.signal.aborted) {
        cancel(claim, "worker turn interrupted before an answer");
        return;
      }
      request.signal.addEventListener("abort", () => cancel(claim, "worker turn interrupted before an answer"), { once: true });
    }
    claim.timer = setInterval(() => checkResponse(claim), pollMs);
    checkResponse(claim);
  };

  const retireUnanswered = (): void => {
    let names: string[];
    try {
      names = readdirSync(approvalsDir);
    } catch {
      return;
    }
    for (const name of names) {
      if (!name.endsWith(".request")) continue;
      const approvalId = name.slice(0, -".request".length);
      if (!/^[0-9a-f]{16}$/.test(approvalId)) continue;
      const closed = ["response", "cancelled", "retired"].some((kind) => existsSync(join(approvalsDir, `${approvalId}.${kind}`)));
      if (closed) continue;
      const header = readHeader(join(approvalsDir, name));
      const requestGen = header?.gen ?? "unknown";
      closeWithRecord(
        { approvalId, requestId: "", gen: requestGen, commandSha256: "", settled: true, timer: undefined },
        "retired",
        `worker incarnation ${requestGen} ended before an answer`,
      );
    }
  };

  const openNativePrompt = (call: PendingCall, kind: string): void => {
    if (call.nativeKey) return;
    const key = `${NATIVE_KEY_PREFIX}${sha256(`${taskId}\n${gen}\n${call.toolCallId}`).slice(0, 8)}`;
    call.nativeKey = key;
    const detail = call.claim
      ? `dialog (${kind}) opened although the coordinator holds this request; press Run/Abort in the pane`
      : `native dialog (${kind}) open in the worker pane; Labmate cannot answer it, press Run/Abort there`;
    appendStatus(statusFile, statusLine("blocked", key, `${detail}; cmd: ${call.command}`));
  };

  const closeNativePrompt = (call: PendingCall, how: string): void => {
    if (!call.nativeKey) return;
    appendStatus(statusFile, statusLine("resolved", call.nativeKey, how));
    call.nativeKey = undefined;
  };

  pi.on("tool_execution_start", (event: any) => {
    if (!event || event.toolName !== "bash" || typeof event.toolCallId !== "string") return;
    const command = typeof event.args?.command === "string" ? event.args.command : "";
    pending.set(event.toolCallId, { toolCallId: event.toolCallId, command, claim: undefined, nativeKey: undefined });
  });

  pi.on("tool_execution_end", (event: any) => {
    if (!event || typeof event.toolCallId !== "string") return;
    const call = pending.get(event.toolCallId);
    if (!call) return;
    pending.delete(event.toolCallId);
    closeNativePrompt(call, "the confirmation dialog closed with the tool call");
    if (call.claim && !call.claim.settled) cancel(call.claim, "guard stopped waiting before an answer");
  });

  pi.on("ui_prompt_start", (event: any) => {
    const kind = typeof event?.kind === "string" ? event.kind : "dialog";
    for (const call of pending.values()) {
      if (call.nativeKey) continue;
      openNativePrompt(call, kind);
      return;
    }
  });

  pi.on("ui_prompt_end", () => {
    for (const call of pending.values()) {
      if (!call.nativeKey) continue;
      closeNativePrompt(call, "the confirmation dialog closed in the pane");
      return;
    }
  });

  pi.on("session_start", () => {
    retireUnanswered();
  });

  pi.on("session_shutdown", () => {
    for (const call of pending.values()) {
      if (call.claim && !call.claim.settled) cancel(call.claim, "worker session shut down before an answer");
    }
  });

  pi.events?.on?.(WORKER_APPROVAL_REQUEST_EVENT, onRequest);
}
