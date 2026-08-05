#!/usr/bin/env bash
# Shared, serialized append writer for bounded private event logs.

fm_append_log_record() {  # <path> <device> <record> <schema>
  local path=$1 device=$2 record=$3 schema=$4
  command -v perl >/dev/null 2>&1 || return 1
  perl -MFcntl=:DEFAULT,:flock -e '
    my ($path, $device, $record, $schema) = @ARGV;
    exit 1 unless $device =~ /\A[0-9]+\z/ && length($record) <= 4096;
    sysopen(my $file, $path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0600)
      or exit 1;
    my @stat = stat($file);
    exit 1 unless @stat && -f _ && $stat[0] == $device && $stat[3] == 1;
    chmod(0600, $file) or exit 1;
    flock($file, LOCK_EX) or exit 1;
    open my $reader, "<:raw", $path or exit 1;
    while (my $line = <$reader>) {
      exit 1 unless valid_record($schema, $line);
    }
    close($reader) or exit 1;
    exit 1 unless valid_record($schema, $record);
    my $offset = 0;
    while ($offset < length($record)) {
      my $written = syswrite($file, $record, length($record) - $offset, $offset);
      exit 1 unless defined($written) && $written > 0;
      $offset += $written;
    }
    close($file) or exit 1;

    sub valid_record {
      my ($kind, $line) = @_;
      return $line =~ /\A[A-Za-z0-9_-][A-Za-z0-9._-]*\t(?:implementation|investigation|validation|pr-open|merged|complete)\t[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\n\z/
        if $kind eq "stage";
      return $line =~ /\A(?:REPLY\t[A-Za-z0-9_-][A-Za-z0-9._-]*\t[0-9a-f]{64}\t-|COMMIT\t[A-Za-z0-9_-][A-Za-z0-9._-]*\t[0-9a-f]{64}\t[0-9a-f]{64})\n\z/
        if $kind eq "captain-ruling";
      return 0;
    }
  ' "$path" "$device" "$record" "$schema" 2>/dev/null
}
