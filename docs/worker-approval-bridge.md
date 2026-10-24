# Worker approval bridge

This document is the authoritative human-readable contract for routing a Pi worker's guard confirmations to the coordinator.
`.pi/extensions/lib/fm-worker-approval.ts` is the worker-side bridge, installed by the per-task extension `bin/fm-spawn.sh` writes for every Pi and pi-signed launch.
`bin/fm-worker-approval.sh` is the coordinator's command surface and the only writer of response records.
`bin/fm-worker-approval-lib.sh` is the single owner of the record layout, record formats, decision key, and binding rule; this page does not restate them.

## Purpose and boundary

Pi has no permission system of its own, and Firstmate launches Pi workers as autonomous interactive sessions.
An operator-installed guard extension can still stop a flagged bash command behind its own Run / Abort dialog, and Pi runs every extension's `tool_call` gate in load order, user-level extensions before the per-task `-e` extension, so the guard's dialog opens in the unattended worker pane before any Firstmate code is reached.
Pi exposes no API for one extension to answer or replace another extension's dialog, so Firstmate cannot take that decision over unilaterally.

The bridge therefore offers the guard a cooperative path: hand the verdict for one command to the coordinator over Pi's shared extension event bus and keep the tool call waiting until that one verdict arrives.
A guard that adopts the contract keeps its own classifier and its own dialog for every launch where no coordinator is present.
A guard that does not adopt it is unchanged; the bridge then only detects the stall and reports it, and it never presses a key in the pane.

The bridge does not decide which commands need permission, adds no bypass or auto-approve posture, and never infers consent from task wording, from silence, or from a response addressed to another request.

## What the bridge records and surfaces

When a cooperative guard asks about a command, the bridge writes the request under `state/<task>.approvals/` with the exact command text, working directory, task id, incarnation gen, Pi tool call id, and the guard's name, severity, and reasons, then appends a keyed status line to `state/<task>.status`:

```text
needs-decision [at=<epoch>] [key=approval-<id>]: fm-worker-approval: <guard> <severity> risk; respond approve|deny; cmd: <command>
```

That line reaches the coordinator through the ordinary wake path and the OPEN DECISIONS fold, so the coordinator sees the exact pending command the moment the worker stops, instead of after the stale timer.
The coordinator reads the full record with `bin/fm-worker-approval.sh show <task> <id>` and answers with `bin/fm-worker-approval.sh respond <task> <id> approve|deny --note '<reason>'`.
The response closes the decision with a `resolved [key=approval-<id>]` line through the home's own self-announced append, so answering does not wake the home a second time.

Approve releases exactly that one tool call once.
Deny makes the guard refuse it.
A request that is already answered, cancelled by an interrupted worker turn or a guard that stopped waiting, retired by a later worker incarnation, addressed to another task, or bound to a superseded incarnation is refused and nothing is written.
The bridge re-checks the response's request id, task, gen, and command digest before releasing, and treats any record that does not bind as a refusal, so neither side relies on the other's check.
A later or different command always opens its own request; one approval never carries over.

## Cooperative contract for guard authors

A guard speaks the contract from its `tool_call` handler through `pi.events`, before it would open its own dialog:

1. Emit `firstmate:worker-approval-request` with `{ requestId, toolCallId, toolName: "bash", command, cwd, guard, severity, reasons, signal }`.
   `requestId` is the guard's own token, one to sixty-four characters from `A-Z a-z 0-9 . _ -`; `toolCallId`, `command`, and `cwd` come from the event and context Pi handed the handler; `signal` is `ctx.signal` so an interrupted turn cancels the request.
2. Wait a short grace, about 250 ms, for `firstmate:worker-approval-claimed` carrying the same `requestId`.
   The bridge claims synchronously inside the request emit when a bridge is loaded and the request names the exact bash tool call Pi announced through `tool_execution_start` with an identical command.
3. Without a claim, proceed exactly as the guard does today; a missing coordinator is never consent and never a block the guard did not choose itself.
4. With a claim, wait for `firstmate:worker-approval-response` carrying the same `requestId` and read its `verdict`: `run` means execute this one command, anything else means refuse it.
   Silence is never `run`; a guard that chooses to stop waiting must refuse the command, and the bridge records that as a cancelled request.

The three channel names and payload fields above are stable public API.
The bridge ignores a request whose shape it cannot verify or whose tool call Pi has not announced, which leaves the guard on its standalone path.

## Detection without a cooperative guard

Pi emits `ui_prompt_start` and `ui_prompt_end` to every extension when any extension opens a blocking dialog, and `tool_execution_start` precedes every `tool_call` gate.
When a dialog opens while a bash tool call is pending and no request was claimed, the bridge appends:

```text
blocked [at=<epoch>] [key=native-prompt-<hash>]: native dialog (<kind>) open in the worker pane; Labmate cannot answer it, press Run/Abort there; cmd: <command>
```

and closes that key with a `resolved` line when the dialog closes or the tool call ends.
This is detection only: the coordinator learns which command is waiting and that the pane needs a keypress, and the worker stays stopped until a person answers in the pane.
Firstmate's key plane carries only Enter, Escape, and C-c, and an Enter cannot be bound to one pending command, so the bridge never offers an approval control for a dialog it cannot answer.

## Verification

[`verification/runtime-backends.md`](verification/runtime-backends.md#pi-worker-approval-bridge) records the deterministic evidence: `tests/fm-worker-approval.test.sh` runs the real spawn, the generated extension, the real coordinator command, the real incarnation writer, the real decision fold, and the real wake drain in a plain Node host next to a fixture guard that speaks this contract.
No shipped guard adopts the contract yet, so native coverage of a real guard remains unverified until one does.
