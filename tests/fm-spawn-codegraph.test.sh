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

make_case() {
  local name=$1 ignored=$2 existing=$3 case_dir home proj wt fakebin
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
  if [ "$existing" = yes ]; then
    mkdir -p "$wt/.codegraph"
  fi
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR ID <<EOF
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
if [ "${FM_FAKE_TIMEOUT_RESULT:-run}" = timeout ]; then
  exit 124
fi
exec "$@"
SH
  cat > "$fakebin/codegraph" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "${FM_FAKE_CODEGRAPH_LOG:?}"
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
    FM_FAKE_TIMEOUT_RESULT="$timeout_result" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$ID" "$PROJ_DIR" 2>&1
}

test_ignored_absent_initializes() {
  local rec out status
  rec=$(make_case init yes no)
  read_case "$rec"
  install_spawn_fakes "$FAKEBIN_DIR"
  out=$(run_spawn)
  status=$?
  expect_code 0 "$status" "ignored absent CodeGraph spawn should succeed"
  assert_contains "$out" "spawned $ID" "ignored absent spawn did not launch"
  assert_grep "init|$WT_DIR" "$CASE_DIR/codegraph.log" "ignored absent worktree did not run codegraph init"
  assert_grep 'codegraph=initialized' "$HOME_DIR/state/$ID.meta" "init outcome was not recorded in meta"
  pass "ignored worktree without an index runs CodeGraph init"
}

test_ignored_present_syncs() {
  local rec out status
  rec=$(make_case sync yes yes)
  read_case "$rec"
  install_spawn_fakes "$FAKEBIN_DIR"
  out=$(run_spawn)
  status=$?
  expect_code 0 "$status" "ignored existing CodeGraph spawn should succeed"
  assert_contains "$out" "spawned $ID" "ignored existing spawn did not launch"
  assert_grep "sync|$WT_DIR" "$CASE_DIR/codegraph.log" "ignored existing worktree did not run codegraph sync"
  assert_grep 'codegraph=synced' "$HOME_DIR/state/$ID.meta" "sync outcome was not recorded in meta"
  pass "ignored worktree with an index runs CodeGraph sync"
}

test_not_ignored_skips() {
  local rec out status
  rec=$(make_case skip no no)
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
  rec=$(make_case failure yes no)
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
  pass "CodeGraph non-zero exit warns once, records failure, and fails open"
}

test_timeout_fails_open() {
  local rec out status
  rec=$(make_case timeout yes no)
  read_case "$rec"
  install_spawn_fakes "$FAKEBIN_DIR"
  out=$(run_spawn ok timeout)
  status=$?
  expect_code 0 "$status" "CodeGraph timeout must not block spawn"
  assert_contains "$out" "spawned $ID" "CodeGraph timeout prevented launch"
  assert_contains "$out" "warning: CodeGraph init timed out after 30s for task $ID; spawn will continue" "CodeGraph timeout warning was unclear"
  assert_grep 'codegraph=init-timeout' "$HOME_DIR/state/$ID.meta" "timeout outcome was not recorded in meta"
  pass "CodeGraph timeout warns, records timeout, and fails open"
}

test_ignored_absent_initializes
test_ignored_present_syncs
test_not_ignored_skips
test_nonzero_fails_open
test_timeout_fails_open

echo "# all fm-spawn CodeGraph tests passed"
