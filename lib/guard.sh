#!/bin/bash
# guard.sh -- THE SAFETY KERNEL.
#
# Every candidate path passes through guard_path() before anything touches it.
# lib/reclaim.sh is the only file permitted to mutate the filesystem, and it
# calls guard_path itself rather than trusting its callers.
#
# The verdict is carried in the EXIT CODE, deliberately: under `set -e`, a
# caller that forgets to check aborts the run instead of silently deleting.
#
#   0  ALLOW  act (subject to the run-level approval)
#   10 ASK    must be confirmed individually; never batch-approved
#   20 DENY   hard refusal; the tool exposes no override
#
# stdout is one TSV line: MODE \t RULE \t REASON \t RESOLVED \t NEEDS

GUARD_ALLOW=0
GUARD_ASK=10
GUARD_DENY=20

_g() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-none}"; }

# guard_process_conflict <path> -- sets _GP_PROC/_GP_BID, returns 0 if a
# process that owns this data is running.
_GP_PROC=""; _GP_BID=""
guard_process_conflict() {
  local p="$1" bid="" app=""
  _GP_PROC=""; _GP_BID=""

  # Derive a bundle id from the standard per-app library layouts.
  case "$p" in
    "$HOME"/Library/Containers/*)        bid=$(printf '%s' "${p#"$HOME"/Library/Containers/}" | $AWK -F/ '{print $1}') ;;
    "$HOME"/Library/Caches/*)            bid=$(printf '%s' "${p#"$HOME"/Library/Caches/}" | $AWK -F/ '{print $1}') ;;
    "$HOME"/Library/Preferences/*.plist) bid=$($BASENAME "$p" .plist) ;;
    *) return 1 ;;
  esac
  case "$bid" in *.*.*) ;; *) return 1 ;; esac   # only reverse-DNS looking ids

  app=$(printf '%s' "$bid" | $AWK -F. '{print $NF}')
  [ -n "$app" ] || return 1
  if $PGREP -x "$app" >/dev/null 2>&1; then
    _GP_PROC="$app"; _GP_BID="$bid"; return 0
  fi
  return 1
}

guard_path() {
  local raw="$1" ctx="${2:-generic}"
  local clean res parent depth mnt owner needs mode uid

  # --- 1. lexical sanity ----------------------------------------------------
  [ -n "$raw" ] || { _g none E_EMPTY "empty path" ""; return $GUARD_DENY; }
  case "$raw" in
    /*) : ;;
    *) _g none E_RELATIVE "not an absolute path: $raw" "$raw"; return $GUARD_DENY ;;
  esac
  case "$raw" in
    */../*|*/..|../*|..) _g none E_DOTDOT "unnormalized path contains .." "$raw"; return $GUARD_DENY ;;
  esac
  case "$raw" in
    *'*'*|*'?'*|*'['*) _g none E_GLOB "glob metacharacter in path" "$raw"; return $GUARD_DENY ;;
  esac

  # Control characters would corrupt the TSV stream and the manifest.
  clean=$(printf '%s' "$raw" | LC_ALL=C $TR -d '\000-\037\177')
  [ "$clean" = "$raw" ] || { _g none E_CTLCHAR "control character in path" "$raw"; return $GUARD_DENY; }

  # Strip trailing slashes (but never reduce "/" to "").
  while [ "$raw" != "/" ] && [ "${raw%/}" != "$raw" ]; do raw="${raw%/}"; done

  # --- 2. must exist (lstat: a dangling symlink is still a real thing) ------
  if [ ! -e "$raw" ] && [ ! -L "$raw" ]; then
    _g none E_ENOENT "does not exist" "$raw"; return $GUARD_DENY
  fi

  # --- 3. symlink resolution with re-verification ---------------------------
  # A symlink is unlinked as itself; we never follow one to delete its target.
  if [ -L "$raw" ]; then
    res="$raw"
  else
    res=$($REALPATH "$raw" 2>/dev/null) || res=""
    [ -n "$res" ] || { _g none E_UNRESOLVED "realpath failed" "$raw"; return $GUARD_DENY; }
    # An ancestor symlink means raw and res name different trees. Both must pass.
    if [ "$res" != "$raw" ]; then
      if ! _guard_denylist_ok "$raw"; then
        _g none E_SYMLINK_ESCAPE "unresolved form is denied: $raw -> $res" "$res"
        return $GUARD_DENY
      fi
    fi
  fi
  mode=self

  # --- 4. never a volume root, /, or $HOME ---------------------------------
  [ "$res" = "/" ]     && { _g none E_ROOT "is the filesystem root" "$res"; return $GUARD_DENY; }
  [ "$res" = "$HOME" ] && { _g none E_HOME "is the home directory" "$res"; return $GUARD_DENY; }
  mnt=$(cmai_volume_of "$res")
  [ -n "$mnt" ] && [ "$res" = "$mnt" ] && { _g none E_MOUNTROOT "is a volume mount point" "$res"; return $GUARD_DENY; }

  # --- 5. depth floor -------------------------------------------------------
  depth=$(printf '%s' "$res" | $AWK -F/ '{print NF-1}')
  [ "$depth" -ge 2 ] || { _g none E_SHALLOW "path depth $depth is below the floor of 2" "$res"; return $GUARD_DENY; }

  # --- 6. SIP and immutability, on the target AND its parent ---------------
  # sunlnk on the PARENT is what actually blocks unlink (/usr/local, /private/var/db).
  # Command substitution rather than `| grep -q`: under `set -o pipefail`, grep -q
  # closing the pipe early makes the producer fail with SIGPIPE and the whole
  # pipeline report non-zero, which would silently turn this refusal into a pass.
  # -maxdepth 0 currently makes that race impossible, but a safety check must not
  # depend on a flag elsewhere in the same line staying put.
  if [ -n "$($FIND "$res" -maxdepth 0 \
       \( -flags +restricted -o -flags +uchg -o -flags +schg \
          -o -flags +uappnd -o -flags +sappnd \) -print 2>/dev/null)" ]; then
    _g none E_SIP "SIP-restricted or immutable" "$res"; return $GUARD_DENY
  fi
  parent=$($DIRNAME "$res")
  if [ -n "$($FIND "$parent" -maxdepth 0 \( -flags +restricted -o -flags +sunlnk \) -print 2>/dev/null)" ]; then
    _g none E_PARENT_SUNLNK "parent directory is restricted or sunlnk: $parent" "$res"; return $GUARD_DENY
  fi

  # --- 7. iCloud and dataless placeholders ---------------------------------
  # Traversing these materializes downloads; deleting one deletes the cloud
  # original on every device and frees essentially nothing locally.
  case "$res" in
    "$HOME/Library/Mobile Documents"|"$HOME/Library/Mobile Documents"/*)
      _g none E_ICLOUD "inside iCloud Drive; traversal materializes evicted files" "$res"
      return $GUARD_DENY ;;
  esac
  if [ -n "$($FIND "$res" -maxdepth 0 -flags +dataless -print 2>/dev/null)" ]; then
    _g none E_DATALESS "dataless placeholder evicted to iCloud" "$res"; return $GUARD_DENY
  fi

  # --- 8. ownership ---------------------------------------------------------
  needs=none
  uid=$($ID -u)
  owner=$($STAT -f '%u' "$res" 2>/dev/null)
  [ -n "$owner" ] && [ "$owner" != "$uid" ] && needs=sudo

  # --- 9. denylist ----------------------------------------------------------
  _guard_eval_rules "$res"
  if [ "$_GR_VERDICT" = "DENY" ]; then
    _g none "$_GR_RULE" "$_GR_REASON" "$res"; return $GUARD_DENY
  fi
  if [ "$depth" -lt "$_GR_MINDEPTH" ]; then
    _g none E_RULE_MINDEPTH "depth $depth is below the rule's floor of $_GR_MINDEPTH ($_GR_RULE)" "$res"
    return $GUARD_DENY
  fi
  [ "$_GR_MODE" = "children" ] && mode=children

  # --- 10. contents-not-directory enforcement ------------------------------
  if [ "$mode" = "children" ] && [ ! -d "$res" ]; then
    _g none E_CHILDREN_NOTDIR "a contents-only rule matched a non-directory" "$res"; return $GUARD_DENY
  fi

  # --- 11. TCC: can we even enumerate it? ----------------------------------
  # TCC blocks directory reads, not stat, so the probe must be a read.
  if [ -d "$res" ] && ! $LS -f "$res" >/dev/null 2>&1; then
    needs="${needs},fda"
    _g "$mode" E_TCC "not readable without Full Disk Access" "$res" "$needs"
    return $GUARD_ASK
  fi

  # --- 12. a process still owns this data ----------------------------------
  if guard_process_conflict "$res"; then
    _g "$mode" E_INUSE "$_GP_PROC is running; its data is live" "$res" "${needs},quit:$_GP_BID"
    return $GUARD_ASK
  fi

  # --- 13. root-owned never auto-allows; sudo never combines with removal ---
  case "$needs" in
    *sudo*)
      _g "$mode" E_NEEDS_ROOT "root-owned; cmai will not elevate to delete" "$res" "$needs"
      return $GUARD_ASK ;;
  esac

  case "$_GR_VERDICT" in
    ASK)   _g "$mode" "$_GR_RULE" "$_GR_REASON" "$res" "$needs"; return $GUARD_ASK ;;
    ALLOW) _g "$mode" "$_GR_RULE" "$_GR_REASON" "$res" "$needs"; return $GUARD_ALLOW ;;
    *)     _g none E_NORULE "no rule covers this path (default deny)" "$res"; return $GUARD_DENY ;;
  esac
}
