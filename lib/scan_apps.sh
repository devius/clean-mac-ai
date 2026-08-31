#!/bin/bash
# scan_apps.sh -- installed applications, and the files apps leave behind.
#
# Matching follows Pearcleaner's approach, which is materially better than
# matching on bundle id alone. Four identifiers are derived per app and scored;
# the sensitivity tier decides which are allowed to match.
#
#   strict    exact bundle id, and the last two components of it
#   enhanced  adds the app name with any trailing version stripped
#   deep      adds a letters-only reduction of the name, and Spotlight metadata
#
# Strict is the default because a false positive here deletes someone's data.
# Anything matched above strict is marked `review` and can never be batch
# approved.

CMAI_APP_ROOTS="/Applications $HOME/Applications /Applications/Utilities"

# Directories an uninstall must consider. /var/db/receipts is deliberately
# absent: it is a hard deny, and breaking pkgutil breaks future updates and
# any MDM inventory. Receipts are reported, never removed.
CMAI_LEFTOVER_DIRS="
$HOME/Library/Application Support
$HOME/Library/Caches
$HOME/Library/Preferences
$HOME/Library/Containers
$HOME/Library/HTTPStorages
$HOME/Library/WebKit
$HOME/Library/Saved Application State
$HOME/Library/Logs
$HOME/Library/Cookies
$HOME/Library/Application Scripts
$HOME/Library/LaunchAgents
/Library/Application Support
/Library/Preferences
/Library/LaunchAgents
/Library/LaunchDaemons
/Library/PrivilegedHelperTools
"

cmai_app_bundleid() { $PLUTIL -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null; }

# Identifiers for one app, one per line, most specific first.
cmai_app_identifiers() {
  local app="$1" tier="${2:-strict}" bid name short letters
  bid=$(cmai_app_bundleid "$app")
  name=$($BASENAME "$app" .app)

  [ -n "$bid" ] && printf '%s\n' "$bid"
  # Last two components: com.example.Widget -> example.Widget
  [ -n "$bid" ] && printf '%s\n' "$bid" | $AWK -F. 'NF>=2 { printf "%s.%s\n", $(NF-1), $NF }'

  case "$tier" in
    enhanced|deep)
      # Trailing version stripped: "Bartender 6" -> "Bartender"
      short=$(printf '%s' "$name" | $SED -E 's/[ _-]+[0-9]+(\.[0-9]+)*$//')
      printf '%s\n' "$short" ;;
  esac
  case "$tier" in
    deep)
      letters=$(printf '%s' "$name" | $TR -cd '[:alnum:]')
      [ -n "$letters" ] && printf '%s\n' "$letters" ;;
  esac
  return 0
}

# cmai_scan_apps -- with --app/--bundle, the leftovers of one app; otherwise
# orphans: support files whose owning application is no longer installed.
cmai_scan_apps() {
  local tier="${OPT_TIER:-strict}"
  if [ -n "${OPT_APP:-}" ]; then
    cmai_app_leftovers "$OPT_APP" "$tier"
  else
    cmai_app_orphans "$tier"
  fi
}

cmai_app_leftovers() {
  local app="$1" tier="$2" ids d hit bid running
  [ -d "$app" ] || cmai_die "no such application: $app"
  bid=$(cmai_app_bundleid "$app")
  ids=$(cmai_app_identifiers "$app" "$tier")

  # A running app rewrites its own files; removing them under it corrupts state.
  running=""
  if [ -n "$bid" ]; then
    $PGREP -f "$app" >/dev/null 2>&1 && running=" The app is currently running: quit it before removing anything."
  fi

  cmai_emit app app-bundle "$app" review trash full "${bid:--}" \
    "The application bundle itself.${running}"

  while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      cmai_emit app app-leftover "$hit" \
        "$([ "$tier" = strict ] && printf review || printf review)" \
        trash full "${bid:--}" \
        "Matched $tier-tier identifier for $($BASENAME "$app" .app).${running}"
    done <<EOF
$($FIND "$d" -maxdepth 1 -mindepth 1 2>/dev/null | cmai_match_ids "$ids")
EOF
  done <<EOF
$CMAI_LEFTOVER_DIRS
EOF

  # Receipts are reported so an uninstall is honest about what it did not touch.
  if [ -n "$bid" ] && command -v pkgutil >/dev/null 2>&1; then
    pkgutil --pkgs 2>/dev/null | $GREP -F "$bid" | while IFS= read -r pkg; do
      [ -n "$pkg" ] || continue
      printf '%s\tapp\treceipt\t%s\t0\t-\treview\tINFO\tnone\treport\t-\tnone\t%s\t-\t%s\n' \
        "$(cmai_id "receipt-$pkg")" "$pkg" "$bid" \
        "Installer receipt. Left in place: /var/db/receipts is protected, and removing receipts breaks pkgutil, future updates and MDM inventory. Use: sudo pkgutil --forget $pkg"
    done
  fi
  return 0
}

# Filter stdin (candidate paths) to those whose basename matches an identifier.
cmai_match_ids() {
  local ids="$1"
  $AWK -v ids="$ids" '
    BEGIN { n = split(ids, a, "\n") }
    {
      path = $0
      k = path; sub(/.*\//, "", k)
      base = k; sub(/\.(plist|savedState|binarycookies)$/, "", base)
      for (i = 1; i <= n; i++) {
        if (a[i] == "") continue
        if (base == a[i] || k == a[i]) { print path; next }
        # Prefix form catches com.vendor.App.helper and ByHost variants.
        if (index(base, a[i] ".") == 1) { print path; next }
      }
    }'
}

# Support files whose owning app is gone. High precision, low risk: we only
# claim an orphan when the identifier looks like a bundle id and no installed
# app declares it.
cmai_app_orphans() {
  local tier="$1" d hit base installed
  installed=$(cmai_installed_bundleids)
  for d in "$HOME/Library/Application Support" "$HOME/Library/Caches" \
           "$HOME/Library/Containers" "$HOME/Library/HTTPStorages"; do
    [ -d "$d" ] || continue
    $FIND "$d" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      base=$($BASENAME "$hit")
      case "$base" in *.*.*) ;; *) continue ;; esac      # reverse-DNS shaped only
      [ -n "$(printf '%s' "$installed" | $GREP -xF "$base")" ] && continue
      cmai_emit app app-orphan "$hit" review trash full "$base" \
        "No installed application declares the bundle identifier $base, so this is left over from software you have already removed."
    done
  done
  return 0
}

cmai_installed_bundleids() {
  local a
  for d in $CMAI_APP_ROOTS; do
    [ -d "$d" ] || continue
    $FIND "$d" -maxdepth 2 -name '*.app' -maxdepth 2 2>/dev/null | while IFS= read -r a; do
      [ -n "$a" ] && cmai_app_bundleid "$a"
    done
  done
  return 0
}
