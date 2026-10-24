#!/usr/bin/env bash
# fm-worker-approval-lib.sh - the ONE owner of the worker approval bridge's
# durable record contract: where a task's approval records live, the request,
# response, cancelled, and retired record formats, the decision key a request
# opens in the task's status log, and the read helpers every consumer uses.
#
# Why this exists (docs/worker-approval-bridge.md): a Pi worker's cooperative
# guard extension asks before running a flagged bash command. The worker-side
# bridge (.pi/extensions/lib/fm-worker-approval.ts, loaded through the
# per-task extension bin/fm-spawn.sh writes) records that request durably in
# the task's home state, opens a keyed needs-decision in the task's status log,
# and releases exactly that one tool call only when a response record bound to
# the same request, task, incarnation, and command arrives.
# bin/fm-worker-approval.sh is the coordinator's command surface and the only
# writer of response records; the bridge is the only writer of request,
# cancelled, and retired records. No other script parses these files.
#
# Layout under <state-dir>:
#   <task>.approvals/<approval-id>.request    the pending request (bridge writes)
#   <task>.approvals/<approval-id>.response   the coordinator's verdict
#                                             (fm-worker-approval.sh respond)
#   <task>.approvals/<approval-id>.cancelled  the worker gave up first: its turn
#                                             was interrupted, or the guard
#                                             stopped waiting
#   <task>.approvals/<approval-id>.retired    a later worker incarnation found
#                                             the request unanswered at its
#                                             session start
#
# <approval-id> is 16 lowercase hex characters: the bridge derives it from the
# task id, incarnation gen, Pi tool call id, working directory, and command
# text, so two different pending commands never share an id and an answer
# cannot be re-addressed to another command.
#
# Record format: key=value header lines, one per line, then a `--` separator
# line, then the body. The request body is the command text verbatim, newlines
# included and without a trailing newline added; the other records have an
# empty body. Header keys:
#
#   request record (bridge; all required):
#     schema=fm-worker-approval.v1
#     request=<approval-id>
#     task=<task-id>
#     gen=<busy incarnation gen, bin/fm-busy-lib.sh>
#     tool_call=<Pi tool call id>
#     tool=bash
#     cwd=<worker working directory>
#     guard=<guard name the request named, or unknown>
#     severity=<severity the guard named, or unknown>
#     reasons=<guard reasons joined with "; ", one line>
#     requested_at=<epoch seconds>
#     command_sha256=<hex digest of the exact command body>
#   response record (coordinator; all required):
#     schema=fm-worker-approval.v1
#     request=<approval-id>
#     task=<task-id>
#     gen=<the request's gen, echoed>
#     verdict=approve|deny
#     command_sha256=<the request's digest, echoed>
#     decided_at=<epoch seconds>
#     note=<one line, may be empty>
#   cancelled and retired records (bridge; all required):
#     schema=fm-worker-approval.v1
#     request=<approval-id>
#     task=<task-id>
#     gen=<the request's gen>
#     reason=<one line>
#     at=<epoch seconds>
#
# Decision key: a request opens `approval-<approval-id>` in state/<task>.status
# as a needs-decision, and exactly one of the three closing records above
# closes it with a resolved line carrying that key (bin/fm-classify-lib.sh owns
# the fold). The response close is the coordinator's own bookkeeping and goes
# through fm_wake_status_append_self_announced (bin/fm-wake-lib.sh); the
# bridge's closes are ordinary worker-authored lines.
#
# Binding rule (the reason every record echoes task, gen, and digest): a
# response applies only when its request, task, gen, and command_sha256 all
# equal the pending request's, the request's gen is still the task's armed
# incarnation (fm_busy_current_gen), and no response, cancelled, or retired
# record exists yet. The coordinator checks this before writing; the bridge
# checks it again before releasing, so neither side trusts the other's check.
#
# Pure read helpers only; sourcing has no side effects.

FM_WORKER_APPROVAL_SCHEMA='fm-worker-approval.v1'
FM_WORKER_APPROVAL_KEY_PREFIX='approval-'

fm_worker_approval_dir() {  # <state-dir> <task-id>
  printf '%s/%s.approvals' "$1" "$2"
}

fm_worker_approval_id_valid() {  # <approval-id>
  case "${1:-}" in
    ????????????????) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
  esac
  return 0
}

fm_worker_approval_key() {  # <approval-id>
  printf '%s%s' "$FM_WORKER_APPROVAL_KEY_PREFIX" "$1"
}

# fm_worker_approval_header <record>: the key=value lines before the separator.
fm_worker_approval_header() {  # <record>
  local f=$1
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  LC_ALL=C awk '/^--$/ { exit } { print }' "$f"
}

# fm_worker_approval_field <record> <key>: the first header value for <key>,
# or failure when the key is absent.
fm_worker_approval_field() {  # <record> <key>
  local f=$1 key=$2 line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) printf '%s' "${line#"$key"=}"; return 0 ;;
    esac
  done <<EOF
$(fm_worker_approval_header "$f")
EOF
  return 1
}

# fm_worker_approval_body <record>: the bytes after the separator line,
# exactly as written (a request body is the command text).
fm_worker_approval_body() {  # <record>
  local f=$1
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  LC_ALL=C awk 'found { if (printed) printf "\n"; printf "%s", $0; printed = 1; next } /^--$/ { found = 1 }' "$f"
}

# fm_worker_approval_request_valid <record>: the request record carries the
# schema and every required header field.
fm_worker_approval_request_valid() {  # <record>
  local f=$1 key
  [ "$(fm_worker_approval_field "$f" schema 2>/dev/null)" = "$FM_WORKER_APPROVAL_SCHEMA" ] || return 1
  for key in request task gen tool_call tool cwd guard severity reasons requested_at command_sha256; do
    fm_worker_approval_field "$f" "$key" >/dev/null 2>&1 || return 1
  done
  fm_worker_approval_id_valid "$(fm_worker_approval_field "$f" request)" || return 1
  [ "$(fm_worker_approval_field "$f" tool)" = bash ] || return 1
  return 0
}

# fm_worker_approval_state <approvals-dir> <approval-id>: pending, approved,
# denied, cancelled, retired, or invalid (no readable request).
fm_worker_approval_state() {  # <approvals-dir> <approval-id>
  local dir=$1 id=$2 verdict
  fm_worker_approval_request_valid "$dir/$id.request" 2>/dev/null || { printf 'invalid'; return 0; }
  if [ -e "$dir/$id.response" ]; then
    verdict=$(fm_worker_approval_field "$dir/$id.response" verdict 2>/dev/null) || verdict=
    case "$verdict" in
      approve) printf 'approved' ;;
      deny) printf 'denied' ;;
      *) printf 'invalid' ;;
    esac
    return 0
  fi
  [ ! -e "$dir/$id.cancelled" ] || { printf 'cancelled'; return 0; }
  [ ! -e "$dir/$id.retired" ] || { printf 'retired'; return 0; }
  printf 'pending'
}

# fm_worker_approval_sha256: hex digest of stdin, portable across the
# coreutils and BSD toolchains.
fm_worker_approval_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | LC_ALL=C awk '{ print $1 }'
  else
    sha256sum | LC_ALL=C awk '{ print $1 }'
  fi
}

# fm_worker_approval_display <text> [<max>]: one printable line for a status
# or listing entry - whitespace runs collapsed, control bytes dropped, cut to
# <max> characters (default 120) with a trailing ellipsis marker.
fm_worker_approval_display() {  # <text> [<max>]
  local text=$1 max=${2:-120} out
  out=$(printf '%s' "$text" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | LC_ALL=C sed -E 's/ +/ /g; s/^ //; s/ $//')
  if [ "${#out}" -gt "$max" ]; then
    out="${out:0:$((max - 3))}..."
  fi
  printf '%s' "$out"
}
