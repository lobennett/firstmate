#!/usr/bin/env bash
# Behavior tests for the Pi worker approval bridge (docs/worker-approval-bridge.md).
#
# Each case runs the REAL bin/fm-spawn.sh against a fake tmux pane and an
# isolated git worktree to obtain the per-task Pi extension it writes, then
# drives that generated extension in a plain Node host next to a FIXTURE
# GUARD that speaks the documented cooperative bus contract (or a fixture
# guard that only opens its own dialog). The real bin/fm-worker-approval.sh,
# the real bin/fm-busy-event.sh incarnation writer, the real decision fold, and
# the real wake drain are exercised together with no live Pi session.
# Nothing here asserts implementation-source bytes: the assertions read the
# durable records the contract names, the status log, and command output.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-worker-approval-lib.sh"

export NODE_NO_WARNINGS=1
APPROVAL="$ROOT/bin/fm-worker-approval.sh"
BUSY_EVENT="$ROOT/bin/fm-busy-event.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-approval)
DRIVER="$TMP_ROOT/driver.mjs"

# The Node host: a fake Pi runtime with the real event-bus semantics (handlers
# wrapped async, emit synchronous), the generated per-task extension, and a
# fixture guard. Modes are selected through MODE; the shell side coordinates
# through marker files so each case asserts the public records at the moment
# the worker is actually holding the command.
cat > "$DRIVER" <<'EOF'
import { EventEmitter } from "node:events";
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mode = process.env.MODE;
const summary = { executed: 0, nativePrompt: false, claims: [], responses: [], blocks: [] };
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const waitForFile = async (path, ms = 20000) => {
  const until = Date.now() + ms;
  while (!existsSync(path)) {
    if (Date.now() > until) throw new Error(`timed out waiting for ${path}`);
    await sleep(25);
  }
};

const emitter = new EventEmitter();
const events = {
  emit: (channel, data) => { emitter.emit(channel, data); },
  on: (channel, handler) => {
    const safe = async (data) => { try { await handler(data); } catch (err) { console.error(err); } };
    emitter.on(channel, safe);
    return () => emitter.off(channel, safe);
  },
};
const handlers = {};
const pi = {
  on: (name, fn) => { (handlers[name] ||= []).push(fn); },
  events,
  registerFlag() {}, registerCommand() {}, getFlag() { return false; },
};
const emitPi = async (type, event, ctx) => {
  for (const fn of handlers[type] ?? []) await fn(event, ctx);
};
const controller = new AbortController();
const ctx = { cwd: process.env.WORK_CWD, signal: controller.signal, hasUI: true, mode: "tui" };

if (process.env.LOAD_EXT === "1") {
  const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
  mod.default(pi);
}

let claimCount = 0;
function cooperativeGuard() {
  pi.on("tool_call", async (event, c) => {
    if (event.toolName !== "bash") return;
    const requestId = `fixture-${event.toolCallId}`;
    let claimed = null;
    const offClaim = events.on("firstmate:worker-approval-claimed", (d) => { if (d?.requestId === requestId) claimed = d; });
    const response = new Promise((resolve) => {
      const off = events.on("firstmate:worker-approval-response", (d) => { if (d?.requestId === requestId) { off(); resolve(d); } });
    });
    events.emit("firstmate:worker-approval-request", {
      requestId, toolCallId: event.toolCallId, toolName: "bash", command: event.input.command, cwd: c.cwd,
      guard: "fixture-guard", severity: "medium", reasons: ["fixture reason one", "fixture reason two"], signal: c.signal,
    });
    await sleep(Number(process.env.GRACE_MS ?? 250));
    offClaim();
    if (!claimed) {
      summary.nativePrompt = true;
      return { block: true, reason: "fixture native prompt: no coordinator claimed the request" };
    }
    claimCount += 1;
    summary.claims.push(claimed);
    writeFileSync(`${process.env.CLAIM_MARKER}.${claimCount}`, JSON.stringify(claimed));
    if (mode === "exit-after-claim") process.exit(0);
    if (mode === "cancel") setTimeout(() => controller.abort(), 100);
    const release = process.env.RELEASE_MARKER
      ? waitForFile(process.env.RELEASE_MARKER, 60000).then(() => ({ verdict: "abort", reason: "fixture guard stopped waiting" }))
      : new Promise(() => {});
    const verdict = await Promise.race([response, release]);
    summary.responses.push(verdict);
    if (verdict.verdict === "run") return undefined;
    return { block: true, reason: verdict.reason };
  });
}
function nativeGuard() {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;
    await emitPi("ui_prompt_start", { type: "ui_prompt_start", reason: "ui_prompt", kind: "custom" });
    writeFileSync(`${process.env.CLAIM_MARKER}.prompt`, "open");
    await waitForFile(process.env.RELEASE_MARKER);
    await emitPi("ui_prompt_end", { type: "ui_prompt_end", reason: "ui_prompt", kind: "custom" });
    return undefined;
  });
}

async function runBashCall(toolCallId, command) {
  await emitPi("tool_execution_start", { type: "tool_execution_start", toolCallId, toolName: "bash", args: { command } });
  let gate;
  for (const fn of handlers.tool_call ?? []) {
    const r = await fn({ type: "tool_call", toolCallId, toolName: "bash", input: { command } }, ctx);
    if (r?.block) { gate = r; break; }
  }
  if (!gate) summary.executed += 1; else summary.blocks.push(gate.reason);
  await emitPi("tool_execution_end", { type: "tool_execution_end", toolCallId, toolName: "bash", result: {}, isError: Boolean(gate) });
}

switch (mode) {
  case "approve": case "deny": case "invalid-response": case "stale": case "cancel": case "exit-after-claim":
    cooperativeGuard();
    await runBashCall("call-1", process.env.COMMAND);
    if (mode === "approve") await runBashCall("call-2", `${process.env.COMMAND}\n# second call`);
    break;
  case "unavailable":
    cooperativeGuard();
    await runBashCall("call-1", process.env.COMMAND);
    break;
  case "detect":
    nativeGuard();
    await runBashCall("call-1", process.env.COMMAND);
    break;
  case "session-start":
    await emitPi("session_start", { type: "session_start", reason: "startup" });
    break;
  default:
    throw new Error(`unknown mode ${mode}`);
}
console.log(JSON.stringify(summary));
EOF

make_case() {  # <name> <id> -> record "case|home|proj|wt|fakebin"
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" pi)
  fm_test_spawn_home "$home" pi
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case() {
  # shellcheck disable=SC2034 # the record shape is shared with the other spawn suites
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

spawn_pi_worker() {  # <rec> <id>
  local out
  read_case "$1"
  out=$(GROK_HOME="$HOME_DIR/grok-home" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$2" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 $? "pi spawn should succeed: $out"
  STATE_DIR="$HOME_DIR/state"
  EXT="$STATE_DIR/$2.pi-ext.ts"
  assert_present "$EXT" "pi spawn did not write the per-task extension"
  GEN=$(fm_busy_current_gen "$STATE_DIR" "$2") || fail "spawn did not arm a busy incarnation"
}

COMMAND=$'printf \'%s\\n\' "working [at=1]: step" >> status.log\nls -la | head -3'

start_driver() {  # <mode> <load-ext 0|1> <case-dir> <extra env...>
  local mode=$1 load=$2 case_dir=$3
  shift 3
  CLAIM_MARKER="$case_dir/claim"
  RELEASE_MARKER="$case_dir/release"
  DRIVER_OUT="$case_dir/driver.out"
  rm -f "$CLAIM_MARKER".* "$RELEASE_MARKER" "$DRIVER_OUT"
  env MODE="$mode" LOAD_EXT="$load" EXT_PATH="$EXT" WORK_CWD="$WT_DIR" COMMAND="$COMMAND" \
    CLAIM_MARKER="$CLAIM_MARKER" RELEASE_MARKER="$RELEASE_MARKER" FM_WORKER_APPROVAL_POLL_MS=50 "$@" \
    node "$DRIVER" > "$DRIVER_OUT" 2>&1 &
  DRIVER_PID=$!
}

wait_file() {  # <path> <label>
  local i=0
  while [ ! -e "$1" ]; do
    i=$((i + 1))
    [ "$i" -lt 400 ] || fail "timed out waiting for $2 ($1)"
    sleep 0.05
  done
}

finish_driver() {
  wait "$DRIVER_PID" || fail "driver exited nonzero: $(cat "$DRIVER_OUT")"
  SUMMARY=$(tail -1 "$DRIVER_OUT")
}

summary_field() {  # <json-path-expr>
  node -e 'const s = JSON.parse(process.argv[1]); console.log(JSON.stringify(eval("s" + process.argv[2])));' "$SUMMARY" "$1"
}

claimed_approval_id() {  # <claim-marker-file>
  node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).approvalId)' "$1"
}

open_keys() {  # <status-file>
  status_open_decisions "$1" | cut -f1
}

# assert_status_note <status-file> <key> <note-prefix> <msg>: a status line
# carries both the key tag and the note, wherever the emission stamp sits.
assert_status_note() {
  grep -F -- "[key=$2]" "$1" | grep -F -- ": $3" >/dev/null || fail "$4"
}

test_approve_releases_exactly_that_call_once() {
  local rec id=wa-approve approval dir out status second
  rec=$(make_case approve "$id")
  spawn_pi_worker "$rec" "$id"
  start_driver approve 1 "$CASE_DIR"
  wait_file "$CLAIM_MARKER.1" "the guard's first claim"
  approval=$(claimed_approval_id "$CLAIM_MARKER.1")
  dir=$(fm_worker_approval_dir "$STATE_DIR" "$id")

  assert_present "$dir/$approval.request" "the bridge did not record the request durably"
  assert_equals "$id" "$(fm_worker_approval_field "$dir/$approval.request" task)" "request task binding"
  assert_equals "$GEN" "$(fm_worker_approval_field "$dir/$approval.request" gen)" "request incarnation binding"
  assert_equals bash "$(fm_worker_approval_field "$dir/$approval.request" tool)" "request tool"
  assert_equals "$WT_DIR" "$(fm_worker_approval_field "$dir/$approval.request" cwd)" "request working directory"
  assert_equals "fixture-guard" "$(fm_worker_approval_field "$dir/$approval.request" guard)" "request guard name"
  assert_equals "fixture reason one; fixture reason two" "$(fm_worker_approval_field "$dir/$approval.request" reasons)" "request reasons"
  assert_equals "$COMMAND" "$(fm_worker_approval_body "$dir/$approval.request")" "the exact multi-line command is the request body"
  assert_equals "$(printf '%s' "$COMMAND" | fm_worker_approval_sha256)" "$(fm_worker_approval_field "$dir/$approval.request" command_sha256)" "command digest"

  status="$STATE_DIR/$id.status"
  assert_grep "needs-decision [at=" "$status" "the request did not open a stamped needs-decision"
  assert_grep "[key=approval-$approval]" "$status" "the needs-decision is not keyed by the approval id"
  assert_grep "fm-worker-approval: fixture-guard medium risk; respond approve|deny; cmd: printf" "$status" "the needs-decision does not name the responder and the command"
  assert_equals "approval-$approval" "$(open_keys "$status")" "the decision fold does not list the request as open"
  kill -0 "$DRIVER_PID" 2>/dev/null || fail "driver finished before the coordinator answered: $(cat "$DRIVER_OUT")"

  out=$(FM_HOME="$HOME_DIR" "$APPROVAL" list) || fail "list failed: $out"
  assert_contains "$out" "$id	$approval	pending	medium	" "list does not show the pending request"
  out=$(FM_HOME="$HOME_DIR" "$APPROVAL" show "$id" "$approval") || fail "show failed: $out"
  assert_contains "$out" "cwd=$WT_DIR" "show omits the working directory"
  assert_contains "$out" 'ls -la | head -3' "show omits the second command line"
  assert_contains "$out" "state=pending" "show does not report the pending state"

  out=$(FM_STATE_OVERRIDE="$STATE_DIR" "$DRAIN" 2>&1) || fail "wake drain failed: $out"
  assert_contains "$out" "OPEN DECISIONS" "the drain does not surface the open approval"
  assert_contains "$out" "[key=approval-$approval]" "the drain entry lacks the approval key"

  out=$(FM_HOME="$HOME_DIR" "$APPROVAL" respond "$id" "$approval" approve --note "brief-mandated status append") || fail "respond approve failed: $out"
  assert_equals "approve $id $approval" "$out" "respond approve output"
  assert_present "$dir/$approval.response" "respond did not write the response record"
  assert_equals approve "$(fm_worker_approval_field "$dir/$approval.response" verdict)" "response verdict"
  assert_equals "$GEN" "$(fm_worker_approval_field "$dir/$approval.response" gen)" "response echoes the incarnation"
  assert_grep "resolved [key=approval-$approval] [at=" "$status" "respond did not append a stamped close"
  assert_status_note "$status" "approval-$approval" "approved: brief-mandated status append" "the close line does not carry the verdict and note"
  assert_equals "" "$(open_keys "$status" | grep -F "approval-$approval" || true)" "the approval decision is still open after respond"

  out=$(FM_HOME="$HOME_DIR" "$APPROVAL" respond "$id" "$approval" approve 2>&1)
  expect_code 1 $? "a second answer to the same request must be refused"
  assert_contains "$out" "already approved" "duplicate answer refusal reason"

  # The second call carries a different command: it opens its own request and
  # the first approval must not release it.
  wait_file "$CLAIM_MARKER.2" "the guard's second claim"
  second=$(claimed_approval_id "$CLAIM_MARKER.2")
  [ "$second" != "$approval" ] || fail "two different commands received the same approval id"
  assert_present "$dir/$second.request" "the second command did not open its own request"
  assert_equals "approval-$second" "$(open_keys "$status")" "only the second request should be open now"
  : > "$RELEASE_MARKER"
  finish_driver
  assert_equals 1 "$(summary_field .executed)" "exactly one command must execute after exactly one approval"
  assert_equals '"run"' "$(summary_field '.responses[0].verdict')" "the guard did not receive run for the approved call"
  assert_equals '"abort"' "$(summary_field '.responses[1].verdict')" "the unanswered second call must end in abort"
  assert_equals cancelled "$(fm_worker_approval_state "$dir" "$second")" "a request the guard stopped waiting on must be recorded cancelled"
  assert_status_note "$status" "approval-$second" "cancelled: guard stopped waiting before an answer" "the cancelled request did not close its decision"
  out=$(FM_HOME="$HOME_DIR" "$APPROVAL" respond "$id" "$second" approve 2>&1)
  expect_code 1 $? "answering a cancelled request must be refused"
  assert_contains "$out" "was cancelled before an answer" "cancelled refusal reason"
  pass "approve releases exactly its own call once; a duplicate answer, a later command, and a cancelled request are refused"
}

test_deny_refuses_the_call() {
  local rec id=wa-deny approval dir out
  rec=$(make_case deny "$id")
  spawn_pi_worker "$rec" "$id"
  start_driver deny 1 "$CASE_DIR"
  wait_file "$CLAIM_MARKER.1" "the guard's claim"
  approval=$(claimed_approval_id "$CLAIM_MARKER.1")
  dir=$(fm_worker_approval_dir "$STATE_DIR" "$id")
  out=$(FM_HOME="$HOME_DIR" "$APPROVAL" respond "$id" "$approval" deny --note "not on this branch") || fail "respond deny failed: $out"
  finish_driver
  assert_equals 0 "$(summary_field .executed)" "a denied command must not execute"
  assert_equals '"abort"' "$(summary_field '.responses[0].verdict')" "the guard did not receive abort on deny"
  assert_contains "$(summary_field '.blocks[0]')" "denied by the coordinator: not on this branch" "the guard's block reason does not carry the denial"
  assert_equals denied "$(fm_worker_approval_state "$dir" "$approval")" "state after deny"
  assert_status_note "$STATE_DIR/$id.status" "approval-$approval" "denied: not on this branch" "deny did not close the decision"
  # No worker write follows this close, so the coordinator's append is provably
  # its own and must be recorded as such rather than waking the home again.
  assert_present "$STATE_DIR/.$id.home-appends" "the close was not recorded as this home's own append"
  pass "deny makes the guard refuse the command and closes the decision"
}

test_unbound_response_record_is_refused_by_the_bridge() {
  local rec id=wa-invalid approval dir out
  rec=$(make_case invalid "$id")
  spawn_pi_worker "$rec" "$id"
  start_driver invalid-response 1 "$CASE_DIR"
  wait_file "$CLAIM_MARKER.1" "the guard's claim"
  approval=$(claimed_approval_id "$CLAIM_MARKER.1")
  dir=$(fm_worker_approval_dir "$STATE_DIR" "$id")
  # A response that names the request but carries another command's digest is
  # exactly what a mis-addressed or forged answer looks like.
  printf 'schema=fm-worker-approval.v1\nrequest=%s\ntask=%s\ngen=%s\nverdict=approve\ncommand_sha256=%s\ndecided_at=1\nnote=forged\n--\n' \
    "$approval" "$id" "$GEN" "$(printf 'rm -rf /' | fm_worker_approval_sha256)" > "$dir/$approval.response"
  finish_driver
  assert_equals 0 "$(summary_field .executed)" "an unbound approval record must not release the command"
  assert_equals '"abort"' "$(summary_field '.responses[0].verdict')" "the bridge did not abort on an unbound record"
  assert_grep "ignored a worker approval response that does not bind to request $approval" "$STATE_DIR/$id.status" "the bridge did not record the refused record"
  out=$(FM_HOME="$HOME_DIR" "$APPROVAL" respond "$id" "$approval" approve 2>&1)
  expect_code 1 $? "the coordinator must not answer over an existing response record"
  pass "a response record whose digest does not match the pending command is refused by the bridge"
}

test_stale_incarnation_and_cross_task_answers_are_refused() {
  local rec id=wa-stale approval dir out other_dir
  rec=$(make_case stale "$id")
  spawn_pi_worker "$rec" "$id"
  start_driver stale 1 "$CASE_DIR"
  wait_file "$CLAIM_MARKER.1" "the guard's claim"
  approval=$(claimed_approval_id "$CLAIM_MARKER.1")
  dir=$(fm_worker_approval_dir "$STATE_DIR" "$id")

  # Cross-task: another recorded task that happens to hold a copy of the record.
  fm_write_meta "$STATE_DIR/wa-other.meta" "kind=crewmate" "harness=pi" "worktree=$WT_DIR"
  other_dir=$(fm_worker_approval_dir "$STATE_DIR" wa-other)
  mkdir -p "$other_dir"
  cp "$dir/$approval.request" "$other_dir/$approval.request"
  out=$(FM_HOME="$HOME_DIR" "$APPROVAL" respond wa-other "$approval" approve 2>&1)
  expect_code 1 $? "an answer addressed to another task must be refused"
  assert_contains "$out" "names task $id, not wa-other" "cross-task refusal reason"
  assert_absent "$other_dir/$approval.response" "a cross-task refusal must write nothing"
  out=$(FM_HOME="$HOME_DIR" "$APPROVAL" respond wa-unknown "$approval" approve 2>&1)
  expect_code 1 $? "an answer for a task this home never recorded must be refused"
  assert_contains "$out" "not recorded in this home" "unknown-task refusal reason"

  # Stale: the worker was relaunched, so a new incarnation is armed.
  "$BUSY_EVENT" arm "$STATE_DIR" "$id" >/dev/null || fail "could not re-arm the incarnation"
  out=$(FM_HOME="$HOME_DIR" "$APPROVAL" respond "$id" "$approval" approve 2>&1)
  expect_code 1 $? "an answer for a superseded incarnation must be refused"
  assert_contains "$out" "belongs to worker incarnation $GEN but the task's current incarnation is" "stale refusal reason"
  assert_absent "$dir/$approval.response" "a stale refusal must write nothing"
  assert_equals "approval-$approval" "$(open_keys "$STATE_DIR/$id.status")" "the refused request must stay open, not silently closed"

  : > "$RELEASE_MARKER"
  finish_driver
  assert_equals 0 "$(summary_field .executed)" "no command may run without its own approval"
  pass "stale-incarnation and cross-task answers are refused and write nothing"
}

test_interrupted_turn_cancels_the_request() {
  local rec id=wa-cancel approval dir out
  rec=$(make_case cancel "$id")
  spawn_pi_worker "$rec" "$id"
  start_driver cancel 1 "$CASE_DIR"
  wait_file "$CLAIM_MARKER.1" "the guard's claim"
  approval=$(claimed_approval_id "$CLAIM_MARKER.1")
  dir=$(fm_worker_approval_dir "$STATE_DIR" "$id")
  finish_driver
  assert_equals 0 "$(summary_field .executed)" "an interrupted call must not execute"
  assert_equals '"abort"' "$(summary_field '.responses[0].verdict')" "the guard did not receive abort on interrupt"
  assert_equals cancelled "$(fm_worker_approval_state "$dir" "$approval")" "state after interrupt"
  assert_status_note "$STATE_DIR/$id.status" "approval-$approval" "cancelled: worker turn interrupted before an answer" "the interrupt did not close the decision"
  out=$(FM_HOME="$HOME_DIR" "$APPROVAL" respond "$id" "$approval" approve 2>&1)
  expect_code 1 $? "a cancelled request must not accept an answer"
  pass "an interrupted worker turn cancels its pending request and refuses a late answer"
}

test_restart_retires_unanswered_requests() {
  local rec id=wa-retire approval dir out
  rec=$(make_case retire "$id")
  spawn_pi_worker "$rec" "$id"
  start_driver exit-after-claim 1 "$CASE_DIR"
  wait_file "$CLAIM_MARKER.1" "the guard's claim"
  approval=$(claimed_approval_id "$CLAIM_MARKER.1")
  wait "$DRIVER_PID" 2>/dev/null || true
  dir=$(fm_worker_approval_dir "$STATE_DIR" "$id")
  assert_equals pending "$(fm_worker_approval_state "$dir" "$approval")" "a dead incarnation leaves its request pending"
  assert_equals "approval-$approval" "$(open_keys "$STATE_DIR/$id.status")" "the dead incarnation's decision is open"

  start_driver session-start 1 "$CASE_DIR"
  finish_driver
  assert_equals retired "$(fm_worker_approval_state "$dir" "$approval")" "a new incarnation did not retire the unanswered request"
  assert_status_note "$STATE_DIR/$id.status" "approval-$approval" "retired: worker incarnation $GEN ended before an answer" "retirement did not close the decision"
  assert_equals "" "$(open_keys "$STATE_DIR/$id.status")" "a retired request must not stay open"
  out=$(FM_HOME="$HOME_DIR" "$APPROVAL" respond "$id" "$approval" approve 2>&1)
  expect_code 1 $? "a retired request must not accept an answer"
  assert_contains "$out" "was retired before an answer" "retired refusal reason"
  pass "a worker restart retires requests nobody answered and refuses late answers"
}

test_no_bridge_leaves_the_guard_standalone() {
  local rec id=wa-standalone dir
  rec=$(make_case standalone "$id")
  spawn_pi_worker "$rec" "$id"
  start_driver unavailable 0 "$CASE_DIR"
  finish_driver
  assert_equals true "$(summary_field .nativePrompt)" "without a bridge the guard must keep its own prompt path"
  assert_equals 0 "$(summary_field .executed)" "silence must never release a command"
  dir=$(fm_worker_approval_dir "$STATE_DIR" "$id")
  assert_absent "$dir" "no bridge means no approval records"
  pass "a guard with no coordinator present keeps its standalone behavior and nothing is approved"
}

test_native_prompt_is_detected_and_closed() {
  local rec id=wa-detect status key dir
  rec=$(make_case detect "$id")
  spawn_pi_worker "$rec" "$id"
  start_driver detect 1 "$CASE_DIR"
  wait_file "$CLAIM_MARKER.prompt" "the native prompt to open"
  status="$STATE_DIR/$id.status"
  sleep 0.1
  key=$(open_keys "$status")
  case "$key" in
    native-prompt-????????) ;;
    *) fail "a native prompt did not open a keyed native-prompt blocker (open keys: '$key')" ;;
  esac
  assert_grep "blocked [at=" "$status" "the native prompt did not open a stamped blocker"
  assert_grep "native dialog (custom) open in the worker pane; Labmate cannot answer it, press Run/Abort there; cmd: printf" "$status" "the blocker does not say honestly that it cannot answer"
  : > "$RELEASE_MARKER"
  finish_driver
  assert_equals 1 "$(summary_field .executed)" "the pane keypress path must still run the command the guard allowed"
  assert_equals "" "$(open_keys "$status")" "the native-prompt blocker did not close when the dialog closed"
  assert_status_note "$status" "$key" "the confirmation dialog closed in the pane" "the blocker close line is missing"
  dir=$(fm_worker_approval_dir "$STATE_DIR" "$id")
  assert_absent "$dir" "detection must not fabricate approval records"
  pass "a native confirmation is surfaced as a keyed blocker while open and closed when the dialog closes"
}

test_approve_releases_exactly_that_call_once
test_deny_refuses_the_call
test_unbound_response_record_is_refused_by_the_bridge
test_stale_incarnation_and_cross_task_answers_are_refused
test_interrupted_turn_cancels_the_request
test_restart_retires_unanswered_requests
test_no_bridge_leaves_the_guard_standalone
test_native_prompt_is_detected_and_closed

echo "all fm-worker-approval tests passed"
