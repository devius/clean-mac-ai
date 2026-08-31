#!/bin/bash
# mkproj.sh -- build fake projects exercising every branch of the project scan.
# Prints the fixture root on stdout.
set -uo pipefail

FIX=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cmai-proj-fix.XXXXXX")

# Isolate from the developer's real git config. Identity, hooks, templates and
# init.defaultBranch all differ per machine and would make these tests flaky.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

big() { /bin/mkdir -p "$(/usr/bin/dirname "$1")"; /bin/dd if=/dev/zero of="$1" bs=1024 count=61440 2>/dev/null; }

# mkrepo <dir> <iso-commit-date> <touch-stamp YYYYMMDDhhmm>
#
# The reflog mtime must be backdated too. last_touch takes the max of the commit
# date and .git/logs/HEAD, so backdating only the commit leaves a fresh reflog
# and the repository still reads as active -- a trap worth knowing about.
mkrepo() {
  /usr/bin/git init -q "$1" 2>/dev/null
  : > "$1/README.md"
  /usr/bin/git -C "$1" add -A 2>/dev/null
  GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" \
    /usr/bin/git -C "$1" commit -q -m init 2>/dev/null
  /usr/bin/touch -t "$3" "$1/.git/logs/HEAD" 2>/dev/null
}

OLD_DATE="2024-01-15T10:00:00"; OLD_STAMP="202401151000"
NEW_DATE="$(/bin/date -u +%Y-%m-%dT%H:%M:%S)"; NEW_STAMP="$(/bin/date +%Y%m%d%H%M)"

# --- idle project, pure build cache: must PRESELECT ------------------------
mkrepo "$FIX/stale-next" "$OLD_DATE" "$OLD_STAMP"
printf '{"name":"x"}\n' > "$FIX/stale-next/package.json"
printf 'lock\n' > "$FIX/stale-next/pnpm-lock.yaml"
big "$FIX/stale-next/.next/chunk.bin"

# --- active project, build cache: OFFERED but never preselected ------------
mkrepo "$FIX/active-next" "$NEW_DATE" "$NEW_STAMP"
printf '{"name":"x"}\n' > "$FIX/active-next/package.json"
big "$FIX/active-next/.next/chunk.bin"

# --- idle project, dependency dir with lockfile: must PRESELECT ------------
mkrepo "$FIX/stale-deps" "$OLD_DATE" "$OLD_STAMP"
printf '{"name":"x"}\n' > "$FIX/stale-deps/package.json"
printf 'lock\n' > "$FIX/stale-deps/package-lock.json"
big "$FIX/stale-deps/node_modules/pkg/index.js"
# A nested dist inside node_modules must never be reported: proving the
# traversal prunes at the first marker instead of descending.
big "$FIX/stale-deps/node_modules/pkg/dist/bundle.js"

# --- active project, dependency dir: PROTECTED -----------------------------
mkrepo "$FIX/active-deps" "$NEW_DATE" "$NEW_STAMP"
printf '{"name":"x"}\n' > "$FIX/active-deps/package.json"
printf 'lock\n' > "$FIX/active-deps/package-lock.json"
big "$FIX/active-deps/node_modules/pkg/index.js"

# --- vendor COMMITTED to git: the hard stop --------------------------------
mkrepo "$FIX/tracked-vendor" "$OLD_DATE" "$OLD_STAMP"
printf '{}\n' > "$FIX/tracked-vendor/composer.json"
big "$FIX/tracked-vendor/vendor/lib/code.php"
/usr/bin/git -C "$FIX/tracked-vendor" add -A 2>/dev/null
GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" \
  /usr/bin/git -C "$FIX/tracked-vendor" commit -q -m vendor 2>/dev/null
/usr/bin/touch -t "$OLD_STAMP" "$FIX/tracked-vendor/.git/logs/HEAD" 2>/dev/null

# --- vendor ignored, not tracked: offered, never preselected ---------------
mkrepo "$FIX/untracked-vendor" "$OLD_DATE" "$OLD_STAMP"
printf '{}\n' > "$FIX/untracked-vendor/composer.json"
printf 'lock\n' > "$FIX/untracked-vendor/composer.lock"
printf 'vendor\n' > "$FIX/untracked-vendor/.gitignore"
big "$FIX/untracked-vendor/vendor/lib/code.php"

# --- ambiguous build/, with and without the CMake marker -------------------
mkrepo "$FIX/cmake-build" "$OLD_DATE" "$OLD_STAMP"
printf 'project(x)\n' > "$FIX/cmake-build/CMakeLists.txt"
big "$FIX/cmake-build/build/out.o"
printf 'x\n' > "$FIX/cmake-build/build/CMakeCache.txt"

mkrepo "$FIX/source-build" "$OLD_DATE" "$OLD_STAMP"
printf 'project(x)\n' > "$FIX/source-build/CMakeLists.txt"
big "$FIX/source-build/build/main.c"

# --- .cmaikeep, on the project and on an ancestor --------------------------
mkrepo "$FIX/kept" "$OLD_DATE" "$OLD_STAMP"
printf '{"name":"x"}\n' > "$FIX/kept/package.json"
: > "$FIX/kept/.cmaikeep"
big "$FIX/kept/.next/chunk.bin"

/bin/mkdir -p "$FIX/clients"; : > "$FIX/clients/.cmaikeep"
mkrepo "$FIX/clients/proj" "$OLD_DATE" "$OLD_STAMP"
printf '{"name":"x"}\n' > "$FIX/clients/proj/package.json"
big "$FIX/clients/proj/.next/chunk.bin"

# --- uncommitted work in an otherwise idle repo ----------------------------
mkrepo "$FIX/dirty" "$OLD_DATE" "$OLD_STAMP"
printf '{"name":"x"}\n' > "$FIX/dirty/package.json"
printf 'changed\n' > "$FIX/dirty/README.md"
big "$FIX/dirty/.next/chunk.bin"

# --- no repository and no manifest -----------------------------------------
/bin/mkdir -p "$FIX/nogit"
big "$FIX/nogit/dist/bundle.js"
printf '{"name":"x"}\n' > "$FIX/nogit/package.json"

# --- below the size floor ---------------------------------------------------
mkrepo "$FIX/tiny" "$OLD_DATE" "$OLD_STAMP"
printf '{"name":"x"}\n' > "$FIX/tiny/package.json"
/bin/mkdir -p "$FIX/tiny/.next"; printf 'x\n' > "$FIX/tiny/.next/small.bin"

# --- a project whose path collides with an app-rules.tsv vendor fragment ---
mkrepo "$FIX/AdobeXD-plugin" "$OLD_DATE" "$OLD_STAMP"
printf '{"name":"x"}\n' > "$FIX/AdobeXD-plugin/package.json"
big "$FIX/AdobeXD-plugin/.next/chunk.bin"

# Backdate EVERYTHING, deepest first. Manifests and lockfiles are written at
# fixture-build time, and the scan reads their mtimes as activity, so without
# this every project looks like it was worked on today. Commit dates live in
# git objects rather than mtimes, so the active repositories keep their recent
# commits and stay active for the right reason.
/usr/bin/find "$FIX" -depth -print0 2>/dev/null \
| /usr/bin/xargs -0 -n 20 /usr/bin/touch -t "$OLD_STAMP" 2>/dev/null

# The active repositories need a fresh reflog again: the sweep above clobbered it.
for r in active-next active-deps; do
  /usr/bin/touch -t "$NEW_STAMP" "$FIX/$r/.git/logs/HEAD" 2>/dev/null
done

# Their artifacts sit a few days old: the project is active, but nothing is
# building right now. That separates the active-project rule from the
# build-in-progress veto, which only fires within 24 hours.
MID_STAMP=$(/bin/date -v-3d +%Y%m%d%H%M 2>/dev/null || printf '%s' "$OLD_STAMP")
/usr/bin/touch -t "$MID_STAMP" "$FIX/active-next/.next" "$FIX/active-deps/node_modules" 2>/dev/null

printf '%s\n' "$FIX"
