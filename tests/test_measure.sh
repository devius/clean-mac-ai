#!/bin/bash
# test_measure.sh -- hardlink dedup, de-nesting, and human formatting.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CMAI_PLUGIN_ROOT=$(cd "$HERE/.." && pwd); export CMAI_PLUGIN_ROOT
CMAI_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cmai-test.XXXXXX"); export CMAI_ROOT
. "$CMAI_PLUGIN_ROOT/lib/common.sh"
. "$CMAI_PLUGIN_ROOT/lib/measure.sh"

FIX=$("$HERE/mkfixture.sh")
cleanup() { "$HERE/rmfixture.sh" "$FIX" >/dev/null 2>&1; /bin/rm -rf "$CMAI_ROOT"; }
trap cleanup EXIT

pass=0; fail=0
ck() { # ck <label> <condition-result>
  if [ "$2" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %s\n' "$1" >&2; fi
}

# --- hardlink dedup: a/big and b/big-link are one 64 KiB file, not two -------
h=$(cmai_size "$FIX/hard")
[ "$h" -ge 65536 ] && [ "$h" -lt 131072 ]; ck "hardlink counted once (got $h bytes)" $?

# --- de-nesting: a parent swallows its descendants ---------------------------
d=$(printf '%s\n%s\n%s\n' "$FIX/nest" "$FIX/nest/inner" "$FIX/nest/inner/deeper" | cmai_denest | wc -l | tr -d ' ')
[ "$d" = 1 ]; ck "denest collapses 3 nested paths to 1 (got $d)" $?

# siblings must both survive
d2=$(printf '%s\n%s\n' "$FIX/nest" "$FIX/hard" | cmai_denest | wc -l | tr -d ' ')
[ "$d2" = 2 ]; ck "denest keeps 2 siblings (got $d2)" $?

# a path that merely shares a name prefix is not a descendant
d3=$(printf '%s\n%s\n' "/tmp/foo" "/tmp/foobar" | cmai_denest | wc -l | tr -d ' ')
[ "$d3" = 2 ]; ck "denest does not treat /tmp/foobar as inside /tmp/foo (got $d3)" $?

# --- sparse file: allocated must be far below logical ------------------------
if [ -f "$FIX/sparse" ]; then
  alloc=$(cmai_size "$FIX/sparse")
  logical=$($STAT -f '%z' "$FIX/sparse")
  [ "$alloc" -lt "$logical" ]; ck "sparse file allocated ($alloc) < logical ($logical)" $?
fi

# --- missing path is 0, not an error ----------------------------------------
z=$(cmai_size "$FIX/definitely-not-here"); [ "$z" = 0 ]; ck "missing path sizes to 0 (got $z)" $?

# --- human formatting --------------------------------------------------------
[ "$(cmai_human 0)" = "0 B" ];          ck "human 0 B" $?
[ "$(cmai_human 1024)" = "1.0 KB" ];    ck "human 1.0 KB" $?
[ "$(cmai_human 7600000000)" = "7.1 GB" ]; ck "human 7.1 GB" $?

# --- noise floor -------------------------------------------------------------
case "$(cmai_delta_phrase 1000000)" in *"no measurable change"*) r=0 ;; *) r=1 ;; esac
ck "1 MB delta reads as noise" $r
case "$(cmai_delta_phrase 8000000000)" in *"rose by"*) r=0 ;; *) r=1 ;; esac
ck "8 GB delta reads as a real gain" $r
case "$(cmai_delta_phrase -8000000000)" in *"fell by"*) r=0 ;; *) r=1 ;; esac
ck "negative delta reads as a fall" $r

printf 'test_measure: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
