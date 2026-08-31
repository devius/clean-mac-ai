#!/bin/bash
# restore.sh -- undo, and an honest account of undo's limits.
#
# Records are replayed newest-first so that nested moves unwind in the right
# order. What can and cannot come back is documented in docs/UNDO.md; the same
# classification lives in each manifest row's `undo` column.

cmai_restore_run() {
  local runid="$1" apply="${2:-0}"
  local f ts status method src dest bytes undo mode cat note
  local restored=0 skipped=0 manual=0

  f="$CMAI_ROOT/manifest/$runid.tsv"
  [ -f "$f" ] || cmai_die "no such run: $runid (try: cmai runs)"

  # tail -r replays newest-first: a child moved after its parent must return first.
  $GREP -v '^#' "$f" | /usr/bin/tail -r | while IFS=$'\t' read -r ts status method src dest bytes undo mode cat note; do
    [ -n "${status:-}" ] || continue
    case "$status" in OK) ;; *) continue ;; esac

    case "$undo" in
      irreversible)
        printf 'CANNOT UNDO\t%s\t%s\n' "$method" "$src"
        manual=$((manual+1)); continue ;;
      rebuildable)
        printf 'REBUILD ONLY\t%s\t%s\n' "$method" "$src"
        manual=$((manual+1)); continue ;;
    esac

    case "$method" in
      quarantine)
        if [ ! -e "$dest" ]; then
          printf 'MISSING\t%s\tquarantined copy is gone\n' "$src"; skipped=$((skipped+1)); continue
        fi
        if [ -e "$src" ]; then
          printf 'CONFLICT\t%s\tsomething exists at the original path; not overwriting\n' "$src"
          skipped=$((skipped+1)); continue
        fi
        if [ "$apply" = 1 ]; then
          $MKDIR -p "$($DIRNAME "$src")" 2>/dev/null
          if $MV -n "$dest" "$src" 2>/dev/null; then
            cmai_manifest_write RESTORED quarantine "$dest" "$src" "$bytes" - "$mode" "$cat" "restored from run $runid"
            printf 'RESTORED\t%s\n' "$src"; restored=$((restored+1))
          else
            printf 'FAILED\t%s\n' "$src"; skipped=$((skipped+1))
          fi
        else
          printf 'WOULD RESTORE\t%s\n' "$src"; restored=$((restored+1))
        fi ;;
      trash|finder)
        # Reaching into ~/.Trash needs Full Disk Access, and the user may have
        # emptied it. Finder's own Put Back is the reliable route, so point at it
        # rather than pretending to a capability we may not have.
        printf 'IN TRASH\t%s\tuse Finder > Put Back (item: %s)\n' "$src" "$($BASENAME "$src")"
        manual=$((manual+1)) ;;
      *)
        printf 'NO ACTION\t%s\t%s\n' "$method" "$src"; skipped=$((skipped+1)) ;;
    esac
  done

  return 0
}

# What a run did, and what of it can be taken back.
cmai_restore_summary() {
  local runid="$1" f="$CMAI_ROOT/manifest/$1.tsv"
  [ -f "$f" ] || cmai_die "no such run: $runid"
  $GREP -v '^#' "$f" | $AWK -F'\t' -v OFS='\t' '
    $2 == "OK" { n[$7]++; b[$7] += $6 }
    END {
      print "undo_class", "items", "bytes"
      for (k in n) print (k == "" ? "-" : k), n[k], b[k]
    }'
}
