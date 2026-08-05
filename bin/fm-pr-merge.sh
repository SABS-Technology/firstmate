#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
# A successful merge emits the independent merged work stage.
# Before invoking merge, the wrapper reads forge truth and reconciles an
# already-merged PR by emitting the missing stage without calling merge again.
# That merge-state read uses the stable `gh pr view --json state,mergedAt`
# machine contract, matching every other forge state query in bin/, rather than
# parsing the agent-facing gh-axi rendering that carries no stability guarantee.
# `state` is the only merge signal the CLI exposes: it reads MERGED once the PR
# lands, and mergedAt stays null until then, so the timestamp only corroborates.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

pr_is_merged() {
  local view state merged_at
  view=$(gh pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --json state,mergedAt \
    -q '.state + "\t" + (.mergedAt | tostring)' 2>/dev/null) || return 2
  state=${view%%$'\t'*}
  merged_at=${view#*$'\t'}
  [ "$merged_at" != "$view" ] || return 2
  case "$state" in
    MERGED|merged)
      # mergedAt is null until the PR lands, so a MERGED state without a merge
      # timestamp is an inconsistent read rather than merge truth.
      case "$merged_at" in
        ''|null) return 2 ;;
        *) return 0 ;;
      esac
      ;;
    OPEN|open|CLOSED|closed) return 1 ;;
    *) return 2 ;;
  esac
}

emit_merged_stage() {
  FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-stage.sh" emit "$ID" merged
}

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

if pr_is_merged; then
  emit_merged_stage
  exit 0
else
  state_rc=$?
  [ "$state_rc" -eq 1 ] || {
    echo "error: could not reconcile PR merge state" >&2
    exit 1
  }
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
if ! emit_merged_stage; then
  pr_is_merged || {
    echo "error: merge succeeded but its stage could not be reconciled" >&2
    exit 1
  }
  emit_merged_stage || {
    echo "error: merge is confirmed but the merged stage remains unavailable" >&2
    exit 1
  }
fi
