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
# /usr stays denied. /usr/local used to be a permissive carve-out of it; it is
# now denied in its own right, so the carve-out branch is exercised against a
# fixture table further down instead.
ck "/usr/bin/something"                                       DENY
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

# --- package-manager prefixes, identical on every architecture --------------
# These are LIVE installations, not caches. Homebrew chowns its directories to
# the invoking user, so the root-ownership ASK never fires, and the sunlnk flag
# on /usr/local protects only its direct children -- the rule table is the only
# thing standing here. Asserted in this file rather than cases-guard.tsv because
# a given Mac has at most one of these prefixes, and guard_path returns
# E_ENOENT for an absent path before any rule is consulted.
ck "/usr/local"                                               DENY
ck "/usr/local/bin"                                           DENY
ck "/usr/local/Cellar/wget/1.0"                               DENY
ck "/usr/local/Homebrew/Library"                              DENY
ck "/opt/homebrew"                                            DENY
ck "/opt/homebrew/Cellar"                                     DENY
ck "/opt/local"                                               DENY
# A name rule must not tunnel into any prefix. Before these rows,
# /opt/homebrew/lib/node_modules was ALLOW via ALLOWNAME:node_modules and
# /usr/local/lib/node_modules was ALLOW via ALLOW:/usr/local, so
# `scan projects --root /` offered the global npm prefix for deletion.
ck "/usr/local/lib/node_modules"                              DENY
ck "/opt/homebrew/lib/node_modules"                           DENY
ck "/opt/local/lib/node_modules"                              DENY
# Unchanged: a project's own node_modules is still reclaimable.
ck "$HOME/Development/proj/node_modules"                      ALLOW

# --- the Mail container carve-out ------------------------------------------
# A permissive rule wins only when STRICTLY longer, so an ASK sharing the DENY's
# pattern string could never fire, which made catalog-space.tsv's mail-downloads
# row unreachable: offered by the scan, always refused by the guard.
ck "$HOME/Library/Containers"                                 DENY
ck "$HOME/Library/Containers/com.apple.Safari"                DENY
ck "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/a" ASK

# --- iCloud, asserted here since the directory may not exist ---------------
ck "$HOME/Library/Mobile Documents"                           DENY
ck "$HOME/Library/Mobile Documents/proj/node_modules"         DENY

# --- the carve-out branch, on a fixture table -------------------------------
# `allow_len > deny_len` is the subtlest branch in _guard_eval_rules, and since
# /usr/local became a deny of its own, no shipped row exercises it any more. It
# is driven against a fixture rather than left uncovered, because the day
# someone adds a real carve-out is the day it needs to still work.
FIXTBL="$CMAI_ROOT/carveout.tsv"
{ printf 'DENY\t/zz\t0\tnone\touter deny\n'
  printf 'ALLOW\t/zz/inner\t2\tself\tlonger permissive prefix wins\n'
  printf 'ALLOW\t/zz\t0\tself\tequal length must NOT win\n'
} > "$FIXTBL"
_REAL_DENYLIST=$CMAI_DENYLIST
CMAI_DENYLIST="$FIXTBL"
ck "/zz/other"                                                DENY
ck "/zz/inner/thing"                                          ALLOW
ck "/zz"                                                      DENY
CMAI_DENYLIST=$_REAL_DENYLIST

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
