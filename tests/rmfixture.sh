#!/bin/bash
# rmfixture.sh -- tear down a fixture built by mkfixture.sh.
# Clears the flags the fixture deliberately set, then removes the tree.
set -uo pipefail
FIX="${1:?usage: rmfixture.sh <fixture-root>}"
case "$FIX" in
  */cmai-fixture.*) : ;;
  *) printf 'refusing to remove %s: not a cmai fixture\n' "$FIX" >&2; exit 1 ;;
esac
/usr/bin/chflags -R nouchg,noschg,nosunlnk "$FIX" 2>/dev/null || :
/bin/rm -rf "$FIX"
