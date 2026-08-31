#!/bin/bash
# manifest.sh -- the audit trail.
#
# TSV is authoritative and append-only: a single printf >> under 512 bytes is
# atomic on macOS, so a manifest survives a crash mid-run. JSONL is materialized
# once at the end via jq, never built incrementally (one jq process per file
# would be unusable at ten thousand files).

CMAI_RUNID=""
CMAI_MANIFEST=""

cmai_manifest_open() {
  cmai_ensure_root
  CMAI_RUNID="${1:-$(cmai_runid)}"
  CMAI_MANIFEST="$CMAI_ROOT/manifest/$CMAI_RUNID.tsv"
  [ -f "$CMAI_MANIFEST" ] && return 0
  {
    printf '# clean-mac-ai manifest\n'
    printf '# runid\t%s\n'   "$CMAI_RUNID"
    printf '# started\t%s\n' "$(cmai_now)"
    printf '# macos\t%s\n'   "${CMAI_OS_FULL:-unknown}"
    printf '# cmai\t%s\n'    "$CMAI_VERSION"
    printf '# uid\t%s\n'     "$($ID -u)"
    printf '# fda\t%s\n'     "${CMAI_FDA:-unknown}"
    printf '# snapshots\t%s\n' "${CMAI_SNAPSHOTS:-0}"
    printf '# df_before\t%s\n' "$(cmai_df_avail)"
    printf '# columns\tts\tstatus\tmethod\tsrc\tdest\tbytes\tundo\tmode\tcategory\tnote\n'
  } >> "$CMAI_MANIFEST"
  printf '%s\n' "$CMAI_RUNID"
}

# cmai_manifest_write <status> <method> <src> <dest> <bytes> <undo> [mode] [category] [note]
#
# status: OK | DRYRUN | SKIP | FAIL | RESTORED
# undo:   full | rebuildable | irreversible | -
cmai_manifest_write() {
  [ -n "$CMAI_MANIFEST" ] || cmai_manifest_open >/dev/null
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(cmai_now)" \
    "$(cmai_tsv_safe "$1")" "$(cmai_tsv_safe "$2")" \
    "$(cmai_tsv_safe "$3")" "$(cmai_tsv_safe "$4")" \
    "${5:-0}" "${6:--}" "${7:--}" "${8:--}" "$(cmai_tsv_safe "${9:--}")" \
    >> "$CMAI_MANIFEST"
}

cmai_manifest_close() {
  local out
  [ -n "$CMAI_MANIFEST" ] || return 0
  printf '# finished\t%s\n'  "$(cmai_now)" >> "$CMAI_MANIFEST"
  printf '# df_after\t%s\n'  "$(cmai_df_avail)" >> "$CMAI_MANIFEST"
  [ -x "$JQ" ] || return 0
  out="${CMAI_MANIFEST%.tsv}.jsonl"
  $GREP -v '^#' "$CMAI_MANIFEST" 2>/dev/null \
  | $JQ -R -c 'split("\t") | {
      ts:.[0], status:.[1], method:.[2], src:.[3], dest:.[4],
      bytes:(.[5]|tonumber? // 0), undo:.[6], mode:.[7],
      category:.[8], note:.[9] }' > "$out" 2>/dev/null || :
  return 0
}

cmai_manifest_list() {
  [ -d "$CMAI_ROOT/manifest" ] || return 0
  $LS -1 "$CMAI_ROOT/manifest" 2>/dev/null | $GREP '\.tsv$' | $SED 's/\.tsv$//' | $SORT -r
}

# Sum of bytes actually moved in a run (status OK only).
cmai_manifest_moved_bytes() {
  local f="$CMAI_ROOT/manifest/$1.tsv"
  [ -f "$f" ] || { printf '0\n'; return 0; }
  $GREP -v '^#' "$f" | $AWK -F'\t' '$2=="OK" { s += $6 } END { printf "%.0f\n", s+0 }'
}
