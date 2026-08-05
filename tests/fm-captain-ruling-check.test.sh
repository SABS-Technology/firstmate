#!/usr/bin/env bash
# Behavior tests for the one global registered captain-ruling watcher check.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-captain-ruling-check.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DECISION_DOC="$ROOT/docs/decision-hold-lifecycle.md"
TMP_ROOT=$(fm_test_tmproot fm-captain-ruling-check-tests)
append_reply() { # <editor> <line>
  printf '%s\n' "$2" >> "$1" || fail "could not append a reply"
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

file_links() {
  if [ "$(uname)" = Darwin ]; then stat -f %l "$1"; else stat -c %h "$1"; fi
}

write_tasks_axi() {
  local fakebin=$1
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  'ready --include-held')
    cat <<'OUT'
ready[0]{}
held[3]{id,title}
  review-decision-route,Route decision
  review-decision-access,Access decision
  spec-decision-canonicity,Ordinary canonicity work
OUT
    exit 0
    ;;
  'list --kind captain')
    cat <<'OUT'
tasks[3]{id,title}
  review-decision-route,Route decision
  review-decision-access,Access decision
  closed-decision,Closed decision
OUT
    exit 0
    ;;
  'list --state held')
    cat <<'OUT'
tasks[4]{id,title}
  review-decision-route,Route decision
  review-decision-access,Access decision
  spec-decision-canonicity,Ordinary canonicity work
  no-active-captain-hold,Crew hold
OUT
    exit 0
    ;;
esac
[ "${1:-}" = show ] && [ "${3:-}" = --full ] || exit 1
case "${2:-}" in
  review-decision-route|review-decision-access)
    key=${2##*-decision-}
    cat <<OUT
task:
  id: ${2:-}
  title: Review decision
  state: queued
  held: yes
  kind: captain
  hold_kind: captain
  hold_reason: captain reply pending
  repo: firstmate
  body: "Origin: review\\nDecision key: $key"
OUT
    ;;
  spec-decision-canonicity)
    cat <<OUT
task:
  id: spec-decision-canonicity
  title: Ordinary canonicity work
  state: queued
  held: yes
  kind: task
  hold_kind: captain
  hold_reason: captain reply pending
  repo: firstmate
  body: "Origin: spec\\nDecision key: canonicity"
OUT
    ;;
  no-active-captain-hold)
    cat <<OUT
task:
  id: no-active-captain-hold
  state: queued
  held: yes
  kind: task
  hold_kind: crew
  title: Crew hold
  hold_reason: crew reply pending
  repo: firstmate
  body: ""
OUT
    ;;
  closed-decision)
    cat <<OUT
task:
  id: closed-decision
  state: done
  held: no
  kind: captain
  hold_kind: captain
  title: Closed decision
  hold_reason: "-"
  repo: firstmate
  body: ""
OUT
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/tasks-axi"
}

test_captain_hold_on_task_kind_is_replyable() {
  local world home fakebin pending out answer
  world=$(make_home task-kind); home=${world%%|*}; fakebin=${world#*|}
  pending="$home/data/captain-replies.md"
  cat > "$pending" <<'EOF'
# Pending decisions

## ✍️ Your replies

<!-- BEGIN APPEND-ONLY: captain-replies -->
spec-decision-canonicity: approve code and tests as canonical
no-active-captain-hold: this must stay silent
<!-- END APPEND-ONLY: captain-replies -->
EOF

  out=$(run_check "$home" "$fakebin") || fail "task-kind captain-hold check failed"
  [ "$out" = 'captain-ruling spec-decision-canonicity' ] \
    || fail "ordinary-kind captain hold did not emit its ruling wake: $out"
  answer=$(read_answer "$home" "$fakebin" spec-decision-canonicity) \
    || fail "answer reader rejected an ordinary-kind captain hold"
  [ "$answer" = 'approve code and tests as canonical' ] \
    || fail "answer reader returned the wrong ordinary-kind ruling: $answer"
  pass "ordinary-kind captain holds emit ruling wakes and exact answers"
}

make_home() {
  local home="$TMP_ROOT/$1" fakebin="$TMP_ROOT/$1/fakebin"
  mkdir -p "$home/data" "$home/state" "$fakebin"
  chmod 0700 "$home/state"
  write_tasks_axi "$fakebin"
  printf '%s|%s\n' "$home" "$fakebin"
}

run_check() {
  local home=$1 fakebin=$2
  FM_HOME="$home" PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" "$CHECK"
}

read_answer() {
  local home=$1 fakebin=$2 id=$3
  FM_HOME="$home" PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    "$CHECK" --answer "$id"
}

ack_detection() {
  local home=$1 fakebin=$2 notification=$3
  FM_HOME="$home" FM_CAPTAIN_RULING_WAKE_DURABLE=1 \
    PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    "$CHECK" --ack "$notification"
}

test_global_install_is_registered() {
  local world home fakebin count
  world=$(make_home install); home=${world%%|*}; fakebin=${world#*|}
  FM_HOME="$home" PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    "$CHECK" --install || fail "global check installation failed"
  [ -f "$home/state/captain-ruling.check.sh" ] || fail "global check shim is absent"
  [ "$(file_mode "$home/state/captain-ruling.check.sh")" = 700 ] || fail "global check mode is not 0700"
  [ "$(file_links "$home/state/captain-ruling.check.sh")" = 1 ] || fail "global check is not single-link"
  [ -f "$home/state/captain-ruling.check-trust" ] || fail "global check registration is absent"
  count=$(find "$home/state" -maxdepth 1 -name '*.check.sh' -type f | wc -l | tr -d '[:space:]')
  [ "$count" = 1 ] || fail "installer published $count checks instead of one global check"
  bash -c '. "$1"; . "$2"; fm_custom_check_registered "$3" captain-ruling' _ \
    "$ROOT/bin/fm-pr-lib.sh" "$ROOT/bin/fm-check-lib.sh" "$home/state" \
    || fail "global check bytes are not registered"
  pass "one private single-link global check is registered"
}

test_global_check_identity_is_reserved() {
  local world home fakebin before_check before_trust rc
  world=$(make_home reserved-id); home=${world%%|*}; fakebin=${world#*|}
  FM_HOME="$home" PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    "$CHECK" --install || fail "global check installation failed for reservation test"
  before_check=$(shasum -a 256 "$home/state/captain-ruling.check.sh")
  before_trust=$(shasum -a 256 "$home/state/captain-ruling.check-trust")
  # shellcheck source=bin/fm-pr-lib.sh disable=SC1091
  . "$ROOT/bin/fm-pr-lib.sh"
  ! fm_task_id_creation_valid captain-ruling \
    || fail "global check identity remained valid for task creation"
  fm_write_meta "$home/state/captain-ruling.meta" \
    window=fm-captain-ruling worktree=/absent project=/absent kind=ship mode=no-mistakes
  set +e
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-pr-check.sh" captain-ruling https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 2 "$rc" "PR registration must refuse the reserved global-check identity"
  set +e
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-teardown.sh" captain-ruling --force >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 2 "$rc" "teardown must refuse the reserved global-check identity"
  [ "$(shasum -a 256 "$home/state/captain-ruling.check.sh")" = "$before_check" ] \
    && [ "$(shasum -a 256 "$home/state/captain-ruling.check-trust")" = "$before_trust" ] \
    || fail "a task lifecycle command changed the global ruling detector"
  pass "the global ruling detector identity is reserved before task check mutation"
}

test_global_install_preserves_and_releases_legacy_task_identity() {
  local world home fakebin check trust before_check before_trust rc
  world=$(make_home legacy-identity); home=${world%%|*}; fakebin=${world#*|}
  check="$home/state/captain-ruling.check.sh"
  trust="$home/state/captain-ruling.check-trust"
  fm_write_meta "$home/state/captain-ruling.meta" \
    window=fm-captain-ruling worktree=/absent project=/absent harness=codex kind=ship mode=no-mistakes
  printf '#!/usr/bin/env bash\nprintf "legacy task check\\n"\n' > "$check"
  chmod 0700 "$check"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-check-register.sh" captain-ruling >/dev/null \
    || fail "could not register the legacy task check fixture"
  before_check=$(shasum -a 256 "$check")
  before_trust=$(shasum -a 256 "$trust")

  set +e
  FM_HOME="$home" PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    "$CHECK" --install > "$home/install.out" 2> "$home/install.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "global installation overwrote a pre-upgrade task identity"
  assert_grep 'must be torn down before installation' "$home/install.err" \
    "legacy collision refusal did not name its cleanup path"
  [ "$(shasum -a 256 "$check")" = "$before_check" ] \
    && [ "$(shasum -a 256 "$trust")" = "$before_trust" ] \
    || fail "global installation changed legacy check or trust bytes"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    "$ROOT/bin/fm-teardown.sh" captain-ruling --force >/dev/null 2>&1 \
    || fail "the bounded legacy-identity teardown path failed"
  assert_absent "$home/state/captain-ruling.meta" \
    "legacy cleanup retained captain-ruling task metadata"
  assert_absent "$check" "legacy cleanup retained the task check"
  assert_absent "$trust" "legacy cleanup retained the task trust binding"
  pass "global install preserves legacy task bytes and guarded teardown releases the identity"
}

test_detection_dedupe_malformed_and_immutability() {
  local world home fakebin pending out before after started elapsed
  world=$(make_home detection); home=${world%%|*}; fakebin=${world#*|}
  pending="$home/data/captain-replies.md"
  cat > "$pending" <<'EOF'
# Pending decisions

## review-decision-route

Choose the route.

## review-decision-access

Choose the access policy.

## ✍️ Your replies

<!-- BEGIN APPEND-ONLY: captain-replies -->
<!-- Reply as <id>: <answer>. -->
review-decision-route:
unknown-decision: ignore this
closed-decision: ignore this too
<!-- END APPEND-ONLY: captain-replies -->
EOF

  out=$(run_check "$home" "$fakebin") || fail "empty-zone check failed"
  [ -z "$out" ] || fail "malformed or non-open replies woke the detector: $out"
  out=$(run_check "$home" "$fakebin") || fail "unchanged empty-zone check failed"
  [ -z "$out" ] || fail "unchanged empty-zone input woke the detector: $out"

  append_reply "$pending" 'review-decision-route: Use route north.'
  before=$(shasum -a 256 "$pending" | awk '{print $1}')
  started=$SECONDS
  out=$(run_check "$home" "$fakebin") || fail "new-ruling check failed"
  elapsed=$((SECONDS - started))
  [ "$out" = 'captain-ruling review-decision-route' ] \
    || fail "new ruling did not name its decision id: $out"
  [ "$elapsed" -lt 5 ] || fail "check took ${elapsed}s, too close to FM_CHECK_TIMEOUT"
  after=$(shasum -a 256 "$pending" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "detector mutated captain-replies.md"
  ack_detection "$home" "$fakebin" "$out" \
    || fail "durable notification acknowledgment failed"
  [ -s "$home/state/.captain-rulings-seen" ] || fail "durable seen state is absent"

  out=$(run_check "$home" "$fakebin") || fail "dedupe check failed"
  [ -z "$out" ] || fail "same answer was re-reported on the next poll: $out"
  out=$(run_check "$home" "$fakebin") || fail "second unchanged check failed"
  [ -z "$out" ] || fail "unchanged file woke a second time: $out"
  pass "new rulings wake once while malformed, unchanged, and resolved ids stay silent"
  pass "the check finishes under 5s and leaves captain-replies.md byte-identical"
}

test_detection_retries_until_durable_wake_is_acknowledged() {
  local world home fakebin pending first second third watch_out
  world=$(make_home durable-ack); home=${world%%|*}; fakebin=${world#*|}
  pending="$home/data/captain-replies.md"
  cat > "$pending" <<'EOF'
<!-- BEGIN APPEND-ONLY: captain-replies -->
review-decision-route: Use route north.
<!-- END APPEND-ONLY: captain-replies -->
EOF

  first=$(run_check "$home" "$fakebin") || fail "initial ruling detection failed"
  [ "$first" = 'captain-ruling review-decision-route' ] \
    || fail "initial ruling detection returned the wrong wake: $first"
  assert_absent "$home/state/.captain-rulings-seen" \
    "detection acknowledged a ruling before any durable wake append"

  second=$(run_check "$home" "$fakebin") || fail "retry ruling detection failed"
  [ "$second" = "$first" ] \
    || fail "a discarded detection did not re-emit on the next poll: $second"

  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  FM_HOME="$home" PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    "$CHECK" --install || fail "could not install the ruling check for watcher acknowledgment"
  watch_out="$home/watch.out"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    FM_POLL=0 FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=5 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 \
    "$WATCH" > "$watch_out" 2> "$home/watch.err" \
    || fail "watcher did not durably append and acknowledge the ruling: $(cat "$home/watch.err")"
  assert_grep 'captain-ruling review-decision-route' "$home/state/.wake-queue" \
    "watcher acknowledged the ruling without a durable wake record"
  [ -s "$home/state/.captain-rulings-seen" ] \
    || fail "watcher did not acknowledge the ruling after the durable wake append"

  third=$(run_check "$home" "$fakebin") || fail "post-acknowledgment ruling check failed"
  [ -z "$third" ] || fail "acknowledged ruling notified twice: $third"
  pass "discarded detection retries, then durable append acknowledgment dedupes"
}

test_every_malformed_resolver_state_wakes_and_recovers_after_repair() {
  local world home fakebin pending log shape before_reply before_log out
  world=$(make_home malformed-resolver-log); home=${world%%|*}; fakebin=${world#*|}
  pending="$home/data/captain-replies.md"
  log="$home/state/captain-ruling-log.tsv"
  cat > "$pending" <<'EOF'
<!-- BEGIN APPEND-ONLY: captain-replies -->
<!-- END APPEND-ONLY: captain-replies -->
EOF
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  FM_HOME="$home" PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    "$CHECK" --install || fail "could not install the detector for malformed-log coverage"

  for shape in unsafe-storage malformed-record torn-reply torn-commit; do
    case "$shape" in
      unsafe-storage)
        printf 'REPLY\treview-decision-route\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t-\n' > "$log"
        chmod 0644 "$log"
        ;;
      malformed-record)
        printf 'BROKEN\n' > "$log"
        chmod 0600 "$log"
        ;;
      torn-reply)
        printf 'REPLY\treview-decision-route\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t-' > "$log"
        chmod 0600 "$log"
        ;;
      torn-commit)
        printf 'COMMIT\treview-decision-route\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' > "$log"
        chmod 0600 "$log"
        ;;
    esac
    rm -f "$home/state/.wake-queue"
    before_reply=$(shasum -a 256 "$pending")
    before_log=$(shasum -a 256 "$log")
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
      FM_POLL=0 FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=5 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 \
      perl -e 'alarm shift; exec @ARGV' 10 "$WATCH" > "$home/watch.out" 2> "$home/watch.err" \
      || fail "watcher failed while surfacing $shape resolver state"
    [ "$(grep -Fc 'captain-ruling-error resolver-log-invalid' "$home/state/.wake-queue")" -eq 1 ] \
      || fail "$shape resolver state did not produce one durable supervisor wake"
    [ "$(shasum -a 256 "$pending")" = "$before_reply" ] \
      && [ "$(shasum -a 256 "$log")" = "$before_log" ] \
      || fail "$shape detection changed captain input or repaired the resolver log"
  done

  : > "$log"
  chmod 0600 "$log"
  cat > "$pending" <<'EOF'
<!-- BEGIN APPEND-ONLY: captain-replies -->
review-decision-route: Use route north.
<!-- END APPEND-ONLY: captain-replies -->
EOF
  out=$(run_check "$home" "$fakebin") || fail "detector did not recover after explicit log repair"
  [ "$out" = 'captain-ruling review-decision-route' ] \
    || fail "explicit repair did not restore ruling detection: $out"
  pass "every malformed resolver-state class wakes durably without mutation, then explicit repair restores detection"
}

test_partial_reply_region_waits_for_completion() {
  local world home fakebin pending out
  world=$(make_home partial); home=${world%%|*}; fakebin=${world#*|}
  pending="$home/data/captain-replies.md"
  printf '# Pending decisions\n\n## ✍️ Your replies\n%s\nreview-decision-access: Restrict' \
    "$REPLY_BEGIN" > "$pending"
  out=$(run_check "$home" "$fakebin") || fail "partial-region check failed"
  [ -z "$out" ] || fail "half-written reply region woke the detector: $out"

  printf '%s\n' " access.$REPLY_END" >> "$pending"
  out=$(run_check "$home" "$fakebin") || fail "glued-marker check failed"
  [ -z "$out" ] || fail "a reply glued to a malformed end marker woke the detector: $out"

  printf '# Pending decisions\n\n## ✍️ Your replies\n%s\nreview-decision-access: Restrict access.\n%s\n' \
    "$REPLY_BEGIN" "$REPLY_END" > "$pending"
  out=$(run_check "$home" "$fakebin") || fail "completed-region check failed"
  [ "$out" = 'captain-ruling review-decision-access' ] \
    || fail "completed reply region was not detected: $out"
  pass "a half-written or malformed reply region waits until the markers close it"
}

test_detection_survives_heading_moves_and_renames() {
  local world home fakebin pending out answer
  world=$(make_home heading-drift); home=${world%%|*}; fakebin=${world#*|}
  pending="$home/data/captain-replies.md"
  cat > "$pending" <<'EOF'
# Pending decisions

## 🧭 Captain rulings

Prose the captain is free to rewrite.

<!-- BEGIN APPEND-ONLY: captain-replies -->
review-decision-route: approve code and tests as canonical
<!-- END APPEND-ONLY: captain-replies -->

## ✍️ Your replies

review-decision-route: this decoy sits outside the append-only region
EOF

  out=$(run_check "$home" "$fakebin") || fail "renamed-heading check failed"
  [ "$out" = 'captain-ruling review-decision-route' ] \
    || fail "renaming or moving the heading changed which replies are detected: $out"
  answer=$(read_answer "$home" "$fakebin" review-decision-route) \
    || fail "answer reader failed after the heading moved"
  [ "$answer" = 'approve code and tests as canonical' ] \
    || fail "answer reader read outside the append-only region: $answer"

  cat > "$pending" <<'EOF'
# Pending decisions

## ✍️ Your replies

review-decision-route: approve code and tests as canonical
EOF
  out=$(run_check "$home" "$fakebin") || fail "markerless check failed"
  [ -z "$out" ] || fail "a heading without the append-only markers woke the detector: $out"
  pass "detection follows the append-only markers, not any heading"
}

test_answer_reads_latest_complete_open_ruling_without_mutation() {
  local world home fakebin pending before after answer
  world=$(make_home answer); home=${world%%|*}; fakebin=${world#*|}
  pending="$home/data/captain-replies.md"
  cat > "$pending" <<'EOF'
# Pending decisions

## ✍️ Your replies

<!-- BEGIN APPEND-ONLY: captain-replies -->
review-decision-route: Use route north.
review-decision-access: Restrict access.
review-decision-route: Use route south instead.
closed-decision: Ignore a closed answer.
<!-- END APPEND-ONLY: captain-replies -->
EOF
  before=$(shasum -a 256 "$pending" | awk '{print $1}')
  answer=$(read_answer "$home" "$fakebin" review-decision-route) \
    || fail "answer reader failed for an active captain hold"
  [ "$answer" = 'Use route south instead.' ] \
    || fail "answer reader did not return the latest complete ruling: $answer"
  after=$(shasum -a 256 "$pending" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "answer reader mutated captain-replies.md"
  assert_absent "$home/state/.captain-rulings-seen" \
    "answer reader mutated ruling-notification state"
  if read_answer "$home" "$fakebin" closed-decision > "$home/closed.out" 2> "$home/closed.err"; then
    fail "answer reader accepted a closed captain decision"
  fi
  if read_answer "$home" "$fakebin" missing-decision > "$home/missing.out" 2> "$home/missing.err"; then
    fail "answer reader accepted an absent captain decision"
  fi
  pass "answer reader returns the latest complete open ruling without changing captain input"
}

test_answer_ingestion_refuses_while_resolution_lock_is_held() {
  local world home fakebin pending lock
  world=$(make_home serialized-answer); home=${world%%|*}; fakebin=${world#*|}
  pending="$home/data/captain-replies.md"
  cat > "$pending" <<'EOF'
<!-- BEGIN APPEND-ONLY: captain-replies -->
review-decision-route: Use route north.
<!-- END APPEND-ONLY: captain-replies -->
EOF
  export FM_HOME="$home"
  export FM_STATE_OVERRIDE="$home/state"
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$ROOT/bin/fm-wake-lib.sh"
  lock="$home/state/.captain-ruling-resolution.lock"
  fm_lock_try_acquire "$lock" || fail "could not hold the ruling-resolution lock fixture"
  if read_answer "$home" "$fakebin" review-decision-route \
    > "$home/locked.out" 2> "$home/locked.err"; then
    fm_lock_release "$lock"
    fail "answer ingestion bypassed an active ruling-resolution lock"
  fi
  fm_lock_release "$lock"
  read_answer "$home" "$fakebin" review-decision-route >/dev/null \
    || fail "answer ingestion did not resume after ruling resolution released its lock"
  pass "reply ingestion serializes with active ruling resolution"
}

test_file_ruling_channel_declares_accepted_untrusted_boundary() {
  assert_grep "not authenticated" "$CHECK" \
    "ruling detector code does not declare the unauthenticated file channel"
  assert_grep "compromised local process can fabricate" "$CHECK" \
    "ruling detector code does not name the accepted fabrication risk"
  assert_no_grep "trusted target" "$CHECK" \
    "ruling detector still describes the file-backed channel as trusted"
  assert_grep "compromised local process can fabricate" "$DECISION_DOC" \
    "decision lifecycle docs omit the accepted local fabrication risk"
  assert_grep "human detection" "$DECISION_DOC" \
    "decision lifecycle docs omit the human detection boundary"
  assert_grep "chat or Linear" "$DECISION_DOC" \
    "decision lifecycle docs do not keep the queue file in its fallback role"
  pass "file-backed ruling channel declares its accepted untrusted boundary"
}

test_global_install_is_registered
test_global_check_identity_is_reserved
test_global_install_preserves_and_releases_legacy_task_identity
test_detection_dedupe_malformed_and_immutability
test_detection_retries_until_durable_wake_is_acknowledged
test_every_malformed_resolver_state_wakes_and_recovers_after_repair
test_captain_hold_on_task_kind_is_replyable
test_answer_reads_latest_complete_open_ruling_without_mutation
test_answer_ingestion_refuses_while_resolution_lock_is_held
test_file_ruling_channel_declares_accepted_untrusted_boundary
