#!/usr/bin/env bash
# Record and read the work-stage axis without changing crew supervision state.
#
# The stage model follows the task lifecycle's actual owner transitions:
#   ship: implementation [-> validation] [-> pr-open -> merged] -> complete
#   scout: investigation -> complete
# Validation belongs to no-mistakes work, PR stages belong to PR delivery modes,
# and local-only work can reach complete without either optional segment.
# A validation finding may return ship work to implementation before validation
# begins again.
#
# Stage and supervision are independent axes.
# The existing status verbs describe what the crew is doing now, while this log
# describes how far the work has progressed.
# This script never reads, writes, or derives state from state/<id>.status.
#
# Every emission appends one TAB-separated record to this home's private
# state/stage-transitions.tsv:
#   <task-id>\t<stage>\t<UTC RFC3339 timestamp>
# The ledger is retained across restarts and task teardown.
# Duplicate and backward transitions are intentionally recorded without
# rewriting history; a point-in-time consumer resolves the current stage as the
# last valid record for that task in append order.
#
# Usage:
#   fm-stage.sh emit <task-id> <stage>
#   fm-stage.sh current <task-id>
#   fm-stage.sh history <task-id>
#   fm-stage.sh stages
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
EVENTS="$STATE/stage-transitions.tsv"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-append-log-lib.sh
. "$SCRIPT_DIR/fm-append-log-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fm_stage_valid() {
  case "${1:-}" in
    implementation|investigation|validation|pr-open|merged|complete) return 0 ;;
    *) return 1 ;;
  esac
}

fm_stage_timestamp_valid() {
  local LC_ALL=C
  [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

fm_stage_parse_record() {
  local line=$1 rest
  case "$line" in *$'\t'*) ;; *) return 1 ;; esac
  FM_STAGE_TASK=${line%%$'\t'*}
  rest=${line#*$'\t'}
  case "$rest" in *$'\t'*) ;; *) return 1 ;; esac
  FM_STAGE_VALUE=${rest%%$'\t'*}
  FM_STAGE_AT=${rest#*$'\t'}
  case "$FM_STAGE_AT" in *$'\t'*) return 1 ;; esac
  fm_task_id_path_safe "$FM_STAGE_TASK" \
    && fm_stage_valid "$FM_STAGE_VALUE" \
    && fm_stage_timestamp_valid "$FM_STAGE_AT"
}

fm_stage_ledger_valid() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    fm_stage_parse_record "$line" || return 1
  done < "$EVENTS"
}

fm_stage_require_readable_ledger() {
  local state_device
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  state_device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_private_file_valid "$EVENTS" 600 "$state_device" || return 1
  fm_stage_ledger_valid
}

fm_stage_emit() {
  local task=$1 stage=$2 at state_device record
  if ! fm_task_id_path_safe "$task" || ! fm_stage_valid "$stage"; then
    echo "error: invalid stage transition" >&2
    return 2
  fi
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || {
    echo "error: stage state directory is unavailable" >&2
    return 1
  }
  state_device=$(fm_pr_file_device "$STATE") || {
    echo "error: stage state directory is unavailable" >&2
    return 1
  }
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ) || return 1
  fm_stage_timestamp_valid "$at" || return 1
  printf -v record '%s\t%s\t%s\n' "$task" "$stage" "$at"

  if ! fm_append_log_record "$EVENTS" "$state_device" "$record" stage; then
    echo "error: stage transition record is unavailable" >&2
    return 1
  fi
}

fm_stage_read() {
  local command=$1 task=$2 line current=
  fm_task_id_path_safe "$task" || {
    echo "error: invalid stage task" >&2
    return 2
  }
  fm_stage_require_readable_ledger || {
    echo "error: stage transition record is unavailable or malformed" >&2
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    fm_stage_parse_record "$line" || return 1
    [ "$FM_STAGE_TASK" = "$task" ] || continue
    if [ "$command" = history ]; then
      printf '%s\n' "$line"
    else
      current=$FM_STAGE_VALUE
    fi
  done < "$EVENTS"
  if [ "$command" = current ]; then
    [ -n "$current" ] || return 1
    printf '%s\n' "$current"
  fi
}

case "${1:-}" in
  -h|--help) usage ;;
  stages)
    [ "$#" -eq 1 ] || { echo "error: invalid stage request" >&2; exit 2; }
    printf '%s\n' implementation investigation validation pr-open merged complete
    ;;
  emit)
    [ "$#" -eq 3 ] || { echo "error: invalid stage request" >&2; exit 2; }
    fm_stage_emit "$2" "$3"
    ;;
  current|history)
    [ "$#" -eq 2 ] || { echo "error: invalid stage request" >&2; exit 2; }
    fm_stage_read "$1" "$2"
    ;;
  *)
    echo "error: invalid stage request" >&2
    exit 2
    ;;
esac
