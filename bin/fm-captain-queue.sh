#!/usr/bin/env bash
# fm-captain-queue.sh - canonical read-only query for captain-held work.
#
# `tasks-axi ready --include-held` finds active unblocked captain holds but misses
# blocked work. `tasks-axi list --kind captain` finds captain-kind items but
# misses captain holds on another task kind. `tasks-axi list --state held`
# supplies the active held-state view needed for blocked ordinary-kind holds.
# This command unions all three views by task id and reports mismatches between
# active captain holds and captain-kind items as orphans. It never repairs holds
# or changes backlog data.
#
# Usage:
#   fm-captain-queue.sh [--json]
#
# The JSON contract is `fm-captain-queue.v1`:
#   {schema,count,orphan_count,items:[...]}
# Every item contains id, title, found_by, orphan, kind, hold_kind, hold_reason,
# normalized repo, structured origin and decision key, and replyability.
# `found_by` uses the stable values `ready_include_held`, `list_kind_captain`,
# and `list_state_held`. An item is an orphan when an active captain hold is not
# captain-kind or a captain-kind item lacks an active hold. A replyable item must
# also be a captain-kind record whose validated Origin and Decision key fields
# reconstruct its exact backlog identity.
# Known sabstech aliases normalize to `sabstech`; `firstmate` stays `firstmate`.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-captain-queue: %s\n' "$*" >&2
  exit 1
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

extract_group_ids() { # <group-name>
  awk -v group="$1" '
    $0 ~ "^" group "\\[[0-9]+\\]\\{" { in_group = 1; next }
    in_group && /^[[:alnum:]_]+\[[0-9]+\]/ { in_group = 0 }
    in_group && /^  [A-Za-z0-9._-]+,/ {
      row = $0
      sub(/^  /, "", row)
      sub(/,.*/, "", row)
      print row
    }
  '
}

show_field() { # <show-output> <field>
  local output=$1 field=$2 raw
  raw=$(printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1)
  case "$raw" in
    \"*) printf '%s' "$raw" | jq -Rr fromjson ;;
    *) printf '%s' "$raw" ;;
  esac
}

normalize_repo() { # <repo>
  case "$1" in
    sabstech|SABS-Technology/sabstech|SABS-Technology-sabstech) printf 'sabstech\n' ;;
    firstmate) printf 'firstmate\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

valid_slug() { # <value>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

active_state() { # <state>
  case "$1" in
    queued|in_flight) return 0 ;;
    *) return 1 ;;
  esac
}

FORMAT=human
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-captain-queue.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

READY_OUTPUT=$(tasks_axi ready --include-held) || fail "tasks-axi ready --include-held failed"
LIST_OUTPUT=$(tasks_axi list --kind captain) || fail "tasks-axi list --kind captain failed"
HELD_OUTPUT=$(tasks_axi list --state held) || fail "tasks-axi list --state held failed"
printf '%s\n' "$READY_OUTPUT" | extract_group_ids held | LC_ALL=C sort -u > "$TMP_DIR/ready.ids"
printf '%s\n' "$LIST_OUTPUT" | extract_group_ids tasks | LC_ALL=C sort -u > "$TMP_DIR/list.ids"
printf '%s\n' "$HELD_OUTPUT" | extract_group_ids tasks | LC_ALL=C sort -u > "$TMP_DIR/held.ids"
LC_ALL=C sort -u "$TMP_DIR/ready.ids" "$TMP_DIR/list.ids" "$TMP_DIR/held.ids" > "$TMP_DIR/candidates.ids"
: > "$TMP_DIR/items.ndjson"

while IFS= read -r id; do
  [ -n "$id" ] || continue
  show=$(tasks_axi show "$id" --full) || fail "tasks-axi show failed for $id"
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  held=$(show_field "$show" held)
  hold_kind=$(show_field "$show" hold_kind)
  in_ready=false
  in_list=false
  in_held=false
  if grep -Fqx -- "$id" "$TMP_DIR/ready.ids" \
    && active_state "$state" && [ "$held" = yes ] && [ "$hold_kind" = captain ]; then
    in_ready=true
  fi
  if grep -Fqx -- "$id" "$TMP_DIR/list.ids" \
    && active_state "$state" && [ "$kind" = captain ]; then
    in_list=true
  fi
  if grep -Fqx -- "$id" "$TMP_DIR/held.ids" \
    && active_state "$state" && [ "$held" = yes ] && [ "$hold_kind" = captain ]; then
    in_held=true
  fi
  [ "$in_ready" = true ] || [ "$in_list" = true ] || [ "$in_held" = true ] || continue

  found_by=$(jq -cn \
    --argjson in_ready "$in_ready" \
    --argjson in_list "$in_list" \
    --argjson in_held "$in_held" \
    '[if $in_ready then "ready_include_held" else empty end,
      if $in_list then "list_kind_captain" else empty end,
      if $in_held then "list_state_held" else empty end]')
  if { [ "$in_ready" = true ] || [ "$in_held" = true ]; } && [ "$in_list" = true ]; then
    orphan=false
  else
    orphan=true
  fi

  title=$(show_field "$show" title)
  hold_reason=$(show_field "$show" hold_reason)
  repo=$(normalize_repo "$(show_field "$show" repo)")
  body=$(show_field "$show" body)
  origin=$(printf '%s\n' "$body" | sed -n 's/^Origin: //p' | head -1)
  decision_key=$(printf '%s\n' "$body" | sed -n 's/^Decision key: //p' | head -1)
  structured=false
  if valid_slug "$origin" && valid_slug "$decision_key" \
    && [ "$id" = "$origin-decision-$decision_key" ]; then
    structured=true
  else
    origin=''
    decision_key=''
  fi
  replyable=false
  if [ "$structured" = true ] && [ "$kind" = captain ] \
    && { [ "$in_ready" = true ] || [ "$in_held" = true ]; }; then
    replyable=true
  fi
  jq -cn \
    --arg id "$id" \
    --arg title "$title" \
    --argjson found_by "$found_by" \
    --argjson orphan "$orphan" \
    --arg hold_kind "$hold_kind" \
    --arg hold_reason "$hold_reason" \
    --arg repo "$repo" \
    --arg kind "$kind" \
    --arg origin "$origin" \
    --arg decision_key "$decision_key" \
    --argjson replyable "$replyable" \
    '{id:$id,title:$title,found_by:$found_by,orphan:$orphan,kind:$kind,hold_kind:$hold_kind,hold_reason:$hold_reason,repo:$repo,origin:$origin,decision_key:$decision_key,replyable:$replyable}' \
    >> "$TMP_DIR/items.ndjson"
done < "$TMP_DIR/candidates.ids"

RESULT=$(jq -s '{schema:"fm-captain-queue.v1",count:length,orphan_count:(map(select(.orphan))|length),items:.}' "$TMP_DIR/items.ndjson")
if [ "$FORMAT" = json ]; then
  printf '%s\n' "$RESULT"
else
  printf '%s\n' "$RESULT" | jq -r '
    "captain_queue: \(.count) (orphans: \(.orphan_count))",
    (.items[] |
      (if .orphan then "ORPHAN " else "QUEUE  " end)
      + .id + " [" + (.found_by | join(",")) + "]"
      + " repo=" + .repo + " hold_kind=" + .hold_kind,
      "  title: " + .title,
      "  hold_reason: " + .hold_reason)
  '
fi
