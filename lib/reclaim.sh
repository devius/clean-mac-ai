#!/bin/bash
# reclaim.sh -- the ONLY file in this project permitted to mutate the filesystem.
#
# Invariants, enforced by tests/lint.sh and not merely by convention:
#   - privilege escalation never appears in this file (see docs/SAFETY.md)
#   - recursive and forced removal appear nowhere in the project
#   - every path is re-guarded here, at the moment of action
#
# The lint that enforces those first two is a plain grep, so this file must not
# contain the forbidden strings even inside a comment.
#
# Re-guarding matters: between the scan and the user's approval an app may have
# launched, a path may have changed, or a symlink may have been swapped.

# cmai_reclaim_one <path> <mode> [category] [confirmed]
#   mode: self | children
#   confirmed: 1 when the user named exactly this item on its own. That is what
#   ASK means ("confirmed individually"), so only then may a rule-table ASK act,
#   and likewise a path matching a risky rule in data/app-rules.tsv.
#   The guard's live-state ASKs (E_TCC, E_INUSE, E_NEEDS_ROOT) never act.
# Returns 0 when handled (including a deliberate skip), 1 on a real failure.
cmai_reclaim_one() {
  local p="$1" gmode="${2:-self}" cat="${3:--}" confirmed="${4:-0}"
  local gline grc bytes dest child backend rp

  gline=$(guard_path "$p" reclaim); grc=$?
  if [ "$grc" -eq "$GUARD_ASK" ] && [ "$confirmed" = 1 ]; then
    case "$(printf '%s' "$gline" | $AWK -F'\t' '{print $2}')" in
      E_*) : ;;
      *)   grc=0 ;;
    esac
  fi
  if [ "$grc" -ne 0 ]; then
    cmai_manifest_write SKIP "guard:$grc" "$p" "" 0 - "$gmode" "$cat" \
      "$(printf '%s' "$gline" | $AWK -F'\t' '{print $3}')"
    return 0
  fi

  # An application exception means this path holds real user data despite its
  # name -- Spotify keeps offline downloads under its cache directory. The guard
  # is path-lexical and cannot know that, so it returns ALLOW; the scan lowers
  # the displayed verdict to ASK. Enforce the same floor here, or that warning
  # is printed and then ignored, which is exactly the failure app-rules.tsv was
  # added to prevent.
  # Checked against the RESOLVED path the guard returned, not the argument:
  # otherwise a symlink pointing into a protected directory would sidestep the
  # rule, and /var vs /private/var alone would defeat the scope test.
  rp=$(printf '%s' "$gline" | $AWK -F'\t' '{print $4}')
  [ -n "$rp" ] || rp="$p"
  if [ "$confirmed" != 1 ] && cmai_app_rule_is_risky "$rp"; then
    cmai_manifest_write SKIP app-rule "$p" "" 0 - "$gmode" "$cat" \
      "$(cmai_app_rule "$rp" | $AWK -F'\t' '{print $2}')"
    return 0
  fi

  # A contents-only rule means the directory itself must survive. Homebrew broke
  # when a cleaner removed the cache directory rather than emptying it
  # (Homebrew/brew#5083), so this is enforced structurally: recurse exactly one
  # level and never pass the parent to a removal.
  if [ "$gmode" = children ]; then
    while IFS= read -r child; do
      [ -n "$child" ] || continue
      cmai_reclaim_one "$child" self "$cat" "$confirmed" || return 1
    done <<EOF
$($FIND "$p" -mindepth 1 -maxdepth 1 2>/dev/null)
EOF
    return 0
  fi

  bytes=$(cmai_size "$p")

  if [ "$CMAI_DRY_RUN" = 1 ]; then
    cmai_manifest_write DRYRUN trash "$p" "" "$bytes" full "$gmode" "$cat" "dry run; nothing moved"
    return 0
  fi

  backend=$(cmai_pick_backend)

  # Tier 1: Apple's own trash(8). Records Put Back metadata, so Finder can undo it.
  if [ "$backend" = trash ] && [ -x "$TRASH" ]; then
    if $TRASH -s "$p" 2>>"$CMAI_ROOT/log/$CMAI_RUNID.err"; then
      cmai_manifest_write OK trash "$p" "$HOME/.Trash/$($BASENAME "$p")" "$bytes" full "$gmode" "$cat" \
        "moved to Trash; still occupies space until the Trash is emptied"
      return 0
    fi
    backend=finder
  fi

  # Tier 2: Finder. Needs Automation consent and a session; fails over ssh.
  if [ "$backend" = finder ] && [ "$CMAI_ALLOW_OSASCRIPT" = 1 ]; then
    if $OSASCRIPT -e "tell application \"Finder\" to delete POSIX file \"$p\"" >/dev/null 2>&1; then
      cmai_manifest_write OK finder "$p" "$HOME/.Trash/$($BASENAME "$p")" "$bytes" full "$gmode" "$cat" \
        "moved to Trash via Finder"
      return 0
    fi
    backend=quarantine
  fi

  # Tier 3: quarantine inside CMAI_ROOT. Needs no TCC grant, and cmai can
  # restore it itself, permissions included.
  #
  # Cross-device mv is a full copy: on a large tree that consumes space instead
  # of freeing it, and can fill the disk we were asked to empty. Refuse instead.
  if [ "$($STAT -f '%d' "$p" 2>/dev/null)" != "$($STAT -f '%d' "$CMAI_ROOT" 2>/dev/null)" ]; then
    cmai_manifest_write FAIL cross-device "$p" "" "$bytes" - "$gmode" "$cat" \
      "on a different volume from $CMAI_ROOT; copying it would consume space rather than free it"
    cmai_warn "left in place (different volume): $p"
    return 1
  fi

  dest="$CMAI_ROOT/quarantine/$CMAI_RUNID/$(cmai_slug "$p")"
  $MKDIR -p "$($DIRNAME "$dest")" 2>/dev/null || {
    cmai_manifest_write FAIL mkdir "$p" "$dest" "$bytes" - "$gmode" "$cat" "could not create quarantine directory"
    return 1; }
  if $MV -n "$p" "$dest" 2>/dev/null; then
    cmai_manifest_write OK quarantine "$p" "$dest" "$bytes" full "$gmode" "$cat" \
      "quarantined; restore with: cmai restore --run $CMAI_RUNID"
    return 0
  fi
  cmai_manifest_write FAIL mv "$p" "$dest" "$bytes" - "$gmode" "$cat" "move failed"
  return 1
}

# cmai_reclaim_gc <tool> <label> <command...>
#
# Tool-native garbage collection is preferred over deletion everywhere it
# exists: higher yield, self-documenting, and the tool's own maintainers decide
# what is safe to drop. It is also irreversible, which the manifest records
# honestly rather than implying an undo that does not exist.
cmai_reclaim_gc() {
  local tool="$1" label="$2"; shift 2
  local before after delta
  if [ "$CMAI_DRY_RUN" = 1 ]; then
    cmai_manifest_write DRYRUN "gc:$tool" "$label" "" 0 irreversible - dev "would run: $*"
    printf 'DRYRUN\t%s\t%s\t%s\n' "$tool" "$label" "$*"
    return 0
  fi
  cmai_df_mark
  if "$@" >>"$CMAI_ROOT/log/$CMAI_RUNID.out" 2>>"$CMAI_ROOT/log/$CMAI_RUNID.err"; then
    delta=$(cmai_df_delta)
    cmai_manifest_write OK "gc:$tool" "$label" "" "$delta" irreversible - dev "ran: $*"
    printf 'OK\t%s\t%s\t%s\n' "$tool" "$label" "$delta"
    return 0
  fi
  cmai_manifest_write FAIL "gc:$tool" "$label" "" 0 - - dev "failed: $*"
  printf 'FAIL\t%s\t%s\t0\n' "$tool" "$label"
  return 1
}
