#!/bin/bash
# common.sh -- shared constants, absolute tool paths, logging, TSV helpers.
#
# Every tool is invoked by absolute path. This is not style: on a machine where
# the user's shell profile defines `find` as a function (e.g. aliased to `bfs`),
# a bare `find` silently changes behaviour and `-flags` stops working. A cleanup
# tool that mis-parses a path deletes the wrong thing.
#
# bash 3.2 compatible. No associative arrays, no mapfile, no ${x,,}.

# --- absolute tool paths ----------------------------------------------------
FIND=/usr/bin/find
STAT=/usr/bin/stat
DF=/bin/df
DU=/usr/bin/du
LS=/bin/ls
AWK=/usr/bin/awk
SED=/usr/bin/sed
SORT=/usr/bin/sort
GREP=/usr/bin/grep
TR=/usr/bin/tr
XARGS=/usr/bin/xargs
MKDIR=/bin/mkdir
MV=/bin/mv
DATE=/bin/date
ID=/usr/bin/id
BASENAME=/usr/bin/basename
DIRNAME=/usr/bin/dirname
REALPATH=/bin/realpath
SHASUM=/usr/bin/shasum
PGREP=/usr/bin/pgrep
PLUTIL=/usr/bin/plutil
SWVERS=/usr/bin/sw_vers
UNAME=/usr/bin/uname
TMUTIL=/usr/bin/tmutil
JQ=/usr/bin/jq
TRASH=/usr/bin/trash
OSASCRIPT=/usr/bin/osascript
SYSCTL=/usr/sbin/sysctl
CODESIGN=/usr/bin/codesign
MDFIND=/usr/bin/mdfind
SQLITE3=/usr/bin/sqlite3
LAUNCHCTL=/bin/launchctl
GIT=/usr/bin/git
LSOF=/usr/sbin/lsof
TOUCH=/usr/bin/touch
PS=/bin/ps
SYNC=/bin/sync

# --- roots and knobs --------------------------------------------------------
: "${CMAI_ROOT:=$HOME/.clean-mac-ai}"
: "${CMAI_DRY_RUN:=1}"          # dry-run is the default; only --apply clears it
: "${CMAI_TRASH_BACKEND:=auto}" # auto | trash | finder | quarantine
: "${CMAI_ALLOW_OSASCRIPT:=1}"
: "${CMAI_MIN_OS_MAJOR:=15}"
: "${CMAI_NOISE_FLOOR:=67108864}" # 64 MiB: below this a df delta is noise

# Per-project artifact scanning. Thresholds are idle-days before an artifact is
# PRESELECTED; anything below is still shown and still tickable.
: "${CMAI_PROJ_MIN:=52428800}"      # 50 MiB floor
: "${CMAI_PROJ_T3_DAYS:=30}"        # pure derived cache
: "${CMAI_PROJ_T1_DAYS:=60}"        # lockfile-backed
: "${CMAI_PROJ_T2_DAYS:=120}"       # manifest only, versions may drift
: "${CMAI_PROJ_ACTIVE_DAYS:=14}"    # idle days within which a project is "active"
: "${CMAI_PROJ_FRESH_DAYS:=7}"      # artifact rebuilt this recently is not preselected
: "${CMAI_PROJ_PARALLEL:=6}"        # du workers

CMAI_VERSION="0.1.0"
CMAI_TAB=$(printf '\t')

# CMAI_PLUGIN_ROOT is set by bin/cmai before sourcing.
: "${CMAI_DENYLIST:=$CMAI_PLUGIN_ROOT/data/denylist.tsv}"
: "${CMAI_DATA_DIR:=$CMAI_PLUGIN_ROOT/data}"

# --- output -----------------------------------------------------------------
# Diagnostics go to stderr so stdout stays a clean machine-readable stream.
cmai_is_tty() { [ -t 2 ]; }
cmai_warn()  { printf 'warn: %s\n'  "$*" >&2; }
cmai_info()  { printf '%s\n'        "$*" >&2; }
cmai_error() { printf 'error: %s\n' "$*" >&2; }
cmai_die()   { cmai_error "$*"; exit 1; }

# --- formatting -------------------------------------------------------------
# Sizes are precomputed here so that consumers (including Claude) never have to
# do arithmetic on raw byte counts.
cmai_human() {
  $AWK -v b="${1:-0}" 'BEGIN{
    split("B KB MB GB TB PB", u, " "); i=1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1) printf "%d %s\n", b, u[i]
    else        printf "%.1f %s\n", b, u[i]
  }'
}

# Stable short id for a path. Used for --ids selection.
cmai_id() { printf '%s' "$1" | $SHASUM -a 1 | $AWK '{print substr($1,1,12)}'; }

# Filesystem-safe slug of an absolute path, for quarantine layout.
cmai_slug() { printf '%s' "$1" | $TR '/' '_' | $TR -cd 'A-Za-z0-9._-'; }

cmai_runid() { $DATE -u +%Y%m%dT%H%M%SZ; }

cmai_now() { $DATE -u +%Y-%m-%dT%H:%M:%SZ; }

# --- TSV --------------------------------------------------------------------
# A field containing a tab or newline would corrupt the stream. guard_path
# rejects such paths outright; this is the belt to that suspenders.
cmai_tsv_safe() { printf '%s' "$1" | LC_ALL=C $TR -d '\000-\037\177'; }

cmai_ensure_root() {
  $MKDIR -p "$CMAI_ROOT/manifest" "$CMAI_ROOT/quarantine" "$CMAI_ROOT/log" 2>/dev/null || \
    cmai_die "cannot create CMAI_ROOT at $CMAI_ROOT"
}

# --- volume helpers ---------------------------------------------------------
# -k is mandatory. Bare `df -P` reports 512-byte blocks on macOS, which would
# double every number we print.
cmai_df_avail() {
  $DF -P -k "${1:-/System/Volumes/Data}" 2>/dev/null \
  | $AWK 'NR==2 { printf "%.0f\n", $4*1024 }'
}

cmai_volume_of() {
  $DF -P -k "$1" 2>/dev/null \
  | $AWK 'NR==2 { for (i=6; i<=NF; i++) printf "%s%s", $i, (i<NF ? OFS : "") }'
}
