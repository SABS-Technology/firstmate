#!/usr/bin/env bash
# fm-captain-queue.sh - canonical read-only query for captain-held work.
#
# `tasks-axi ready --include-held` finds active captain holds but misses captain
# items whose hold was cleared outside fm-decision-hold.sh. `tasks-axi list
# --kind captain` finds those items but misses captain holds on another task kind.
# This command unions both views by task id and reports asymmetric membership as
# an orphan. It never repairs holds or changes backlog data.
#
# Usage:
#   fm-captain-queue.sh [--json]
#
# The JSON contract is `fm-captain-queue.v1`:
#   {schema,count,orphan_count,items:[...]}
# Every item contains id, title, found_by, orphan, hold_kind, hold_reason, and
# normalized repo. `found_by` uses the stable values `ready_include_held` and
# `list_kind_captain`. An item is an orphan when exactly one view found it.
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
printf '%s\n' "$READY_OUTPUT" | extract_group_ids held | LC_ALL=C sort -u > "$TMP_DIR/ready.ids"
printf '%s\n' "$LIST_OUTPUT" | extract_group_ids tasks | LC_ALL=C sort -u > "$TMP_DIR/list.ids"
LC_ALL=C sort -u "$TMP_DIR/ready.ids" "$TMP_DIR/list.ids" > "$TMP_DIR/candidates.ids"
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
  if grep -Fqx -- "$id" "$TMP_DIR/ready.ids" \
    && [ "$state" = queued ] && [ "$held" = yes ] && [ "$hold_kind" = captain ]; then
    in_ready=true
  fi
  if grep -Fqx -- "$id" "$TMP_DIR/list.ids" \
    && [ "$state" = queued ] && [ "$kind" = captain ]; then
    in_list=true
  fi
  [ "$in_ready" = true ] || [ "$in_list" = true ] || continue

  if [ "$in_ready" = true ] && [ "$in_list" = true ]; then
    found_by='["ready_include_held","list_kind_captain"]'
    orphan=false
  elif [ "$in_ready" = true ]; then
    found_by='["ready_include_held"]'
    orphan=true
  else
    found_by='["list_kind_captain"]'
    orphan=true
  fi

  title=$(show_field "$show" title)
  hold_reason=$(show_field "$show" hold_reason)
  repo=$(normalize_repo "$(show_field "$show" repo)")
  jq -cn \
    --arg id "$id" \
    --arg title "$title" \
    --argjson found_by "$found_by" \
    --argjson orphan "$orphan" \
    --arg hold_kind "$hold_kind" \
    --arg hold_reason "$hold_reason" \
    --arg repo "$repo" \
    '{id:$id,title:$title,found_by:$found_by,orphan:$orphan,hold_kind:$hold_kind,hold_reason:$hold_reason,repo:$repo}' \
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
