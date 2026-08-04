#!/usr/bin/env bash
# End-to-end tests for durable captain-held decisions discovered by investigations
# and visual reviews.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
CAPTAIN_QUEUE="$ROOT/bin/fm-captain-queue.sh"
RULING_CHECK="$ROOT/bin/fm-captain-ruling-check.sh"
PENDING_GENERATOR="$ROOT/bin/fm-pending-decisions-generate.sh"
DECISION_SKILL="$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md"
AGENTS="$ROOT/AGENTS.md"
TMP_ROOT=$(fm_test_tmproot fm-decision-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$$" > "$home/state/.lock"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved decision is report prose,
# no held backlog item or open status exists, and the authoritative Bearings view
# correctly omits it. Completion must now refuse before teardown can erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-scratch" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-decision regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved decision"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved decision is reproduced and completion refuses before loss"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  if [ "${1:-}" = resolve ] && [ "${FM_TEST_OMIT_DECISION_POINTER:-0}" != 1 ]; then
    local origin=${2:-} key=${3:-} hold pointer previous='' argument
    hold="$origin-decision-$key"
    pointer="data/decisions/$hold.md"
    for argument in "$@"; do
      if [ "$previous" = --routed-to ]; then
        mkdir -p "$home/data/$argument"
        if [ ! -f "$home/data/$argument/brief.md" ] \
          || ! grep -Fqx "Decision record: $pointer" "$home/data/$argument/brief.md"; then
          printf 'Decision record: %s\n' "$pointer" >> "$home/data/$argument/brief.md"
        fi
      fi
      previous=$argument
    done
  fi
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind"
}

test_structured_holds_survive_teardown_and_route_resolution() {
  local home id route_hold access_hold before after json open show
  home=$(make_home durable-lifecycle)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
done: report and visual review complete
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_decisions "$home" complete "$id" route access > "$home/early-complete.out" 2> "$home/early-complete.err"; then
    fail "completion succeeded before unresolved decisions had captain holds"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"

  route_hold=$(run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register route hold"
  [ "$route_hold" = "$id-decision-route" ] || fail "route hold identity was not deterministic: $route_hold"
  run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  if run_decisions "$home" complete "$id" route access > "$home/partial-complete.out" 2> "$home/partial-complete.err"; then
    fail "completion succeeded while one of two distinct decisions lacked a hold"
  fi
  access_hold=$(run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample) \
    || fail "could not register access hold"
  [ "$access_hold" = "$id-decision-access" ] || fail "access hold identity was not distinct: $access_hold"
  [ "$(grep -cE "^- \[ \] $route_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the route hold"
  [ "$(grep -cE "^- \[ \] $access_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "second decision did not retain one distinct backlog identity"

  run_decisions "$home" complete "$id" route access >/dev/null \
    || fail "shared investigation completion gate failed"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=access,route" "$home/state/$id.meta" "decision inventory was not deterministic"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close duplicate live status decisions: $open"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with captain-held decisions"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold" and .owner == "(main)"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == $route or .id == $access) | not)
  ' >/dev/null || fail "Bearings did not surface structured captain holds: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  ! grep -E "^- \[[ x]\] $id -" "$home/data/backlog.md" >/dev/null \
    || fail "origin remained in the live backlog after archival"
  grep -E "^- \[x\] $id -" "$home/data/done-archive.md" >/dev/null \
    || fail "origin was not durably archived"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held decision: $json"

  tasks_in "$home" add sample-route-implementation "Apply the selected sample route" \
    --kind ship --repo sample >/dev/null \
    || fail "could not create dependent work fixture"
  mkdir -p "$home/data/decisions"
  printf 'Use route north for the sample system.\n' > "$home/data/decisions/$route_hold.md"
  write_captain_reply "$home" "$route_hold" 'Use route north for the sample system.'
  if run_decisions "$home" resolve "$id" route --decision-file "$home/data/decisions/$route_hold.md" \
    --routed-to sample-route-implementation > "$home/early-resolve.out" 2> "$home/early-resolve.err"; then
    fail "captain hold closed before dependent work had a durable routing edge"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "failed routing attempt closed the hold"
  assert_contains "$show" "held: yes" "failed routing attempt released the hold"
  tasks_in "$home" block sample-route-implementation --by "$route_hold" >/dev/null \
    || fail "could not route dependent work behind the decision hold"
  tasks_in "$home" add sample-route-followup "Check the selected sample route" \
    --kind ship --repo sample --blocked-by "$route_hold" >/dev/null \
    || fail "could not create second dependent work fixture"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = unblock ] && [ "${2:-}" = sample-route-implementation ] \
  && [ ! -f "$FM_HOME/unblock-failed-once" ]; then
  : > "$FM_HOME/unblock-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/data/decisions/$route_hold.md" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-route.out" 2> "$home/partial-route.err"; then
    fail "resolution succeeded after a partial dependent-routing failure"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "partial routing failure closed the hold"
  show=$(tasks_in "$home" show sample-route-followup --full)
  assert_contains "$show" "blocked: no" "partial routing fixture did not release its first dependent"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: yes" "partial routing fixture unexpectedly released its second dependent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/data/decisions/$route_hold.md" \
    --routed-to sample-route-followup > "$home/reduced-retry.out" 2> "$home/reduced-retry.err"; then
    fail "partial resolution retry accepted a reduced routed task set"
  fi
  printf 'Use route south for the sample system.\n' > "$home/data/decisions/$route_hold.md"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/data/decisions/$route_hold.md" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-drifted-decision.out" 2> "$home/partial-drifted-decision.err"; then
    fail "partial resolution retry accepted a different captain decision"
  fi
  printf 'Use route north for the sample system.\n' > "$home/data/decisions/$route_hold.md"
  tasks_in "$home" "done" sample-route-followup >/dev/null \
    || fail "could not complete already-routed dependent work"
  run_decisions "$home" resolve "$id" route --decision-file "$home/data/decisions/$route_hold.md" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "could not resume and complete partial decision routing"
  run_decisions "$home" resolve "$id" route --decision-file "$home/data/decisions/$route_hold.md" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "identical resolution retry was not idempotent"
  printf 'Use route south for the sample system.\n' > "$home/data/decisions/$route_hold.md"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/data/decisions/$route_hold.md" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/drifted-decision.out" 2> "$home/drifted-decision.err"; then
    fail "resolution retry accepted a different captain decision"
  fi
  printf 'Use route north for the sample system.\n' > "$home/data/decisions/$route_hold.md"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/data/decisions/$route_hold.md" \
    --routed-to sample-route-implementation \
    > "$home/drifted-routes.out" 2> "$home/drifted-routes.err"; then
    fail "resolution retry accepted a different routed task set"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: done" "resolved hold did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "resolved hold lost the decision record"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: no" "recorded decision did not release dependent work"
  json=$(run_bearings "$home") || fail "Bearings failed after decision resolution"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route) | not)
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.gates | any(.id == "sample-route-implementation"))
      and (.decisions_open | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "resolved or decision-like report prose produced a false hold: $json"
  pass "captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close"
}

test_scout_teardown_always_requires_inventory_verification() {
  local home id
  home=$(make_home unconditional-teardown)
  id=sample-absent-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample absent review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  if run_teardown "$home" "$id" > "$home/absent-teardown.out" 2> "$home/absent-teardown.err"; then
    fail "scout teardown skipped verification when its backlog task was absent"
  fi
  assert_present "$home/state/$id.meta" "refused absent-task teardown removed metadata"

  home=$(make_home unavailable-teardown)
  id=sample-unavailable-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample unavailable review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_teardown "$home" "$id" > "$home/unavailable-teardown.out" 2> "$home/unavailable-teardown.err"; then
    fail "scout teardown skipped verification when tasks-axi was unavailable"
  fi
  assert_present "$home/state/$id.meta" "refused unavailable-task teardown removed metadata"
  pass "non-forced scout teardown always requires durable inventory verification"
}

test_origin_slug_validation_precedes_path_construction() {
  local home escaped
  home=$(make_home origin-validation)
  escaped="$home/escaped-origin.meta"
  printf 'sentinel=unchanged\n' > "$escaped"
  if run_decisions "$home" complete ../escaped-origin --none \
    > "$home/invalid-complete.out" 2> "$home/invalid-complete.err"; then
    fail "completion accepted an origin path traversal"
  fi
  if run_decisions "$home" verify ../escaped-origin \
    > "$home/invalid-verify.out" 2> "$home/invalid-verify.err"; then
    fail "verification accepted an origin path traversal"
  fi
  [ "$(cat "$escaped")" = "sentinel=unchanged" ] \
    || fail "invalid origin changed metadata outside the state directory"
  pass "completion and verification validate origins before constructing paths"
}

test_visual_review_uses_shared_completion_owner() {
  local home id hold json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  hold=$(run_decisions "$home" hold "$id" layout \
    --title "Choose the sample layout" --reason "captain layout choice pending" --repo sample) \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_decisions "$home" complete "$id" layout >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  [ "$hold" = "$id-decision-layout" ] || fail "visual review used a separate identity policy"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.id == $hold and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same decision-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-decision inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-decision inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false hold: $json"
  pass "resolved findings and decision-like prose do not create false holds"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_decisions "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate origin hold json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  hold=$(run_decisions "$mate" hold "$origin" release \
    --title "Choose the sample release" --reason "captain release choice pending" --repo sample) \
    || fail "secondmate-owned hold creation failed"
  run_decisions "$mate" complete "$origin" release >/dev/null \
    || fail "secondmate-owned completion failed"
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  json=$(run_bearings "$parent") || fail "parent Bearings could not read secondmate hold"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold" and (.id | endswith($hold)))
  ' >/dev/null || fail "secondmate captain hold did not surface with authoritative owner: $json"
  assert_no_grep "$hold" "$parent/data/backlog.md" "secondmate hold leaked into the main backlog"
  assert_grep "$hold" "$mate/data/backlog.md" "secondmate hold left its authoritative backlog"
  pass "main-home and secondmate-home captain holds remain correctly routed"
}

# tasks-axi quotes multi-entry blocked_by values as "a,b,c". resolve must strip
# those surrounding quotes before comma-boundary membership so the first and last
# list elements match, not only middle elements.
test_resolve_matches_quoted_blocked_by_edges() {
  local home origin hold_first hold_mid hold_last hold_absent show
  home=$(make_home quoted-blocked-by-edges)
  origin=sample-quote-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Quoted blocked_by edge review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create quote-edge origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Quote edge review\n\nThree edge decisions and one absent control.\n' > "$home/data/$origin/report.md"

  hold_first=$(run_decisions "$home" hold "$origin" edge-first \
    --title "First edge decision" --reason "captain first pending" --repo sample) \
    || fail "could not register first-edge hold"
  hold_mid=$(run_decisions "$home" hold "$origin" edge-mid \
    --title "Middle edge decision" --reason "captain mid pending" --repo sample) \
    || fail "could not register mid-edge hold"
  hold_last=$(run_decisions "$home" hold "$origin" edge-last \
    --title "Last edge decision" --reason "captain last pending" --repo sample) \
    || fail "could not register last-edge hold"
  hold_absent=$(run_decisions "$home" hold "$origin" edge-absent \
    --title "Absent edge decision" --reason "captain absent pending" --repo sample) \
    || fail "could not register absent-edge hold"

  tasks_in "$home" add pad-a "Pad A" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-a blocker"
  tasks_in "$home" add pad-b "Pad B" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-b blocker"

  tasks_in "$home" add dep-first "Dep first position" --kind ship --repo sample >/dev/null \
    || fail "could not create first-position dependent"
  tasks_in "$home" block dep-first --by "$hold_first" >/dev/null || fail "could not block dep-first by first hold"
  tasks_in "$home" block dep-first --by pad-a >/dev/null || fail "could not block dep-first by pad-a"
  tasks_in "$home" block dep-first --by pad-b >/dev/null || fail "could not block dep-first by pad-b"
  show=$(tasks_in "$home" show dep-first --full)
  assert_contains "$show" "blocked_by: \"$hold_first,pad-a,pad-b\"" \
    "first-position fixture must quote multi-entry blocked_by"
  mkdir -p "$home/data/decisions"
  printf 'Decide first edge.\n' > "$home/data/decisions/$hold_first.md"
  write_captain_reply "$home" "$hold_first" 'Decide first edge.'
  if ! run_decisions "$home" resolve "$origin" edge-first --decision-file "$home/data/decisions/$hold_first.md" \
    --routed-to dep-first > "$home/first.out" 2> "$home/first.err"; then
    fail "resolve failed when hold id is FIRST in quoted blocked_by: $(cat "$home/first.err")"
  fi

  tasks_in "$home" add dep-mid "Dep mid position" --kind ship --repo sample >/dev/null \
    || fail "could not create mid-position dependent"
  tasks_in "$home" block dep-mid --by pad-a >/dev/null || fail "could not block dep-mid by pad-a"
  tasks_in "$home" block dep-mid --by "$hold_mid" >/dev/null || fail "could not block dep-mid by mid hold"
  tasks_in "$home" block dep-mid --by pad-b >/dev/null || fail "could not block dep-mid by pad-b"
  show=$(tasks_in "$home" show dep-mid --full)
  assert_contains "$show" "blocked_by: \"pad-a,$hold_mid,pad-b\"" \
    "middle-position fixture must quote multi-entry blocked_by"
  printf 'Decide mid edge.\n' > "$home/data/decisions/$hold_mid.md"
  write_captain_reply "$home" "$hold_mid" 'Decide mid edge.'
  if ! run_decisions "$home" resolve "$origin" edge-mid --decision-file "$home/data/decisions/$hold_mid.md" \
    --routed-to dep-mid > "$home/mid.out" 2> "$home/mid.err"; then
    fail "resolve failed when hold id is MIDDLE in quoted blocked_by: $(cat "$home/mid.err")"
  fi

  tasks_in "$home" add dep-last "Dep last position" --kind ship --repo sample >/dev/null \
    || fail "could not create last-position dependent"
  tasks_in "$home" block dep-last --by pad-a >/dev/null || fail "could not block dep-last by pad-a"
  tasks_in "$home" block dep-last --by pad-b >/dev/null || fail "could not block dep-last by pad-b"
  tasks_in "$home" block dep-last --by "$hold_last" >/dev/null || fail "could not block dep-last by last hold"
  show=$(tasks_in "$home" show dep-last --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b,$hold_last\"" \
    "last-position fixture must quote multi-entry blocked_by"
  printf 'Decide last edge.\n' > "$home/data/decisions/$hold_last.md"
  write_captain_reply "$home" "$hold_last" 'Decide last edge.'
  if ! run_decisions "$home" resolve "$origin" edge-last --decision-file "$home/data/decisions/$hold_last.md" \
    --routed-to dep-last > "$home/last.out" 2> "$home/last.err"; then
    fail "resolve failed when hold id is LAST in quoted blocked_by: $(cat "$home/last.err")"
  fi

  tasks_in "$home" add dep-absent "Dep absent control" --kind ship --repo sample >/dev/null \
    || fail "could not create absent-control dependent"
  tasks_in "$home" block dep-absent --by pad-a >/dev/null || fail "could not block dep-absent by pad-a"
  tasks_in "$home" block dep-absent --by pad-b >/dev/null || fail "could not block dep-absent by pad-b"
  show=$(tasks_in "$home" show dep-absent --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b\"" \
    "absent-control fixture must quote multi-entry blocked_by without the hold id"
  printf 'Decide absent edge.\n' > "$home/data/decisions/$hold_absent.md"
  if run_decisions "$home" resolve "$origin" edge-absent --decision-file "$home/data/decisions/$hold_absent.md" \
    --routed-to dep-absent > "$home/absent.out" 2> "$home/absent.err"; then
    fail "resolve succeeded when hold id is genuinely absent from blocked_by"
  fi
  assert_grep "not durably blocked by" "$home/absent.err" \
    "absent id must fail with durable-block error"
  show=$(tasks_in "$home" show "$hold_absent" --full)
  assert_contains "$show" "state: queued" "failed absent resolve must leave the hold open"
  assert_contains "$show" "held: yes" "failed absent resolve must leave the hold held"

  pass "resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id"
}

test_detected_ruling_becomes_work_before_hold_closes() {
  local home origin key hold wake answer record dependent show queue
  home=$(make_home ruling-round-trip)
  origin=sample-ruling-review
  key=route
  dependent=sample-ruling-implementation
  mkdir -p "$home/data/$origin" "$home/data/decisions"
  tasks_in "$home" add "$origin" "Review sample ruling route" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create ruling-round-trip origin"
  write_origin_meta "$home" "$origin"
  printf '# Sample ruling review\n\nThe captain must select the route.\n' \
    > "$home/data/$origin/report.md"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the sample ruling route" \
    --reason "captain sample route pending" --repo sample) \
    || fail "could not create ruling-round-trip hold"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "could not complete ruling-round-trip inventory"
  cat > "$home/data/pending-decisions.md" <<EOF
# Captain decisions

## ✍️ Your replies

<!-- BEGIN APPEND-ONLY: captain-replies -->
$hold: Use the east route.
<!-- END APPEND-ONLY: captain-replies -->
EOF

  wake=$(FM_HOME="$home" "$RULING_CHECK") \
    || fail "ruling detector failed in the round-trip fixture"
  [ "$wake" = "captain-ruling $hold" ] \
    || fail "ruling detector did not identify the held decision: $wake"
  answer=$(FM_HOME="$home" "$RULING_CHECK" --answer "$hold") \
    || fail "agent turn could not read the exact captain ruling"
  [ "$answer" = 'Use the east route.' ] \
    || fail "agent turn read the wrong captain ruling: $answer"

  record="$home/data/decisions/$hold.md"
  printf '%s\n' "$answer" > "$record"
  chmod 0600 "$record"
  tasks_in "$home" add "$dependent" "Apply the captain-selected sample route" \
    --kind ship --repo sample --body "Decision record: data/decisions/$hold.md" \
    --blocked-by "$hold" >/dev/null \
    || fail "agent turn could not create dependent work behind the hold"
  run_decisions "$home" resolve "$origin" "$key" --decision-file "$record" \
    --routed-to "$dependent" >/dev/null \
    || fail "agent-authored work and decision record did not close the hold"

  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "round-trip did not close the captain hold"
  assert_contains "$show" "Captain decision:\\nUse the east route." \
    "round-trip did not retain the exact captain ruling"
  assert_contains "$show" "Routed work:\\n- $dependent" \
    "round-trip did not retain the dependent work identity"
  show=$(tasks_in "$home" show "$dependent" --full)
  assert_contains "$show" "blocked: no" \
    "dependent work was not released after the decision record became durable"
  assert_contains "$show" "Decision record: data/decisions/$hold.md" \
    "dependent work lost its durable decision-record pointer"
  assert_present "$record" "round-trip removed the on-disk decision record"
  queue=$(FM_HOME="$home" "$CAPTAIN_QUEUE" --json) \
    || fail "canonical captain queue failed after round-trip ingestion"
  printf '%s' "$queue" | jq -e --arg hold "$hold" \
    'all(.items[]; .id != $hold)' >/dev/null \
    || fail "closed captain hold remained in the canonical queue: $queue"
  pass "a detected ruling becomes durable dependent work before its hold closes"
}

test_rehold_requires_canonical_identity_fields() {
  local home origin=sample-collision-review key=route hold title show queue
  hold="$origin-decision-$key"
  title="Choose the collision route"

  home=$(make_home malformed-hold-identity)
  mkdir -p "$home/data/$origin"
  write_origin_meta "$home" "$origin"
  tasks_in "$home" add "$hold" "$title" --kind captain --repo sample \
    --body "Not canonical lifecycle data." >/dev/null
  if run_decisions "$home" hold "$origin" "$key" --title "$title" \
    --reason "captain route pending" --repo sample \
    > "$home/malformed.out" 2> "$home/malformed.err"; then
    fail "re-hold accepted an identity with missing canonical body fields"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "held: no" "malformed identity was activated before refusal"

  home=$(make_home conflicting-hold-identity)
  mkdir -p "$home/data/$origin"
  write_origin_meta "$home" "$origin"
  tasks_in "$home" add "$hold" "$title" --kind captain --repo sample \
    --body $'Origin: different-origin\nDecision key: route\nState: awaiting captain decision.' >/dev/null
  if run_decisions "$home" hold "$origin" "$key" --title "$title" \
    --reason "captain route pending" --repo sample \
    > "$home/conflicting.out" 2> "$home/conflicting.err"; then
    fail "re-hold accepted conflicting canonical identity fields"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "held: no" "conflicting identity was activated before refusal"

  home=$(make_home canonical-hold-identity)
  mkdir -p "$home/data/$origin"
  write_origin_meta "$home" "$origin"
  run_decisions "$home" hold "$origin" "$key" --title "$title" \
    --reason "captain route pending" --repo sample >/dev/null \
    || fail "could not create canonical hold identity"
  run_decisions "$home" hold "$origin" "$key" --title "$title" \
    --reason "captain route pending" --repo sample >/dev/null \
    || fail "canonical existing hold was not idempotent"
  queue=$(FM_HOME="$home" "$CAPTAIN_QUEUE" --json) \
    || fail "canonical queue failed for idempotent hold"
  printf '%s' "$queue" | jq -e --arg hold "$hold" '
    [.items[] | select(.id == $hold and .replyable == true)] | length == 1
  ' >/dev/null || fail "canonical idempotent hold was not exactly once and replyable: $queue"
  pass "re-hold rejects malformed identity collisions and preserves canonical idempotence"
}

test_resolve_requires_canonical_record_and_routed_pointer() {
  local home origin=sample-canonical-review key=route hold transient canonical dependent show
  hold="$origin-decision-$key"
  dependent=sample-canonical-work
  home=$(make_ruling_home canonical-resolution-record "$origin" "$key" 'Use the east route.')
  canonical="$home/data/decisions/$hold.md"
  transient="$home/state/transient-answer.txt"
  cp "$canonical" "$transient"
  tasks_in "$home" add "$dependent" "Apply the canonical sample route" \
    --kind ship --repo sample --body "No decision-record pointer." \
    --blocked-by "$hold" >/dev/null \
    || fail "could not create pointerless dependent"
  mkdir -p "$home/data/$dependent"
  printf 'Decision record: data/decisions/%s.md\n' "$hold" \
    > "$home/data/$dependent/brief.md"

  if FM_TEST_OMIT_DECISION_POINTER=1 run_decisions "$home" resolve "$origin" "$key" \
    --decision-file "$transient" --routed-to "$dependent" \
    > "$home/volatile.out" 2> "$home/volatile.err"; then
    fail "resolve accepted a volatile decision file and pointerless dependent"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "noncanonical resolution closed the hold"
  assert_contains "$show" "held: yes" "noncanonical resolution released the hold"
  show=$(tasks_in "$home" show "$dependent" --full)
  assert_contains "$show" "blocked: yes" "noncanonical resolution unblocked its dependent"

  rm "$home/data/$dependent/brief.md"
  if FM_TEST_OMIT_DECISION_POINTER=1 run_decisions "$home" resolve "$origin" "$key" \
    --decision-file "$canonical" --routed-to "$dependent" \
    > "$home/pointerless.out" 2> "$home/pointerless.err"; then
    fail "resolve accepted canonical input without a durable routed-work pointer"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "pointerless resolution closed the hold"
  show=$(tasks_in "$home" show "$dependent" --full)
  assert_contains "$show" "blocked: yes" "pointerless resolution unblocked its dependent"

  printf 'Decision record: data/decisions/%s.md\n' "$hold" \
    > "$home/data/$dependent/brief.md"
  run_decisions "$home" resolve "$origin" "$key" --decision-file "$canonical" \
    --routed-to "$dependent" >/dev/null \
    || fail "canonical regular decision record with durable routed pointer did not resolve"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "canonical resolution did not close the hold"
  show=$(tasks_in "$home" show "$dependent" --full)
  assert_contains "$show" "blocked: no" "canonical resolution did not route its dependent"
  pass "resolve requires the canonical record and exact routed-work pointer"
}

test_resolve_enforces_session_lock_and_stable_dependent_set() {
  local home origin=sample-concurrent-review key=route hold record show
  hold="$origin-decision-$key"

  home=$(make_ruling_home missing-session-lock "$origin" "$key" 'Use the east route.')
  record="$home/data/decisions/$hold.md"
  tasks_in "$home" add sample-lock-work "Apply the locked sample route" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null
  rm "$home/state/.lock"
  if run_decisions "$home" resolve "$origin" "$key" --decision-file "$record" \
    --routed-to sample-lock-work > "$home/lock.out" 2> "$home/lock.err"; then
    fail "resolve mutated backlog without owning the home session lock"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "missing-lock resolve closed the hold"
  show=$(tasks_in "$home" show sample-lock-work --full)
  assert_contains "$show" "blocked: yes" "missing-lock resolve routed dependent work"

  home=$(make_ruling_home changed-dependent-set "$origin" "$key" 'Use the east route.')
  record="$home/data/decisions/$hold.md"
  tasks_in "$home" add sample-stable-work "Apply the stable sample route" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null
  cat > "$home/fakebin/tasks-axi" <<EOF
#!/usr/bin/env bash
set -eu
if [ "\${1:-}" = list ] && [ "\${2:-}" = --blocked ] \
  && [ ! -f "$home/dependent-added" ]; then
  output=\$("\$REAL_TASKS_AXI" "\$@")
  "\$REAL_TASKS_AXI" add sample-late-work "Late concurrent dependent" \
    --kind ship --repo sample \
    --body "Decision record: data/decisions/$hold.md" \
    --blocked-by "$hold" >/dev/null
  : > "$home/dependent-added"
  printf '%s\n' "\$output"
  exit 0
fi
exec "\$REAL_TASKS_AXI" "\$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$origin" "$key" --decision-file "$record" \
    --routed-to sample-stable-work > "$home/concurrent.out" 2> "$home/concurrent.err"; then
    fail "resolve closed after the dependent set changed following enumeration"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "changed-dependent resolve closed the hold"
  assert_not_contains "$show" "Resolution recorded by fm-decision-hold" \
    "changed-dependent resolve mutated the hold body"
  show=$(tasks_in "$home" show sample-stable-work --full)
  assert_contains "$show" "blocked: yes" "changed-dependent resolve routed initial work"
  show=$(tasks_in "$home" show sample-late-work --full)
  assert_contains "$show" "blocked: yes" "changed-dependent resolve released late work"
  pass "resolve requires its session lock and refuses a changed dependent set"
}

make_ruling_home() {  # <name> <origin> <key> <answer>
  local name=$1 origin=$2 key=$3 answer=$4 home hold
  home=$(make_home "$name")
  hold="$origin-decision-$key"
  mkdir -p "$home/data/$origin" "$home/data/decisions"
  tasks_in "$home" add "$origin" "Review the sample ruling route" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the $name origin"
  write_origin_meta "$home" "$origin"
  printf '# Sample ruling review\n\nThe captain must select the route.\n' \
    > "$home/data/$origin/report.md"
  run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the sample ruling route" \
    --reason "captain sample route pending" --repo sample >/dev/null \
    || fail "could not create the $name hold"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "could not complete the $name inventory"
  write_captain_reply "$home" "$hold" "$answer"
  printf '%s\n' "$answer" > "$home/data/decisions/$hold.md"
  printf '%s\n' "$home"
}

write_captain_reply() {  # <home> <hold> <answer>
  cat > "$1/data/pending-decisions.md" <<EOF
# Captain decisions

## ✍️ Your replies

<!-- BEGIN APPEND-ONLY: captain-replies -->
$2: $3
<!-- END APPEND-ONLY: captain-replies -->
EOF
}

# Builds a runnable copy of bin/ whose fm-decision-hold.sh carries the smallest
# falsifying edit: the named refusal becomes a no-op. The regression above must
# fail against this mutant, which is what proves the refusal is load-bearing.
falsified_decision_hold() {  # <home> <label> <sed-expression>
  local home=$1 label=$2 expression=$3
  local dir="$home/falsified-$label"
  rm -rf "$dir"
  mkdir -p "$dir"
  ln -s "$ROOT"/bin/* "$dir/" || fail "could not stage the $label falsifying copy"
  rm -f "$dir/fm-decision-hold.sh"
  sed "$expression" "$ROOT/bin/fm-decision-hold.sh" > "$dir/fm-decision-hold.sh" \
    || fail "could not apply the $label falsifying edit"
  chmod +x "$dir/fm-decision-hold.sh"
  ! cmp -s "$ROOT/bin/fm-decision-hold.sh" "$dir/fm-decision-hold.sh" \
    || fail "the $label falsifying edit changed nothing, so it proves nothing"
  printf '%s\n' "$dir/fm-decision-hold.sh"
}

run_falsified_decisions() {  # <home> <script> <command args...>
  local home=$1 script=$2
  shift 2
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$script" "$@"
}

decision_hold_with_answer_command() {  # <home> <label> <stub-mode>
  local home=$1 label=$2 mode=$3 dir
  dir="$home/answer-command-$label"
  mkdir -p "$dir"
  ln -s "$ROOT"/bin/* "$dir/" || fail "could not stage the $label answer-command fixture"
  rm -f "$dir/fm-decision-hold.sh" "$dir/fm-captain-ruling-check.sh"
  cp "$ROOT/bin/fm-decision-hold.sh" "$dir/fm-decision-hold.sh"
  chmod +x "$dir/fm-decision-hold.sh"
  if [ "$mode" = closed ]; then
    cat > "$dir/fm-captain-ruling-check.sh" <<'EOF'
#!/usr/bin/env bash
printf 'fm-captain-ruling-check: captain hold is not open\n' >&2
exit 1
EOF
    chmod +x "$dir/fm-captain-ruling-check.sh"
  fi
  printf '%s\n' "$dir/fm-decision-hold.sh"
}

assert_unreadable_answer_refuses() {  # <condition>
  local condition=$1 origin key hold home record dependent script='' show
  origin="sample-$condition-review"
  key=route
  hold="$origin-decision-$key"
  dependent="sample-$condition-work"
  home=$(make_ruling_home "unreadable-$condition" "$origin" "$key" 'Captain-approved route.')
  record="$home/data/decisions/$hold.md"
  printf 'ATTACKER-SUPPLIED ROUTE\n' > "$record"
  tasks_in "$home" add "$dependent" "Apply the $condition ruling" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create the $condition dependent"

  case "$condition" in
    absent) rm "$home/data/pending-decisions.md" ;;
    malformed)
      printf '<!-- BEGIN APPEND-ONLY: captain-replies -->\n%s: Captain-approved route.\n' "$hold" \
        > "$home/data/pending-decisions.md"
      ;;
    unavailable)
      script=$(decision_hold_with_answer_command "$home" "$condition" unavailable)
      ;;
    closed)
      script=$(decision_hold_with_answer_command "$home" "$condition" closed)
      ;;
    empty)
      write_captain_reply "$home" "$hold" ''
      ;;
    *) fail "unknown unreadable-answer condition: $condition" ;;
  esac

  if [ -n "$script" ]; then
    if run_falsified_decisions "$home" "$script" resolve "$origin" "$key" \
      --decision-file "$record" --routed-to "$dependent" \
      > "$home/$condition.out" 2> "$home/$condition.err"; then
      fail "resolve accepted the $condition captain-answer condition"
    fi
  elif run_decisions "$home" resolve "$origin" "$key" \
    --decision-file "$record" --routed-to "$dependent" \
    > "$home/$condition.out" 2> "$home/$condition.err"; then
    fail "resolve accepted the $condition captain-answer condition"
  fi

  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" \
    "the $condition answer condition closed the hold"
  assert_contains "$show" "held: yes" \
    "the $condition answer condition released the hold"
  assert_not_contains "$show" "ATTACKER-SUPPLIED ROUTE" \
    "the $condition answer condition recorded caller-supplied text"
  show=$(tasks_in "$home" show "$dependent" --full)
  assert_contains "$show" "blocked: yes" \
    "the $condition answer condition cleared the dependent's blocker"
}

test_resolve_fails_closed_when_current_answer_is_unreadable() {
  local condition
  for condition in absent malformed unavailable closed empty; do
    assert_unreadable_answer_refuses "$condition"
  done
  pass "resolve refuses every non-affirmative captain-answer read without changing holds or dependents"
}

test_resolve_refuses_an_undisclosed_blocked_dependent() {
  local home origin=sample-undisclosed-review key=route hold record show falsified
  hold="$origin-decision-$key"
  home=$(make_ruling_home undisclosed-dependent "$origin" "$key" 'Use the east route.')
  record="$home/data/decisions/$hold.md"
  tasks_in "$home" add sample-undisclosed-first "Apply the sample ruling route" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create the disclosed dependent"
  tasks_in "$home" add sample-undisclosed-second "Check the sample ruling route" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create the undisclosed dependent"

  if run_decisions "$home" resolve "$origin" "$key" --decision-file "$record" \
    --routed-to sample-undisclosed-first \
    > "$home/undisclosed.out" 2> "$home/undisclosed.err"; then
    fail "resolve closed a hold that still owned an undisclosed blocked dependent"
  fi
  assert_grep "sample-undisclosed-second is still blocked by $hold" "$home/undisclosed.err" \
    "the refusal must name the undisclosed dependent"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "the refused resolve closed the hold"
  assert_contains "$show" "held: yes" "the refused resolve released the hold"
  assert_not_contains "$show" "Resolution recorded by fm-decision-hold" \
    "the refused resolve recorded a decision before its own gate passed"
  show=$(tasks_in "$home" show sample-undisclosed-first --full)
  assert_contains "$show" "blocked: yes" "the refused resolve cleared a dependency edge"

  falsified=$(falsified_decision_hold "$home" routing \
    's/fail "task \$dep is still blocked/: "task $dep is still blocked/')
  run_falsified_decisions "$home" "$falsified" resolve "$origin" "$key" \
    --decision-file "$record" --routed-to sample-undisclosed-first >/dev/null 2>&1 \
    || fail "the falsifying edit did not reach the closure path it must expose"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" \
    "the undisclosed-dependent regression still passes without its refusal"
  show=$(tasks_in "$home" show sample-undisclosed-second --full)
  assert_contains "$show" "blocked-by:$hold" \
    "the falsified run must leave the undisclosed dependent pointing at a closed hold"

  home=$(make_ruling_home disclosed-dependents "$origin" "$key" 'Use the east route.')
  record="$home/data/decisions/$hold.md"
  tasks_in "$home" add sample-undisclosed-first "Apply the sample ruling route" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create the first disclosed dependent"
  tasks_in "$home" add sample-undisclosed-second "Check the sample ruling route" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create the second disclosed dependent"
  run_decisions "$home" resolve "$origin" "$key" --decision-file "$record" \
    --routed-to sample-undisclosed-first --routed-to sample-undisclosed-second >/dev/null \
    || fail "resolve refused a fully routed dependent set"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "a fully routed dependent set did not close the hold"
  pass "resolve discovers every still-blocked dependent and refuses an undisclosed one"
}

test_resolve_refuses_a_superseded_captain_ruling() {
  local home origin=sample-superseded-review key=route hold record show falsified
  hold="$origin-decision-$key"
  home=$(make_ruling_home superseded-ruling "$origin" "$key" 'Use the east route.')
  record="$home/data/decisions/$hold.md"
  tasks_in "$home" add sample-superseded-work "Apply the sample ruling route" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create the superseded-ruling dependent"
  write_captain_reply "$home" "$hold" 'Use the west route instead.'

  if run_decisions "$home" resolve "$origin" "$key" --decision-file "$record" \
    --routed-to sample-superseded-work \
    > "$home/superseded.out" 2> "$home/superseded.err"; then
    fail "resolve closed a hold on a captain reply the captain had already revised"
  fi
  assert_grep "newer captain reply" "$home/superseded.err" \
    "the refusal must name the newer captain reply"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "the superseded resolve closed the hold"
  assert_contains "$show" "held: yes" "the superseded resolve released the hold"
  assert_not_contains "$show" "Use the east route." \
    "the superseded resolve recorded the stale captain text"
  show=$(tasks_in "$home" show sample-superseded-work --full)
  assert_contains "$show" "blocked: yes" "the superseded resolve cleared a dependency edge"

  falsified=$(falsified_decision_hold "$home" freshness \
    's/fail "captain hold \$id has a newer/: "captain hold $id has a newer/; s/^  captain_answer_matches "\$1" "\$2" && return 0$/  return 0/')
  run_falsified_decisions "$home" "$falsified" resolve "$origin" "$key" \
    --decision-file "$record" --routed-to sample-superseded-work >/dev/null 2>&1 \
    || fail "the falsifying edit did not reach the closure path it must expose"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" \
    "the superseded-ruling regression still passes without its refusal"
  assert_contains "$show" "Use the east route." \
    "the falsified run must close the hold on the superseded captain text"

  home=$(make_ruling_home current-ruling "$origin" "$key" 'Use the east route.')
  record="$home/data/decisions/$hold.md"
  tasks_in "$home" add sample-superseded-work "Apply the sample ruling route" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create the current-ruling dependent"
  write_captain_reply "$home" "$hold" 'Use the west route instead.'
  printf 'Use the west route instead.\n' > "$record"
  run_decisions "$home" resolve "$origin" "$key" --decision-file "$record" \
    --routed-to sample-superseded-work >/dev/null \
    || fail "resolve refused a decision record that matches the current captain reply"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "a re-read current ruling did not close the hold"
  assert_contains "$show" "Use the west route instead." \
    "the closed hold did not retain the revised captain ruling"
  pass "resolve re-reads the captain ruling and refuses a superseded decision record"
}

test_resolve_cas_refuses_ruling_changed_during_dependency_unblock() {
  local home origin=sample-cas-review key=route hold record show
  hold="$origin-decision-$key"
  home=$(make_ruling_home ruling-cas-boundary "$origin" "$key" 'Use the east route.')
  record="$home/data/decisions/$hold.md"
  tasks_in "$home" add sample-cas-work "Apply the CAS-protected sample route" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create the CAS-boundary dependent"
  cat > "$home/fakebin/tasks-axi" <<EOF
#!/usr/bin/env bash
set -eu
if [ "\${1:-}" = unblock ] && [ "\${2:-}" = sample-cas-work ] \
  && [ ! -f "$home/ruling-revised" ]; then
  cat > "$home/data/pending-decisions.md" <<'REPLY'
# Captain decisions

<!-- BEGIN APPEND-ONLY: captain-replies -->
$hold: Use the west route instead.
<!-- END APPEND-ONLY: captain-replies -->
REPLY
  : > "$home/ruling-revised"
fi
exec "\$REAL_TASKS_AXI" "\$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"

  if run_decisions "$home" resolve "$origin" "$key" --decision-file "$record" \
    --routed-to sample-cas-work > "$home/cas.out" 2> "$home/cas.err"; then
    fail "resolve closed on ruling text superseded during dependency unblocking"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "CAS refusal closed the hold"
  assert_contains "$show" "held: yes" "CAS refusal released the hold"
  assert_not_contains "$show" "Use the east route." \
    "CAS refusal left the superseded ruling committed"
  show=$(tasks_in "$home" show sample-cas-work --full)
  assert_contains "$show" "blocked: yes" "CAS refusal routed dependent work"

  printf 'Use the west route instead.\n' > "$record"
  run_decisions "$home" resolve "$origin" "$key" --decision-file "$record" \
    --routed-to sample-cas-work >/dev/null \
    || fail "revised ruling could not commit after the CAS refusal"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "revised ruling did not close after CAS retry"
  assert_contains "$show" "Use the west route instead." \
    "CAS retry did not commit the revised ruling"
  pass "ruling revision CAS covers the body write, dependency unblock, and close window"
}

write_pending_skeleton() {  # <home>
  cat > "$1/data/pending-decisions.md" <<'EOF'
# Captain decisions

<!-- BEGIN APPEND-ONLY: captain-replies -->
<!-- END APPEND-ONLY: captain-replies -->

<!-- BEGIN GENERATED: captain-queue -->
<!-- END GENERATED: captain-queue -->
EOF
}

answer_generated_prefix() {  # <pending> <id> <answer>
  local pending=$1 id=$2 answer=$3
  perl -0pi -e '
    BEGIN { $id = shift @ARGV; $answer = shift @ARGV }
    s/^\Q$id\E: \n/$id: $answer\n/m or die "reply prefix absent\n";
  ' "$id" "$answer" "$pending"
}

test_in_flight_captain_hold_resolves_end_to_end() {
  local home origin=sample-inflight-review key=route hold dependent answer wake record show
  hold="$origin-decision-$key"
  dependent=sample-inflight-work
  home=$(make_home inflight-captain-resolution)
  mkdir -p "$home/data/$origin" "$home/data/decisions"
  tasks_in "$home" add "$origin" "Review the in-flight sample route" \
    --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$origin"
  run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the in-flight sample route" \
    --reason "captain route pending" --repo sample >/dev/null
  tasks_in "$home" start "$hold" >/dev/null \
    || fail "could not move the captain hold in flight"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "durability verification rejected an in-flight captain hold"
  tasks_in "$home" add "$dependent" "Apply the in-flight sample route" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null
  mkdir -p "$home/data/$dependent"
  printf 'Decision record: data/decisions/%s.md\n' "$hold" \
    > "$home/data/$dependent/brief.md"
  write_pending_skeleton "$home"
  FM_HOME="$home" "$PENDING_GENERATOR" >/dev/null \
    || fail "generator rejected an in-flight captain hold"
  answer_generated_prefix "$home/data/pending-decisions.md" "$hold" 'Use the east route.'
  wake=$(FM_HOME="$home" "$RULING_CHECK") \
    || fail "detector rejected the in-flight captain ruling"
  [ "$wake" = "captain-ruling $hold" ] \
    || fail "in-flight ruling emitted the wrong wake: $wake"
  answer=$(FM_HOME="$home" "$RULING_CHECK" --answer "$hold") \
    || fail "answer read rejected the in-flight captain hold"
  record="$home/data/decisions/$hold.md"
  printf '%s\n' "$answer" > "$record"
  run_decisions "$home" resolve "$origin" "$key" --decision-file "$record" \
    --routed-to "$dependent" >/dev/null \
    || fail "guarded resolve rejected an in-flight captain hold"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "in-flight captain hold did not resolve"
  show=$(tasks_in "$home" show "$dependent" --full)
  assert_contains "$show" "blocked: no" "in-flight resolution left its dependent blocked"
  pass "in-flight captain holds generate, wake, read, record, route, and resolve"
}

test_ordinary_work_decision_resolves_without_completing_work() {
  local home id=sample-ordinary-work answer wake record show queue
  home=$(make_home ordinary-work-resolution)
  mkdir -p "$home/data/decisions"
  tasks_in "$home" add "$id" "Implement ordinary sample work" \
    --kind ship --repo sample \
    --body 'Keep this work payload.' >/dev/null
  tasks_in "$home" hold "$id" --reason "captain route pending" --kind captain >/dev/null
  write_pending_skeleton "$home"
  FM_HOME="$home" "$PENDING_GENERATOR" >/dev/null \
    || fail "generator rejected a captain hold carried by ordinary work"
  assert_grep "$id: " "$home/data/pending-decisions.md" \
    "ordinary work decision did not receive a reply prefix"
  answer_generated_prefix "$home/data/pending-decisions.md" "$id" 'Use the east route.'
  wake=$(FM_HOME="$home" "$RULING_CHECK") \
    || fail "detector rejected the ordinary-work captain ruling"
  [ "$wake" = "captain-ruling $id" ] \
    || fail "ordinary-work ruling emitted the wrong wake: $wake"
  answer=$(FM_HOME="$home" "$RULING_CHECK" --answer "$id") \
    || fail "answer read rejected the ordinary-work captain hold"
  record="$home/data/decisions/$id.md"
  printf '%s\n' "$answer" > "$record"
  run_decisions "$home" resolve-item "$id" --decision-file "$record" >/dev/null \
    || fail "ordinary-work captain decision did not resolve"
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "state: queued" "decision resolution completed the underlying work item"
  assert_contains "$show" "kind: ship" "decision resolution changed the underlying work kind"
  assert_contains "$show" "held: no" "decision resolution left the ordinary work held"
  assert_contains "$show" "Keep this work payload." "decision resolution discarded the work payload"
  assert_contains "$show" "Captain decision recorded by fm-decision-hold" \
    "ordinary work lost its durable decision-resolution pointer"
  queue=$(FM_HOME="$home" "$CAPTAIN_QUEUE" --json) \
    || fail "captain queue failed after ordinary-work resolution"
  printf '%s' "$queue" | jq -e --arg id "$id" \
    'any(.items[]; .id == $id) | not' >/dev/null \
    || fail "resolved ordinary decision remained in the open captain queue: $queue"
  pass "ordinary-kind replies resolve only the captain hold and never complete the work item"
}

PARTIAL_HOME=''

# Leaves a hold that durably committed its captain decision but died before it
# finished clearing edges, which is the recovery state `resolve` must still be
# able to complete. Sets PARTIAL_HOME rather than echoing it so a failed setup
# stops the run instead of returning an empty home from a command substitution.
setup_partial_resolve() {  # <name> <origin> <key> <answer>
  local name=$1 origin=$2 key=$3 answer=$4
  local home hold show
  hold="$origin-decision-$key"
  home=$(make_ruling_home "$name" "$origin" "$key" "$answer")
  [ -n "$home" ] || fail "could not stage the $name partial-resolve home"
  tasks_in "$home" add sample-partial-first "Apply the sample ruling route" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create the first $name dependent"
  tasks_in "$home" add sample-partial-second "Check the sample ruling route" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create the second $name dependent"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = unblock ] && [ "${2:-}" = sample-partial-second ] \
  && [ ! -f "$FM_HOME/partial-unblock-failed-once" ]; then
  : > "$FM_HOME/partial-unblock-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$origin" "$key" \
    --decision-file "$home/data/decisions/$hold.md" \
    --routed-to sample-partial-first --routed-to sample-partial-second \
    > "$home/partial.out" 2> "$home/partial.err"; then
    fail "the $name fixture finished routing instead of failing midway"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "the $name partial resolve closed the hold"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" \
    "the $name partial resolve did not durably commit the captain decision"
  show=$(tasks_in "$home" show sample-partial-first --full)
  assert_contains "$show" "blocked: no" "the $name partial resolve cleared no dependency edge"
  show=$(tasks_in "$home" show sample-partial-second --full)
  assert_contains "$show" "blocked: yes" "the $name partial resolve cleared every dependency edge"
  PARTIAL_HOME=$home
}

test_exact_retry_finishes_routing_after_a_revised_reply() {
  local origin=sample-partial-review key=route
  local home hold record show falsified
  hold="$origin-decision-$key"
  setup_partial_resolve partial-retry "$origin" "$key" 'Use the east route.'
  home=$PARTIAL_HOME
  record="$home/data/decisions/$hold.md"
  write_captain_reply "$home" "$hold" 'Use the west route instead.'

  run_decisions "$home" resolve "$origin" "$key" --decision-file "$record" \
    --routed-to sample-partial-first --routed-to sample-partial-second >/dev/null \
    || fail "an exact retry could not finish routing an already committed decision"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the exact retry did not close the half-routed hold"
  assert_contains "$show" "Use the east route." \
    "the exact retry did not preserve the durably committed captain decision"
  assert_not_contains "$show" "Use the west route instead." \
    "the exact retry adopted a reply the hold had never committed"
  show=$(tasks_in "$home" show sample-partial-second --full)
  assert_contains "$show" "blocked: no" "the exact retry did not finish clearing the edges"

  setup_partial_resolve falsified-partial-retry "$origin" "$key" 'Use the east route.'
  home=$PARTIAL_HOME
  record="$home/data/decisions/$hold.md"
  write_captain_reply "$home" "$hold" 'Use the west route instead.'
  falsified=$(falsified_decision_hold "$home" committed-skip \
    's/\[ "\$resolution_recorded" = 1 \] || verify_decision_is_current/false || verify_decision_is_current/')
  if run_falsified_decisions "$home" "$falsified" resolve "$origin" "$key" \
    --decision-file "$record" --routed-to sample-partial-first \
    --routed-to sample-partial-second >/dev/null 2>&1; then
    fail "the exact-retry regression still passes without the committed-decision skip"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" \
    "the falsified run must leave the half-routed hold permanently unresolvable"
  show=$(tasks_in "$home" show sample-partial-second --full)
  assert_contains "$show" "blocked: yes" \
    "the falsified run must leave the unfinished dependency edge in place"
  pass "an exact retry finishes routing a committed decision after a revised reply"
}

test_partial_retry_still_refuses_a_different_decision() {
  local origin=sample-drift-review key=route
  local home hold record show falsified
  hold="$origin-decision-$key"
  setup_partial_resolve drifted-partial-retry "$origin" "$key" 'Use the east route.'
  home=$PARTIAL_HOME
  record="$home/data/decisions/$hold.md"
  printf 'Use the west route instead.\n' > "$record"
  write_captain_reply "$home" "$hold" 'Use the west route instead.'

  if run_decisions "$home" resolve "$origin" "$key" --decision-file "$record" \
    --routed-to sample-partial-first --routed-to sample-partial-second \
    > "$home/drifted.out" 2> "$home/drifted.err"; then
    fail "a partial-resolve retry closed the hold on a different captain decision"
  fi
  assert_grep "records a different captain decision" "$home/drifted.err" \
    "the refusal must name the committed-decision mismatch"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "the drifted retry closed the hold"
  assert_contains "$show" "held: yes" "the drifted retry released the hold"
  assert_not_contains "$show" "Use the west route instead." \
    "the drifted retry overwrote the durably committed captain decision"
  show=$(tasks_in "$home" show sample-partial-second --full)
  assert_contains "$show" "blocked: yes" "the drifted retry cleared a dependency edge"

  setup_partial_resolve falsified-drifted-retry "$origin" "$key" 'Use the east route.'
  home=$PARTIAL_HOME
  record="$home/data/decisions/$hold.md"
  printf 'Use the west route instead.\n' > "$record"
  write_captain_reply "$home" "$hold" 'Use the west route instead.'
  falsified=$(falsified_decision_hold "$home" committed-identity \
    's/fail "captain hold \$id records a different captain decision"/: "captain hold $id records a different captain decision"/')
  run_falsified_decisions "$home" "$falsified" resolve "$origin" "$key" \
    --decision-file "$record" --routed-to sample-partial-first \
    --routed-to sample-partial-second >/dev/null 2>&1 \
    || fail "the falsifying edit did not reach the closure path it must expose"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" \
    "the different-decision regression still passes without its identity refusal"
  assert_contains "$show" "Use the west route instead." \
    "the falsified run must close the hold on the drifted captain decision"
  pass "a partial-resolve retry carrying a different decision is still refused"
}

test_ruling_wake_loads_the_single_lifecycle_owner() {
  assert_grep 'on a `captain-ruling <hold-id>[,<hold-id>...]` `check:` wake' "$AGENTS" \
    "AGENTS.md does not load the decision owner for captain-ruling wakes"
  for phrase in \
    'bin/fm-captain-ruling-check.sh --answer' \
    'data/decisions/<hold-id>.md' \
    'tasks-axi add' \
    '--blocked-by <hold-id>' \
    'bin/fm-decision-hold.sh resolve' \
    'Only after `resolve` succeeds'; do
    assert_grep "$phrase" "$DECISION_SKILL" \
      "decision lifecycle owner is missing the round-trip instruction '$phrase'"
  done
  assert_grep 'A status change is not ruling ingestion' "$DECISION_SKILL" \
    "decision lifecycle owner permits a status-only close"
  pass "captain-ruling wakes load the single lifecycle owner and preserve close ordering"
}

test_uninventoried_report_decision_refuses_completion

test_scout_teardown_always_requires_inventory_verification
test_structured_holds_survive_teardown_and_route_resolution
test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_resolve_matches_quoted_blocked_by_edges
test_detected_ruling_becomes_work_before_hold_closes
test_rehold_requires_canonical_identity_fields
test_resolve_requires_canonical_record_and_routed_pointer
test_resolve_enforces_session_lock_and_stable_dependent_set
test_resolve_fails_closed_when_current_answer_is_unreadable
test_resolve_refuses_an_undisclosed_blocked_dependent
test_resolve_refuses_a_superseded_captain_ruling
test_resolve_cas_refuses_ruling_changed_during_dependency_unblock
test_in_flight_captain_hold_resolves_end_to_end
test_ordinary_work_decision_resolves_without_completing_work
test_exact_retry_finishes_routing_after_a_revised_reply
test_partial_retry_still_refuses_a_different_decision
test_ruling_wake_loads_the_single_lifecycle_owner
