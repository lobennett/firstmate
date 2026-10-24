#!/usr/bin/env bash
# fm-worker-approval.sh - the coordinator's command surface for worker approval
# requests: list what Pi workers are waiting on, show one request in full, and
# answer exactly one request with a response bound to it.
#
# Usage:
#   fm-worker-approval.sh list [<task-id>]
#       One line per request in this home (or in one task):
#       <task>\t<approval-id>\t<state>\t<severity>\t<age>s\t<command display>
#       state is pending, approved, denied, cancelled, retired, or invalid.
#   fm-worker-approval.sh show <task-id> <approval-id>
#       Print the request's header fields and the exact command text, then the
#       current state.
#   fm-worker-approval.sh respond <task-id> <approval-id> approve|deny [--note <text>]
#       Write the response record for that one request and close its keyed
#       decision in state/<task>.status. Exit 0 when written; exit 1 and write
#       nothing when the request is not pending (already answered, cancelled,
#       or retired), names another task, belongs to a superseded worker
#       incarnation, or cannot be read; exit 2 on usage.
#
# What a response does (docs/worker-approval-bridge.md): the worker's bridge
# releases the one tool call it holds only on approve, and tells its guard
# "abort" on deny; it never runs a later or different command on either answer,
# and it re-checks the record's binding before releasing, so an answer written
# here can never reach a command the worker is not holding right now.
#
# Who may approve: an approval is a decision about running one command inside
# a task whose authority is already fixed by its brief and the project's
# registered posture. A request whose command plainly lies inside that
# authorized work - the brief's own status appends, a redirected validation
# drive call, a listing pipeline, committing on the task's branch - is the
# coordinator's to approve. A destructive, irreversible, or security-sensitive
# command, or one outside the authorized scope, is the captain's call: ask it
# in the primary conversation first, one decision at a time, and record the
# captain's word as the --note. Never approve on general task wording alone,
# and never answer a request you did not read with show.
#
# Record format, directory layout, decision key, and the binding rule are owned
# by bin/fm-worker-approval-lib.sh. The close line is this home's own
# bookkeeping, so it is appended through fm_wake_status_append_self_announced
# (bin/fm-wake-lib.sh) exactly as fm-send --resolve-key appends its close.
# Answering a worker approval is main-owned while attended, like every other
# decision answer: the supervision branch is refused unless the away-posture
# record relocates main's authority to it (bin/fm-lease-lib.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# shellcheck source=bin/fm-worker-approval-lib.sh
. "$SCRIPT_DIR/fm-worker-approval-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  fm-worker-approval.sh list [<task-id>]
  fm-worker-approval.sh show <task-id> <approval-id>
  fm-worker-approval.sh respond <task-id> <approval-id> approve|deny [--note <text>]
See the header comment for the full contract.
EOF
  exit 2
}

refuse() {
  printf 'fm-worker-approval: %s\n' "$*" >&2
  exit 1
}

task_id_valid() {  # <task-id>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

request_age() {  # <request-record>
  local at now
  at=$(fm_worker_approval_field "$1" requested_at 2>/dev/null) || at=
  now=$(date +%s)
  case "$at" in ''|*[!0-9]*) printf '?'; return 0 ;; esac
  printf '%s' $((now - at))
}

list_task() {  # <task-id>
  local task=$1 dir f id state severity age display
  dir=$(fm_worker_approval_dir "$STATE" "$task")
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.request; do
    [ -e "$f" ] || continue
    id=${f##*/}
    id=${id%.request}
    fm_worker_approval_id_valid "$id" || continue
    state=$(fm_worker_approval_state "$dir" "$id")
    severity=$(fm_worker_approval_field "$f" severity 2>/dev/null) || severity=unknown
    age=$(request_age "$f")
    display=$(fm_worker_approval_display "$(fm_worker_approval_body "$f" 2>/dev/null)" 100)
    printf '%s\t%s\t%s\t%s\t%ss\t%s\n' "$task" "$id" "$state" "$severity" "$age" "$display"
  done
}

cmd_list() {
  local task d
  if [ -n "${1:-}" ]; then
    task_id_valid "$1" || refuse "invalid task id: $1"
    list_task "$1"
    return 0
  fi
  for d in "$STATE"/*.approvals; do
    [ -d "$d" ] || continue
    task=${d##*/}
    task=${task%.approvals}
    task_id_valid "$task" || continue
    list_task "$task"
  done
}

cmd_show() {
  local task=$1 id=$2 dir f state
  task_id_valid "$task" || refuse "invalid task id: $task"
  fm_worker_approval_id_valid "$id" || refuse "invalid approval id: $id (16 lowercase hex characters)"
  dir=$(fm_worker_approval_dir "$STATE" "$task")
  f="$dir/$id.request"
  [ -f "$f" ] || refuse "no request $id recorded for task $task"
  fm_worker_approval_request_valid "$f" || refuse "request $id for task $task is not a readable fm-worker-approval record"
  fm_worker_approval_header "$f"
  printf -- '--\n'
  fm_worker_approval_body "$f"
  printf '\n--\n'
  state=$(fm_worker_approval_state "$dir" "$id")
  printf 'state=%s\n' "$state"
  case "$state" in
    approved|denied) fm_worker_approval_header "$dir/$id.response" | sed -n 's/^\(decided_at\|note\)=/response_\1=/p' ;;
    cancelled|retired) fm_worker_approval_header "$dir/$id.$state" | sed -n 's/^reason=/'"$state"'_reason=/p' ;;
  esac
}

cmd_respond() {
  local task=$1 id=$2 verdict=$3 note='' dir f state request_task request_gen current_gen digest
  shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --note)
        [ "$#" -ge 2 ] || usage
        note=$2
        shift 2
        ;;
      --note=*)
        note=${1#--note=}
        shift
        ;;
      *) usage ;;
    esac
  done
  task_id_valid "$task" || refuse "invalid task id: $task"
  fm_worker_approval_id_valid "$id" || refuse "invalid approval id: $id (16 lowercase hex characters)"
  case "$verdict" in approve|deny) ;; *) usage ;; esac
  note=$(printf '%s' "$note" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')

  [ -f "$STATE/$task.meta" ] || refuse "task $task is not recorded in this home ($STATE/$task.meta is missing); a worker approval can only be answered by the home that launched the worker"
  dir=$(fm_worker_approval_dir "$STATE" "$task")
  f="$dir/$id.request"
  [ -f "$f" ] || refuse "no request $id recorded for task $task; run: fm-worker-approval.sh list $task"
  fm_worker_approval_request_valid "$f" || refuse "request $id for task $task is not a readable fm-worker-approval record; nothing written"
  request_task=$(fm_worker_approval_field "$f" task)
  [ "$request_task" = "$task" ] || refuse "request $id names task $request_task, not $task; a response never crosses tasks, nothing written"
  state=$(fm_worker_approval_state "$dir" "$id")
  case "$state" in
    pending) ;;
    approved|denied) refuse "request $id was already $state at $(fm_worker_approval_field "$dir/$id.response" decided_at 2>/dev/null || echo '?'); a request is answered once, nothing written" ;;
    cancelled|retired) refuse "request $id was $state before an answer ($(fm_worker_approval_field "$dir/$id.$state" reason 2>/dev/null || echo 'no reason recorded')); the worker is no longer holding that command, nothing written" ;;
    *) refuse "request $id is in state $state; nothing written" ;;
  esac
  request_gen=$(fm_worker_approval_field "$f" gen)
  current_gen=$(fm_busy_current_gen "$STATE" "$task") || refuse "task $task has no armed worker incarnation (its busy contract is not armed or the task is retired); the request from incarnation $request_gen is stale, nothing written"
  [ "$request_gen" = "$current_gen" ] || refuse "request $id belongs to worker incarnation $request_gen but the task's current incarnation is $current_gen; a relaunched worker is not holding that command, nothing written"
  digest=$(fm_worker_approval_field "$f" command_sha256)
  [ "$(fm_worker_approval_body "$f" | fm_worker_approval_sha256)" = "$digest" ] || refuse "request $id's recorded command no longer matches its digest; nothing written"

  # A worker approval is a decision answer: main-owned while attended, the
  # same partition fm-send --resolve-key applies (bin/fm-lease-lib.sh).
  fm_lease_forbid_branch "worker approval answer (fm-worker-approval respond)" --away-relocated

  local tmp close_max close_line key
  key=$(fm_worker_approval_key "$id")
  close_max=$((FM_LINE_CAP_DEFAULT - $(status_stamp_width)))
  [ "$close_max" -ge 0 ] || close_max=0
  case "$verdict" in
    approve) fm_cap_line_var "resolved [key=$key]: approved: ${note:-coordinator approved this one command}" "$close_max" ;;
    deny) fm_cap_line_var "resolved [key=$key]: denied: ${note:-coordinator refused this command}" "$close_max" ;;
  esac
  close_line=$FM_LINE_CAP_LINE
  if [ "$(status_line_verb "$close_line")" != resolved ] || [ "$(_fm_decision_key "$close_line" 2>/dev/null)" != "$key" ]; then
    refuse "the close record for $key would not survive the status-line cap; nothing written"
  fi

  tmp="$dir/$id.response.tmp-$$"
  {
    printf 'schema=%s\n' "$FM_WORKER_APPROVAL_SCHEMA"
    printf 'request=%s\n' "$id"
    printf 'task=%s\n' "$task"
    printf 'gen=%s\n' "$request_gen"
    printf 'verdict=%s\n' "$verdict"
    printf 'command_sha256=%s\n' "$digest"
    printf 'decided_at=%s\n' "$(date +%s)"
    printf 'note=%s\n' "$note"
    printf -- '--\n'
  } > "$tmp" || { rm -f "$tmp"; refuse "could not write the response record under $dir"; }
  # The response is the binding artifact; it must not appear unless the request
  # is still pending at this instant, so re-check right before the rename.
  if [ -e "$dir/$id.response" ] || [ -e "$dir/$id.cancelled" ] || [ -e "$dir/$id.retired" ]; then
    rm -f "$tmp"
    refuse "request $id was closed concurrently; nothing written"
  fi
  mv "$tmp" "$dir/$id.response" || { rm -f "$tmp"; refuse "could not publish the response record under $dir"; }
  if [ -e "$dir/$id.cancelled" ] || [ -e "$dir/$id.retired" ]; then
    refuse "request $id was closed concurrently; the worker keeps the command refused and the response does not apply"
  fi

  local append_rc=0
  fm_wake_status_append_self_announced "$STATE" "$STATE/$task.status" "$close_line" || append_rc=$?
  if [ "$append_rc" -eq 2 ]; then
    printf 'fm-worker-approval: response %s written for %s (%s), but its close could not be appended to %s; close it by hand with: printf '"'"'%%s\\n'"'"' %q >> %q\n' \
      "$verdict" "$id" "$task" "$STATE/$task.status" "$close_line" "$STATE/$task.status" >&2
    exit 1
  fi
  printf '%s %s %s\n' "$verdict" "$task" "$id"
}

CMD=${1:-}
shift 2>/dev/null || true
case "$CMD" in
  list)
    [ "$#" -le 1 ] || usage
    cmd_list "${1:-}"
    ;;
  show)
    [ "$#" -eq 2 ] || usage
    cmd_show "$1" "$2"
    ;;
  respond)
    [ "$#" -ge 3 ] || usage
    cmd_respond "$@"
    ;;
  *) usage ;;
esac
