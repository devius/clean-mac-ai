#!/bin/bash
# scan.sh -- read-only discovery. Emits one record per candidate.
#
# The wire format is TSV; --json converts it with `jq -R`. jq ships with macOS,
# so availability is not the issue -- generating JSON from bash 3.2 is. Escaping
# arbitrary macOS filenames by hand is exactly the code that eventually emits a
# malformed record and deletes the wrong path. guard_path already rejects tabs
# and control characters, so TSV is safe to build and jq does the encoding.

CMAI_SCAN_COLS="id	category	subcategory	path	bytes	bytes_human	risk	verdict	mode	method	undo	needs	owner	last_used	evidence"

cmai_scan_header() {
  if [ "$OPT_JSON" = 1 ]; then :; else printf '%s\n' "$CMAI_SCAN_COLS"; fi
}

# One record. Runs the candidate through the guard so that `verdict` in the
# output is the real answer, not a guess the reclaim step might contradict.
# cmai_emit <cat> <sub> <path> <risk> <method> <undo> <owner> <evidence>
#           [floor] [bytes]
#
#   floor  "ask" raises an ALLOW verdict to ASK. It may only ever weaken a
#          verdict: a caller cannot grant an ALLOW the guard did not give, and
#          a DENY is never softened.
#   bytes  a size the caller already measured. The project scan sizes every
#          candidate in one parallel du pass, and re-measuring here would
#          double the most expensive phase of the scan for no new information.
cmai_emit() {
  local cat="$1" sub="$2" path="$3" risk="$4" method="$5" undo="$6" owner="$7" why="$8"
  local floor="${9:-}" pre="${10:-}"
  local bytes human gline grc verdict mode needs last id

  [ -e "$path" ] || return 0
  if [ -n "$pre" ]; then bytes="$pre"; else bytes=$(cmai_size_fast "$path"); fi
  [ "${bytes:-0}" -gt 0 ] || return 0

  # An application exception downgrades the risk and replaces the explanation:
  # this is where "cache" turns out to mean "the user's offline music".
  # app-rules.tsv keys are bundle-id and vendor fragments, meaningful only under
  # ~/Library where a path component genuinely is a bundle id. Applied to an
  # arbitrary project path the substring match false-fires: a project at
  # ~/Development/AdobeXD-plugin/dist matches the "Adobe" rule and would be
  # described to the user as Adobe's media cache.
  local rule="" rrisk rnote
  case "$path" in
    "$HOME"/Library/*) rule=$(cmai_app_rule "$path") ;;
  esac
  if [ -n "$rule" ]; then
    rrisk=$(printf '%s' "$rule" | $AWK -F'\t' '{print $1}')
    rnote=$(printf '%s' "$rule" | $AWK -F'\t' '{print $2}')
    [ -n "$rrisk" ] && risk="$rrisk"
    [ -n "$rnote" ] && why="$rnote"
  fi

  gline=$(guard_path "$path" scan); grc=$?
  mode=$(printf  '%s' "$gline" | $AWK -F'\t' '{print $1}')
  needs=$(printf '%s' "$gline" | $AWK -F'\t' '{print $5}')
  case "$grc" in
    0)  verdict=ALLOW ;;
    10) verdict=ASK ;;
    *)  verdict=DENY
        # A denied path still earns a row when it is large: the user deserves to
        # know where the space went even where we refuse to touch it.
        why="$why [refused: $(printf '%s' "$gline" | $AWK -F'\t' '{print $3}')]"
        method=none ;;
  esac

  # Risk may downgrade a verdict but never upgrade one. An application exception
  # marking something "risky" forces individual confirmation even where the rule
  # table would have allowed it; the guard's DENY is never softened here.
  if [ "$risk" = risky ] && [ "$verdict" = ALLOW ]; then
    verdict=ASK
  fi
  # Same one-way rule for a caller-supplied floor. "info" marks a row that is
  # reported for visibility but is never actionable, which is what a protected
  # project artifact is: the user should see where the space went and why it is
  # refused, without it ever appearing selectable.
  if [ "$floor" = ask ] && [ "$verdict" = ALLOW ]; then
    verdict=ASK
  elif [ "$floor" = info ]; then
    verdict=INFO
  fi

  human=$(cmai_human "$bytes")
  last=$(cmai_mtime_iso "$path")
  id=$(cmai_id "$path")

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$cat" "$sub" "$(cmai_tsv_safe "$path")" "$bytes" "$human" \
    "$risk" "$verdict" "$mode" "$method" "$undo" "${needs:-none}" \
    "${owner:--}" "$last" "$(cmai_tsv_safe "$why")"
}

cmai_expand_home() { printf '%s' "$1" | $SED "s|^~|$HOME|"; }

# Paths claimed by catalog-dev, so scan_space can exclude them.
_cmai_dev_paths() {
  $AWK -F'\t' '!/^#/ && NF>=6 { print $3 }' "$CMAI_DATA_DIR/catalog-dev.tsv" \
  | while IFS= read -r p; do [ "$p" = "-" ] && continue; cmai_expand_home "$p"; printf '\n'; done
}

# ---------------------------------------------------------------- space
# True when a path is, or lives under, something catalog-dev claims.
cmai_is_dev_path() {
  local p="$1" list="$2" d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ "$p" = "$d" ] && return 0
    case "$p" in "$d"/*) return 0 ;; esac
  done <<EOF
$list
EOF
  return 1
}

# Per-application exception lookup. Returns the note, or nothing.
# Some applications keep real user data under a "cache" name; app-rules.tsv
# records those so the scan can say so instead of calling it junk.
cmai_app_rule() {
  local p="$1"
  [ -f "$CMAI_DATA_DIR/app-rules.tsv" ] || return 1
  $AWK -F'\t' -v path="$p" '
    !/^#/ && NF >= 3 {
      if (index(path, $1) > 0) { printf "%s\t%s\n", $2, $3; exit }
    }' "$CMAI_DATA_DIR/app-rules.tsv"
}

# Turn one catalog row into the actual candidate paths.
#
# Offering a whole directory as a single item is how cleaners end up proposing
# to delete a user's music library as "Spotify cache". Where a location holds
# many independent things, each is judged on its own.
cmai_select_candidates() {
  local mode="$1" path="$2" days ext
  case "$mode" in
    self)     printf '%s\n' "$path" ;;
    children) $FIND "$path" -mindepth 1 -maxdepth 1 2>/dev/null ;;
    older:*)
      days=${mode#older:}
      $FIND "$path" -mindepth 1 -maxdepth 1 -mtime "+${days}" 2>/dev/null ;;
    ext:*)
      ext=$(printf '%s' "${mode#ext:}" | $TR ',' '|')
      $FIND "$path" -mindepth 1 -maxdepth 1 2>/dev/null \
        | $AWK -v e="$ext" 'tolower($0) ~ ("\\.(" e ")$")' ;;
    *)        printf '%s\n' "$path" ;;
  esac
  return 0
}

cmai_scan_space() {
  local sub path select risk method undo why devsum=0 devcount=0 p
  local devlist; devlist=$(_cmai_dev_paths)

  while IFS=$'\t' read -r sub path select risk method undo why; do
    case "$sub" in \#*|'') continue ;; esac
    [ -n "${why:-}" ] || continue
    path=$(cmai_expand_home "$path")
    [ -e "$path" ] || continue
    cmai_select_candidates "$select" "$path" | while IFS= read -r p; do
      [ -n "$p" ] || continue
      # catalog-dev owns these; emitting them here would let two skills propose
      # the same path, and would delete files a toolchain collector handles better.
      cmai_is_dev_path "$p" "$devlist" && continue
      cmai_emit space "$sub" "$p" "$risk" "$method" "$undo" - "$why"
    done
  done < "$CMAI_DATA_DIR/catalog-space.tsv"

  # One summary row for everything catalog-dev owns, rather than duplicating it.
  while IFS= read -r p; do
    [ -n "$p" ] && [ -e "$p" ] || continue
    devsum=$(( devsum + $(cmai_size_fast "$p") ))
    devcount=$((devcount+1))
  done <<EOF
$devlist
EOF
  if [ "$devcount" -gt 0 ]; then
    printf '%s\tspace\tdev-summary\t-\t%s\t%s\treview\tINFO\tnone\tdefer\t-\tnone\t-\t-\t%s\n' \
      "$(cmai_id dev-summary)" "$devsum" "$(cmai_human "$devsum")" \
      "Developer toolchain caches across $devcount locations. Owned by /clean-dev, which reclaims them with each tool's own collector instead of deleting files."
  fi
}

# ---------------------------------------------------------------- dev
cmai_scan_dev() {
  local tool sub path method undo why
  while IFS=$'\t' read -r tool sub path method undo why; do
    case "$tool" in \#*|'') continue ;; esac
    [ -n "${why:-}" ] || continue
    if [ "$path" = "-" ]; then
      # Engine-managed: size comes from the engine, not the filesystem.
      case "$sub" in
        docker-build-cache|docker-images) cmai_scan_docker "$sub" "$method" "$why" ;;
      esac
      continue
    fi
    command -v "$tool" >/dev/null 2>&1 || [ -e "$(cmai_expand_home "$path")" ] || continue
    path=$(cmai_expand_home "$path")
    cmai_emit dev "$sub" "$path" safe "$method" "$undo" "$tool" "$why"
  done < "$CMAI_DATA_DIR/catalog-dev.tsv"
}

# Docker reports its own reclaimable bytes; asking the daemon beats guessing
# from disk images we must never touch anyway.
cmai_scan_docker() {
  local sub="$1" method="$2" why="$3" line rec
  command -v docker >/dev/null 2>&1 || return 0
  case "$sub" in
    docker-build-cache) line=$(docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null | $GREP -i 'build cache') ;;
    docker-images)      line=$(docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null | $GREP -i '^images') ;;
  esac
  [ -n "$line" ] || return 0
  rec=$(printf '%s' "$line" | $AWK -F'\t' '{print $2}')
  printf '%s\tdev\t%s\t(docker engine)\t0\t%s\tsafe\tALLOW\tnone\t%s\tirreversible\tnone\tdocker\t-\t%s\n' \
    "$(cmai_id "docker-$sub")" "$sub" "${rec:-unknown}" "$method" \
    "$why Docker reports ${rec:-an unknown amount} reclaimable."
}

# Per-project build and dependency directories live in lib/scan_projects.sh.
# `scan dev` deliberately does not call it: that scan is the fast toolchain-cache
# pass, and project discovery walks the whole home directory.

# ---------------------------------------------------------------- large files
# cmai_size_bytes <size-with-suffix> -- 500M -> 524288000
cmai_to_bytes() {
  printf '%s' "$1" | $AWK '
    /[Gg]$/ { printf "%.0f\n", substr($0,1,length($0)-1)*1073741824; next }
    /[Mm]$/ { printf "%.0f\n", substr($0,1,length($0)-1)*1048576; next }
    /[Kk]$/ { printf "%.0f\n", substr($0,1,length($0)-1)*1024; next }
    { printf "%.0f\n", $0+0 }'
}

# Large, long-unused files.
#
# Spotlight first: it has already indexed size and dates, so this returns in
# about a second where walking a large home directory takes minutes. `find` is
# the fallback for unindexed volumes, bounded in depth so it cannot run away.
cmai_scan_large() {
  local root="${OPT_ROOT:-$HOME}" f bytes days minb
  minb=$(cmai_to_bytes "$OPT_MIN")

  _cmai_large_candidates "$root" "$minb" \
  | while IFS= read -r f; do
      [ -n "$f" ] || continue
      days=$(cmai_mtime_days "$f")
      [ "$days" -ge "$OPT_DAYS" ] || continue
      bytes=$(cmai_size "$f")
      cmai_emit large large-file "$f" review trash full - \
        "At least $OPT_MIN and untouched for ${days} days. User data: shown so you can decide, never selected for you."
    done
  return 0
}

_cmai_large_candidates() {
  local root="$1" minb="$2"
  if [ -x "$MDFIND" ] && [ -n "$($MDFIND -onlyin "$root" "kMDItemFSSize > $minb" 2>/dev/null | $AWK 'NR==1')" ]; then
    $MDFIND -onlyin "$root" "kMDItemFSSize > $minb" 2>/dev/null | $AWK 'NR<=500'
    return 0
  fi
  # Fallback. -maxdepth bounds the walk; Mobile Documents is pruned because
  # traversing it can materialize iCloud downloads.
  $FIND "$root" -xdev -maxdepth 6 \
      \( -flags +dataless -prune \) -o \
      \( -path "$HOME/Library/Mobile Documents" -prune \) -o \
      \( -type f -size "+${OPT_MIN}" -print \) 2>/dev/null | $AWK 'NR<=500'
  return 0
}

# ---------------------------------------------------------------- persistence
cmai_scan_agents() {
  local d f label prog signed status
  for d in "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons; do
    [ -d "$d" ] || continue
    $FIND "$d" -maxdepth 1 -name '*.plist' -type f 2>/dev/null | while IFS= read -r f; do
      [ -n "$f" ] || continue
      label=$($PLUTIL -extract Label raw -o - "$f" 2>/dev/null) || label=$($BASENAME "$f" .plist)
      # Three spellings are in real use: Program, ProgramArguments[0], and
      # BundleProgram for helpers shipped inside an app bundle.
      prog=$($PLUTIL -extract Program raw -o - "$f" 2>/dev/null) \
        || prog=$($PLUTIL -extract ProgramArguments.0 raw -o - "$f" 2>/dev/null) \
        || prog=$($PLUTIL -extract BundleProgram raw -o - "$f" 2>/dev/null) || prog=""
      case "$prog" in *'Could not extract'*|*'invalid key path'*) prog="" ;; esac

      if [ -n "$prog" ] && [ ! -e "$prog" ]; then
        # The highest-value finding: the software is gone, its startup hook remains.
        status="ORPHAN"; signed="target does not exist: $prog"
      elif [ -n "$prog" ]; then
        # --verbose=4 is required. Plain `codesign -dv` never prints Authority,
        # so parsing its output for one always yields nothing.
        signed=$($CODESIGN -dv --verbose=4 "$prog" 2>&1 | $AWK -F= '/^Authority=/{print $2; exit}')
        if [ -n "$signed" ]; then
          status="signed"
        elif $CODESIGN -dv "$prog" >/dev/null 2>&1; then
          status="signed"; signed="signed, but no certificate authority (ad-hoc or self-signed)"
        else
          status="UNSIGNED"; signed="no valid signature"
        fi
      else
        status="present"; signed="no program path in plist (MachServices-only helper)"
      fi
      printf '%s\tagent\t%s\t%s\t0\t-\t%s\t%s\tnone\treport\t-\tnone\t%s\t%s\t%s\n' \
        "$(cmai_id "$f")" "$($BASENAME "$d")" "$(cmai_tsv_safe "$f")" \
        "$([ "$status" = ORPHAN ] && printf review || printf safe)" \
        "$([ "$status" = ORPHAN ] && printf ASK || printf INFO)" \
        "$label" "$(cmai_mtime_iso "$f")" \
        "$(cmai_tsv_safe "${status}: ${signed}")"
    done
  done
}

# ---------------------------------------------------------------- dispatch
# Kept out of the command substitution below on purpose: bash 3.2 mis-parses a
# case statement inside $(...), because the ) closing each pattern is mistaken
# for the end of the substitution.
_cmai_scan_run() {
  case "$1" in
    space)  cmai_scan_space ;;
    dev)      cmai_scan_dev ;;
    projects) cmai_scan_projects ;;
    large)  cmai_scan_large ;;
    agents) cmai_scan_agents ;;
    apps)   cmai_scan_apps ;;
    all)      cmai_scan_space; cmai_scan_dev; cmai_scan_projects; cmai_scan_agents ;;
    *)      cmai_die "unknown scan target: $1 -- expected space, dev, projects, apps, agents, large or all" ;;
  esac
}

cmai_scan_dispatch() {
  local what="$1" out
  out=$(_cmai_scan_run "$what" | $SORT -t"$CMAI_TAB" -k5,5nr)

  if [ "$OPT_JSON" = 1 ] && [ -x "$JQ" ]; then
    printf '%s\n' "$out" | $GREP -v '^$' | $JQ -R -c 'split("\t") | {
      id:.[0], category:.[1], subcategory:.[2], path:.[3],
      bytes:(.[4]|tonumber? // 0), bytes_human:.[5], risk:.[6],
      verdict:.[7], mode:.[8], method:.[9], undo:.[10], needs:.[11],
      owner:.[12], last_used:.[13], evidence:.[14] }'
  else
    cmai_scan_header
    printf '%s\n' "$out" | $GREP -v '^$'
  fi
}
