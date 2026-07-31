#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's best-effort CodeGraph preparation.
#
# Every case drives a real isolated git worktree through the tmux spawn path.
# Fake CodeGraph and timeout executables make the selected action and failure
# result deterministic without creating an index or waiting for the real bound.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-codegraph)

# <name> <ignores-.codegraph> <existing-index>, where existing-index is one of:
#   none     - no .codegraph directory at all
#   partial  - an initialized database whose state marker reports partial
#   indexing - an initialized database whose state marker reports indexing
#   failed   - an initialized database whose state marker reports failed
#   complete - a .codegraph directory whose CodeGraph marker reports complete
make_case() {
  local name=$1 ignored=$2 existing=$3 case_dir home proj wt fakebin state
  local id="codegraph-$name"
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/worktree"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_init_commit "$proj"
  if [ "$ignored" = yes ]; then
    printf '.codegraph/\n' > "$proj/.gitignore"
    git -C "$proj" add .gitignore
    git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'ignore codegraph'
  fi
  git -C "$proj" worktree add --quiet -b "fixture-$name" "$wt"
  state=absent
  case "$existing" in
    partial|indexing|failed)
      mkdir -p "$wt/.codegraph"
      printf 'old incomplete database\n' > "$wt/.codegraph/codegraph.db"
      state=$existing
      ;;
    complete)
      mkdir -p "$wt/.codegraph"
      printf 'complete database\n' > "$wt/.codegraph/codegraph.db"
      state=complete
      ;;
  esac
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id|$state"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR ID INDEX_STATE <<EOF
$1
EOF
}

install_spawn_fakes() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --kill-after=*) shift ;;
  -k|--kill-after) shift 2 ;;
esac
shift
case "${FM_FAKE_TIMEOUT_RESULT:-run}" in
  timeout) exit 124 ;;
  unavailable) exit 125 ;;
esac
exec "$@"
SH
  cat > "$fakebin/codegraph" <<'SH'
#!/usr/bin/env bash
set -u
printf 'dir=%s %s\n' "${CODEGRAPH_DIR:-unset}" "$*" >> "${FM_FAKE_CODEGRAPH_LOG:?}"
if [ "${1:-}" = status ]; then
  case "${FM_FAKE_CODEGRAPH_STATE:-absent}" in
    complete) printf '{"initialized":true,"index":{"state":"complete","pendingRefs":0}}\n' ;;
    partial|indexing|failed) printf '{"initialized":true,"index":{"state":"%s","pendingRefs":0}}\n' "$FM_FAKE_CODEGRAPH_STATE" ;;
    *) printf '{"initialized":false,"lastIndexed":null}\n' ;;
  esac
  exit 0
fi
if [ "${1:-}" = init ]; then
  index_dir="${2:?}/${CODEGRAPH_DIR:-.codegraph}"
  if [ -f "$index_dir/codegraph.db" ]; then
    exit 0
  fi
  mkdir -p "$index_dir"
  printf 'replacement complete database\n' > "$index_dir/codegraph.db"
fi
if [ "${FM_FAKE_CODEGRAPH_RESULT:-ok}" = fail ]; then
  printf 'fake codegraph diagnostic that spawn must suppress\n' >&2
  exit 7
fi
if [ "${FM_FAKE_CODEGRAPH_RESULT:-ok}" = exit125 ]; then
  exit 125
fi
if [ "${FM_FAKE_CODEGRAPH_RESULT:-ok}" = signal ]; then
  exec perl -e 'kill 9, $$'
fi
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse" "$fakebin/timeout" "$fakebin/codegraph"
}

# PATH with every directory holding a real codegraph removed, so the
# unavailable-binary case is deterministic on machines that have CodeGraph
# installed. Everything else the spawn path needs stays on PATH.
path_without_codegraph() {
  local dir out=''
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ -x "$dir/codegraph" ] || out="$out$dir:"
  done <<EOF
$(printf '%s' "$PATH" | tr ':' '\n')
EOF
  printf '%s' "${out%:}"
}

run_spawn() {
  local result=${1:-ok} timeout_result=${2:-run} extra=${3:-}
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_SPAWN_TEST_CODEGRAPH_TIMEOUT_RUNNER="${FM_SPAWN_TEST_CODEGRAPH_TIMEOUT_RUNNER:-}" \
    FM_FAKE_CODEGRAPH_LOG="$CASE_DIR/codegraph.log" FM_FAKE_CODEGRAPH_RESULT="$result" \
    FM_FAKE_CODEGRAPH_STATE="$INDEX_STATE" \
    FM_FAKE_TIMEOUT_RESULT="$timeout_result" PATH="$FAKEBIN_DIR:${SPAWN_PATH:-$PATH}" \
    "$SPAWN" "$ID" "$PROJ_DIR" ${extra:+"$extra"} 2>&1
}

test_ignored_absent_initializes() {
  local rec out status
  rec=$(make_case init yes none)
  read_case "$rec"
  install_spawn_fakes "$FAKEBIN_DIR"
  out=$(run_spawn)
  status=$?
  expect_code 0 "$status" "ignored absent CodeGraph spawn should succeed"
  assert_contains "$out" "spawned $ID" "ignored absent spawn did not launch"
  assert_grep "dir=.codegraph init $WT_DIR" "$CASE_DIR/codegraph.log" "ignored absent worktree did not run codegraph init with the fixed index directory"
  assert_grep 'codegraph=initialized' "$HOME_DIR/state/$ID.meta" "init outcome was not recorded in meta"
  pass "ignored worktree without an index runs CodeGraph init"
}

test_incomplete_databases_are_rebuilt() {
  local incomplete rec out status
  for incomplete in partial indexing failed; do
    rec=$(make_case "rebuild-$incomplete" yes "$incomplete")
    read_case "$rec"
    install_spawn_fakes "$FAKEBIN_DIR"
    out=$(run_spawn)
    status=$?
    expect_code 0 "$status" "$incomplete CodeGraph index spawn should succeed"
    assert_contains "$out" "spawned $ID" "$incomplete index spawn did not launch"
    assert_grep "dir=.codegraph init $WT_DIR" "$CASE_DIR/codegraph.log" "$incomplete index did not run codegraph init"
    assert_no_grep "dir=.codegraph sync $WT_DIR" "$CASE_DIR/codegraph.log" "$incomplete index was synced instead of rebuilt"
    assert_grep 'replacement complete database' "$WT_DIR/.codegraph/codegraph.db" "$incomplete index was left as CodeGraph's successful init no-op"
    assert_grep 'codegraph=initialized' "$HOME_DIR/state/$ID.meta" "$incomplete init outcome was not recorded in meta"
  done
  pass "partial, indexing, and failed databases are removed and genuinely rebuilt before init"
}

test_complete_index_syncs() {
  local rec out status
  rec=$(make_case sync yes complete)
  read_case "$rec"
  install_spawn_fakes "$FAKEBIN_DIR"
  out=$(run_spawn)
  status=$?
  expect_code 0 "$status" "complete CodeGraph index spawn should succeed"
  assert_contains "$out" "spawned $ID" "complete index spawn did not launch"
  assert_grep "dir=.codegraph sync $WT_DIR" "$CASE_DIR/codegraph.log" "complete index did not run codegraph sync"
  assert_no_grep "dir=.codegraph init $WT_DIR" "$CASE_DIR/codegraph.log" "complete index was re-initialized instead of synced"
  assert_grep 'codegraph=synced' "$HOME_DIR/state/$ID.meta" "sync outcome was not recorded in meta"
  pass "worktree with a completed-index marker runs CodeGraph sync"
}

test_not_ignored_skips() {
  local rec out status
  rec=$(make_case skip no none)
  read_case "$rec"
  install_spawn_fakes "$FAKEBIN_DIR"
  out=$(run_spawn)
  status=$?
  expect_code 0 "$status" "not-ignored CodeGraph spawn should succeed"
  assert_contains "$out" "spawned $ID" "not-ignored spawn did not launch"
  [ ! -e "$CASE_DIR/codegraph.log" ] || fail "not-ignored worktree invoked CodeGraph"
  assert_grep 'codegraph=skipped-not-ignored' "$HOME_DIR/state/$ID.meta" "not-ignored skip was not recorded in meta"
  pass "worktree that does not ignore .codegraph skips indexing"
}

test_unrelated_repository_is_refused_before_codegraph() {
  local rec unrelated out status
  rec=$(make_case unrelated-repository yes none)
  read_case "$rec"
  install_spawn_fakes "$FAKEBIN_DIR"
  unrelated="$CASE_DIR/unrelated-repository"
  fm_git_init_commit "$unrelated"
  printf '.codegraph/\n' > "$unrelated/.gitignore"
  git -C "$unrelated" add .gitignore
  git -C "$unrelated" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'ignore codegraph'
  mkdir -p "$unrelated/.codegraph"
  printf 'preserve me\n' > "$unrelated/.codegraph/sentinel"
  WT_DIR=$unrelated
  out=$(run_spawn)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a stable worktree path from an unrelated repository"
  assert_contains "$out" "does not belong to selected repository" "unrelated-repository refusal did not explain the identity mismatch"
  assert_absent "$CASE_DIR/codegraph.log" "unrelated repository invoked CodeGraph before repository identity was established"
  assert_grep 'preserve me' "$unrelated/.codegraph/sentinel" "unrelated repository's CodeGraph index was changed or discarded"
  pass "an unrelated repository is refused before CodeGraph can inspect or mutate its index"
}

test_ambient_codegraph_dir_is_forced_and_worktree_stays_clean() {
  local rec out status dirty
  rec=$(make_case forced-directory yes none)
  read_case "$rec"
  install_spawn_fakes "$FAKEBIN_DIR"
  out=$(CODEGRAPH_DIR=.codegraph-win run_spawn)
  status=$?
  expect_code 0 "$status" "ambient CODEGRAPH_DIR must not block spawn"
  assert_contains "$out" "spawned $ID" "ambient CODEGRAPH_DIR prevented launch"
  assert_grep "dir=.codegraph init $WT_DIR" "$CASE_DIR/codegraph.log" "CodeGraph call site did not force CODEGRAPH_DIR=.codegraph"
  assert_absent "$WT_DIR/.codegraph-win" "ambient CODEGRAPH_DIR created an unguarded alternate index"
  dirty=$(git -C "$WT_DIR" status --porcelain)
  [ -z "$dirty" ] || fail "ambient CODEGRAPH_DIR left the spawned worktree dirty and ineligible for teardown: $dirty"
  git -C "$PROJ_DIR" merge-base --is-ancestor "$(git -C "$WT_DIR" rev-parse HEAD)" HEAD || \
    fail "forced-directory fixture was clean but still held unlanded work"
  assert_grep 'codegraph=initialized' "$HOME_DIR/state/$ID.meta" "forced-directory init outcome was not recorded in meta"
  pass "every CodeGraph call forces .codegraph and leaves the task worktree clean and teardown-eligible"
}

test_nonzero_fails_open() {
  local rec out status warning_count attempts
  rec=$(make_case failure yes none)
  read_case "$rec"
  install_spawn_fakes "$FAKEBIN_DIR"
  out=$(run_spawn fail)
  status=$?
  expect_code 0 "$status" "CodeGraph failure must not block spawn"
  assert_contains "$out" "spawned $ID" "CodeGraph failure prevented launch"
  assert_contains "$out" "warning: CodeGraph init failed for task $ID with exit 7; spawn will continue" "CodeGraph failure warning was unclear"
  assert_not_contains "$out" "fake codegraph diagnostic" "CodeGraph emitted more than the single spawn warning"
  warning_count=$(printf '%s\n' "$out" | grep -c '^warning: CodeGraph ')
  [ "$warning_count" -eq 1 ] || fail "CodeGraph failure printed $warning_count warnings instead of one"
  assert_grep 'codegraph=init-failed' "$HOME_DIR/state/$ID.meta" "failure outcome was not recorded in meta"
  [ ! -e "$WT_DIR/.codegraph" ] || fail "failed CodeGraph init left an unusable index behind"
  attempts=$(grep -c "dir=.codegraph init $WT_DIR" "$CASE_DIR/codegraph.log")
  [ "$attempts" -eq 1 ] || fail "failed CodeGraph init was attempted $attempts times instead of once"
  pass "CodeGraph non-zero exit warns once, records failure, discards the partial index, does not retry, and fails open"
}

test_timeout_fails_open() {
  local rec out status
  rec=$(make_case timeout yes partial)
  read_case "$rec"
  install_spawn_fakes "$FAKEBIN_DIR"
  out=$(run_spawn ok timeout)
  status=$?
  expect_code 0 "$status" "CodeGraph timeout must not block spawn"
  assert_contains "$out" "spawned $ID" "CodeGraph timeout prevented launch"
  assert_contains "$out" "warning: CodeGraph init timed out after 30s for task $ID; spawn will continue" "CodeGraph timeout warning was unclear"
  assert_grep 'codegraph=init-timeout' "$HOME_DIR/state/$ID.meta" "timeout outcome was not recorded in meta"
  [ ! -e "$WT_DIR/.codegraph" ] || fail "timed-out CodeGraph init left an unusable index behind"
  pass "CodeGraph timeout warns, records timeout, discards the partial index, and fails open"
}

test_term_ignoring_codegraph_is_killed_within_one_total_deadline() {
  local rec out status warning_count status_budget action_budget real_timeout
  rec=$(make_case stubborn-timeout yes none)
  read_case "$rec"
  install_spawn_fakes "$FAKEBIN_DIR"
  real_timeout=$(command -v timeout)
  cat > "$FAKEBIN_DIR/timeout" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TIMEOUT_LOG:?}"
case "${1:-}" in
  --kill-after=*) shift ;;
  -k|--kill-after) shift 2 ;;
  *) exit 98 ;;
esac
budget=${1%s}
shift
printf '%s\n' "$budget" >> "${FM_FAKE_TIMEOUT_BUDGET_LOG:?}"
case " $* " in
  *" codegraph status "*) sleep 2; exec "$@" ;;
esac
"${FM_REAL_TIMEOUT:?}" --kill-after=1s 1s "$@"
rc=$?
case "$rc" in
  124|137) exit 124 ;;
  *) exit "$rc" ;;
esac
SH
  chmod +x "$FAKEBIN_DIR/timeout"
  cat > "$FAKEBIN_DIR/codegraph" <<'SH'
#!/usr/bin/env bash
set -u
printf 'dir=%s %s\n' "${CODEGRAPH_DIR:-unset}" "$*" >> "${FM_FAKE_CODEGRAPH_LOG:?}"
if [ "${1:-}" = status ]; then
  printf '{"initialized":false,"lastIndexed":null}\n'
  exit 0
fi
mkdir -p "${2:?}/${CODEGRAPH_DIR:-.codegraph}"
trap '' TERM
while :; do sleep 1; done
SH
  chmod +x "$FAKEBIN_DIR/codegraph"
  out=$(FM_FAKE_TIMEOUT_LOG="$CASE_DIR/timeout.log" \
    FM_FAKE_TIMEOUT_BUDGET_LOG="$CASE_DIR/timeout-budgets.log" \
    FM_REAL_TIMEOUT="$real_timeout" "$real_timeout" --kill-after=1s 8s \
    env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' FM_FAKE_PANE_PATH="$WT_DIR" \
      FM_FAKE_CODEGRAPH_LOG="$CASE_DIR/codegraph.log" \
      PATH="$FAKEBIN_DIR:$PATH" "$SPAWN" "$ID" "$PROJ_DIR" 2>&1)
  status=$?
  expect_code 0 "$status" "independent watchdog should observe spawn complete after CodeGraph ignores TERM"
  assert_contains "$out" "spawned $ID" "TERM-ignoring CodeGraph prevented harness launch"
  assert_contains "$out" "warning: CodeGraph init timed out after 30s for task $ID; spawn will continue" "TERM-ignoring CodeGraph did not report the bounded timeout"
  warning_count=$(printf '%s\n' "$out" | grep -c '^warning: CodeGraph ')
  [ "$warning_count" -eq 1 ] || fail "TERM-ignoring CodeGraph printed $warning_count warnings instead of one"
  assert_grep 'codegraph=init-timeout' "$HOME_DIR/state/$ID.meta" "TERM-ignoring timeout was not recorded in meta"
  assert_absent "$WT_DIR/.codegraph" "TERM-ignoring timed-out init left a partial index behind"
  status_budget=$(sed -n '1p' "$CASE_DIR/timeout-budgets.log")
  action_budget=$(sed -n '2p' "$CASE_DIR/timeout-budgets.log")
  [ "$action_budget" -lt "$status_budget" ] || fail "status and action received separate timeout budgets instead of one decreasing deadline ($status_budget then $action_budget)"
  pass "a TERM-ignoring CodeGraph process is killed, recorded, and bypassed within one decreasing total deadline"
}

test_executed_exit_125_is_failure_and_cleans_index() {
  local rec out status warning_count
  rec=$(make_case exit-125 yes partial)
  read_case "$rec"
  install_spawn_fakes "$FAKEBIN_DIR"
  out=$(run_spawn exit125)
  status=$?
  expect_code 0 "$status" "executed CodeGraph exit 125 must not block spawn"
  assert_contains "$out" "spawned $ID" "executed CodeGraph exit 125 prevented launch"
  assert_contains "$out" "warning: CodeGraph init failed for task $ID with exit 125; spawn will continue" "executed exit 125 was confused with missing timeout-runner preflight"
  warning_count=$(printf '%s\n' "$out" | grep -c '^warning: CodeGraph ')
  [ "$warning_count" -eq 1 ] || fail "executed exit 125 printed $warning_count warnings instead of one"
  assert_grep 'codegraph=init-failed' "$HOME_DIR/state/$ID.meta" "executed exit 125 was not recorded as failure"
  assert_absent "$WT_DIR/.codegraph" "executed exit 125 left its partial replacement index behind"
  assert_grep "dir=.codegraph init $WT_DIR" "$CASE_DIR/codegraph.log" "exit-125 regression did not execute CodeGraph init"
  pass "an executed CodeGraph exit 125 is a failure, not a no-runner result, and cleans its partial index"
}

test_perl_runner_reports_signal_failure() {
  local rec out status
  rec=$(make_case perl-signal yes none)
  read_case "$rec"
  install_spawn_fakes "$FAKEBIN_DIR"
  out=$(FM_SPAWN_TEST_CODEGRAPH_TIMEOUT_RUNNER=perl run_spawn signal)
  status=$?
  expect_code 0 "$status" "signal-killed CodeGraph under Perl must fail open"
  assert_contains "$out" "spawned $ID" "Perl runner signal handling prevented launch"
  assert_contains "$out" "warning: CodeGraph init failed for task $ID with exit 137; spawn will continue" "Perl runner discarded the child signal bits"
  assert_grep 'codegraph=init-failed' "$HOME_DIR/state/$ID.meta" "Perl signal failure was not recorded in meta"
  assert_absent "$WT_DIR/.codegraph" "Perl signal failure left a partial index behind"
  pass "the Perl timeout fallback converts a signal-killed CodeGraph child into failure and cleans its index"
}

test_scout_worktree_initializes() {
  local rec out status
  rec=$(make_case scout yes none)
  read_case "$rec"
  install_spawn_fakes "$FAKEBIN_DIR"
  out=$(run_spawn ok run --scout)
  status=$?
  expect_code 0 "$status" "scout CodeGraph spawn should succeed"
  assert_contains "$out" "spawned $ID" "scout spawn did not launch"
  assert_grep 'kind=scout' "$HOME_DIR/state/$ID.meta" "scout spawn did not record kind=scout"
  assert_grep "dir=.codegraph init $WT_DIR" "$CASE_DIR/codegraph.log" "scout worktree did not run codegraph init"
  assert_grep 'codegraph=initialized' "$HOME_DIR/state/$ID.meta" "scout init outcome was not recorded in meta"
  pass "scout worktree without an index runs CodeGraph init"
}

test_missing_binary_fails_open() {
  local rec out status warning_count
  rec=$(make_case nobinary yes none)
  read_case "$rec"
  install_spawn_fakes "$FAKEBIN_DIR"
  rm -f "$FAKEBIN_DIR/codegraph"
  SPAWN_PATH=$(path_without_codegraph)
  out=$(run_spawn)
  status=$?
  unset SPAWN_PATH
  expect_code 0 "$status" "missing codegraph binary must not block spawn"
  assert_contains "$out" "spawned $ID" "missing codegraph binary prevented launch"
  assert_contains "$out" "warning: CodeGraph init skipped for task $ID because codegraph is unavailable; spawn will continue" "missing binary warning was unclear"
  warning_count=$(printf '%s\n' "$out" | grep -c '^warning: CodeGraph ')
  [ "$warning_count" -eq 1 ] || fail "missing codegraph binary printed $warning_count warnings instead of one"
  assert_grep 'codegraph=init-unavailable' "$HOME_DIR/state/$ID.meta" "unavailable outcome was not recorded in meta"
  pass "missing codegraph binary warns once, records the outcome, and fails open"
}

test_ignored_absent_initializes
test_incomplete_databases_are_rebuilt
test_complete_index_syncs
test_not_ignored_skips
test_unrelated_repository_is_refused_before_codegraph
test_ambient_codegraph_dir_is_forced_and_worktree_stays_clean
test_nonzero_fails_open
test_timeout_fails_open
test_term_ignoring_codegraph_is_killed_within_one_total_deadline
test_executed_exit_125_is_failure_and_cleans_index
test_perl_runner_reports_signal_failure
test_scout_worktree_initializes
test_missing_binary_fails_open

echo "# all fm-spawn CodeGraph tests passed"
