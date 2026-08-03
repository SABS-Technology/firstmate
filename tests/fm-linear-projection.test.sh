#!/usr/bin/env bash
# One-way Linear projection, archive reconciliation, and credential-boundary tests.
set -eu

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECTION="$ROOT/bin/fm-linear-projection.sh"
TMP_ROOT=$(fm_test_tmproot fm-linear-projection)
mkdir -p "$TMP_ROOT"
WORKSPACE_ID=11111111-1111-4111-8111-111111111111
TOKEN='linear-secret-fixture-value'
FAKE_LINEAR="$TMP_ROOT/fake-linear.sh"
FAKE_GITHUB="$TMP_ROOT/fake-github.sh"
FAKE_QUEUE="$TMP_ROOT/fake-queue.sh"

cat > "$FAKE_LINEAR" <<'EOF'
#!/usr/bin/env bash
set -eu
request=$(cat)
if [ "${FAKE_LINEAR_FAIL:-0}" = 1 ]; then
  printf '%s\n' "${LINEAR_API_KEY:-}" >&2
  printf '%s\n' "${LINEAR_API_KEY:-}"
  exit 17
fi
printf '%s\n' "$request" >> "$FAKE_LINEAR_LOG"
operation=$(printf '%s' "$request" | jq -r .operationName)
case "$operation" in
  CreateIssue)
    id=$(printf '%s' "$request" | jq -r .variables.input.id)
    body=$(jq -cn --arg id "$id" '{data:{issueCreate:{success:true,issue:{id:$id,identifier:"FM-1",url:"https://linear.example/FM-1"}}}}')
    ;;
  UpdateIssue)
    id=$(printf '%s' "$request" | jq -r .variables.id)
    body=$(jq -cn --arg id "$id" '{data:{issueUpdate:{success:true,issue:{id:$id,identifier:"FM-1",url:"https://linear.example/FM-1"}}}}')
    ;;
  LinkGitHubPr)
    id=$(printf '%s' "$request" | jq -r .variables.id)
    issue=$(printf '%s' "$request" | jq -r .variables.issueId)
    url=$(printf '%s' "$request" | jq -r .variables.url)
    body=$(jq -cn --arg id "$id" --arg issue "$issue" --arg url "$url" '{data:{attachmentLinkGitHubPR:{success:true,attachment:{id:$id,url:$url,issue:{id:$issue}}}}}')
    ;;
  ArchiveIssue)
    body='{"data":{"issueArchive":{"success":true}}}'
    ;;
  *) exit 19 ;;
esac
jq -cn --argjson body "$body" '{status:200,body:$body}'
EOF
chmod +x "$FAKE_LINEAR"

cat > "$FAKE_GITHUB" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$#" -eq 1 ]
printf '%s\n' '{"state":"open","checks":"green"}'
EOF
chmod +x "$FAKE_GITHUB"

cat > "$FAKE_QUEUE" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE_QUEUE_CALLS"
cat "$FM_FAKE_QUEUE_JSON"
EOF
chmod +x "$FAKE_QUEUE"

write_config() { # <home>
  mkdir -p "$1/config"
  cat > "$1/config/linear-projection.json" <<EOF
{"schema":"fm-linear-projection-config.v1","workspace_id":"$WORKSPACE_ID","team_id":"team-1","untracked_state_id":"state-untracked","stage_state_ids":{"implementation":"state-implementation","investigation":"state-investigation","validation":"state-validation","pr-open":"state-pr-open","merged":"state-merged","complete":"state-complete"}}
EOF
}

make_fixture() { # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] ship-a - Build the projected feature (repo: firstmate) (kind: ship) (since 2026-08-03)
- [ ] ship-a-decision-approval - Decide approval for PR 42 (repo: firstmate) (kind: captain) (since 2026-08-03)

## Queued
- [ ] scout-b - Investigate the projection (repo: firstmate) (kind: scout)

## Done
EOF
  : > "$home/data/done-archive.md"
  cat > "$home/state/stage-transitions.tsv" <<'EOF'
ship-a	implementation	2026-08-03T00:00:00Z
ship-a	validation	2026-08-03T01:00:00Z
ship-a	paused	2026-08-03T02:00:00Z
ship-a-decision-approval	implementation	2026-08-03T00:00:00Z
scout-b	investigation	2026-08-03T00:00:00Z
EOF
  printf '%s\n' 'pr=https://github.com/SABS-Technology/firstmate/pull/42' > "$home/state/ship-a.meta"
  cat > "$home/queue.json" <<'EOF'
{"schema":"fm-captain-queue.v1","count":1,"orphan_count":0,"items":[{"id":"ship-a-decision-approval","title":"Decide approval for PR 42","found_by":["ready_include_held","list_kind_captain"],"orphan":false,"hold_kind":"captain","hold_reason":"approval pending","repo":"firstmate"}]}
EOF
  write_config "$home"
  printf '%s\n' "$home"
}

sync_env() { # <home> [command]
  local home=$1 command=${2:-sync}
  FM_HOME="$home" \
  FM_LINEAR_PROJECTION_ENABLED=1 \
  LINEAR_API_KEY="$TOKEN" \
  FM_LINEAR_TRANSPORT="$FAKE_LINEAR" \
  FM_GITHUB_STATUS_TRANSPORT="$FAKE_GITHUB" \
  FM_CAPTAIN_QUEUE_BIN="$FAKE_QUEUE" \
  FM_FAKE_QUEUE_JSON="$home/queue.json" \
  FAKE_LINEAR_LOG="$home/linear.log" \
  FAKE_QUEUE_CALLS="$home/queue.calls" \
  "$PROJECTION" "$command"
}

digest() {
  shasum -a 256 "$1" | awk '{print $1}'
}

line_count() {
  [ -f "$1" ] && wc -l < "$1" | tr -d '[:space:]' || printf '0\n'
}

test_prerequisites_fail_closed_before_transport() {
  local home out rc
  home=$(make_fixture missing-opt-in)
  set +e
  out=$(FM_HOME="$home" LINEAR_API_KEY="$TOKEN" FM_LINEAR_TRANSPORT="$FAKE_LINEAR" FAKE_LINEAR_LOG="$home/linear.log" "$PROJECTION" sync 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "disabled projection must refuse"
  assert_contains "$out" "missing requirement: FM_LINEAR_PROJECTION_ENABLED=1" "disabled projection did not name the opt-in"
  [ "$(line_count "$home/linear.log")" = 0 ] || fail "disabled projection reached Linear"

  home=$(make_fixture missing-token)
  set +e
  out=$(FM_HOME="$home" FM_LINEAR_PROJECTION_ENABLED=1 FM_LINEAR_TRANSPORT="$FAKE_LINEAR" FAKE_LINEAR_LOG="$home/linear.log" "$PROJECTION" sync 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "tokenless projection must refuse"
  assert_contains "$out" "missing requirement: LINEAR_API_KEY" "tokenless projection did not name the credential"
  [ "$(line_count "$home/linear.log")" = 0 ] || fail "tokenless projection reached Linear"

  home=$(make_fixture missing-config)
  rm "$home/config/linear-projection.json"
  set +e
  out=$(FM_HOME="$home" FM_LINEAR_PROJECTION_ENABLED=1 LINEAR_API_KEY="$TOKEN" FM_LINEAR_TRANSPORT="$FAKE_LINEAR" FAKE_LINEAR_LOG="$home/linear.log" "$PROJECTION" sync 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unconfigured projection must refuse"
  assert_contains "$out" "missing requirement:" "unconfigured projection did not name the missing requirement"
  assert_contains "$out" "linear-projection.json" "unconfigured projection did not name its workspace config"
  [ "$(line_count "$home/linear.log")" = 0 ] || fail "unconfigured projection reached Linear"
  pass "each missing prerequisite fails closed before any network transport"
}

test_entities_keep_stage_and_pr_axes_and_link_decisions() {
  local home before_backlog before_stage summary log state decision_issue
  home=$(make_fixture entities)
  before_backlog=$(digest "$home/data/backlog.md")
  before_stage=$(digest "$home/state/stage-transitions.tsv")
  summary=$(sync_env "$home") || fail "fixture projection failed: $summary"
  log=$(jq -s . "$home/linear.log")
  state="$home/state/linear-projection.json"
  printf '%s' "$summary" | jq -e '.source_count == 3 and .created == 3 and .linked == 2 and .updated == 0' >/dev/null \
    || fail "projection summary did not report exactly one entity per work item: $summary"
  printf '%s' "$log" | jq -e '
    ([.[] | select(.operationName == "CreateIssue")] | length) == 3
    and all(.[] | select(.operationName == "CreateIssue"); .variables.input.id | test("^[0-9a-f-]{14}4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
    and all(.[] | select(.operationName == "CreateIssue"); (.variables.input | has("parentId") | not))
    and any(.[] | select(.operationName == "CreateIssue"); .variables.input.description | contains("Stage: validation\nGitHub PR: https://github.com/SABS-Technology/firstmate/pull/42\nGitHub PR status: open; checks=green"))
    and any(.[] | select(.operationName == "CreateIssue"); .variables.input.description | contains("Stage: investigation\nGitHub PR: none\nGitHub PR status: none; checks=none"))
  ' >/dev/null || fail "stage and PR status axes were not projected independently: $log"
  decision_issue=$(jq -r '.items["ship-a-decision-approval"].remote_issue_id' "$state")
  printf '%s' "$log" | jq -e --arg issue "$decision_issue" '
    any(.[] | select(.operationName == "CreateIssue"); .variables.input.id == $issue and (.variables.input.description | contains("Type: decision")))
    and any(.[] | select(.operationName == "LinkGitHubPr"); .variables.issueId == $issue and .variables.url == "https://github.com/SABS-Technology/firstmate/pull/42" and (.variables.id | test("^[0-9a-f-]{14}4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")))
    and all(.[] | select(.operationName == "LinkGitHubPr"); .query | contains("linkKind: links"))
  ' >/dev/null || fail "decision was not a peer entity linked to its PR: $log"
  [ "$(cat "$home/queue.calls")" = "--json" ] || fail "projection did not consume fm-captain-queue --json"
  [ "$(digest "$home/data/backlog.md")" = "$before_backlog" ] || fail "projection changed backlog bytes"
  [ "$(digest "$home/state/stage-transitions.tsv")" = "$before_stage" ] || fail "projection changed stage-ledger bytes"
  pass "one entity per item carries independent stage/PR axes and decisions link without nesting"
}

test_unchanged_second_run_is_mutation_free() {
  local home first_count second_count summary
  home=$(make_fixture idempotent)
  sync_env "$home" >/dev/null || fail "initial idempotence sync failed"
  first_count=$(line_count "$home/linear.log")
  summary=$(sync_env "$home") || fail "second idempotence sync failed: $summary"
  second_count=$(line_count "$home/linear.log")
  [ "$second_count" = "$first_count" ] || fail "unchanged second run sent another Linear mutation"
  printf '%s' "$summary" | jq -e '.created == 0 and .updated == 0 and .linked == 0 and .archived == 0 and .unchanged == 3' >/dev/null \
    || fail "unchanged run summary was not idempotent: $summary"
  pass "an unchanged second run emits no second Linear mutation"
}

test_archive_boundary_never_resurrects_completed_item() {
  local home after_first after_archive after_repeat archive_ops
  home=$(make_fixture archive-boundary)
  sync_env "$home" >/dev/null || fail "initial archive-boundary sync failed"
  after_first=$(line_count "$home/linear.log")
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued
- [ ] scout-b - Investigate the projection (repo: firstmate) (kind: scout)

## Done
EOF
  cat > "$home/data/done-archive.md" <<'EOF'
## Archived 2026-08-03
- [x] ship-a - Build the projected feature (repo: firstmate) (kind: ship) (merged 2026-08-03)
- [x] ship-a-decision-approval - Decide approval for PR 42 (repo: firstmate) (kind: captain) (done 2026-08-03)
EOF
  cat > "$home/queue.json" <<'EOF'
{"schema":"fm-captain-queue.v1","count":0,"orphan_count":0,"items":[]}
EOF
  sync_env "$home" >/dev/null || fail "archive reconciliation failed"
  after_archive=$(line_count "$home/linear.log")
  sync_env "$home" >/dev/null || fail "repeated archive reconciliation failed"
  after_repeat=$(line_count "$home/linear.log")
  [ "$after_archive" -eq $((after_first + 2)) ] || fail "archive transition did not archive exactly two projected items"
  [ "$after_repeat" = "$after_archive" ] || fail "archive replay recreated or re-archived an item"
  archive_ops=$(jq -s '[.[] | select(.operationName == "ArchiveIssue")] | length' "$home/linear.log")
  [ "$archive_ops" = 2 ] || fail "archive boundary produced unexpected mutations: $archive_ops"
  jq -e '.items["ship-a"].archived == true and .items["ship-a-decision-approval"].archived == true' "$home/state/linear-projection.json" >/dev/null \
    || fail "archive tombstones were not persisted"
  pass "archive rollover closes once and cannot resurrect completed work"
}

test_transport_failure_never_emits_credential() {
  local home output rc
  home=$(make_fixture credential-redaction)
  set +e
  output=$(FAKE_LINEAR_FAIL=1 sync_env "$home" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "synthetic Linear transport failure must fail the run"
  assert_contains "$output" "linear_transport_error" "transport failure did not report its safe class"
  assert_not_contains "$output" "$TOKEN" "credential reached projection error or summary output"
  pass "transport failures expose only a safe class and never the credential"
}

test_live_linear_schema_accepts_every_document() {
  local output
  output=$($PROJECTION schema-check) || fail "live Linear schema check failed: $output"
  printf '%s' "$output" | jq -e '.schema == "fm-linear-projection-schema-check.v1" and .documents == 4 and .valid == true' >/dev/null \
    || fail "live Linear schema check returned an invalid proof: $output"
  pass "all four GraphQL documents validate against Linear's live introspected schema"
}

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

test_prerequisites_fail_closed_before_transport
test_entities_keep_stage_and_pr_axes_and_link_decisions
test_unchanged_second_run_is_mutation_free
test_archive_boundary_never_resurrects_completed_item
test_transport_failure_never_emits_credential
test_live_linear_schema_accepts_every_document

echo "# fm-linear-projection.test.sh: all assertions passed"
