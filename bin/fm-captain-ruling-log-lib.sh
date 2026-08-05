#!/usr/bin/env bash
# Program-owned captain ruling log and captain-owned editor ingestion.
#
# Records are totally ordered in state/captain-ruling-log.tsv:
#   REPLY<TAB><hold-id><TAB><answer-digest><TAB>-
#   COMMIT<TAB><hold-id><TAB><answer-digest><TAB><route-set-digest>
# A ruling is committed only while its COMMIT is the last record for the hold.

# shellcheck source=bin/fm-append-log-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-append-log-lib.sh"

FM_RULING_LOG=${FM_CAPTAIN_RULING_LOG_OVERRIDE:-$STATE/captain-ruling-log.tsv}
FM_RULING_REPLIES=${FM_CAPTAIN_REPLIES_OVERRIDE:-${DATA:-$FM_HOME/data}/captain-replies.md}
FM_RULING_LAST_TYPE=
FM_RULING_LAST_DECISION=
FM_RULING_LAST_ROUTES=
FM_RULING_COMMIT_RETRY=0

fm_ruling_sha256() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

fm_ruling_log_valid() {
  local type id decision routes extra read_status
  [ ! -e "$FM_RULING_LOG" ] && [ ! -L "$FM_RULING_LOG" ] && return 0
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  local device
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_private_file_valid "$FM_RULING_LOG" 600 "$device" || return 1
  while :; do
    type='' id='' decision='' routes='' extra=''
    IFS=$'\t' read -r type id decision routes extra
    read_status=$?
    if [ "$read_status" -ne 0 ]; then
      [ -z "$type$id$decision$routes$extra" ] || return 1
      break
    fi
    [ -z "${extra:-}" ] && fm_pr_task_id_valid "$id" \
      && [[ "$decision" =~ ^[0-9a-f]{64}$ ]] || return 1
    case "$type:$routes" in
      REPLY:-) ;;
      COMMIT:*) [[ "$routes" =~ ^[0-9a-f]{64}$ ]] || return 1 ;;
      *) return 1 ;;
    esac
  done < "$FM_RULING_LOG"
}

fm_ruling_append() {  # <type> <id> <decision-digest> <routes-digest-or-dash>
  local type=$1 id=$2 decision=$3 routes=$4 device record
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  printf -v record '%s\t%s\t%s\t%s\n' "$type" "$id" "$decision" "$routes"
  fm_append_log_record "$FM_RULING_LOG" "$device" "$record" captain-ruling
}

fm_ruling_last_record() {  # <hold-id>
  local wanted=$1 type id decision routes
  FM_RULING_LAST_TYPE=
  FM_RULING_LAST_DECISION=
  FM_RULING_LAST_ROUTES=
  fm_ruling_log_valid || return 1
  [ -f "$FM_RULING_LOG" ] || return 0
  while IFS=$'\t' read -r type id decision routes; do
    [ "$id" = "$wanted" ] || continue
    FM_RULING_LAST_TYPE=$type
    FM_RULING_LAST_DECISION=$decision
    FM_RULING_LAST_ROUTES=$routes
  done < "$FM_RULING_LOG"
}

fm_ruling_last_reply_digest() {  # <hold-id>
  local wanted=$1 type id decision _routes found=
  fm_ruling_log_valid || return 1
  [ -f "$FM_RULING_LOG" ] || return 1
  while IFS=$'\t' read -r type id decision _routes; do
    [ "$type" = REPLY ] && [ "$id" = "$wanted" ] || continue
    found=$decision
  done < "$FM_RULING_LOG"
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

fm_ruling_reply_candidates() {
  local line id answer
  [ -f "$FM_RULING_REPLIES" ] && [ ! -L "$FM_RULING_REPLIES" ] || return 0
  {
    while IFS= read -r line; do
      case "$line" in *:*) ;; *) continue ;; esac
      id=${line%%:*}
      answer=${line#*:}
      id=${id#"${id%%[![:space:]]*}"}
      id=${id%"${id##*[![:space:]]}"}
      answer=${answer#"${answer%%[![:space:]]*}"}
      answer=${answer%"${answer##*[![:space:]]}"}
      fm_pr_task_id_valid "$id" || continue
      case "$answer" in ''|'<answer>'|'[answer]') continue ;; esac
      printf '%s\t%s\n' "$id" "$answer"
    done < "$FM_RULING_REPLIES"
  } | awk -F '\t' '
    { ids[NR] = $1; lines[NR] = $0; last[$1] = NR }
    END { for (row = 1; row <= NR; row++) if (last[ids[row]] == row) print lines[row] }
  '
}

fm_ruling_ingest() {
  local id answer digest previous candidates
  fm_ruling_log_valid || return 1
  candidates=$(fm_ruling_reply_candidates) || return 1
  while IFS=$'\t' read -r id answer; do
    [ -n "$id" ] && [ -n "$answer" ] || continue
    digest=$(fm_ruling_sha256 "$answer") || return 1
    previous=$(fm_ruling_last_reply_digest "$id" 2>/dev/null || true)
    [ "$digest" = "$previous" ] || fm_ruling_append REPLY "$id" "$digest" - || return 1
  done <<< "$candidates"
}

fm_ruling_answer() {  # <hold-id>
  local wanted=$1 id answer digest candidate=
  fm_ruling_ingest || return 1
  fm_ruling_last_record "$wanted" || return 1
  case "$FM_RULING_LAST_TYPE" in REPLY|COMMIT) ;; *) return 1 ;; esac
  while IFS=$'\t' read -r id answer; do
    [ "$id" = "$wanted" ] || continue
    digest=$(fm_ruling_sha256 "$answer") || return 1
    [ "$digest" = "$FM_RULING_LAST_DECISION" ] && candidate=$answer
  done <<< "$(fm_ruling_reply_candidates)"
  [ -n "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

fm_ruling_commit() {  # <hold-id> <decision-digest> <routes-digest>
  local id=$1 decision=$2 routes=$3
  FM_RULING_COMMIT_RETRY=0
  fm_ruling_ingest || return 1
  fm_ruling_last_record "$id" || return 1
  if [ "$FM_RULING_LAST_TYPE" = COMMIT ]; then
    [ "$FM_RULING_LAST_DECISION" = "$decision" ] \
      && [ "$FM_RULING_LAST_ROUTES" = "$routes" ] || return 3
    # fm-decision-hold.sh reads this sourced-library result after the call.
    # shellcheck disable=SC2034
    FM_RULING_COMMIT_RETRY=1
    return 0
  fi
  [ "$FM_RULING_LAST_TYPE" = REPLY ] \
    && [ "$FM_RULING_LAST_DECISION" = "$decision" ] || return 3
  fm_ruling_append COMMIT "$id" "$decision" "$routes" || return 1
  fm_ruling_last_record "$id" || return 1
  [ "$FM_RULING_LAST_TYPE" = COMMIT ] \
    && [ "$FM_RULING_LAST_DECISION" = "$decision" ] \
    && [ "$FM_RULING_LAST_ROUTES" = "$routes" ]
}
