#!/bin/bash
# test_reclaim.sh -- reclaim and restore, entirely inside a sandbox.
#
# CMAI_ROOT and CMAI_DENYLIST are both overridden, and the trash backend is
# forced to quarantine, so no test can reach the real ~/.Trash or the real
# rule table.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CMAI_PLUGIN_ROOT=$(cd "$HERE/.." && pwd); export CMAI_PLUGIN_ROOT

SANDBOX=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cmai-sandbox.XXXXXX")
WORK="$SANDBOX/work"
export CMAI_ROOT="$SANDBOX/root"
export CMAI_TRASH_BACKEND=quarantine
export CMAI_DENYLIST="$SANDBOX/denylist.tsv"
trap '/bin/rm -rf "$SANDBOX"' EXIT

# A rule table scoped to the sandbox. The real one denies $TMPDIR outright,
# which is correct in production and unusable for testing removal.
/bin/mkdir -p "$WORK"
REAL_WORK=$(/bin/realpath "$WORK")
{
  printf 'ALLOW\t%s/allowed\t3\tself\tsandbox: removable\n'          "$REAL_WORK"
  printf 'CHILDREN\t%s/keepdir\t3\tchildren\tsandbox: contents only\n' "$REAL_WORK"
  printf 'DENY\t%s/protected\t0\tnone\tsandbox: protected\n'         "$REAL_WORK"
  printf 'ASK\t%s/askdir\t3\tself\tsandbox: per-item only\n'          "$REAL_WORK"
} > "$CMAI_DENYLIST"

# app-rules.tsv keys only mean anything inside this scope. Pointing it at the
# sandbox lets the gate be tested without touching the real ~/Library.
export CMAI_APPRULE_SCOPE="$REAL_WORK"
export CMAI_DATA_DIR="$SANDBOX/data"
/bin/mkdir -p "$CMAI_DATA_DIR"
{
  printf 'sandbox.risky\trisky\tHolds real user data despite the name.\n'
  printf 'sandbox.review\treview\tWorth a look, but not gated.\n'
} > "$CMAI_DATA_DIR/app-rules.tsv"

. "$CMAI_PLUGIN_ROOT/lib/common.sh"
. "$CMAI_PLUGIN_ROOT/lib/denylist.sh"
. "$CMAI_PLUGIN_ROOT/lib/guard.sh"
. "$CMAI_PLUGIN_ROOT/lib/measure.sh"
. "$CMAI_PLUGIN_ROOT/lib/preflight.sh"
. "$CMAI_PLUGIN_ROOT/lib/manifest.sh"
. "$CMAI_PLUGIN_ROOT/lib/reclaim.sh"
. "$CMAI_PLUGIN_ROOT/lib/restore.sh"

pass=0; fail=0
ck() { if [ "$2" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %s\n' "$1" >&2; fi; }

mkfile() { /bin/mkdir -p "$(/usr/bin/dirname "$1")"; /usr/bin/printf 'x%.0s' $(/usr/bin/seq 1 "${2:-2048}") > "$1"; }

mkfile "$WORK/allowed/a.bin"
mkfile "$WORK/protected/keepme.bin"
mkfile "$WORK/keepdir/c1.bin"
mkfile "$WORK/keepdir/c2.bin"
mkfile "$WORK/askdir/q.bin"
mkfile "$WORK/allowed/sandbox.risky.bin"
mkfile "$WORK/allowed/sandbox.review.bin"

cmai_manifest_open >/dev/null

# --- dry run must change nothing -------------------------------------------
CMAI_DRY_RUN=1 cmai_reclaim_one "$WORK/allowed/a.bin" self test >/dev/null
[ -f "$WORK/allowed/a.bin" ]; ck "dry run leaves the file in place" $?

# --- a denied path is never removed ----------------------------------------
CMAI_DRY_RUN=0 cmai_reclaim_one "$WORK/protected/keepme.bin" self test >/dev/null
[ -f "$WORK/protected/keepme.bin" ]; ck "denied path survives an apply" $?

# --- ASK acts only when individually confirmed -----------------------------
CMAI_DRY_RUN=0 cmai_reclaim_one "$WORK/askdir/q.bin" self test >/dev/null
[ -f "$WORK/askdir/q.bin" ]; ck "unconfirmed ASK path survives an apply" $?
CMAI_DRY_RUN=0 cmai_reclaim_one "$WORK/askdir/q.bin" self test 1 >/dev/null
[ ! -e "$WORK/askdir/q.bin" ]; ck "confirmed ASK path was moved" $?
CMAI_DRY_RUN=0 cmai_reclaim_one "$WORK/protected/keepme.bin" self test 1 >/dev/null
[ -f "$WORK/protected/keepme.bin" ]; ck "confirmation never overrides DENY" $?

# --- an app rule gates a path the guard would otherwise allow ---------------
# The guard is path-lexical and returns ALLOW for these; app-rules.tsv is what
# knows the directory holds real user data. Before this gate the scan displayed
# the warning and the reclaim path ignored it.
guard_path "$WORK/allowed/sandbox.risky.bin" test >/dev/null 2>&1
[ $? -eq "$GUARD_ALLOW" ]; ck "guard alone allows the risky path" $?

CMAI_DRY_RUN=0 cmai_reclaim_one "$WORK/allowed/sandbox.risky.bin" self test >/dev/null
[ -f "$WORK/allowed/sandbox.risky.bin" ]; ck "unconfirmed risky path survives an apply" $?
/usr/bin/grep -q 'app-rule' "$CMAI_MANIFEST"; ck "  and the manifest records why" $?

CMAI_DRY_RUN=0 cmai_reclaim_one "$WORK/allowed/sandbox.risky.bin" self test 1 >/dev/null
[ ! -e "$WORK/allowed/sandbox.risky.bin" ]; ck "confirmed risky path was moved" $?

# `review` is informational; only `risky` gates.
CMAI_DRY_RUN=0 cmai_reclaim_one "$WORK/allowed/sandbox.review.bin" self test >/dev/null
[ ! -e "$WORK/allowed/sandbox.review.bin" ]; ck "a review-level rule does not gate" $?

# The scan and the reclaim path must agree, or the warning is theatre again.
[ "$(cmai_app_rule "$REAL_WORK/allowed/sandbox.risky.bin" | $AWK -F'\t' '{print $1}')" = risky ]
ck "cmai_app_rule matches inside the scope" $?
[ -z "$(cmai_app_rule "/tmp/sandbox.risky.bin" 2>/dev/null)" ]
ck "and does not match outside it (no false fire on project paths)" $?

# --- apply moves the file to quarantine ------------------------------------
CMAI_DRY_RUN=0 cmai_reclaim_one "$WORK/allowed/a.bin" self test >/dev/null
[ ! -e "$WORK/allowed/a.bin" ]; ck "allowed file was moved" $?
[ -n "$(/usr/bin/find "$CMAI_ROOT/quarantine" -name '*a.bin*' 2>/dev/null)" ]
ck "moved file is in quarantine" $?

# --- children mode empties a directory but keeps the directory itself -------
# This is the Homebrew lesson: removing the cache directory rather than its
# contents broke brew until Homebrew patched itself to recreate it.
CMAI_DRY_RUN=0 cmai_reclaim_one "$WORK/keepdir" children test >/dev/null
[ -d "$WORK/keepdir" ]; ck "children mode preserves the parent directory" $?
[ -z "$(/usr/bin/find "$WORK/keepdir" -mindepth 1 2>/dev/null)" ]
ck "children mode removed the contents" $?

# --- the manifest recorded it ----------------------------------------------
[ -f "$CMAI_MANIFEST" ]; ck "manifest exists" $?
/usr/bin/grep -q "OK" "$CMAI_MANIFEST"; ck "manifest recorded an OK row" $?
/usr/bin/grep -q "SKIP" "$CMAI_MANIFEST"; ck "manifest recorded the refusal" $?

# --- restore puts it back ---------------------------------------------------
cmai_restore_run "$CMAI_RUNID" 1 >/dev/null 2>&1
[ -f "$WORK/allowed/a.bin" ]; ck "restore returned the file to its original path" $?
[ -f "$WORK/keepdir/c1.bin" ]; ck "restore returned a contents-mode child" $?

# --- restore is idempotent and refuses to overwrite -------------------------
out=$(cmai_restore_run "$CMAI_RUNID" 1 2>&1)
case "$out" in *CONFLICT*|*MISSING*) r=0 ;; *) r=1 ;; esac
ck "a second restore reports a conflict rather than overwriting" $r

printf 'test_reclaim: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
