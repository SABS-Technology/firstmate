#!/usr/bin/env bash
# Generate data/pending-decisions.md from the canonical captain queue.
#
# An absent target is atomically initialized with each marker exactly once on its own line:
#   <!-- BEGIN GENERATED: captain-queue -->
#   <!-- END GENERATED: captain-queue -->
#   <!-- BEGIN APPEND-ONLY: captain-replies -->
#   <!-- END APPEND-ONLY: captain-replies -->
# A present target must already contain the same four-marker scaffold.
# The captain-queue region is replaced atomically from fm-captain-queue.sh
# --json. Everything outside it is copied byte-for-byte, except that missing
# `<hold-task-id>: ` prefixes are appended to the captain-replies region.
# Existing reply-zone bytes are never removed, reordered, or rewritten.
#
# Stable human labels are retained as generated mapping records:
#   <!-- captain-decision: D4 backing-hold-task-id -->
# Retired mappings remain in the generated region so D numbers are never reused.
# Seed existing D labels in those records before the first generation.
#
# Every active captain hold carried by ordinary work receives a reply prefix.
# Captain-kind records remain replyable only when their structured identity is
# valid. Other queue members stay visible with an unavailable-reply warning.
#
# Usage: fm-pending-decisions-generate.sh
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
TARGET="${FM_PENDING_DECISIONS_OVERRIDE:-$FM_HOME/data/pending-decisions.md}"
DATA_DIR=$(dirname "$TARGET")
QUEUE_BEGIN='<!-- BEGIN GENERATED: captain-queue -->'
QUEUE_END='<!-- END GENERATED: captain-queue -->'
REPLY_BEGIN='<!-- BEGIN APPEND-ONLY: captain-replies -->'
REPLY_END='<!-- END APPEND-ONLY: captain-replies -->'
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}
fail() {
  printf 'fm-pending-decisions-generate: %s\n' "$*" >&2
  exit 1
}
case "${1:-}" in
  '') ;;
  -h|--help) [ "$#" -eq 1 ] || exit 2; usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v perl >/dev/null 2>&1 || fail "perl not found"
[ -x "$SCRIPT_DIR/fm-captain-queue.sh" ] || fail "canonical captain queue is unavailable"
[ -d "$DATA_DIR" ] && [ ! -L "$DATA_DIR" ] || fail "target directory is unavailable"
data_device=$(fm_pr_file_device "$DATA_DIR") || fail "target directory is unavailable"
TMP_DIR=
PUBLISH_TMP=
SCAFFOLD_TMP=
cleanup() {
  [ -z "$SCAFFOLD_TMP" ] || rm -f -- "$SCAFFOLD_TMP"
  [ -z "$PUBLISH_TMP" ] || rm -f -- "$PUBLISH_TMP"
  [ -z "$TMP_DIR" ] || rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
if [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
  umask 077
  SCAFFOLD_TMP=$(mktemp "$DATA_DIR/.pending-decisions-scaffold.XXXXXX") \
    || fail "atomic scaffold preparation failed"
  if ! printf '# Captain decisions\n\n%s\n%s\n\n%s\n%s\n' \
    "$REPLY_BEGIN" "$REPLY_END" "$QUEUE_BEGIN" "$QUEUE_END" > "$SCAFFOLD_TMP" \
    || ! chmod 0644 "$SCAFFOLD_TMP" \
    || ! fm_pr_private_file_valid "$SCAFFOLD_TMP" 644 "$data_device"; then
    fail "atomic scaffold preparation failed"
  fi
  if ! ln -- "$SCAFFOLD_TMP" "$TARGET" 2>/dev/null; then
    fail "target changed during generation; refusing to overwrite captain input"
  fi
  rm -f -- "$SCAFFOLD_TMP"
  SCAFFOLD_TMP=
fi
[ -f "$TARGET" ] && [ ! -L "$TARGET" ] || fail "target is not a regular file"
[ "$(fm_pr_file_link_count "$TARGET")" = 1 ] || fail "target must be single-link"
target_device=$(fm_pr_file_device "$TARGET") || fail "target is unavailable"
[ "$data_device" = "$target_device" ] || fail "target is on a different device"
target_mode=$(fm_pr_file_mode "$TARGET") || fail "target mode is unavailable"
target_identity=$(fm_pr_file_identity "$TARGET") || fail "target identity is unavailable"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-pending-decisions.XXXXXX") \
  || fail "temporary workspace is unavailable"
ORIGINAL="$TMP_DIR/original.md"
CURRENT_GENERATED="$TMP_DIR/current-generated.md"
CURRENT_REPLIES="$TMP_DIR/current-replies.md"
MAPPINGS="$TMP_DIR/mappings.tsv"
QUEUE_JSON="$TMP_DIR/queue.json"
QUEUE_IDS="$TMP_DIR/queue.ids"
REPLYABLE_IDS="$TMP_DIR/replyable.ids"
LABELS_JSON="$TMP_DIR/labels.json"
NEW_GENERATED="$TMP_DIR/new-generated.md"
ADDITIONS="$TMP_DIR/reply-additions.md"
CANDIDATE="$TMP_DIR/candidate.md"
perl - "$TARGET" "$ORIGINAL" "$CURRENT_GENERATED" "$CURRENT_REPLIES" \
  "$QUEUE_BEGIN" "$QUEUE_END" "$REPLY_BEGIN" "$REPLY_END" <<'PERL'
use strict;
use warnings;
my ($path, $original, $generated, $replies, $qb, $qe, $rb, $re) = @ARGV;
sub refuse {
  print STDERR "fm-pending-decisions-generate: $_[0]\n";
  exit 1;
}
open my $source, '<:raw', $path or refuse("target could not be read");
local $/;
my $data = <$source>;
close $source or refuse("target could not be read");
my %marker = (
  $qb => ['begin', 'queue'],
  $qe => ['end', 'queue'],
  $rb => ['begin', 'reply'],
  $re => ['end', 'reply'],
);
my %count = map { $_ => 0 } keys %marker;
my @events;
for my $raw (split /(?<=\n)/, $data) {
  my $line = $raw;
  $line =~ s/\n\z//;
  if (exists $marker{$line}) {
    $count{$line}++;
    push @events, $marker{$line};
    next;
  }
  if (index($line, 'GENERATED: captain-queue') >= 0
      || index($line, 'APPEND-ONLY: captain-replies') >= 0) {
    refuse("malformed marker: $line");
  }
}
for my $required ($qb, $qe, $rb, $re) {
  refuse("missing marker: $required") if $count{$required} == 0;
  refuse("malformed marker count: $required") if $count{$required} != 1;
}
my @stack;
for my $event (@events) {
  my ($action, $zone) = @$event;
  if ($action eq 'begin') {
    refuse("nested markers: $zone begins inside $stack[-1]") if @stack;
    push @stack, $zone;
    next;
  }
  refuse("malformed marker order: unexpected $zone end") if !@stack;
  refuse("malformed marker order: $zone end closes $stack[-1]")
    if $stack[-1] ne $zone;
  pop @stack;
}
refuse("malformed marker order: unclosed $stack[-1]") if @stack;
sub region {
  my ($begin, $end) = @_;
  my $start = index($data, "$begin\n");
  refuse("malformed marker: $begin must end with a newline") if $start < 0;
  $start += length($begin) + 1;
  my $finish = index($data, $end, $start);
  refuse("malformed marker order: $end") if $finish < 0;
  return substr($data, $start, $finish - $start);
}
for my $output ([$original, $data], [$generated, region($qb, $qe)],
    [$replies, region($rb, $re)]) {
  open my $fh, '>:raw', $output->[0] or refuse("temporary extraction failed");
  print {$fh} $output->[1] or refuse("temporary extraction failed");
  close $fh or refuse("temporary extraction failed");
}
PERL
perl - "$CURRENT_GENERATED" "$MAPPINGS" <<'PERL'
use strict;
use warnings;
my ($source_path, $output_path) = @ARGV;
open my $source, '<:raw', $source_path or die "mapping source unavailable\n";
open my $output, '>:raw', $output_path or die "mapping output unavailable\n";
my (%labels, %ids);
while (my $line = <$source>) {
  next if index($line, 'captain-decision:') < 0;
  if ($line !~ /\A<!-- captain-decision: (D[1-9][0-9]*) ((?!\.)[A-Za-z0-9._-]+) -->\n?\z/) {
    print STDERR "fm-pending-decisions-generate: malformed decision mapping: $line";
    exit 1;
  }
  my ($label, $id) = ($1, $2);
  if ($labels{$label}++ || $ids{$id}++) {
    print STDERR "fm-pending-decisions-generate: duplicate decision mapping: $label $id\n";
    exit 1;
  }
  print {$output} "$label\t$id\n" or die "mapping output unavailable\n";
}
close $source or die "mapping source unavailable\n";
close $output or die "mapping output unavailable\n";
PERL
if ! "$SCRIPT_DIR/fm-captain-queue.sh" --json > "$QUEUE_JSON"; then
  fail "canonical captain queue failed"
fi
if ! jq -e '
  .schema == "fm-captain-queue.v1"
  and (.count | type) == "number"
  and (.orphan_count | type) == "number"
  and (.items | type) == "array"
  and .count == (.items | length)
  and .orphan_count == ([.items[] | select(.orphan)] | length)
  and ([.items[].id] | unique | length) == (.items | length)
  and all(.items[];
    (.id | type) == "string"
    and (.id | test("^[A-Za-z0-9_-][A-Za-z0-9._-]*$"))
    and (.title | type) == "string"
    and (.found_by | type) == "array"
    and all(.found_by[];
      . == "ready_include_held" or . == "list_kind_captain" or . == "list_state_held")
    and (.orphan | type) == "boolean"
    and (.kind | type) == "string"
    and (.hold_kind | type) == "string"
    and (.hold_reason | type) == "string"
    and (.repo | type) == "string"
    and (.origin | type) == "string"
    and (.decision_key | type) == "string"
    and (.replyable | type) == "boolean")
' "$QUEUE_JSON" >/dev/null; then
  fail "canonical captain queue returned an invalid fm-captain-queue.v1 document"
fi
jq -r '.items[].id' "$QUEUE_JSON" > "$QUEUE_IDS"
jq -r '.items[] | select(.replyable) | .id' \
  "$QUEUE_JSON" > "$REPLYABLE_IDS"
max_label=$(awk -F '\t' '
  { value = substr($1, 2) + 0; if (value > maximum) maximum = value }
  END { print maximum + 0 }
' "$MAPPINGS")
while IFS= read -r id; do
  [ -n "$id" ] || continue
  if ! awk -F '\t' -v wanted="$id" '$2 == wanted { found = 1 } END { exit !found }' \
    "$MAPPINGS"; then
    max_label=$((max_label + 1))
    printf 'D%s\t%s\n' "$max_label" "$id" >> "$MAPPINGS"
  fi
done < "$QUEUE_IDS"
jq -Rn '[inputs | split("\t") | {label:.[0], id:.[1]}]' \
  "$MAPPINGS" > "$LABELS_JSON"
while IFS=$'\t' read -r label id; do
  [ -n "$label" ] && [ -n "$id" ] || continue
  printf '<!-- captain-decision: %s %s -->\n' "$label" "$id"
done < "$MAPPINGS" > "$NEW_GENERATED"
jq -r --slurpfile labels "$LABELS_JSON" '
  def markdown:
    gsub("\\\\"; "\\\\\\\\")
    | gsub("`"; "\\`")
    | gsub("\\r\\n|\\r|\\n"; " ");
  ($labels[0] | map({key:.id, value:.label}) | from_entries) as $by_id
  | (if .count == 1 then "decision" else "decisions" end) as $decision_word
  | (if .orphan_count == 1 then "orphan" else "orphans" end) as $orphan_word
  | [
      "# ⏸ Needs your call",
      "**\(.count) open \($decision_word); \(.orphan_count) queue \($orphan_word).**",
      (.items[] |
        "### \($by_id[.id]) - \(.title | markdown)\n\n"
        + "- **Backing hold task:** `\(.id)`\n"
        + "- **Hold reason:** \(.hold_reason | markdown)\n"
        + "- **Hold kind:** `\(.hold_kind | markdown)`\n"
        + "- **Origin task:** `\(if .origin == "" then "unrecorded" else .origin end)`\n"
        + "- **Repository:** `\(.repo | markdown)`\n"
        + "- **Queue status:** "
        + (if .replyable then
            (if .orphan then "active captain hold; queue orphan disclosed."
             else "active captain hold."
             end)
          elif ((.found_by | index("ready_include_held")) or (.found_by | index("list_state_held"))) then
            "reply unavailable; this item is not a structured active captain decision."
          else
            "reply unavailable; this queue orphan has no active captain hold for the ruling detector."
          end))
    ]
  | join("\n\n") + "\n"
' "$QUEUE_JSON" >> "$NEW_GENERATED"
perl - "$CURRENT_REPLIES" "$REPLYABLE_IDS" "$ADDITIONS" <<'PERL'
use strict;
use warnings;
my ($replies_path, $ids_path, $output_path) = @ARGV;
open my $replies_fh, '<:raw', $replies_path or die "reply extraction unavailable\n";
my $replies;
{
  local $/;
  $replies = <$replies_fh>;
}
close $replies_fh or die "reply extraction unavailable\n";
open my $ids_fh, '<:raw', $ids_path or die "reply ids unavailable\n";
open my $output, '>:raw', $output_path or die "reply additions unavailable\n";
while (my $id = <$ids_fh>) {
  chomp $id;
  next if $id eq '';
  next if $replies =~ /(?:\A|\n)[ \t]*\Q$id\E[ \t]*:/;
  print {$output} "$id: \n" or die "reply additions unavailable\n";
}
close $ids_fh or die "reply ids unavailable\n";
close $output or die "reply additions unavailable\n";
PERL
perl - "$ORIGINAL" "$NEW_GENERATED" "$ADDITIONS" "$CANDIDATE" \
  "$QUEUE_BEGIN" "$QUEUE_END" "$REPLY_BEGIN" "$REPLY_END" <<'PERL'
use strict;
use warnings;
my ($original_path, $generated_path, $additions_path, $output_path,
    $qb, $qe, $rb, $re) = @ARGV;
sub read_raw {
  open my $fh, '<:raw', $_[0] or die "candidate input unavailable\n";
  local $/;
  my $value = <$fh>;
  close $fh or die "candidate input unavailable\n";
  return $value;
}
sub replace_region {
  my ($data_ref, $begin, $end, $replacement) = @_;
  my $start = index($$data_ref, "$begin\n");
  die "validated marker disappeared\n" if $start < 0;
  $start += length($begin) + 1;
  my $finish = index($$data_ref, $end, $start);
  die "validated marker disappeared\n" if $finish < 0;
  substr($$data_ref, $start, $finish - $start, $replacement);
}
my $data = read_raw($original_path);
my $generated = read_raw($generated_path);
my $additions = read_raw($additions_path);
replace_region(\$data, $qb, $qe, $generated);
my $reply_start = index($data, "$rb\n");
die "validated reply marker disappeared\n" if $reply_start < 0;
$reply_start += length($rb) + 1;
my $reply_finish = index($data, $re, $reply_start);
die "validated reply marker disappeared\n" if $reply_finish < 0;
my $replies = substr($data, $reply_start, $reply_finish - $reply_start);
if ($additions ne '') {
  $replies .= "\n" if $replies ne '' && $replies !~ /\n\z/;
  $replies .= $additions;
}
substr($data, $reply_start, $reply_finish - $reply_start, $replies);
open my $output, '>:raw', $output_path or die "candidate output unavailable\n";
print {$output} $data or die "candidate output unavailable\n";
close $output or die "candidate output unavailable\n";
PERL
if cmp -s "$ORIGINAL" "$CANDIDATE"; then
  printf 'pending-decisions: unchanged\n'
  exit 0
fi
if [ "$(fm_pr_file_identity "$TARGET")" != "$target_identity" ] \
  || ! cmp -s "$TARGET" "$ORIGINAL"; then
  fail "target changed during generation; refusing to overwrite captain input"
fi
fm_pr_regular_destination_on_device_or_absent "$TARGET" "$data_device" \
  || fail "target became unsafe during generation"
umask 077
PUBLISH_TMP=$(mktemp "$DATA_DIR/.pending-decisions.XXXXXX") \
  || fail "atomic target preparation failed"
if ! cp "$CANDIDATE" "$PUBLISH_TMP" \
  || ! chmod "$target_mode" "$PUBLISH_TMP" \
  || ! fm_pr_private_file_valid "$PUBLISH_TMP" "$target_mode" "$data_device"; then
  fail "atomic target preparation failed"
fi
if [ "$(fm_pr_file_identity "$TARGET")" != "$target_identity" ] \
  || ! cmp -s "$TARGET" "$ORIGINAL" \
  || ! fm_pr_regular_destination_on_device_or_absent "$TARGET" "$data_device"; then
  fail "target changed during generation; refusing to overwrite captain input"
fi
mv -f -- "$PUBLISH_TMP" "$TARGET" || fail "atomic target publication failed"
PUBLISH_TMP=
count=$(jq -r '.count' "$QUEUE_JSON")
orphans=$(jq -r '.orphan_count' "$QUEUE_JSON")
printf 'pending-decisions: generated %s open decisions (%s orphans)\n' "$count" "$orphans"
