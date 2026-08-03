#!/usr/bin/env bash
# Behavior tests for the one global registered captain-ruling watcher check.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-captain-ruling-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-ruling-check-tests)

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
[ "${1:-}" = show ] && [ "${3:-}" = --full ] || exit 1
case "${2:-}" in
  review-decision-route|review-decision-access)
    cat <<OUT
task:
  id: ${2:-}
  state: queued
  held: yes
  kind: captain
  hold_kind: captain
OUT
    ;;
  spec-canonicity-policy)
    cat <<OUT
task:
  id: spec-canonicity-policy
  state: queued
  held: yes
  kind: task
  hold_kind: captain
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
OUT
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/tasks-axi"
}

test_captain_hold_on_task_kind_is_detected() {
  local world home fakebin pending out
  world=$(make_home task-kind); home=${world%%|*}; fakebin=${world#*|}
  pending="$home/data/pending-decisions.md"
  cat > "$pending" <<'EOF'
# Pending decisions

## ✍️ Your replies

spec-canonicity-policy: approve code and tests as canonical
no-active-captain-hold: this must stay silent
EOF

  out=$(run_check "$home" "$fakebin") || fail "task-kind captain-hold check failed"
  [ "$out" = 'captain-ruling spec-canonicity-policy' ] \
    || fail "active captain hold on kind=task was not detected or non-captain hold leaked: $out"
  pass "active captain holds are accepted on any task kind while other holds stay silent"
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

test_detection_dedupe_malformed_and_immutability() {
  local world home fakebin pending out before after started elapsed
  world=$(make_home detection); home=${world%%|*}; fakebin=${world#*|}
  pending="$home/data/pending-decisions.md"
  cat > "$pending" <<'EOF'
# Pending decisions

## review-decision-route

Choose the route.

## review-decision-access

Choose the access policy.

## ✍️ Your replies

<!-- Reply as <id>: <answer>. -->
review-decision-route:
unknown-decision: ignore this
closed-decision: ignore this too
EOF

  out=$(run_check "$home" "$fakebin") || fail "empty-zone check failed"
  [ -z "$out" ] || fail "malformed or non-open replies woke the detector: $out"
  out=$(run_check "$home" "$fakebin") || fail "unchanged empty-zone check failed"
  [ -z "$out" ] || fail "unchanged empty-zone input woke the detector: $out"

  printf '%s\n' 'review-decision-route: Use route north.' >> "$pending"
  before=$(shasum -a 256 "$pending" | awk '{print $1}')
  started=$SECONDS
  out=$(run_check "$home" "$fakebin") || fail "new-ruling check failed"
  elapsed=$((SECONDS - started))
  [ "$out" = 'captain-ruling review-decision-route' ] \
    || fail "new ruling did not name its decision id: $out"
  [ "$elapsed" -lt 5 ] || fail "check took ${elapsed}s, too close to FM_CHECK_TIMEOUT"
  after=$(shasum -a 256 "$pending" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "detector mutated pending-decisions.md"
  [ -s "$home/state/.captain-rulings-seen" ] || fail "durable seen state is absent"

  out=$(run_check "$home" "$fakebin") || fail "dedupe check failed"
  [ -z "$out" ] || fail "same answer was re-reported on the next poll: $out"
  out=$(run_check "$home" "$fakebin") || fail "second unchanged check failed"
  [ -z "$out" ] || fail "unchanged file woke a second time: $out"
  pass "new rulings wake once while malformed, unchanged, and resolved ids stay silent"
  pass "the check finishes under 5s and leaves pending-decisions.md byte-identical"
}

test_partial_final_line_waits_for_completion() {
  local world home fakebin pending out
  world=$(make_home partial); home=${world%%|*}; fakebin=${world#*|}
  pending="$home/data/pending-decisions.md"
  printf '# Pending decisions\n\n## ✍️ Your replies\nreview-decision-access: Restrict' > "$pending"
  out=$(run_check "$home" "$fakebin") || fail "partial-line check failed"
  [ -z "$out" ] || fail "unterminated half-typed line woke the detector: $out"
  printf '%s\n' ' access.' >> "$pending"
  out=$(run_check "$home" "$fakebin") || fail "completed-line check failed"
  [ "$out" = 'captain-ruling review-decision-access' ] \
    || fail "completed line was not detected: $out"
  pass "an unterminated half-typed reply waits until the line is complete"
}

test_global_install_is_registered
test_detection_dedupe_malformed_and_immutability
test_partial_final_line_waits_for_completion
test_captain_hold_on_task_kind_is_detected
