#!/bin/bash
# run.sh -- lint plus every test. Exits non-zero if anything fails.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FAIL=0

printf '\n=== lint ===\n'
"$HERE/lint.sh" || FAIL=1

for t in "$HERE"/test_*.sh; do
  printf '\n=== %s ===\n' "$(/usr/bin/basename "$t")"
  "$t" || FAIL=1
done

printf '\n'
if [ "$FAIL" = 0 ]; then printf 'ALL GREEN\n'; else printf 'FAILURES ABOVE\n'; fi
exit "$FAIL"
