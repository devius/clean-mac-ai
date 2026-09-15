#!/bin/bash
# preflight.sh -- establish what this machine will actually permit, before any
# scan runs. Everything here is read-only apart from one zero-byte probe file
# created and trashed inside CMAI_ROOT.

CMAI_OS_MAJOR=""; CMAI_OS_FULL=""; CMAI_ARCH=""
CMAI_FDA="unknown"; CMAI_TRASH_OK="unknown"; CMAI_SNAPSHOTS=0; CMAI_SUDO="no"
CMAI_GIT_OK="unknown"

cmai_os_detect() {
  CMAI_OS_FULL=$($SWVERS -productVersion 2>/dev/null)
  CMAI_OS_MAJOR=${CMAI_OS_FULL%%.*}
  CMAI_ARCH=$($UNAME -m 2>/dev/null)
}

cmai_os_gate() {
  cmai_os_detect
  [ -n "${CMAI_SKIP_OS_GATE:-}" ] && return 0
  case "$CMAI_OS_MAJOR" in
    ''|*[!0-9]*) cmai_die "cannot determine macOS version" ;;
  esac
  if [ "$CMAI_OS_MAJOR" -lt "$CMAI_MIN_OS_MAJOR" ]; then
    cmai_error "clean-mac-ai requires macOS $CMAI_MIN_OS_MAJOR (Sequoia) or newer; this is macOS $CMAI_OS_FULL."
    cmai_error "Earlier releases lack /usr/bin/trash, so there is no dependency-free way to"
    cmai_error "delete reversibly. Refusing to run rather than fall back to unlinking."
    exit 1
  fi
}

# Full Disk Access. TCC blocks directory ENUMERATION, not stat, so the probe
# must be a read: `ls -d ~/.Trash` succeeds without FDA, `ls -f ~/.Trash` does not.
cmai_fda_probe() {
  if $LS -f "$HOME/.Trash" >/dev/null 2>&1; then CMAI_FDA=yes; else CMAI_FDA=no; fi
  printf '%s\n' "$CMAI_FDA"
}

# Whether trash(8) actually works in this TCC state cannot be determined by
# inspection: the answer differs per host application. So measure it, by
# trashing a zero-byte probe file of our own.
cmai_trash_probe() {
  local probe
  [ -x "$TRASH" ] || { CMAI_TRASH_OK=no; printf 'no\n'; return 0; }
  cmai_ensure_root
  probe="$CMAI_ROOT/.cmai-trash-probe.$$"
  : > "$probe" 2>/dev/null || { CMAI_TRASH_OK=no; printf 'no\n'; return 0; }
  if $TRASH -s "$probe" >/dev/null 2>&1; then
    CMAI_TRASH_OK=yes
  else
    CMAI_TRASH_OK=no
    # Unlink our own zero-byte probe. No flags, so this can never recurse.
    /bin/rm "$probe" 2>/dev/null || :
  fi
  printf '%s\n' "$CMAI_TRASH_OK"
}

# /usr/bin/git is not git. It is com.apple.dt.xcode_select.tool-shim-public, a
# stub that forwards to the Command Line Tools -- and on a Mac without them it
# raises an install dialog and exits non-zero. Everything that depends on git
# must know whether it is real, because the tracked-source check is a SAFETY
# guarantee: without git we cannot prove a directory is untracked.
cmai_git_probe() {
  if [ -x "$GIT" ] && $GIT --version >/dev/null 2>&1; then
    CMAI_GIT_OK=yes
  elif [ -x "$GIT" ]; then
    CMAI_GIT_OK=stub          # present, but the Command Line Tools are absent
  else
    CMAI_GIT_OK=no
  fi
  printf '%s\n' "$CMAI_GIT_OK"
}

cmai_sudo_probe() {
  if /usr/bin/sudo -n -v >/dev/null 2>&1; then CMAI_SUDO=cached; else CMAI_SUDO=no; fi
  printf '%s\n' "$CMAI_SUDO"
}

# Which backend reclaim.sh will use, given what the probes found.
cmai_pick_backend() {
  case "$CMAI_TRASH_BACKEND" in
    trash|finder|quarantine) printf '%s\n' "$CMAI_TRASH_BACKEND"; return 0 ;;
  esac
  [ "$CMAI_TRASH_OK" = yes ] && { printf 'trash\n'; return 0; }
  [ "$CMAI_ALLOW_OSASCRIPT" = 1 ] && { printf 'finder\n'; return 0; }
  printf 'quarantine\n'
}

cmai_preflight() {
  local backend
  cmai_os_gate
  cmai_ensure_root
  cmai_fda_probe   >/dev/null
  cmai_trash_probe >/dev/null
  cmai_sudo_probe  >/dev/null
  cmai_git_probe   >/dev/null
  CMAI_SNAPSHOTS=$(cmai_snapshot_count)
  backend=$(cmai_pick_backend)

  printf 'macos\t%s\n'        "$CMAI_OS_FULL"
  printf 'arch\t%s\n'         "$CMAI_ARCH"
  printf 'cmai_version\t%s\n' "$CMAI_VERSION"
  printf 'full_disk_access\t%s\n' "$CMAI_FDA"
  printf 'trash_works\t%s\n'  "$CMAI_TRASH_OK"
  printf 'backend\t%s\n'      "$backend"
  printf 'sudo\t%s\n'         "$CMAI_SUDO"
  printf 'git\t%s\n'          "$CMAI_GIT_OK"
  printf 'local_snapshots\t%s\n' "$CMAI_SNAPSHOTS"
  printf 'df_avail\t%s\n'     "$(cmai_df_avail)"
  printf 'dry_run\t%s\n'      "$CMAI_DRY_RUN"
  printf 'cmai_root\t%s\n'    "$CMAI_ROOT"

  cmai_toolchains
  return 0
}

# Which developer toolchains exist here. Absence is reported, not guessed at:
# a scanner that reports 0 B for a tool you do not have is noise.
cmai_toolchains() {
  local t
  for t in brew docker orb node npm pnpm yarn bun go cargo rustup python3 uv pip3 \
           gradle mvn xcodebuild swift java conda deno; do
    if command -v "$t" >/dev/null 2>&1; then printf 'tool\t%s\tyes\n' "$t"; fi
  done
}

# The warnings a human needs before believing any number this tool prints.
cmai_preflight_notes() {
  [ "$CMAI_SNAPSHOTS" -gt 0 ] && cat >&2 <<NOTE

  ${CMAI_SNAPSHOTS} local Time Machine snapshot(s) are present.

  Snapshots pin the disk blocks of deleted files, so reclaiming space may show
  no change at all until they expire (usually within 24 hours). This is normal
  and is not a failure of the clean.

  To thin them yourself -- irreversible, and it removes restore points:
    sudo tmutil thinlocalsnapshots /System/Volumes/Data 5000000000 4

  clean-mac-ai will not run that for you.
NOTE

  case "$CMAI_GIT_OK" in
    yes) : ;;
    *) cat >&2 <<'NOTE'

  git is not usable on this machine.

  /usr/bin/git is a stub that forwards to the Xcode Command Line Tools. Without
  them, clean-mac-ai cannot tell a build directory from committed source, so
  scan projects will protect everything inside a repository rather than risk
  offering your code. Install them with:

    xcode-select --install
NOTE
    ;;
  esac

  if [ "$CMAI_FDA" = no ]; then cat >&2 <<'NOTE'

  Full Disk Access is not granted to this terminal.

  Some locations cannot be read and will be reported as "needs FDA" rather than
  silently omitted. Note the trade-off before granting it: Full Disk Access is
  inherited by every process this terminal starts, not just this tool.
NOTE
  fi
  return 0
}
