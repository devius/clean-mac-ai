#!/bin/bash
# test_guard.sh -- assert guard_path's verdict for every row of cases-guard.tsv.
#
# This is the highest-value test in the repo. If it passes, no code path in
# cmai can reach a protected location.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CMAI_PLUGIN_ROOT=$(cd "$HERE/.." && pwd)
export CMAI_PLUGIN_ROOT

# Sandbox everything: never touch the real ~/.clean-mac-ai during tests.
CMAI_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cmai-test.XXXXXX")
export CMAI_ROOT CMAI_DRY_RUN=1

# shellcheck source=../lib/common.sh
. "$CMAI_PLUGIN_ROOT/lib/common.sh"
. "$CMAI_PLUGIN_ROOT/lib/denylist.sh"
. "$CMAI_PLUGIN_ROOT/lib/guard.sh"

FIX=$("$HERE/mkfixture.sh")
cleanup() { "$HERE/rmfixture.sh" "$FIX" >/dev/null 2>&1; /bin/rm -rf "$CMAI_ROOT"; }
trap cleanup EXIT

pass=0; fail=0

while IFS=$'\t' read -r path want_exit want_mode want_rule; do
  case "$path" in \#*) continue ;; esac
  [ -n "$want_exit" ] || continue

  # Expand $FIX and $HOME without eval.
  p=${path//\$FIX/$FIX}
  p=${p//\$HOME/$HOME}
  [ "$p" = "<EMPTY>" ] && p=""

  out=$(guard_path "$p" test 2>/dev/null); got_exit=$?
  got_mode=$(printf '%s' "$out" | $AWK -F'\t' '{print $1}')
  got_rule=$(printf '%s' "$out" | $AWK -F'\t' '{print $2}')

  ok=1
  [ "$got_exit" = "$want_exit" ] || ok=0
  [ "$got_mode" = "$want_mode" ] || ok=0
  if [ "$want_rule" != "-" ]; then
    case "$got_rule" in "$want_rule"*) ;; *) ok=0 ;; esac
  fi

  if [ "$ok" = 1 ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    printf 'FAIL %s\n  want exit=%s mode=%s rule=%s\n  got  exit=%s mode=%s rule=%s\n' \
      "$p" "$want_exit" "$want_mode" "$want_rule" "$got_exit" "$got_mode" "$got_rule" >&2
  fi
done < "$HERE/cases-guard.tsv"

printf 'test_guard: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
