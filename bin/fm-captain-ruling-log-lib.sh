#!/usr/bin/env bash
# Program-owned captain ruling log and captain-owned editor snapshots.
#
# Records are totally ordered in state/captain-ruling-log.tsv.
# Legacy v1 records have no explicit version or origin:
#   REPLY<TAB><hold-id><TAB><answer-digest><TAB>-
#   COMMIT<TAB><hold-id><TAB><answer-digest><TAB><route-set-digest>
# New v2 records preserve the type in field one for operational compatibility:
#   REPLY<TAB>v2<TAB><hold-id><TAB><answer-digest><TAB>-<TAB><origin>
#   COMMIT<TAB>v2<TAB><hold-id><TAB><answer-digest><TAB><route-set-digest><TAB><origin>
# Readers deliberately interpret legacy records as origin captain-typed because
# v1 could only be produced from the captain-owned reply-file adapter.
# New origins are captain-typed, chat, and linear; linear is reserved for a later
# authenticated adapter and has no public recording path yet.
# The first COMMIT for a hold is its snapshot commit point.
# A later REPLY is a new decision and never supersedes that committed ruling.

# shellcheck source=bin/fm-append-log-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-append-log-lib.sh"

FM_RULING_LOG=${FM_CAPTAIN_RULING_LOG_OVERRIDE:-$STATE/captain-ruling-log.tsv}
FM_RULING_REPLIES=${FM_CAPTAIN_REPLIES_OVERRIDE:-${DATA:-$FM_HOME/data}/captain-replies.md}
FM_RULING_LAST_TYPE=
FM_RULING_LAST_DECISION=
FM_RULING_LAST_ROUTES=
FM_RULING_LAST_ORIGIN=
FM_RULING_COMMITTED_DECISION=
FM_RULING_COMMITTED_ROUTES=
FM_RULING_COMMITTED_ORIGIN=
FM_RULING_LAST_REPLY_DECISION=
FM_RULING_COMMIT_RETRY=0
FM_RULING_COMMIT_CONFLICT=

fm_ruling_sha256() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

fm_ruling_origin_valid() {  # <origin>
  case "$1" in captain-typed|chat|linear) return 0 ;; *) return 1 ;; esac
}

fm_ruling_log_valid() {
  local device
  [ ! -e "$FM_RULING_LOG" ] && [ ! -L "$FM_RULING_LOG" ] && return 0
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_private_file_valid "$FM_RULING_LOG" 600 "$device" || return 1
  command -v perl >/dev/null 2>&1 || return 1
  perl -MFcntl=:DEFAULT -e '
    # FM_RULING_RAW_VALIDATOR: this reader must preserve every ledger byte.
    my ($path, $device) = @ARGV;
    exit 1 unless $device =~ /\A[0-9]+\z/;
    sysopen(my $file, $path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW) or exit 1;
    my @stat = stat($file);
    exit 1 unless @stat && -f _ && $stat[0] == $device && $stat[3] == 1
      && ($stat[2] & 07777) == 0600 && $stat[7] > 0;
    binmode($file, ":raw") or exit 1;
    my ($buffer, $total) = ("", 0);
    while (1) {
      my $read = sysread($file, my $chunk, 4096);
      exit 1 unless defined $read;
      last if $read == 0;
      $total += $read;
      $buffer .= $chunk;
      while ((my $newline = index($buffer, "\n")) >= 0) {
        my $line = substr($buffer, 0, $newline + 1, "");
        exit 1 if length($line) >= 4096 || !valid_record($line);
      }
      exit 1 if length($buffer) > 4096;
    }
    close($file) or exit 1;
    exit 1 unless $buffer eq "" && $total == $stat[7];

    sub valid_record {
      my ($line) = @_;
      return $line =~ /\A(?:REPLY\t[A-Za-z0-9_-][A-Za-z0-9._-]*\t[0-9a-f]{64}\t-|COMMIT\t[A-Za-z0-9_-][A-Za-z0-9._-]*\t[0-9a-f]{64}\t[0-9a-f]{64}|REPLY\tv2\t[A-Za-z0-9_-][A-Za-z0-9._-]*\t[0-9a-f]{64}\t-\t(?:captain-typed|chat|linear)|COMMIT\tv2\t[A-Za-z0-9_-][A-Za-z0-9._-]*\t[0-9a-f]{64}\t[0-9a-f]{64}\t(?:captain-typed|chat|linear))\n\z/;
    }
  ' "$FM_RULING_LOG" "$device" 2>/dev/null
}

fm_ruling_records() {
  fm_ruling_log_valid || return 1
  [ -f "$FM_RULING_LOG" ] || return 0
  awk -F '\t' '
    NF == 4 { print $1 "\t" $2 "\t" $3 "\t" $4 "\tcaptain-typed"; next }
    NF == 6 && $2 == "v2" { print $1 "\t" $3 "\t" $4 "\t" $5 "\t" $6 }
  ' "$FM_RULING_LOG"
}

fm_ruling_append() {  # <type> <id> <decision-digest> <routes-digest-or-dash> <origin>
  local type=$1 id=$2 decision=$3 routes=$4 origin=$5 device record
  fm_ruling_origin_valid "$origin" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  printf -v record '%s\tv2\t%s\t%s\t%s\t%s\n' \
    "$type" "$id" "$decision" "$routes" "$origin"
  fm_append_log_record "$FM_RULING_LOG" "$device" "$record" captain-ruling
}

fm_ruling_last_record() {  # <hold-id>
  local wanted=$1 type id decision routes origin
  FM_RULING_LAST_TYPE=
  FM_RULING_LAST_DECISION=
  FM_RULING_LAST_ROUTES=
  FM_RULING_LAST_ORIGIN=
  fm_ruling_log_valid || return 1
  [ -f "$FM_RULING_LOG" ] || return 0
  while IFS=$'\t' read -r type id decision routes origin; do
    [ "$id" = "$wanted" ] || continue
    FM_RULING_LAST_TYPE=$type
    FM_RULING_LAST_DECISION=$decision
    # shellcheck disable=SC2034 # Completes the last-record read contract for callers.
    FM_RULING_LAST_ROUTES=$routes
    # shellcheck disable=SC2034 # Completes the last-record read contract for callers.
    FM_RULING_LAST_ORIGIN=$origin
  done < <(fm_ruling_records) || return 1
}

fm_ruling_last_reply_record() {  # <hold-id>
  local wanted=$1 type id decision _routes _origin
  FM_RULING_LAST_REPLY_DECISION=
  fm_ruling_log_valid || return 1
  [ -f "$FM_RULING_LOG" ] || return 1
  while IFS=$'\t' read -r type id decision _routes _origin; do
    [ "$type" = REPLY ] && [ "$id" = "$wanted" ] || continue
    FM_RULING_LAST_REPLY_DECISION=$decision
  done < <(fm_ruling_records) || return 1
  [ -n "$FM_RULING_LAST_REPLY_DECISION" ]
}

fm_ruling_last_reply_digest() {  # <hold-id>
  fm_ruling_last_reply_record "$1" || return 1
  printf '%s\n' "$FM_RULING_LAST_REPLY_DECISION"
}

fm_ruling_committed_record() {  # <hold-id>
  local wanted=$1 type id decision routes origin
  FM_RULING_COMMITTED_DECISION=
  FM_RULING_COMMITTED_ROUTES=
  FM_RULING_COMMITTED_ORIGIN=
  fm_ruling_log_valid || return 1
  [ -f "$FM_RULING_LOG" ] || return 0
  while IFS=$'\t' read -r type id decision routes origin; do
    [ "$type" = COMMIT ] && [ "$id" = "$wanted" ] || continue
    if [ -n "$FM_RULING_COMMITTED_DECISION" ] \
      && { [ "$FM_RULING_COMMITTED_DECISION" != "$decision" ] \
        || [ "$FM_RULING_COMMITTED_ROUTES" != "$routes" ] \
        || [ "$FM_RULING_COMMITTED_ORIGIN" != "$origin" ]; }; then
      return 1
    fi
    FM_RULING_COMMITTED_DECISION=$decision
    FM_RULING_COMMITTED_ROUTES=$routes
    FM_RULING_COMMITTED_ORIGIN=$origin
  done < <(fm_ruling_records) || return 1
}

fm_ruling_reply_candidates() {
  local line id answer
  [ -f "$FM_RULING_REPLIES" ] && [ ! -L "$FM_RULING_REPLIES" ] || return 0
  {
    while IFS= read -r line; do
      case "$line" in *:*) ;; *) continue ;; esac
      id=${line%%:*}
      answer=${line#*:}
      id=${id#"${id%%[![:space:]]*}"}
      id=${id%"${id##*[![:space:]]}"}
      answer=${answer#"${answer%%[![:space:]]*}"}
      answer=${answer%"${answer##*[![:space:]]}"}
      fm_pr_task_id_valid "$id" || continue
      case "$answer" in ''|'<answer>'|'[answer]') continue ;; esac
      printf '%s\t%s\tcaptain-typed\n' "$id" "$answer"
    done < "$FM_RULING_REPLIES"
  } | awk -F '\t' '
    { ids[NR] = $1; lines[NR] = $0; last[$1] = NR }
    END { for (row = 1; row <= NR; row++) if (last[ids[row]] == row) print lines[row] }
  '
}

fm_ruling_record() {  # <origin> <hold-id> <answer>
  local origin=$1 id=$2 answer=$3 digest
  fm_ruling_origin_valid "$origin" || return 2
  fm_pr_task_id_valid "$id" || return 2
  [ -n "$answer" ] || return 2
  [ "$(printf '%s' "$answer" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] || return 2
  fm_ruling_log_valid || return 1
  digest=$(fm_ruling_sha256 "$answer") || return 1
  if fm_ruling_last_reply_record "$id" 2>/dev/null \
    && [ "$FM_RULING_LAST_REPLY_DECISION" = "$digest" ]; then
    return 0
  fi
  fm_ruling_append REPLY "$id" "$digest" - "$origin"
}

fm_ruling_ingest() {
  local id answer origin candidates
  fm_ruling_log_valid || return 1
  candidates=$(fm_ruling_reply_candidates) || return 1
  while IFS=$'\t' read -r id answer origin; do
    [ -n "$id" ] && [ -n "$answer" ] || continue
    fm_ruling_record "$origin" "$id" "$answer" || return 1
  done <<< "$candidates"
}

fm_ruling_answer() {  # <hold-id>
  local wanted=$1 id answer _origin digest candidate=
  fm_ruling_ingest || return 1
  fm_ruling_last_record "$wanted" || return 1
  case "$FM_RULING_LAST_TYPE" in REPLY|COMMIT) ;; *) return 1 ;; esac
  while IFS=$'\t' read -r id answer _origin; do
    [ "$id" = "$wanted" ] || continue
    digest=$(fm_ruling_sha256 "$answer") || return 1
    [ "$digest" = "$FM_RULING_LAST_DECISION" ] && candidate=$answer
  done <<< "$(fm_ruling_reply_candidates)"
  [ -n "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

fm_ruling_commit() {  # <hold-id> <decision-digest> <routes-digest>
  local id=$1 decision=$2 routes=$3
  FM_RULING_COMMIT_RETRY=0
  FM_RULING_COMMIT_CONFLICT=
  fm_ruling_ingest || return 1
  fm_ruling_committed_record "$id" || return 1
  if [ -n "$FM_RULING_COMMITTED_DECISION" ]; then
    if [ "$FM_RULING_COMMITTED_DECISION" = "$decision" ] \
      && [ "$FM_RULING_COMMITTED_ROUTES" = "$routes" ]; then
      # shellcheck disable=SC2034 # Read by fm-decision-hold.sh after the call.
      FM_RULING_COMMIT_RETRY=1
      return 0
    fi
    # shellcheck disable=SC2034 # Read by fm-decision-hold.sh after the call.
    FM_RULING_COMMIT_CONFLICT=committed
    return 3
  fi
  fm_ruling_last_record "$id" || return 1
  [ "$FM_RULING_LAST_TYPE" = REPLY ] \
    && [ "$FM_RULING_LAST_DECISION" = "$decision" ] || {
      # shellcheck disable=SC2034 # Read by fm-decision-hold.sh after the call.
      FM_RULING_COMMIT_CONFLICT=observed
      return 3
    }
  fm_ruling_append COMMIT "$id" "$decision" "$routes" "$FM_RULING_LAST_ORIGIN" || return 1
  fm_ruling_committed_record "$id" || return 1
  [ "$FM_RULING_COMMITTED_DECISION" = "$decision" ] \
    && [ "$FM_RULING_COMMITTED_ROUTES" = "$routes" ] \
    && [ "$FM_RULING_COMMITTED_ORIGIN" = "$FM_RULING_LAST_ORIGIN" ]
}
