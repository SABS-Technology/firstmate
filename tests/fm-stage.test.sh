#!/usr/bin/env bash
# Behavior tests for the independent work-stage event ledger.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

STAGE="$ROOT/bin/fm-stage.sh"
TMP_ROOT=$(fm_test_tmproot fm-stage)

make_state() {
  local name=$1 state
  state="$TMP_ROOT/$name/state"
  mkdir -p "$state"
  printf '%s\n' "$state"
}

run_stage() {
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" "$STAGE" "$@"
}

test_model_matches_lifecycle() {
  local actual
  actual=$($STAGE stages)
  [ "$actual" = $'implementation\ninvestigation\nvalidation\npr-open\nmerged\ncomplete' ] \
    || fail "stage model does not match the ship/scout lifecycle: $actual"
  pass "stage model names the lifecycle-owned ship and scout stages"
}

test_append_only_restart_round_trip() {
  local state ledger first current fields task stage at mode
  state=$(make_state append-only)
  ledger="$state/stage-transitions.tsv"

  run_stage "$state" emit task-a implementation
  first=$(sed -n '1p' "$ledger")
  run_stage "$state" emit task-a validation

  [ "$(sed -n '1p' "$ledger")" = "$first" ] \
    || fail "a later stage emission rewrote the first event"
  [ "$(wc -l < "$ledger" | tr -d '[:space:]')" = 2 ] \
    || fail "stage emissions were not append-only"
  current=$(run_stage "$state" current task-a)
  [ "$current" = validation ] || fail "a fresh stage reader did not recover the last event after restart"

  IFS=$'\t' read -r task stage at fields <<EOF
$first
EOF
  [ "$task" = task-a ] && [ "$stage" = implementation ] && [ -z "${fields:-}" ] \
    || fail "stage event does not contain exactly task, stage, and time"
  [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || fail "stage event timestamp is not UTC RFC3339: $at"
  mode=$(fm_pr_file_mode "$ledger")
  [ "$mode" = 600 ] || fail "stage ledger is not private mode 0600: $mode"
  pass "stage events append durably and round-trip through a fresh reader"
}

test_duplicate_and_backward_events_are_preserved() {
  local state history stages
  state=$(make_state duplicate-order)
  run_stage "$state" emit task-b implementation
  run_stage "$state" emit task-b validation
  run_stage "$state" emit task-b validation
  run_stage "$state" emit task-b implementation

  history=$(run_stage "$state" history task-b)
  stages=$(printf '%s\n' "$history" | cut -f2)
  [ "$stages" = $'implementation\nvalidation\nvalidation\nimplementation' ] \
    || fail "duplicate or backward emissions were dropped or mangled: $stages"
  [ "$(run_stage "$state" current task-b)" = implementation ] \
    || fail "current stage did not resolve by last append order"
  pass "duplicate and backward stage events remain intact and resolve last-event-wins"
}

test_invalid_event_is_rejected_without_mutation() {
  local state ledger before rc
  state=$(make_state reject-invalid)
  ledger="$state/stage-transitions.tsv"
  run_stage "$state" emit task-c implementation
  before=$(cat "$ledger")
  set +e
  run_stage "$state" emit task-c paused >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 2 "$rc" "a supervision verb must not be accepted as a work stage"
  [ "$(cat "$ledger")" = "$before" ] || fail "rejected stage emission mutated the ledger"
  pass "invalid stages fail closed without changing the append-only record"
}

test_corrupt_ledger_refuses_without_mutation() {
  local state ledger before rc
  state=$(make_state corrupt-ledger)
  ledger="$state/stage-transitions.tsv"
  printf 'malformed-existing-row\n' > "$ledger"
  chmod 0600 "$ledger"
  before=$(cat "$ledger")
  set +e
  run_stage "$state" emit task-c merged >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "emission against a corrupt ledger must refuse"
  [ "$(cat "$ledger")" = "$before" ] || fail "corrupt-ledger refusal changed the ledger"
  pass "stage emission refuses an already-corrupt ledger without changing its bytes"
}

# A probe bin symlinks every real script and shadows only fm-append-log-lib.sh
# with a copy whose publish sequence can be interrupted at a chosen point.
# fm-stage.sh resolves its library from the directory of the invoked path, so
# the probed script runs the real emitter over the faulted writer.
FAULTED_STAGE=''

install_append_fault_probe() {
  local probe_bin=$1 source name marker
  mkdir -p "$probe_bin"
  for source in "$ROOT"/bin/*; do
    name=${source##*/}
    ln -sf "$source" "$probe_bin/$name"
  done
  rm -f "$probe_bin/fm-append-log-lib.sh"
  awk '
    /^      write_all\(\$replacement, \$record\) or die;$/ {
      print "      if ($fault eq \"partial-record\") {"
      print "        write_all($replacement, substr($record, 0, int(length($record) / 2))) or die;"
      print "        die;"
      print "      }"
      print $0
      print "      die if $fault eq \"before-publish\";"
      next
    }
    { print }
    /^    my \(\$path, \$device, \$record, \$schema\) = @ARGV;$/ {
      print "    my $fault = $ENV{FM_STAGE_TEST_APPEND_FAULT} // \"\";"
    }
    /^      rename\(\$temporary, \$path\) or die;$/ {
      print "      die if $fault eq \"after-publish\";"
    }
  ' "$ROOT/bin/fm-append-log-lib.sh" > "$probe_bin/fm-append-log-lib.sh"
  for marker in 'FM_STAGE_TEST_APPEND_FAULT' 'partial-record' 'before-publish' 'after-publish'; do
    [ "$(grep -Fc "$marker" "$probe_bin/fm-append-log-lib.sh")" -eq 1 ] \
      || fail "could not stage the $marker append fault against the real writer"
  done
  FAULTED_STAGE="$probe_bin/fm-stage.sh"
}

test_append_failures_leave_only_complete_records() {
  local fault state ledger before rc
  install_append_fault_probe "$TMP_ROOT/append-fault-bin"
  for fault in partial-record before-publish after-publish; do
    state=$(make_state "atomic-$fault")
    ledger="$state/stage-transitions.tsv"
    run_stage "$state" emit task-atomic implementation
    before=$(cat "$ledger")
    set +e
    FM_STAGE_TEST_APPEND_FAULT="$fault" FM_STATE_OVERRIDE="$state" "$FAULTED_STAGE" \
      emit task-atomic validation > "$state/stdout" 2> "$state/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "$fault append fault must be reported"
    run_stage "$state" preflight \
      || fail "$fault append fault left a partial ledger record"
    if [ "$fault" = after-publish ]; then
      [ "$(run_stage "$state" current task-atomic)" = validation ] \
        || fail "after-publish fault did not leave the complete record"
    else
      [ "$(cat "$ledger")" = "$before" ] \
        || fail "$fault append changed the original valid ledger"
    fi
  done
  pass "append faults leave each newline-terminated stage record fully present or absent"
}

test_unterminated_valid_record_is_rejected() {
  local state ledger rc
  state=$(make_state unterminated-record)
  ledger="$state/stage-transitions.tsv"
  printf 'task-a\timplementation\t2026-08-05T12:00:00Z' > "$ledger"
  chmod 0600 "$ledger"
  set +e
  run_stage "$state" preflight >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "unterminated shaped record must be refused"
  pass "a shaped record without its terminating newline is never readable state"
}

test_axes_round_trip_independently() {
  local state paused_status working_status
  state=$(make_state independent-axes)
  paused_status="$state/paused-task.status"
  working_status="$state/working-task.status"
  printf 'paused: PR is awaiting merge\n' > "$paused_status"
  printf 'working: validation is running\n' > "$working_status"
  run_stage "$state" emit paused-task pr-open
  run_stage "$state" emit working-task validation

  [ "$(status_line_verb "$(last_status_line "$paused_status")")" = paused ] \
    || fail "paused supervision state did not round-trip"
  [ "$(run_stage "$state" current paused-task)" = pr-open ] \
    || fail "pr-open stage did not round-trip beside paused supervision"
  [ "$(status_line_verb "$(last_status_line "$working_status")")" = working ] \
    || fail "working supervision state did not round-trip"
  [ "$(run_stage "$state" current working-task)" = validation ] \
    || fail "validation stage did not round-trip beside working supervision"
  pass "paused/pr-open and working/validation round-trip as independent axes"
}

classification_signature() {
  local line=$1 terminal=0 relevant=0 paused=0
  status_is_terminal_verb "$line" && terminal=1
  status_is_captain_relevant "$line" && relevant=1
  status_is_paused "$line" && paused=1
  printf '%s|%s|%s|%s\n' "$(status_line_verb "$line")" "$terminal" "$relevant" "$paused"
}

test_supervision_meanings_are_unchanged() {
  local actual fake_state
  actual=$(for line in \
    'working: compiling' \
    'paused: waiting on upstream' \
    'blocked: firstmate must act' \
    'needs-decision [key=choice]: captain must choose' \
    'done: checks green' \
    'failed: tests red' \
    'resolved: blocker cleared'; do
      classification_signature "$line"
    done)
  [ "$actual" = $'working|0|0|0\npaused|0|0|1\nblocked|1|1|0\nneeds-decision|1|1|0\ndone|1|1|0\nfailed|1|1|0\nresolved|0|0|0' ] \
    || fail "supervision verb meanings changed: $actual"

  fake_state="$TMP_ROOT/fake-crew-state"
  # shellcheck disable=SC2016 # The generated fixture expands this at execution time.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$FM_STAGE_TEST_CREW_STATE"\n' > "$fake_state"
  chmod +x "$fake_state"
  export FM_CREW_STATE_BIN=$fake_state
  export FM_STAGE_TEST_CREW_STATE
  FM_STAGE_TEST_CREW_STATE='state: working · source: run-step · validation running'
  [ "$(crew_absorb_class task)" = working ] || fail "working no longer absorbs as working"
  FM_STAGE_TEST_CREW_STATE='state: paused · source: status-log · bounded wait'
  [ "$(crew_absorb_class task)" = paused ] || fail "paused no longer absorbs on the long cadence"
  FM_STAGE_TEST_CREW_STATE='state: blocked · source: status-log · action required'
  [ "$(crew_absorb_class task)" = none ] || fail "blocked was incorrectly made absorbable"
  pass "the working/paused/blocked/done supervision classifier contract is unchanged"
}

test_model_matches_lifecycle
test_append_only_restart_round_trip
test_duplicate_and_backward_events_are_preserved
test_invalid_event_is_rejected_without_mutation
test_corrupt_ledger_refuses_without_mutation
test_append_failures_leave_only_complete_records
test_unterminated_valid_record_is_rejected
test_axes_round_trip_independently
test_supervision_meanings_are_unchanged

echo "# fm-stage.test.sh: all assertions passed"
