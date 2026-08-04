#!/usr/bin/env bash
# Canonical captain queue union, orphan disclosure, JSON, and read-only tests.
set -eu

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QUERY="$ROOT/bin/fm-captain-queue.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-queue)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_fixture() { # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  tasks_in "$home" add cleared-hold "Cleared hold remains captain work" \
    --kind captain --repo SABS-Technology-sabstech >/dev/null
  tasks_in "$home" hold cleared-hold --reason "cleared outside resolve" --kind captain >/dev/null
  tasks_in "$home" unhold cleared-hold >/dev/null
  tasks_in "$home" add noncaptain-hold "Non-captain kind remains held" \
    --kind task --repo sabstech >/dev/null
  tasks_in "$home" hold noncaptain-hold --reason "captain ruling pending" --kind captain >/dev/null
  tasks_in "$home" add visible-both "Visible in both enumerations" \
    --kind captain --repo firstmate >/dev/null
  tasks_in "$home" hold visible-both --reason "captain confirmation pending" --kind captain >/dev/null
  printf '%s\n' "$home"
}

tasks_in() { # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

query_json() { # <home>
  FM_HOME="$1" "$QUERY" --json
}

digest() { # <file>
  shasum -a 256 "$1" | awk '{print $1}'
}

test_union_includes_each_one_sided_failure_mode() {
  local home json
  home=$(make_fixture union)
  json=$(query_json "$home") || fail "canonical query failed: $json"
  printf '%s' "$json" | jq -e '
    (.items[] | select(.id == "cleared-hold")
      | .found_by == ["list_kind_captain"] and .orphan == true)
    and
    (.items[] | select(.id == "noncaptain-hold")
      | .found_by == ["ready_include_held","list_state_held"] and .orphan == true)
  ' >/dev/null || fail "one-sided queue members were omitted or misclassified: $json"
  pass "union includes cleared-hold and non-captain-kind failure modes"
}

test_union_deduplicates_two_sided_item() {
  local home json
  home=$(make_fixture dedupe)
  json=$(query_json "$home") || fail "canonical query failed: $json"
  printf '%s' "$json" | jq -e '
    [.items[] | select(.id == "visible-both")] as $matches
    | ($matches | length) == 1
      and $matches[0].found_by == ["ready_include_held","list_kind_captain","list_state_held"]
      and $matches[0].orphan == false
  ' >/dev/null || fail "two-sided item was duplicated or misclassified: $json"
  pass "union de-duplicates an item visible in both enumerations"
}

test_blocked_ordinary_hold_is_enumerated_once() {
  local home json ready
  home=$(make_fixture blocked-ordinary)
  tasks_in "$home" add readiness-blocker "Independent ready blocker" \
    --kind task --repo firstmate >/dev/null
  tasks_in "$home" add ordinary-blocked "Blocked ordinary captain hold" \
    --kind task --repo firstmate >/dev/null
  tasks_in "$home" hold ordinary-blocked \
    --reason "captain ruling pending behind blocker" --kind captain >/dev/null
  tasks_in "$home" block ordinary-blocked --by readiness-blocker >/dev/null

  ready=$(tasks_in "$home" ready --include-held)
  assert_contains "$ready" "readiness-blocker," \
    "independent blocker was not still represented in readiness"
  assert_not_contains "$ready" "ordinary-blocked," \
    "fixture did not reproduce ready --include-held omitting blocked work"

  json=$(query_json "$home") || fail "canonical query failed: $json"
  printf '%s' "$json" | jq -e '
    [.items[] | select(.id == "ordinary-blocked")] as $matches
    | ($matches | length) == 1
      and $matches[0].found_by == ["list_state_held"]
      and $matches[0].orphan == true
      and $matches[0].replyable == true
      and ([.items[] | select(.id == "readiness-blocker")] | length) == 0
  ' >/dev/null || fail "blocked ordinary captain hold was omitted or duplicated: $json"
  pass "blocked ordinary captain hold appears once while blocker readiness stays separate"
}

test_open_in_flight_holds_are_deduplicated_and_done_is_excluded() {
  local home json
  home=$(make_fixture active-states)
  tasks_in "$home" add inflight-captain "In-flight captain-kind hold" \
    --kind captain --repo firstmate --start >/dev/null
  tasks_in "$home" hold inflight-captain --reason "captain ruling pending" --kind captain >/dev/null
  tasks_in "$home" add inflight-ordinary "In-flight ordinary-kind hold" \
    --kind task --repo firstmate --start >/dev/null
  tasks_in "$home" hold inflight-ordinary --reason "captain ruling pending" --kind captain >/dev/null
  tasks_in "$home" add done-captain "Completed captain hold" \
    --kind captain --repo firstmate >/dev/null
  tasks_in "$home" hold done-captain --reason "captain ruling completed" --kind captain >/dev/null
  tasks_in "$home" "done" done-captain >/dev/null

  json=$(query_json "$home") || fail "canonical active-state query failed: $json"
  printf '%s' "$json" | jq -e '
    ([.items[] | select(.id == "inflight-captain")] | length) == 1
      and ([.items[] | select(.id == "inflight-ordinary")] | length) == 1
      and ([.items[] | select(.id == "done-captain")] | length) == 0
      and (.items[] | select(.id == "inflight-captain")
        | .found_by == ["list_kind_captain","list_state_held"])
      and (.items[] | select(.id == "inflight-ordinary")
        | .found_by == ["list_state_held"] and .replyable == true)
  ' >/dev/null || fail "active captain holds were omitted, duplicated, or mixed with Done: $json"
  pass "queued and in-flight hold discovery is exact while Done stays excluded"
}

test_json_contract_carries_required_fields() {
  local home json
  home=$(make_fixture json)
  json=$(query_json "$home") || fail "canonical query failed: $json"
  printf '%s' "$json" | jq -e '
    .schema == "fm-captain-queue.v1"
      and .count == 3
      and .orphan_count == 2
      and (.items | length) == 3
      and all(.items[];
        (.id | type) == "string"
        and (.title | type) == "string"
        and (.found_by | type) == "array"
        and (.kind | type) == "string"
        and (.hold_kind | type) == "string"
        and (.hold_reason | type) == "string"
        and (.repo | type) == "string"
        and (.origin | type) == "string"
        and (.decision_key | type) == "string"
        and (.replyable | type) == "boolean")
  ' >/dev/null || fail "JSON contract is incomplete or invalid: $json"
  pass "JSON output parses and carries every required field"
}

test_repo_aliases_normalize_without_backlog_writes() {
  local home json before after
  home=$(make_fixture normalization)
  before=$(digest "$home/data/backlog.md")
  json=$(query_json "$home") || fail "canonical query failed: $json"
  after=$(digest "$home/data/backlog.md")
  [ "$before" = "$after" ] || fail "query changed backlog bytes during normalization"
  printf '%s' "$json" | jq -e '
    (.items[] | select(.id == "cleared-hold") | .repo == "sabstech")
      and (.items[] | select(.id == "noncaptain-hold") | .repo == "sabstech")
      and (.items[] | select(.id == "visible-both") | .repo == "firstmate")
      and ([.items[].repo] | unique | sort) == ["firstmate","sabstech"]
  ' >/dev/null || fail "repository aliases did not normalize to two stable values: $json"
  pass "repository aliases normalize on read without changing backlog bytes"
}

test_orphans_are_impossible_to_miss_and_read_only() {
  local home json human before after
  home=$(make_fixture orphans)
  before=$(digest "$home/data/backlog.md")
  json=$(query_json "$home") || fail "canonical query failed: $json"
  human=$(FM_HOME="$home" "$QUERY") || fail "human query failed: $human"
  after=$(digest "$home/data/backlog.md")
  [ "$before" = "$after" ] || fail "orphan reporting changed backlog bytes"
  printf '%s' "$json" | jq -e '
    .orphan_count == 2
      and ([.items[] | select(.orphan) | .id] | sort)
        == ["cleared-hold","noncaptain-hold"]
  ' >/dev/null || fail "structured output hid an orphan: $json"
  assert_contains "$human" "ORPHAN cleared-hold [list_kind_captain]" \
    "human output did not identify the cleared-hold orphan and its source"
  assert_contains "$human" "ORPHAN noncaptain-hold [ready_include_held,list_state_held]" \
    "human output did not identify the non-captain-kind orphan and its source"
  pass "orphans are explicit in both formats and discovery mutates nothing"
}

test_union_includes_each_one_sided_failure_mode
test_union_deduplicates_two_sided_item
test_blocked_ordinary_hold_is_enumerated_once
test_open_in_flight_holds_are_deduplicated_and_done_is_excluded
test_json_contract_carries_required_fields
test_repo_aliases_normalize_without_backlog_writes
test_orphans_are_impossible_to_miss_and_read_only
