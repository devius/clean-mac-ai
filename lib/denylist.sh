#!/bin/bash
# denylist.sh -- evaluates the rule table against a resolved path.
#
# Precedence is deliberately not a single "longest match wins" ordering, because
# that would let a long permissive pattern outrank a short protective one: a
# glob such as */node_modules is 15 characters and /System is 7, so naive length
# comparison would let the glob win. Deny and allow are therefore evaluated
# independently and combined by an explicit rule:
#
#   1. find the longest DENY prefix (or any DENY glob) that matches
#   2. find the longest permissive prefix (ALLOW / ASK / CHILDREN) that matches
#   3. a permissive rule wins only if it is strictly MORE specific -- a longer
#      prefix -- than the deny. This is what carves /usr/local out of /usr.
#   4. name rules (ALLOWNAME / ASKNAME) match a basename anywhere and carry
#      length 0, so they can never override any deny. They exist so build
#      artifacts can be reclaimed wherever a project happens to live.
#   5. nothing matched at all means DENY. Default-deny is the whole point.

_GR_VERDICT=""; _GR_MODE=""; _GR_RULE=""; _GR_REASON=""; _GR_MINDEPTH=0

_guard_eval_rules() {
  local p="$1" out local_file=""
  [ -f "$CMAI_ROOT/denylist.local.tsv" ] && local_file="$CMAI_ROOT/denylist.local.tsv"

  out=$($AWK -F'\t' -v path="$p" -v home="$HOME" -v localfile="${local_file:-}" '
    function glob2re(g,   i, c, r) {
      r = ""
      for (i = 1; i <= length(g); i++) {
        c = substr(g, i, 1)
        if (c == "*") r = r ".*"
        else if (c == "?") r = r "."
        else if (index(".^$+(){}[]|\\", c)) r = r "\\" c
        else r = r c
      }
      return r
    }
    function is_prefix(pat, s) { return (s == pat || index(s, pat "/") == 1) }
    function basename(s) { sub(/.*\//, "", s); return s }

    BEGIN { deny_len = -1; allow_len = -1; base = basename(path) }
    /^[ \t]*#/ { next }
    /^[ \t]*$/ { next }
    NF < 5 { next }
    {
      kind = $1; pat = $2; mind = $3 + 0; mode = $4; reason = $5
      # A local rule file may only strengthen protection.
      if (FILENAME == localfile && kind !~ /^(DENY|ASK)/) next
      sub(/^~/, home, pat)

      if (kind == "DENY") {
        if (is_prefix(pat, path) && length(pat) > deny_len) {
          deny_len = length(pat); deny_rule = kind ":" pat; deny_reason = reason
        }
      } else if (kind == "DENYGLOB") {
        if (path ~ ("^" glob2re(pat) "$")) {
          # A glob deny outranks any prefix carve-out.
          deny_len = 1e9; deny_rule = kind ":" pat; deny_reason = reason
        }
      } else if (kind == "ALLOW" || kind == "ASK" || kind == "CHILDREN") {
        if (is_prefix(pat, path) && length(pat) > allow_len) {
          allow_len = length(pat)
          allow_verdict = (kind == "CHILDREN" ? "ALLOW" : kind)
          # "Contents only" applies to the directory the rule names, and only to
          # it. The items inside are ordinary removable things; if the mode were
          # inherited down the tree, every child would be judged a directory that
          # must be preserved and nothing could ever be removed.
          allow_mode = ((kind == "CHILDREN" && path == pat) ? "children" : \
                        (kind == "CHILDREN" ? "self" : mode))
          allow_rule = kind ":" pat; allow_reason = reason; allow_mind = mind
        }
      } else if (kind == "ALLOWNAME" || kind == "ASKNAME") {
        # Length 0: informative, but never strong enough to beat a deny.
        if (base == pat && allow_len < 0) {
          allow_len = 0
          allow_verdict = (kind == "ALLOWNAME" ? "ALLOW" : "ASK")
          allow_mode = mode; allow_rule = kind ":" pat
          allow_reason = reason; allow_mind = mind
        }
      }
    }
    END {
      if (allow_len >= 0 && allow_len > deny_len) {
        printf "%s\t%s\t%s\t%s\t%d\n", allow_verdict, allow_mode, allow_rule, allow_reason, allow_mind
      } else if (deny_len >= 0) {
        printf "DENY\tnone\t%s\t%s\t0\n", deny_rule, deny_reason
      } else if (allow_len >= 0) {
        printf "%s\t%s\t%s\t%s\t%d\n", allow_verdict, allow_mode, allow_rule, allow_reason, allow_mind
      } else {
        print "DENY\tnone\tE_NORULE\tno rule covers this path (default deny)\t0"
      }
    }
  ' "$CMAI_DENYLIST" ${local_file:+"$local_file"})

  _GR_VERDICT=$(printf  '%s' "$out" | $AWK -F'\t' '{print $1}')
  _GR_MODE=$(printf     '%s' "$out" | $AWK -F'\t' '{print $2}')
  _GR_RULE=$(printf     '%s' "$out" | $AWK -F'\t' '{print $3}')
  _GR_REASON=$(printf   '%s' "$out" | $AWK -F'\t' '{print $4}')
  _GR_MINDEPTH=$(printf '%s' "$out" | $AWK -F'\t' '{print $5+0}')
  return 0
}

# Used by guard.sh's symlink re-verification: succeeds unless the raw
# (unresolved) form matches an EXPLICIT deny.
#
# Default-deny deliberately does not count here. Any path reached through an
# ancestor symlink differs from its resolved form -- /tmp, /var and $TMPDIR all
# do -- so treating "matched no rule" as an escape would flag every one of them.
# The resolved path is still evaluated against the full table in guard_path.
_guard_denylist_ok() {
  _guard_eval_rules "$1"
  [ "$_GR_VERDICT" != "DENY" ] || [ "$_GR_RULE" = "E_NORULE" ]
}
