#!/bin/bash
# measure.sh -- size things truthfully on APFS.
#
# Three numbers, never conflated:
#   candidate_bytes  allocated, hardlink-deduped, dataless-excluded
#   pending_bytes    moved to the Trash but NOT yet reclaimed
#   reclaimed_bytes  the actual df delta
#
# CleanMyMac's most-criticized trait is an inflated "junk" figure. Everything
# here exists to avoid that.

# cmai_size <path> -- allocated bytes, hardlink-deduped, dataless-excluded.
#
#   -xdev            never cross into another filesystem. A home directory can
#                    contain an NFS or virtual mount; sizing must not wander in.
#   -flags +dataless iCloud placeholders are skipped AND not descended into,
#   -prune           because traversal alone can trigger a download.
#   %b               allocated 512-byte blocks, not %z logical length. This is
#                    the APFS-truthful number for sparse and compressed files.
#   %i %d            inode and device, keyed together, so a file hardlinked into
#                    two directories is counted once. npm and pnpm stores are
#                    hardlink-heavy; naive summation overstates them.
cmai_size() {
  [ -e "$1" ] || { printf '0\n'; return 0; }
  $FIND "$1" -xdev \( -flags +dataless -prune \) -o \( -type f -o -type l \) -print0 2>/dev/null \
  | $XARGS -0 -n 512 "$STAT" -f '%b %i %d' 2>/dev/null \
  | $AWK '!seen[$3":"$2]++ { s += $1 } END { printf "%.0f\n", s*512 }'
}

# cmai_size_fast <path> -- du-based, one traversal, for the overview pass.
# Accurate enough to rank candidates; cmai_size is used once the user is
# actually considering an item.
cmai_size_fast() {
  [ -e "$1" ] || { printf '0\n'; return 0; }
  $DU -skx "$1" 2>/dev/null | $AWK '{printf "%.0f\n", $1*1024}'
}

# cmai_denest -- read paths on stdin, drop any that live inside another.
#
# `du -c a a/b` counts a/b twice. Any total built from overlapping candidates is
# wrong, so overlaps are removed before anything is summed or shown.
# Lexical sort puts a parent immediately before its descendants.
cmai_denest() {
  $SORT | $AWK '
    NR == 1 { keep = $0; print; next }
    index($0, keep "/") == 1 { next }
    { keep = $0; print }'
}

# cmai_mtime_days <path> -- whole days since last modification, or -1.
cmai_mtime_days() {
  local m now
  m=$($STAT -f '%m' "$1" 2>/dev/null) || { printf '%s\n' -1; return 0; }
  [ -n "$m" ] || { printf '%s\n' -1; return 0; }
  now=$($DATE +%s)
  $AWK -v a="$now" -v b="$m" 'BEGIN { printf "%d\n", int((a-b)/86400) }'
}

# cmai_mtime_iso <path> -- last-modified date as YYYY-MM-DD, or "-".
cmai_mtime_iso() {
  $STAT -f '%Sm' -t '%Y-%m-%d' "$1" 2>/dev/null || printf '%s\n' -
}

# --- df delta ---------------------------------------------------------------
# Sampled around each reclaim phase. This, not the sum of candidate sizes, is
# what the final report calls "reclaimed".
_CMAI_DF_BEFORE=""
cmai_df_mark()  { _CMAI_DF_BEFORE=$(cmai_df_avail "${1:-/System/Volumes/Data}"); }
cmai_df_delta() {
  local after
  $SYNC 2>/dev/null || :
  after=$(cmai_df_avail "${1:-/System/Volumes/Data}")
  $AWK -v a="$after" -v b="${_CMAI_DF_BEFORE:-0}" 'BEGIN { printf "%.0f\n", a-b }'
}

# cmai_delta_phrase <delta_bytes> -- the honest sentence for a measured delta.
#
# Below the noise floor we say so rather than printing a spurious figure:
# Spotlight, the `deleted` daemon and ordinary background writes all move this
# number by tens of megabytes on their own.
cmai_delta_phrase() {
  local d="$1" mag
  mag=${d#-}
  if [ "$mag" -lt "$CMAI_NOISE_FLOOR" ]; then
    printf 'no measurable change (within measurement noise)\n'
  elif [ "$d" -lt 0 ]; then
    printf 'disk available fell by %s\n' "$(cmai_human "$mag")"
  else
    printf 'disk available rose by %s\n' "$(cmai_human "$d")"
  fi
}

# cmai_snapshot_count -- local Time Machine snapshots on the data volume.
#
# These pin the blocks of deleted files. Until they expire, a clean can free
# zero bytes. Reporting this up front is the difference between an honest tool
# and a bug report.
cmai_snapshot_count() {
  $TMUTIL listlocalsnapshots /System/Volumes/Data 2>/dev/null \
  | $GREP -c 'com\.apple\.TimeMachine' || printf '0\n'
}
