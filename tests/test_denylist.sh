#!/bin/bash
# test_denylist.sh -- rule precedence, driven directly so that no test has to
# create files inside protected directories.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CMAI_PLUGIN_ROOT=$(cd "$HERE/.." && pwd); export CMAI_PLUGIN_ROOT
CMAI_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cmai-test.XXXXXX"); export CMAI_ROOT
. "$CMAI_PLUGIN_ROOT/lib/common.sh"
. "$CMAI_PLUGIN_ROOT/lib/denylist.sh"
trap '/bin/rm -rf "$CMAI_ROOT"' EXIT

pass=0; fail=0
ck() { # ck <path> <expected-verdict>
  _guard_eval_rules "$1"
  if [ "$_GR_VERDICT" = "$2" ]; then pass=$((pass+1))
  else fail=$((fail+1)); printf 'FAIL %s\n  want %s, got %s (%s)\n' "$1" "$2" "$_GR_VERDICT" "$_GR_RULE" >&2; fi
}

# A name rule (length 0) must never outrank a deny, however deep the path.
ck "$HOME/Library/Group Containers/node_modules"              DENY
ck "$HOME/Library/Group Containers/x/y/z/node_modules"        DENY
ck "$HOME/Library/Mobile Documents/proj/node_modules"         DENY
ck "$HOME/Library/Keychains/node_modules"                     DENY
ck "/System/node_modules"                                     DENY
# A glob deny outranks any prefix carve-out. Note the realistic names: the
# extension is what identifies these bundles, not a leading dot.
ck "$HOME/Pictures/Photos Library.photoslibrary"              DENY
ck "$HOME/Pictures/Photos Library.photoslibrary/database"     DENY
ck "$HOME/Music/Music Library.musiclibrary"                   DENY
ck "/Volumes/Backup/Old Photos.photoslibrary/Masters"         DENY
# A longer permissive prefix does carve out of a shorter deny: /usr vs /usr/local.
ck "/usr/bin/something"                                       DENY
ck "/usr/local/Cellar/foo"                                    ALLOW
# Name rules apply where nothing protective matches.
ck "$HOME/Development/proj/node_modules"                      ALLOW
ck "$HOME/Development/proj/target"                            ASK
# Anything uncovered is denied.
ck "$HOME/Development/proj/src"                               DENY
# Explicit dev allowances resolve as intended.
ck "$HOME/go/pkg/mod"                                         ALLOW
ck "$HOME/Library/Caches/Homebrew"                            ALLOW
ck "$HOME/Library/Logs/SomeApp"                               ASK

# Every protective rule gets an assertion. tests/lint.sh fails the build if a
# DENY rule is added to the table without one appearing here.
ck "/sbin/launchd"                                            DENY
ck "/private/etc/hosts"                                       DENY
ck "/Library/Apple/System"                                    DENY
ck "$HOME/Library/Developer/Xcode/Archives/2026-01-01"        DENY
ck "$HOME/Library/Application Support/MobileSync/Backup/abc"  DENY
ck "$HOME/.ssh/id_ed25519"                                    DENY
ck "$HOME/.gnupg/secring.gpg"                                 DENY
ck "$HOME/Library/Safari/History.db"                          DENY
ck "$HOME/Library/Messages/chat.db"                           DENY
ck "/System/Volumes/VM/swapfile0"                             DENY
ck "/private/var/db/receipts/x.plist"                         DENY
ck "/private/var/folders/ab/cd/T/x"                           DENY
ck "/private/var/log/system.log"                              DENY
ck "/Library/Logs/DiagnosticReports/x"                        DENY
ck "/Volumes/External"                                        DENY
ck "$HOME/Library/Mail/V10/x"                                 DENY
ck "$HOME/Library/Containers"                                 DENY
ck "$HOME/Library/Group Containers/x"                         DENY
ck "$HOME/Library/Keychains/login.keychain"                   DENY
ck "$HOME/Library/Mobile Documents/x"                         DENY
ck "/bin/sh"                                                  DENY
ck "/System/Library/Frameworks"                               DENY

# --- project artifact name rules -------------------------------------------
# One assertion per ALLOWNAME/ASKNAME row. lint.sh gate 8b requires this: a name
# rule matches a basename ANYWHERE, so each one needs a verdict on record.
P="$HOME/Development/proj"
for n in node_modules .next .turbo .nuxt Pods .svelte-kit .astro .angular \
         .parcel-cache .dart_tool .gradle .stack-work dist-newstyle \
         DerivedData Carthage Intermediate DerivedDataCache \
         cmake-build-debug cmake-build-release cmake-build-relwithdebinfo \
         cmake-build-minsizerel; do
  ck "$P/$n" ALLOW
done
for n in target build .venv venv dist out vendor deps _build obj; do
  ck "$P/$n" ASK
done

# --- the reserved-name footgun ---------------------------------------------
# `ALLOWNAME Library` would resolve $HOME/Library itself to ALLOW: no DENY
# prefix covers it, and a length-0 name rule beats deny_len of -1. Verified
# live. These assert the rule was never added, and that a protected tree still
# wins over a name rule wherever one legitimately applies.
ck "$HOME/Library"                                            DENY
ck "$HOME/Library/Caches/SomeApp/node_modules"                ALLOW
ck "$HOME/Library/Group Containers/x/node_modules"            DENY
ck "$HOME/Library/Keychains/dist"                             DENY
ck "/System/Library/dist"                                     DENY
ck "$HOME/Library/Mobile Documents/proj/.next"                DENY

printf 'test_denylist: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
