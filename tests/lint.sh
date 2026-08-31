#!/bin/bash
# lint.sh -- mechanical enforcement of the project's safety invariants.
#
# These are greps rather than review conventions because a convention that is
# only documented eventually gets broken by a well-meaning change.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
cd "$ROOT" || exit 1

FAIL=0
PROD="bin/cmai $(/bin/ls lib/*.sh 2>/dev/null)"

bad() { printf 'LINT FAIL: %s\n' "$1" >&2; FAIL=1; }
ok()  { printf 'ok: %s\n' "$1"; }

# Concatenate production code with full-line comments removed, keeping
# file:line prefixes so a hit can still be located. Without this the checks
# below match their own explanatory comments.
code() {
  local f
  for f in $PROD; do
    /usr/bin/grep -nv '^[[:space:]]*#' "$f" 2>/dev/null | /usr/bin/sed "s|^|$f:|"
  done
}

# 1. syntax ------------------------------------------------------------------
for f in $PROD tests/*.sh; do
  /bin/bash -n "$f" 2>/dev/null || bad "syntax error in $f"
done
[ "$FAIL" = 0 ] && ok "all scripts parse"

# 2. no recursive or forced removal in production code -----------------------
# Nothing in bin/ or lib/ may remove recursively. Removal goes through the
# trash or the quarantine, both of which are reversible.
if code | /usr/bin/grep -E '\brm\b[^|;&]*-[a-zA-Z]*[rRf]'; then
  bad "recursive or forced removal in production code"
else ok "no recursive or forced removal in bin/ or lib/"; fi

# 3. privilege escalation never combines with removal ------------------------
if /usr/bin/grep -nv '^[[:space:]]*#' lib/reclaim.sh | /usr/bin/grep 'sudo'; then
  bad "privilege escalation appears in lib/reclaim.sh"
else ok "lib/reclaim.sh does not escalate privileges"; fi
if code | /usr/bin/grep -E 'sudo[^|;&]*\brm\b|\brm\b[^|;&]*sudo'; then
  bad "privilege escalation on the same line as a removal"
else ok "no escalated removal anywhere"; fi

# 4. no network access -------------------------------------------------------
# A tool that reads your whole disk should not also be able to send anything.
if code | /usr/bin/grep -E '\b(curl|wget|nc|ftp|scp|ssh)\b'; then
  bad "network client invoked in production code"
else ok "no network access in production code"; fi

# 5. bash 3.2 only -----------------------------------------------------------
# /bin/bash on macOS is 3.2.57 and that is what the shebangs select.
if code | /usr/bin/grep -E 'declare -A|local -A|mapfile|readarray|\$\{[A-Za-z_]+\^\^|\$\{[A-Za-z_]+,,'; then
  bad "bash 4+ construct in production code"
else ok "bash 3.2 compatible"; fi

# 6. (the bash 3.2 "case inside $()" parser bug) -----------------------------
# Not a separate check: that construct is a hard syntax error, so check 1's
# `bash -n` catches every instance of it. A grep-based heuristic for it produced
# only false positives, since $( appears on most lines of this codebase.

# 6b. no `grep -q` as the consumer of a pipeline in production code ----------
# bin/cmai sets `set -o pipefail`. grep -q exits on the first match, closing the
# pipe; the producer then dies of SIGPIPE and the pipeline reports 141, so a
# successful match reads as a failure. In a safety check that silently inverts
# the result. Use a command substitution and test for a non-empty string.
if code | /usr/bin/grep -E '\|[[:space:]]*(\$GREP|/usr/bin/grep|grep) -q'; then
  bad "grep -q consuming a pipeline (SIGPIPE inverts the result under pipefail)"
else ok "no grep -q pipeline consumers"; fi

# 7. external tools are called by absolute path ------------------------------
# A user profile that defines find() as a function silently changes behaviour;
# -flags stops working and the guard's SIP checks become no-ops.
if code | /usr/bin/grep -E '(^|[|;&(] *|\$\( *)(find|stat|du|df|ls|awk|sed|sort|grep|xargs) '; then
  bad "external tool invoked without an absolute path"
else ok "external tools are called by absolute path"; fi

# 8. every protective rule has a test ----------------------------------------
missing=0
while IFS=$'\t' read -r kind pat _rest; do
  case "$kind" in DENY) ;; *) continue ;; esac
  case "$pat" in '~'*) pat_expanded=$(printf '%s' "$pat" | /usr/bin/sed "s|^~|\$HOME|") ;; *) pat_expanded="$pat" ;; esac
  /usr/bin/grep -qF "$pat_expanded" tests/cases-guard.tsv tests/test_denylist.sh 2>/dev/null && continue
  printf '  untested deny rule: %s\n' "$pat" >&2
  missing=$((missing+1))
done < <(/usr/bin/grep -v '^#' data/denylist.tsv)
if [ "$missing" -gt 0 ]; then
  bad "$missing deny rule(s) have no corresponding test"
else ok "every deny rule is covered by a test"; fi

# 9. shellcheck, when available ----------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  # SC1090/SC1091: dynamic `source` paths are how the dispatcher composes itself.
  # Suppressions live in .shellcheckrc, each with a written reason.
  if shellcheck -s bash $PROD; then ok "shellcheck clean"
  else bad "shellcheck reported problems"; fi
else
  printf 'skip: shellcheck not installed (brew install shellcheck)\n'
fi

[ "$FAIL" = 0 ] && printf '\nlint: all checks passed\n'
exit "$FAIL"
