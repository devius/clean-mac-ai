#!/bin/bash
# mkfixture.sh -- build a throwaway tree exercising the guard's edge cases.
# Prints the fixture root on stdout. Caller is responsible for cleanup.
set -euo pipefail

FIX=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cmai-fixture.XXXXXX")

/bin/mkdir -p "$FIX/normal/cache"
/usr/bin/printf 'x%.0s' $(/usr/bin/seq 1 4096) > "$FIX/normal/cache/file1"
/usr/bin/printf 'y%.0s' $(/usr/bin/seq 1 4096) > "$FIX/normal/cache/file2"

# symlink escaping the fixture into a protected tree
/bin/ln -s /System "$FIX/symlink-to-system"
# symlink loop
/bin/ln -s "$FIX/loop-b" "$FIX/loop-a"
/bin/ln -s "$FIX/loop-a" "$FIX/loop-b"
# dangling symlink: still unlinkable as itself
/bin/ln -s "$FIX/nowhere-at-all" "$FIX/dangling"

# immutable file
/usr/bin/touch "$FIX/locked-file"
/usr/bin/chflags uchg "$FIX/locked-file"

# sunlnk parent: children cannot be unlinked.
# Setting sunlnk requires root, so this normally fails when run unprivileged.
# The guard's parent-flag check is therefore asserted against a real sunlnk
# directory (/usr/local) in cases-guard.tsv. Kept here for privileged runs.
/bin/mkdir -p "$FIX/sunlnk-dir"
/usr/bin/touch "$FIX/sunlnk-dir/child"
/usr/bin/chflags sunlnk "$FIX/sunlnk-dir" 2>/dev/null || :

# awkward names
/bin/mkdir -p "$FIX/names"
/usr/bin/touch "$FIX/names/with space"
/usr/bin/touch "$FIX/names/-leading-dash"
/usr/bin/touch "$FIX/names/ünïcodé"

# hardlink pair: must be counted once
/bin/mkdir -p "$FIX/hard/a" "$FIX/hard/b"
/bin/dd if=/dev/zero of="$FIX/hard/a/big" bs=1024 count=64 2>/dev/null
/bin/ln "$FIX/hard/a/big" "$FIX/hard/b/big-link"

# sparse file: allocated (%b) must differ sharply from logical (%z)
/usr/bin/mkfile -n 64m "$FIX/sparse" 2>/dev/null || :

# nested candidates: must de-nest to one
/bin/mkdir -p "$FIX/nest/inner/deeper"
/usr/bin/printf 'n%.0s' $(/usr/bin/seq 1 4096) > "$FIX/nest/inner/deeper/f"

printf '%s\n' "$FIX"
