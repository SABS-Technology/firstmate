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
#   partial  - a .codegraph directory with no completed-index marker
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
    printf '.codegraph\n' > "$proj/.gitignore"
    git -C "$proj" add .gitignore
    git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'ignore codegraph'
  fi
  git -C "$proj" worktree add --quiet -b "fixture-$name" "$wt"
  state=absent
  case "$existing" in
    partial) mkdir -p "$wt/.codegraph" ;;
    complete) mkdir -p "$wt/.codegraph"; state=complete ;;
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
printf '%s\n' "$*" >> "${FM_FAKE_CODEGRAPH_LOG:?}"
if [ "${1:-}" = status ]; then
  if [ "${FM_FAKE_CODEGRAPH_STATE:-absent}" = complete ]; then
    printf '{"initialized":true,"index":{"state":"complete","pendingRefs":0}}\n'
  else
    printf '{"initialized":false,"lastIndexed":null}\n'
  fi
  exit 0
fi
if [ "${1:-}" = init ]; then
  mkdir -p "${2:?}/.codegraph"
fi
if [ "${FM_FAKE_CODEGRAPH_RESULT:-ok}" = fail ]; then
  printf 'fake codegraph diagnostic that spawn must suppress\n' >&2
  exit 7
fi
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse" "$fakebin/timeout" "$fakebin/codegraph"
}

run_spawn() {
  local result=${1:-ok} timeout_result=${2:-run}
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_CODEGRAPH_LOG="$CASE_DIR/codegraph.log" FM_FAKE_CODEGRAPH_RESULT="$result" \
    FM_FAKE_CODEGRAPH_STATE="$INDEX_STATE" \
    FM_FAKE_TIMEOUT_RESULT="$timeout_result" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$ID" "$PROJ_DIR" 2>&1
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
  assert_grep "init $WT_DIR" "$CASE_DIR/codegraph.log" "ignored absent worktree did not run codegraph init"
  assert_grep 'codegraph=initialized' "$HOME_DIR/state/$ID.meta" "init outcome was not recorded in meta"
  pass "ignored worktree without an index runs CodeGraph init"
}

test_partial_index_initializes() {
  local rec out status
  rec=$(make_case partial yes partial)
  read_case "$rec"
  install_spawn_fakes "$FAKEBIN_DIR"
  out=$(run_spawn)
  status=$?
  expect_code 0 "$status" "partial CodeGraph index spawn should succeed"
  assert_contains "$out" "spawned $ID" "partial index spawn did not launch"
  assert_grep "init $WT_DIR" "$CASE_DIR/codegraph.log" "partial index did not re-run codegraph init"
  assert_no_grep "sync $WT_DIR" "$CASE_DIR/codegraph.log" "partial index was synced instead of re-initialized"
  assert_grep 'codegraph=initialized' "$HOME_DIR/state/$ID.meta" "init outcome was not recorded in meta"
  pass "worktree with a .codegraph directory but no completed-index marker runs CodeGraph init"
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
  assert_grep "sync $WT_DIR" "$CASE_DIR/codegraph.log" "complete index did not run codegraph sync"
  assert_no_grep "init $WT_DIR" "$CASE_DIR/codegraph.log" "complete index was re-initialized instead of synced"
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

test_nonzero_fails_open() {
  local rec out status warning_count
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
  pass "CodeGraph non-zero exit warns once, records failure, discards the partial index, and fails open"
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

test_no_timeout_runner_preserves_index() {
  local rec out status warning_count
  rec=$(make_case norunner yes complete)
  read_case "$rec"
  install_spawn_fakes "$FAKEBIN_DIR"
  out=$(run_spawn ok unavailable)
  status=$?
  expect_code 0 "$status" "missing timeout runner must not block spawn"
  assert_contains "$out" "spawned $ID" "missing timeout runner prevented launch"
  assert_contains "$out" "warning: CodeGraph init skipped for task $ID because no timeout runner is available; spawn will continue" "missing timeout runner warning was unclear"
  warning_count=$(printf '%s\n' "$out" | grep -c '^warning: CodeGraph ')
  [ "$warning_count" -eq 1 ] || fail "missing timeout runner printed $warning_count warnings instead of one"
  assert_grep 'codegraph=init-unavailable' "$HOME_DIR/state/$ID.meta" "unavailable outcome was not recorded in meta"
  assert_present "$WT_DIR/.codegraph" "missing timeout runner destroyed an index CodeGraph never ran against"
  pass "no timeout runner leaves the existing index untouched, warns once, and fails open"
}

test_ignored_absent_initializes
test_partial_index_initializes
test_complete_index_syncs
test_not_ignored_skips
test_nonzero_fails_open
test_timeout_fails_open
test_no_timeout_runner_preserves_index

echo "# all fm-spawn CodeGraph tests passed"
