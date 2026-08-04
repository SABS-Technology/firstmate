#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, records completion attestation
# in the originating task's metadata, and closes a hold only after a durable
# decision record has been linked to existing dependent work.
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. Repeating `hold` with the same identity
# is idempotent. A different decision key creates a different backlog identity.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
#
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#   fm-decision-hold.sh resolve-item <task-id> --decision-file <path>
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded.
#
# `resolve` requires the canonical regular data/decisions/<hold-id>.md record.
# Every --routed-to task must durably point to that exact record in its body or brief and be blocked by the hold.
# It also discovers every other task in the active home that is still blocked by
# that hold and refuses while any of them is absent from --routed-to, so the caller
# cannot close a hold that still owns undisclosed dependent work.
# Direct concurrent backlog mutation is unsupported.
# The command requires ownership of the home session lock and refuses if the blocked-dependent set changes between enumeration and the first mutation.
# It then re-reads the captain's current reply through
# `fm-captain-ruling-check.sh --answer` and refuses when that reply differs from the
# prepared decision record, so a ruling revised during the agent turn is never closed
# on superseded text. That read only ever refuses; it never supplies decision text.
# Reply ingestion and resolution share state/.captain-ruling-resolution.lock from the first freshness read through hold closure.
# A scoped ruling revision guard follows every body write, dependency unblock,
# and hold close. If an actor bypasses the serialization contract and changes the
# answer during that window, the resolver rolls back its mutations and refuses.
# The re-read is skipped only once the identical decision is already committed to the
# hold body, because that retry finishes an existing close rather than deciding a new
# one; a changed decision is still rejected by the retry identity record.
# It writes the captain decision and routed identities into a captain-kind hold,
# clears those dependency edges, and only then marks that dedicated hold Done.
# For a structured captain hold carried by ordinary work, resolve records the
# decision and clears only the hold; it can never mark the work item Done.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
RULING_CHECK="$SCRIPT_DIR/fm-captain-ruling-check.sh"
RULING_LOCK="$STATE/.captain-ruling-resolution.lock"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

hold_id() {  # <origin-id> <decision-key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s\n' "$1" "$2"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

decoded_field() {  # <show-output> <field>
  local raw
  raw=$(show_field "$1" "$2")
  case "$raw" in
    \"*) printf '%s' "$raw" | jq -Rr fromjson ;;
    *) printf '%s' "$raw" ;;
  esac
}

blocked_edges() {  # <show-output>
  local blocked
  # tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
  blocked=$(show_field "$1" blocked_by | tr -d '[:space:]')
  blocked=${blocked#\"}
  blocked=${blocked%\"}
  printf '%s' "$blocked"
}

blocked_row_ids() {
  awk '
    /^tasks\[[0-9]+\]\{/ { in_group = 1; next }
    in_group && /^[[:alnum:]_]+\[[0-9]+\]/ { in_group = 0 }
    in_group && /^  [A-Za-z0-9._-]+,/ {
      row = $0
      sub(/^  /, "", row)
      sub(/,.*/, "", row)
      print row
    }
  '
}

hold_dependents() {  # <hold-id>
  local id=$1 listing dep show
  listing=$(tasks_axi list --blocked --fields blocked_by) || return 1
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    show=$(task_show "$dep") || return 1
    case ",$(blocked_edges "$show")," in
      *",$id,"*) printf '%s\n' "$dep" ;;
    esac
  done <<EOF
$(printf '%s\n' "$listing" | blocked_row_ids)
EOF
}

current_captain_answer() {  # <hold-id>
  [ -x "$RULING_CHECK" ] || return 1
  FM_CAPTAIN_RULING_LOCK_HELD=1 FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_PENDING_DECISIONS_OVERRIDE="$DATA/pending-decisions.md" \
    "$RULING_CHECK" --answer "$1" 2>/dev/null
}

captain_answer_matches() {  # <hold-id> <decision>
  local answer
  answer=$(FM_CAPTAIN_RULING_LOCK_HELD=1 FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="$STATE" \
    FM_PENDING_DECISIONS_OVERRIDE="$DATA/pending-decisions.md" \
    "$RULING_CHECK" --answer-locked "$1" 2>/dev/null) || return 1
  [ -n "$answer" ] && [ "$answer" = "$2" ]
}

verify_decision_is_current() {  # <hold-id> <decision>
  local id=$1 decision=$2 answer
  answer=$(current_captain_answer "$id") \
    || fail "could not affirm the current captain reply for $id"
  [ -n "$answer" ] \
    || fail "could not affirm a non-empty current captain reply for $id"
  [ "$answer" = "$decision" ] \
    || fail "captain hold $id has a newer captain reply than the prepared decision record"
}

active_hold_state() {  # <state>
  case "$1" in
    queued|in_flight) return 0 ;;
    *) return 1 ;;
  esac
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1" >/dev/null 2>&1
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

verify_hold_active() {  # <hold-id>
  local id=$1 show state held kind hold_kind
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  active_hold_state "$state" \
    || fail "captain hold $id is not queued or in flight (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
}

verify_hold_resolved() {  # <hold-id>
  local id=$1 show state kind body
  show=$(task_show "$id") || return 1
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  [ "$state" = "done" ] || return 1
  [ "$kind" = captain ] || return 1
  case "$body" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
  esac
  return 1
}

verify_hold_durable() {  # <hold-id>
  local id=$1 show state held kind hold_kind body
  show=$(task_show "$id") || fail "captain decision $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  if active_hold_state "$state" && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  if [ "$state" = "done" ] && [ "$kind" = captain ]; then
    case "$body" in
      *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
    esac
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

verify_embedded_hold_active() {  # <hold-id> [<origin-id> <decision-key>]
  local id=$1 origin=${2:-} key=${3:-} show state held kind hold_kind body
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  active_hold_state "$state" \
    || fail "captain hold $id is not queued or in flight (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" != captain ] || fail "backlog item $id is not ordinary work"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
  if [ -n "$origin" ] || [ -n "$key" ]; then
    [ -n "$origin" ] && [ -n "$key" ] || fail "ordinary hold identity requires both origin and decision key"
    verify_hold_identity "$id" "$origin" "$key" "$body"
  fi
}

embedded_resolution_marker() {  # <decision-digest> <decision-pointer>
  printf 'Captain decision recorded by fm-decision-hold.\nDecision digest: %s\nDecision record: %s' "$1" "$2"
}

verify_embedded_resolution_identity() {  # <hold-id> <decoded-body> <decision-digest> <decision-pointer>
  local id=$1 body=$2 marker
  marker=$(embedded_resolution_marker "$3" "$4")
  case "$body" in
    *"$marker"*) return 0 ;;
  esac
  fail "ordinary work item $id has no matching decision-resolution record"
}

verify_embedded_hold_resolved() {  # <hold-id> <decision-digest> <decision-pointer>
  local id=$1 show state held kind body
  show=$(task_show "$id") || return 1
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  body=$(decoded_field "$show" body)
  active_hold_state "$state" || return 1
  [ "$held" = no ] || return 1
  [ "$kind" != captain ] || return 1
  case "$body" in
    *"Captain decision recorded by fm-decision-hold."*)
      verify_embedded_resolution_identity "$id" "$body" "$2" "$3"
      ;;
    *) return 1 ;;
  esac
}

restore_embedded_hold() {  # <hold-id> <original-body> <original-state> <hold-reason>
  local id=$1 original_body=$2 original_state=$3 hold_reason=$4
  tasks_axi update "$id" --body "$original_body" >/dev/null \
    || fail "captain ruling changed during resolve and the ordinary work body could not be rolled back"
  tasks_axi hold "$id" --reason "$hold_reason" --kind captain >/dev/null \
    || fail "captain ruling changed during resolve and the ordinary work hold could not be restored"
  if [ "$original_state" = in_flight ]; then
    tasks_axi start "$id" >/dev/null \
      || fail "captain ruling changed during resolve and the in-flight work state could not be restored"
  fi
}

resolve_embedded_hold() {  # <id> <origin> <key> <decision> <digest> <pointer>
  local id=$1 origin=$2 key=$3 decision=$4 decision_digest=$5 decision_pointer=$6
  local show original_body original_state hold_reason body marker
  if verify_embedded_hold_resolved "$id" "$decision_digest" "$decision_pointer"; then
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_embedded_hold_active "$id" "$origin" "$key"
  show=$(task_show "$id")
  original_body=$(decoded_field "$show" body)
  original_state=$(show_field "$show" state)
  hold_reason=$(decoded_field "$show" hold_reason)
  verify_decision_is_current "$id" "$decision"
  marker=$(embedded_resolution_marker "$decision_digest" "$decision_pointer")
  body=$(printf '%s\n\n%s\n\nCaptain decision:\n%s' "$original_body" "$marker" "$decision")
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on ordinary work item $id"
  if ! captain_answer_matches "$id" "$decision"; then
    restore_embedded_hold "$id" "$original_body" "$original_state" "$hold_reason"
    fail "captain hold $id has a newer captain reply than the prepared decision record"
  fi
  tasks_axi unhold "$id" >/dev/null \
    || fail "could not clear the resolved captain hold from ordinary work item $id"
  if ! captain_answer_matches "$id" "$decision"; then
    restore_embedded_hold "$id" "$original_body" "$original_state" "$hold_reason"
    fail "captain hold $id has a newer captain reply than the prepared decision record"
  fi
  verify_embedded_hold_resolved "$id" "$decision_digest" "$decision_pointer" \
    || fail "ordinary work item $id did not retain its durable decision record"
  printf 'resolved: %s (ordinary work remains active)\n' "$id"
}

command_resolve_item() {
  local id=${1:-} decision_file='' decision decision_digest decision_pointer show kind
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
  decision=$(cat "$decision_file")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  require_tasks_axi
  require_canonical_decision_file "$id" "$decision_file"
  require_session_lock_ownership
  if [ "${FM_CAPTAIN_RULING_LOCK_HELD:-0}" != 1 ]; then
    fm_lock_try_acquire "$RULING_LOCK" \
      || fail "captain ruling ingestion is already active; resolve refused"
    trap 'fm_lock_release "$RULING_LOCK"' EXIT
    export FM_CAPTAIN_RULING_LOCK_HELD=1
  fi
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  kind=$(show_field "$show" kind)
  [ "$kind" != captain ] \
    || fail "resolve-item is only for captain holds carried by ordinary work"
  decision_digest=$(sha256_text "$decision")
  decision_pointer="data/decisions/$id.md"
  resolve_embedded_hold "$id" '' '' "$decision" "$decision_digest" "$decision_pointer"
}

restore_captain_resolution() {  # <hold-id> <original-body> <original-state> <hold-reason> <released> <closed>
  local id=$1 original_body=$2 original_state=$3 hold_reason=$4 released=$5 closed=$6 dep
  if [ "$closed" = 1 ]; then
    tasks_axi reopen "$id" >/dev/null \
      || fail "captain ruling changed during resolve and the closed hold could not be reopened"
  fi
  for dep in $released; do
    tasks_axi block "$dep" --by "$id" >/dev/null \
      || fail "captain ruling changed during resolve and the dependency on $dep could not be restored"
  done
  tasks_axi update "$id" --body "$original_body" >/dev/null \
    || fail "captain ruling changed during resolve and the hold body could not be rolled back"
  tasks_axi hold "$id" --reason "$hold_reason" --kind captain >/dev/null \
    || fail "captain ruling changed during resolve and the captain hold could not be restored"
  if [ "$original_state" = in_flight ]; then
    tasks_axi start "$id" >/dev/null \
      || fail "captain ruling changed during resolve and the in-flight hold state could not be restored"
  fi
}

guard_captain_ruling_revision() {  # <id> <decision> <original-body> <original-state> <hold-reason> <released> <closed>
  captain_answer_matches "$1" "$2" && return 0
  restore_captain_resolution "$1" "$3" "$4" "$5" "$6" "$7"
  fail "captain hold $1 has a newer captain reply than the prepared decision record"
}

verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 resolution_prefix resolution_fields recorded_digest recorded_routes
  resolution_prefix='"Resolution recorded by fm-decision-hold.\nDecision digest: '
  case "$hold_body" in
    "$resolution_prefix"*) resolution_fields=${hold_body#"$resolution_prefix"} ;;
    *) fail "captain hold $id has no retry identity record" ;;
  esac
  case "$resolution_fields" in
    *'\nRouted identities: '*'\n\nCaptain decision:'*) : ;;
    *) fail "captain hold $id has an invalid retry identity record" ;;
  esac
  recorded_digest=${resolution_fields%%\\n*}
  resolution_fields=${resolution_fields#*\\nRouted identities: }
  recorded_routes=${resolution_fields%%\\n*}
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

verify_hold_identity() {  # <hold-id> <origin-id> <decision-key> <body>
  local id=$1 origin=$2 key=$3 body=$4 expected
  expected=$(printf '"Origin: %s\\nDecision key: %s\\n' "$origin" "$key")
  case "$body" in
    "$expected"*) return 0 ;;
  esac
  fail "existing captain hold $id has missing or conflicting canonical identity fields"
}

require_canonical_decision_file() {  # <hold-id> <path>
  local id=$1 path=$2 canonical="$DATA/decisions/$1.md"
  [ "$path" = "$canonical" ] \
    || fail "decision file must be the canonical record: $canonical"
  [ -f "$canonical" ] && [ ! -L "$canonical" ] \
    || fail "canonical decision record must be a regular file: $canonical"
}

routed_has_decision_pointer() {  # <task-id> <pointer> <show-output>
  local dep=$1 pointer=$2 show=$3 brief="$DATA/$1/brief.md" body
  body=$(show_field "$show" body)
  case "$body" in
    *"Decision record: $pointer\\n"*|*"Decision record: $pointer\""|*"Decision record: $pointer") return 0 ;;
  esac
  [ -f "$brief" ] && [ ! -L "$brief" ] \
    && grep -Fqx -- "Decision record: $pointer" "$brief"
}

require_session_lock_ownership() {
  local lock="$STATE/.lock" holder pid=$$ parent steps=0
  [ -f "$lock" ] && [ ! -L "$lock" ] \
    || fail "resolve requires ownership of the home session lock: $lock"
  IFS= read -r holder < "$lock" \
    || fail "resolve could not read the home session lock: $lock"
  case "$holder" in
    ''|*[!0-9]*) fail "resolve found an invalid home session lock: $lock" ;;
  esac
  while [ "$steps" -lt 16 ]; do
    [ "$pid" = "$holder" ] && return 0
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]') \
      || fail "resolve could not verify home session lock ownership"
    [ -n "$parent" ] && [ "$parent" != 1 ] \
      || fail "resolve does not own the home session lock (holder=$holder)"
    pid=$parent
    steps=$((steps + 1))
  done
  fail "resolve does not own the home session lock (holder=$holder)"
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' id show state kind existing_title body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    body=$(show_field "$show" body)
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
    verify_hold_identity "$id" "$origin" "$key" "$body"
  else
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with decision keys"
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
  done <<EOF
$open
EOF

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      printf 'captain-held [key=%s]: tracked by %s\n' "$key" "$(hold_id "$origin" "$key")" >> "$status_file"
      key_seen=1
    done <<EOF
$raw_open
EOF
  fi
  : "$key_seen"
  printf 'complete: %s decision inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    verify_hold_durable "$(hold_id "$origin" "$key")"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' decision='' decision_digest='' decision_pointer='' body='' routed='' routed_csv='' dep show blocked state kind hold_show hold_body original_hold_body original_hold_state original_hold_reason dependents current_dependents released='' resolution_recorded=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
  decision=$(cat "$decision_file")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  decision_digest=$(sha256_text "$decision")
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  require_canonical_decision_file "$id" "$decision_file"
  require_session_lock_ownership
  if [ "${FM_CAPTAIN_RULING_LOCK_HELD:-0}" != 1 ]; then
    fm_lock_try_acquire "$RULING_LOCK" \
      || fail "captain ruling ingestion is already active; resolve refused"
    trap 'fm_lock_release "$RULING_LOCK"' EXIT
    export FM_CAPTAIN_RULING_LOCK_HELD=1
  fi
  decision_pointer="data/decisions/$id.md"
  hold_show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  kind=$(show_field "$hold_show" kind)
  if [ "$kind" != captain ]; then
    [ -z "$routed" ] \
      || fail "ordinary-work captain decisions do not accept --routed-to; resolving the decision must not release work dependencies"
    resolve_embedded_hold "$id" "$origin" "$key" "$decision" "$decision_digest" "$decision_pointer"
    return 0
  fi
  [ -n "$routed" ] || fail "at least one --routed-to task is required"
  if verify_hold_resolved "$id"; then
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$(task_show "$id")
  hold_body=$(show_field "$hold_show" body)
  original_hold_body=$(decoded_field "$hold_show" body)
  original_hold_state=$(show_field "$hold_show" state)
  original_hold_reason=$(decoded_field "$hold_show" hold_reason)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
      resolution_recorded=1
      ;;
  esac

  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    routed_has_decision_pointer "$dep" "$decision_pointer" "$show" \
      || fail "routed task $dep does not point to $decision_pointer in its durable body or brief"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    blocked=$(blocked_edges "$show")
    case ",$blocked," in
      *",$id,"*) : ;;
      *)
        case "$hold_body" in
          *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
          *) fail "routed task $dep is not durably blocked by $id" ;;
        esac
        ;;
    esac
  done

  dependents=$(hold_dependents "$id" | LC_ALL=C sort -u) \
    || fail "could not enumerate the work blocked by $id"
  for dep in $dependents; do
    case " $routed " in
      *" $dep "*) : ;;
      *) fail "task $dep is still blocked by $id and is not routed" ;;
    esac
  done

  [ "$resolution_recorded" = 1 ] || verify_decision_is_current "$id" "$decision"

  current_dependents=$(hold_dependents "$id" | LC_ALL=C sort -u) \
    || fail "could not re-enumerate the work blocked by $id"
  [ "$current_dependents" = "$dependents" ] \
    || fail "work blocked by $id changed during resolve; direct concurrent backlog mutation is unsupported"

  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\n\nCaptain decision:\n%s\n\nRouted work:' "$decision_digest" "$routed_csv" "$decision")
  for dep in $routed; do
    body="${body}"$'\n'"- ${dep}"
  done
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  if [ "$resolution_recorded" != 1 ]; then
    guard_captain_ruling_revision "$id" "$decision" "$original_hold_body" \
      "$original_hold_state" "$original_hold_reason" "$released" 0
  fi
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    blocked=$(blocked_edges "$show")
    case ",$blocked," in
      *",$id,"*)
        tasks_axi unblock "$dep" --by "$id" >/dev/null \
          || fail "could not route the recorded decision to $dep"
        released="${released}${released:+ }$dep"
        if [ "$resolution_recorded" != 1 ]; then
          guard_captain_ruling_revision "$id" "$decision" "$original_hold_body" \
            "$original_hold_state" "$original_hold_reason" "$released" 0
        fi
        ;;
    esac
  done
  tasks_axi "done" "$id" >/dev/null || fail "could not close resolved captain hold $id"
  if [ "$resolution_recorded" != 1 ]; then
    guard_captain_ruling_revision "$id" "$decision" "$original_hold_body" \
      "$original_hold_state" "$original_hold_reason" "$released" 1
  fi
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  resolve-item) shift; command_resolve_item "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
