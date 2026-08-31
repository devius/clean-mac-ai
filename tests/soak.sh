#!/bin/bash
# soak.sh -- end-to-end verification against the REAL system.
#
# Opt-in, because unlike the other tests this uses the real Trash, the real rule
# table and the real manifest. It never touches anything it did not create: the
# subject is a directory it makes itself under ~/Library/Caches, which the rule
# table permits at depth 5.
#
#   CMAI_I_UNDERSTAND=yes tests/soak.sh
set -uo pipefail
[ "${CMAI_I_UNDERSTAND:-}" = yes ] || {
  printf 'soak.sh uses the real Trash and manifest.\n'
  printf 'Run it as: CMAI_I_UNDERSTAND=yes tests/soak.sh\n'; exit 2; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SUBJECT="$HOME/Library/Caches/cmai-selftest"

pass=0; fail=0
ck() { if [ "$2" = 0 ]; then pass=$((pass+1)); printf 'ok: %s\n' "$1"
       else fail=$((fail+1)); printf 'FAIL: %s\n' "$1" >&2; fi; }

/bin/mkdir -p "$SUBJECT"
# dd, not a printf loop: 200k arguments overflows the argument list.
/bin/dd if=/dev/zero of="$SUBJECT/payload.bin" bs=1024 count=2048 2>/dev/null
[ -f "$SUBJECT/payload.bin" ]; ck "created a subject we own" $?

# The guard must permit it: ~/Library/Caches is ALLOW at depth 4, this is depth 5.
# Captured first rather than piped into grep -q: under pipefail, grep -q closing
# the pipe early makes the producer fail with SIGPIPE and the test read as failed.
SCAN=$("$ROOT/bin/cmai" scan space --json 2>/dev/null)
printf '%s' "$SCAN" | /usr/bin/grep -q 'cmai-selftest'
ck "the scan finds it" $?

ID=$(printf '%s' "$SCAN" | /usr/bin/jq -r 'select(.path | test("cmai-selftest")) | .id' | /usr/bin/head -1)
[ -n "$ID" ]; ck "it has a stable id ($ID)" $?

# Dry run must change nothing.
"$ROOT/bin/cmai" apply --ids "$ID" >/dev/null 2>&1
[ -d "$SUBJECT" ]; ck "dry run left it in place" $?

# Apply for real.
OUT=$("$ROOT/bin/cmai" apply --ids "$ID" --apply 2>&1)
[ ! -e "$SUBJECT" ]; ck "apply removed it" $?

RUNID=$(printf '%s' "$OUT" | /usr/bin/awk '/^run  /{print $2}')
[ -n "$RUNID" ]; ck "the run was recorded ($RUNID)" $?
/usr/bin/grep -q 'cmai-selftest' "$HOME/.clean-mac-ai/manifest/$RUNID.tsv"
ck "the manifest names it" $?

# The report must not claim space was freed by a move to the Trash.
case "$OUT" in
  *"still occupy space until the Trash is emptied"*|*"no measurable change"*) r=0 ;;
  *) r=1 ;;
esac
ck "the report does not claim a trash move freed space" $r

# It is in the Trash, recoverable by the user.
[ -e "$HOME/.Trash/cmai-selftest" ] || [ -n "$(/usr/bin/find "$HOME/.clean-mac-ai/quarantine" -name '*cmai-selftest*' 2>/dev/null)" ]
ck "it is recoverable (Trash or quarantine)" $?

printf '\nsoak: %d passed, %d failed\n' "$pass" "$fail"
printf 'Left in the Trash for you to inspect: cmai-selftest\n'
[ "$fail" -eq 0 ]
