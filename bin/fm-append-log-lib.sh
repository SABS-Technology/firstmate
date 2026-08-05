#!/usr/bin/env bash
# Shared failure-atomic append writer for bounded private event logs.

fm_append_log_record() {  # <path> <device> <record> <schema>
  local path=$1 device=$2 record=$3 schema=$4
  command -v perl >/dev/null 2>&1 || return 1
  perl -MFcntl=:DEFAULT,:flock -MFile::Basename=dirname -MFile::Temp=tempfile -MIO::Handle -e '
    my ($path, $device, $record, $schema) = @ARGV;
    my $fault = $ENV{FM_APPEND_LOG_FAULT_INJECT} // "";
    exit 1 unless $device =~ /\A[0-9]+\z/ && length($record) <= 4096;
    my $lock_path = "$path.append.lock";
    sysopen(my $lock, $lock_path, O_RDWR | O_CREAT | O_NOFOLLOW, 0600) or exit 1;
    my @lock_stat = stat($lock);
    exit 1 unless @lock_stat && -f _ && $lock_stat[0] == $device && $lock_stat[3] == 1;
    chmod(0600, $lock) or exit 1;
    flock($lock, LOCK_EX) or exit 1;
    my ($replacement, $temporary) = tempfile(".fm-append.XXXXXX", DIR => dirname($path), UNLINK => 0);
    my $ok = eval {
      chmod(0600, $replacement) or die;
      binmode($replacement, ":raw") or die;
      if (-e $path || -l $path) {
        sysopen(my $reader, $path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW) or die;
        my @stat = stat($reader);
        die unless @stat && -f _ && $stat[0] == $device && $stat[3] == 1
          && ($stat[2] & 07777) == 0600;
        binmode($reader, ":raw") or die;
        while (my $line = <$reader>) {
          die unless valid_record($schema, $line);
          write_all($replacement, $line) or die;
        }
        die unless eof($reader) && close($reader);
      }
      die unless valid_record($schema, $record);
      if ($fault eq "partial-record") {
        write_all($replacement, substr($record, 0, int(length($record) / 2))) or die;
        die;
      }
      write_all($replacement, $record) or die;
      die if $fault eq "before-publish";
      $replacement->sync or die;
      close($replacement) or die;
      rename($temporary, $path) or die;
      die if $fault eq "after-publish";
      1;
    };
    if (!$ok) {
      close($replacement);
      unlink($temporary);
      exit 1;
    }
    close($lock) or exit 1;

    sub write_all {
      my ($file, $bytes) = @_;
      my $offset = 0;
      while ($offset < length($bytes)) {
        my $written = syswrite($file, $bytes, length($bytes) - $offset, $offset);
        return 0 unless defined($written) && $written > 0;
        $offset += $written;
      }
      return 1;
    }

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
