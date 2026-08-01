#!/usr/bin/env bash
# Regression test for fm-spawn.sh's fail-open CodeGraph worktree preparation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-codegraph)
HOME_DIR="$TMP_ROOT/home"
PROJ_DIR="$TMP_ROOT/project"
WT_DIR="$TMP_ROOT/worktree"
FAKEBIN_DIR=$(fm_fakebin "$TMP_ROOT")
ID=codegraph-failure
TMUX_LOG="$TMP_ROOT/tmux.log"
CODEGRAPH_LOG="$TMP_ROOT/codegraph.log"

mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
printf 'codex\n' > "$HOME_DIR/config/crew-harness"
printf 'brief for %s\n' "$ID" > "$HOME_DIR/data/$ID/brief.md"
touch "$HOME_DIR/state/.last-watcher-beat"
fm_git_init_commit "$PROJ_DIR"
printf '.codegraph/\n' > "$PROJ_DIR/.gitignore"
git -C "$PROJ_DIR" add .gitignore
git -C "$PROJ_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'ignore codegraph'
git -C "$PROJ_DIR" worktree add --quiet -b fixture-codegraph-failure "$WT_DIR"

cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FAKEBIN_DIR/codegraph" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "${CODEGRAPH_DIR:-}" "$1" "$2" >> "${FM_FAKE_CODEGRAPH_LOG:?}"
exit 7
SH
chmod +x "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/treehouse" "$FAKEBIN_DIR/codegraph"

out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' FM_FAKE_PANE_PATH="$WT_DIR" \
  FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_FAKE_CODEGRAPH_LOG="$CODEGRAPH_LOG" \
  CODEGRAPH_DIR=ambient-override PATH="$FAKEBIN_DIR:$PATH" \
  "$SPAWN" "$ID" "$PROJ_DIR" 2>&1)
status=$?

expect_code 0 "$status" "CodeGraph failure must not block spawn"
assert_contains "$out" "spawned $ID" "CodeGraph failure prevented spawn completion"
assert_contains "$out" "warning: CodeGraph init failed or timed out for task $ID; spawn will continue" \
  "CodeGraph failure did not produce the single fail-open warning"
[ "$(printf '%s\n' "$out" | grep -c '^warning: CodeGraph ')" -eq 1 ] \
  || fail "CodeGraph failure produced more than one warning"
assert_grep ".codegraph|init|$WT_DIR" "$CODEGRAPH_LOG" \
  "CodeGraph did not receive the forced directory, init action, and worktree"
assert_grep 'send-keys' "$TMUX_LOG" "agent launch was not sent after CodeGraph failed"
assert_grep 'codegraph=init-failed' "$HOME_DIR/state/$ID.meta" \
  "CodeGraph failure outcome was not recorded in task metadata"
pass "CodeGraph failure warns once, records the outcome, and still launches the agent"

echo "# all fm-spawn CodeGraph tests passed"
