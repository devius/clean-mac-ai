#!/bin/bash
# report.sh -- say what actually happened.
#
# The distinction this file exists to preserve: moving files to the Trash does
# not free space. A tool that trashes 4 GB and reports "4 GB freed" is lying;
# the space returns only when the Trash is emptied. Every number here is
# labelled with which of the three it is.

cmai_report_run() {
  local runid="$1" f moved dfb dfa delta snaps
  f="$CMAI_ROOT/manifest/$runid.tsv"
  [ -f "$f" ] || return 0

  moved=$(cmai_manifest_moved_bytes "$runid")
  dfb=$($GREP '^# df_before' "$f" 2>/dev/null | $AWK -F'\t' '{print $2}')
  dfa=$($GREP '^# df_after'  "$f" 2>/dev/null | $AWK -F'\t' '{print $2}')
  snaps=$($GREP '^# snapshots' "$f" 2>/dev/null | $AWK -F'\t' '{print $2}')
  delta=$($AWK -v a="${dfa:-0}" -v b="${dfb:-0}" 'BEGIN { printf "%.0f\n", a-b }')

  printf '\n'
  printf 'run                %s\n' "$runid"
  if [ "$CMAI_DRY_RUN" = 1 ]; then
    printf 'mode               dry run -- nothing was changed\n'
  fi
  printf 'items moved        %s\n' "$($GREP -cv '^#' "$f" 2>/dev/null)"
  printf 'bytes moved        %s\n' "$(cmai_human "${moved:-0}")"
  printf 'disk change        %s\n' "$(cmai_delta_phrase "${delta:-0}")"

  # The three explanations for "I moved gigabytes and nothing changed", in the
  # order they actually apply. Saying this up front is the difference between an
  # honest report and a bug report.
  if [ "${moved:-0}" -gt 0 ] && [ "${delta:-0}" -lt "$CMAI_NOISE_FLOOR" ]; then
    printf '\n'
    printf 'Bytes moved and disk change disagree. That is expected:\n'
    printf '  - Trashed items still occupy space until the Trash is emptied.\n'
    [ "${snaps:-0}" -gt 0 ] && \
    printf '  - %s local Time Machine snapshot(s) still pin the blocks of deleted files.\n' "$snaps"
    printf '  - APFS clones share storage, so a directory total can exceed what its removal returns.\n'
  fi

  printf '\nundo\n'
  cmai_restore_summary "$runid" 2>/dev/null | $SED 's/^/  /'
  printf '\n  restore what can be restored:  cmai restore --run %s --apply\n' "$runid"
  printf '  full detail:                   %s\n' "$f"
}

# cmai_apply_ids <comma-separated ids>
#
# Ids come from a prior scan. The scan is re-run so that sizes and guard
# verdicts are current: acting on a stale scan is how a cleaner deletes
# something the user started using ten minutes ago.
# cmai_apply_ids <ids> [scan-target]
#
# The scan is re-run so sizes and guard verdicts are current: acting on a stale
# scan is how a cleaner deletes something the user started using ten minutes
# ago. The target narrows which scan resolves the ids, because a full rescan to
# act on one project artifact is a poor trade. Safety is unaffected either way:
# cmai_reclaim_one calls guard_path again at the moment of action.
cmai_apply_ids() {
  local ids="$1" from="${2:-all}" line id path mode method undo confirmed=0
  local want; want=$(printf '%s' "$ids" | $TR ',' '\n' | $GREP -v '^$' | $SORT -u)
  # A single id is an individual confirmation; a list is a batch, and ASK
  # rows in a batch are still skipped.
  [ "$(printf '%s\n' "$want" | $GREP -c .)" = 1 ] && confirmed=1

  _cmai_scan_run "$from" | while IFS=$'\t' read -r id _cat _sub path _bytes _human _risk verdict mode method undo _needs _owner _last _why; do
    [ -n "$(printf '%s' "$want" | $GREP -x "$id")" ] || continue
    case "$verdict" in
      DENY) cmai_warn "refused (protected): $path"; continue ;;
      INFO) continue ;;
    esac
    case "$method" in
      none|defer|report) cmai_warn "not actionable here: $path"; continue ;;
      gc:*) cmai_warn "use 'cmai gc' for $path"; continue ;;
    esac
    cmai_reclaim_one "$path" "${mode:-self}" "${_cat:-space}" "$confirmed"
  done
}

# cmai_doctor -- self-check. Answers "is this tool safe to run here?"
cmai_doctor() {
  local rc=0 p
  printf 'check\tresult\tdetail\n'
  printf 'bash\t%s\t%s\n' "$([ -x /bin/bash ] && printf ok || printf MISSING)" "$(/bin/bash --version 2>/dev/null | $AWK 'NR==1{print $4}')"
  # $REALPATH earns its place here: guard_path resolves every path through it,
  # so without it the kernel returns E_UNRESOLVED for everything and refuses the
  # entire disk. That failure is safe but invisible, which is the problem.
  for p in "$FIND" "$STAT" "$DF" "$AWK" "$TRASH" "$JQ" "$TMUTIL" \
           "$REALPATH" "$SQLITE3" "$LSOF" "$PLUTIL" "$CODESIGN"; do
    if [ -x "$p" ]; then printf 'tool\tok\t%s\n' "$p"
    else printf 'tool\tMISSING\t%s\n' "$p"; rc=1; fi
  done

  # git is reported separately because "present" is not the same as "usable":
  # /usr/bin/git is a Command Line Tools stub, and when it cannot run, the
  # tracked-source check can no longer tell build output from committed code.
  case "$(cmai_git_probe)" in
    yes)  printf 'git\tok\t%s\n' "$GIT" ;;
    stub) printf 'git\tSTUB\tpresent but the Xcode Command Line Tools are absent; run: xcode-select --install\n'; rc=1 ;;
    *)    printf 'git\tMISSING\t%s\n' "$GIT"; rc=1 ;;
  esac
  if [ -f "$CMAI_DENYLIST" ]; then
    printf 'denylist\tok\t%s rules\n' "$($GREP -cv '^#\|^$' "$CMAI_DENYLIST")"
  else
    printf 'denylist\tMISSING\t%s\n' "$CMAI_DENYLIST"; rc=1
  fi

  # The guard must refuse the obvious catastrophes. If this ever prints FAIL,
  # nothing else in the tool should be trusted.
  for p in / /System /usr "$HOME"; do
    guard_path "$p" doctor >/dev/null 2>&1
    if [ $? -eq "$GUARD_DENY" ]; then printf 'guard\tok\trefuses %s\n' "$p"
    else printf 'guard\tFAIL\tdid not refuse %s\n' "$p"; rc=1; fi
  done

  # And one path it must PERMIT. A self-check that only verifies refusals passes
  # trivially when the kernel is dead: with /bin/realpath missing, every path
  # returns E_UNRESOLVED, every refusal above still "passes", and doctor exits 0
  # on a machine where nothing can ever be reclaimed.
  # The probe path must EXIST: guard_path returns E_ENOENT before consulting any
  # rule, so a made-up path would "fail" this check for the wrong reason and
  # make it as useless as the refusal-only version it replaces.
  if [ -d "$HOME/Library/Caches" ]; then
    guard_path "$HOME/Library/Caches" doctor >/dev/null 2>&1
    case $? in
      "$GUARD_ALLOW"|"$GUARD_ASK") printf 'guard\tok\tpermits an ordinary cache path\n' ;;
      *) printf 'guard\tFAIL\trefuses everything, including paths it should permit\n'; rc=1 ;;
    esac
  fi
  printf 'dry_run\t%s\t%s\n' "$([ "$CMAI_DRY_RUN" = 1 ] && printf ok || printf ARMED)" \
    "$([ "$CMAI_DRY_RUN" = 1 ] && printf 'nothing will be changed' || printf 'changes ARE enabled')"
  return $rc
}

# cmai_myths -- what this tool refuses to do, and why.
cmai_myths() {
  [ -f "$CMAI_DATA_DIR/myths.tsv" ] || { cmai_warn "no myths.tsv"; return 0; }
  $GREP -v '^#' "$CMAI_DATA_DIR/myths.tsv" | $AWK -F'\t' 'NF>=4 {
    printf "\n%s\n  verdict: %s\n  %s\n  source:  %s\n", $1, $2, $3, $4 }'
  printf '\n'
}
