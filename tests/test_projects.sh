#!/bin/bash
# test_projects.sh -- the per-project artifact scanner.
#
# Sandboxed like test_reclaim.sh: CMAI_ROOT and CMAI_DENYLIST are overridden so
# no test can reach the real rule table. The fixture lives under $TMPDIR, which
# resolves inside /private/var/folders and is denied by the REAL table -- that
# refusal is correct in production, which is exactly why the table is replaced
# here rather than the fixture being moved.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CMAI_PLUGIN_ROOT=$(cd "$HERE/.." && pwd); export CMAI_PLUGIN_ROOT

SANDBOX=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cmai-projtest.XXXXXX")
export CMAI_ROOT="$SANDBOX/root"
export CMAI_DENYLIST="$SANDBOX/denylist.tsv"
export CMAI_TRASH_BACKEND=quarantine
/bin/mkdir -p "$CMAI_ROOT"

FIX=$("$HERE/mkproj.sh")
REAL_FIX=$(/bin/realpath "$FIX")

# The real name rules, rescoped to the sandbox: every ALLOWNAME/ASKNAME row is
# copied verbatim so tiering is tested against the shipping table, plus one
# ALLOW prefix so the fixture tree itself is reachable.
{
  /usr/bin/grep -E '^(ALLOWNAME|ASKNAME)'"$(printf '\t')" "$CMAI_PLUGIN_ROOT/data/denylist.tsv"
  printf 'ALLOW\t%s\t3\tself\tsandbox fixture root\n' "$REAL_FIX"
} > "$CMAI_DENYLIST"

. "$CMAI_PLUGIN_ROOT/lib/common.sh"
. "$CMAI_PLUGIN_ROOT/lib/denylist.sh"
. "$CMAI_PLUGIN_ROOT/lib/guard.sh"
. "$CMAI_PLUGIN_ROOT/lib/measure.sh"
# cmai_git_probe lives here. Without it CMAI_GIT_OK stays "unknown" and the
# tracked-source check fails closed, protecting every fixture inside a repo --
# correct behaviour, but it would mask what these tests are actually checking.
. "$CMAI_PLUGIN_ROOT/lib/preflight.sh"
. "$CMAI_PLUGIN_ROOT/lib/scan.sh"
. "$CMAI_PLUGIN_ROOT/lib/scan_projects.sh"

cleanup() { "$HERE/rmfixture.sh" "$FIX" >/dev/null 2>&1 || /bin/rm -rf "$FIX"; /bin/rm -rf "$SANDBOX"; }
trap cleanup EXIT

OPT_JSON=0; OPT_ROOT="$REAL_FIX"; OPT_INCLUDE_ACTIVE=0
OPT_MINSIZE=""; OPT_DAYS=180; OPT_DAYS_SET=""; OPT_TIER=strict
export OPT_JSON OPT_ROOT OPT_INCLUDE_ACTIVE OPT_MINSIZE OPT_DAYS OPT_DAYS_SET

OUT="$SANDBOX/out.tsv"
cmai_scan_projects > "$OUT" 2>/dev/null

pass=0; fail=0
ck() { if [ "$2" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %s\n' "$1" >&2; fi; }

# verdict_of <path-suffix>  -- the verdict column for the row whose path ends thus
verdict_of() { $AWK -F'\t' -v s="$1" '$4 ~ (s "$") { print $8; exit }' "$OUT"; }
eviof()     { $AWK -F'\t' -v s="$1" '$4 ~ (s "$") { print $15; exit }' "$OUT"; }
rows_for()  { $AWK -F'\t' -v s="$1" '$4 ~ s { n++ } END { print n+0 }' "$OUT"; }

# --- the decision table ----------------------------------------------------
[ "$(verdict_of '/stale-next/.next')" = ALLOW ]
ck "idle project, build cache -> preselected" $?

[ "$(verdict_of '/active-next/.next')" = ASK ]
ck "active project, build cache -> offered but not preselected" $?

[ "$(verdict_of '/stale-deps/node_modules')" = ALLOW ]
ck "idle project, dependency dir with lockfile -> preselected" $?

[ "$(verdict_of '/active-deps/node_modules')" = INFO ]
ck "active project, dependency dir -> protected, never actionable" $?

# --- the hard stop ---------------------------------------------------------
[ "$(verdict_of '/tracked-vendor/vendor')" = INFO ]
ck "vendor committed to git -> refused as source" $?
case "$(eviof '/tracked-vendor/vendor')" in *"tracked in git"*) r=0 ;; *) r=1 ;; esac
ck "  and says why" $r

[ "$(verdict_of '/untracked-vendor/vendor')" = ASK ]
ck "vendor ignored, not tracked -> offered, never preselected" $?

# --- ambiguity -------------------------------------------------------------
[ "$(verdict_of '/cmake-build/build')" = ASK ]
ck "ambiguous build/ is never preselected even with its marker" $?
case "$(eviof '/cmake-build/build')" in *inmarker=ok*) r=0 ;; *) r=1 ;; esac
ck "  and records that CMakeCache.txt is present" $r
case "$(eviof '/source-build/build')" in *inmarker=missing*) r=0 ;; *) r=1 ;; esac
ck "build/ without CMakeCache.txt is flagged as possibly not build output" $r

# --- exclusion -------------------------------------------------------------
[ "$(verdict_of '/kept/.next')" = INFO ]
ck ".cmaikeep protects its own project" $?
[ "$(verdict_of '/clients/proj/.next')" = INFO ]
ck ".cmaikeep protects from an ancestor directory" $?

# --- vetoes ----------------------------------------------------------------
[ "$(verdict_of '/dirty/.next')" = ASK ]
ck "uncommitted work suppresses preselection" $?
case "$(eviof '/dirty/.next')" in *"uncommitted changes"*) r=0 ;; *) r=1 ;; esac
ck "  and says so" $r

[ "$(verdict_of '/nogit/dist')" = ASK ]
ck "ambiguous name in a non-repository -> never preselected" $?

# --- discovery -------------------------------------------------------------
[ "$(rows_for '/node_modules/pkg/dist')" = 0 ]
ck "a dist nested inside node_modules is never reported (single-traversal prune)" $?

[ "$(rows_for '/tiny/')" = 0 ]
ck "an artifact below the size floor is not reported" $?

# --- the app-rules scoping bug --------------------------------------------
case "$(eviof '/AdobeXD-plugin/.next')" in
  *"next build"*) r=0 ;; *) r=1 ;;
esac
ck "a project path containing a vendor name keeps its own evidence" $r
case "$(eviof '/AdobeXD-plugin/.next')" in
  *"media cache"*) r=1 ;; *) r=0 ;;
esac
ck "  and does not pick up an unrelated app rule" $r

# --- record shape ----------------------------------------------------------
[ -z "$($AWK -F'\t' 'NF != 15 { print; exit }' "$OUT")" ]
ck "every row has exactly 15 fields" $?

[ "$($AWK -F'\t' '$3 !~ /^project-/ { n++ } END { print n+0 }' "$OUT")" = 0 ]
ck "every row is subcategorised project-*" $?

if [ -x "$JQ" ]; then
  $GREP -v '^$' "$OUT" | $JQ -R -c 'split("\t")' >/dev/null 2>&1
  ck "output survives jq -R (--json path)" $?
fi

# --- --include-active reaches, but never preselects ------------------------
OPT_INCLUDE_ACTIVE=1 cmai_scan_projects > "$SANDBOX/out2.tsv" 2>/dev/null
v=$($AWK -F'\t' '$4 ~ /\/active-deps\/node_modules$/ { print $8; exit }' "$SANDBOX/out2.tsv")
[ "$v" = ASK ]
ck "--include-active offers an active dependency dir as ASK, never ALLOW" $?

printf 'test_projects: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
