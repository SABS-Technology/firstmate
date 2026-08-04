#!/usr/bin/env bash
# Behavior tests for the one global registered captain-ruling watcher check.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-captain-ruling-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-ruling-check-tests)
REPLY_BEGIN='<!-- BEGIN APPEND-ONLY: captain-replies -->'
REPLY_END='<!-- END APPEND-ONLY: captain-replies -->'

# Appends one reply line inside the append-only region, exactly where
# bin/fm-pending-decisions-generate.sh puts generated reply prefixes.
append_reply() { # <pending> <line>
  local pending=$1 line=$2 tmp="$1.append"
  awk -v end="$REPLY_END" -v line="$line" '
    $0 == end { print line }
    { print }
  ' "$pending" > "$tmp" || fail "could not stage a reply append"
  mv "$tmp" "$pending" || fail "could not append a reply"
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

test_captain_hold_on_task_kind_is_not_replyable() {
  local world home fakebin pending out
  world=$(make_home task-kind); home=${world%%|*}; fakebin=${world#*|}
  pending="$home/data/pending-decisions.md"
  cat > "$pending" <<'EOF'
# Pending decisions

## ✍️ Your replies

<!-- BEGIN APPEND-ONLY: captain-replies -->
spec-decision-canonicity: approve code and tests as canonical
no-active-captain-hold: this must stay silent
<!-- END APPEND-ONLY: captain-replies -->
EOF

  out=$(run_check "$home" "$fakebin") || fail "task-kind captain-hold check failed"
  [ -z "$out" ] \
    || fail "ordinary-kind captain hold emitted an unprocessable ruling wake: $out"
  if read_answer "$home" "$fakebin" spec-decision-canonicity \
    > "$home/ordinary.out" 2> "$home/ordinary.err"; then
    fail "answer reader accepted an ordinary-kind captain hold"
  fi
  pass "ordinary-kind captain holds cannot emit ruling wakes or answers"
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
  [ "$before" = "$after" ] || fail "detector mutated pending-decisions.md"
  [ -s "$home/state/.captain-rulings-seen" ] || fail "durable seen state is absent"

  out=$(run_check "$home" "$fakebin") || fail "dedupe check failed"
  [ -z "$out" ] || fail "same answer was re-reported on the next poll: $out"
  out=$(run_check "$home" "$fakebin") || fail "second unchanged check failed"
  [ -z "$out" ] || fail "unchanged file woke a second time: $out"
  pass "new rulings wake once while malformed, unchanged, and resolved ids stay silent"
  pass "the check finishes under 5s and leaves pending-decisions.md byte-identical"
}

test_partial_reply_region_waits_for_completion() {
  local world home fakebin pending out
  world=$(make_home partial); home=${world%%|*}; fakebin=${world#*|}
  pending="$home/data/pending-decisions.md"
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
  pending="$home/data/pending-decisions.md"
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
  pending="$home/data/pending-decisions.md"
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
  printf '%s' 'review-decision-route: this trailing draft sits outside the region' >> "$pending"

  before=$(shasum -a 256 "$pending" | awk '{print $1}')
  answer=$(read_answer "$home" "$fakebin" review-decision-route) \
    || fail "answer reader failed for an active captain hold"
  [ "$answer" = 'Use route south instead.' ] \
    || fail "answer reader did not return the latest complete ruling: $answer"
  after=$(shasum -a 256 "$pending" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "answer reader mutated pending-decisions.md"
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

test_global_install_is_registered
test_detection_dedupe_malformed_and_immutability
test_partial_reply_region_waits_for_completion
test_detection_survives_heading_moves_and_renames
test_captain_hold_on_task_kind_is_not_replyable
test_answer_reads_latest_complete_open_ruling_without_mutation
