#!/bin/bash
#
# Mac Performance Monitor — Full uninstaller
# -------------------------------------------------------------------------------
# Double-click to run (see note below if macOS blocks it the first time).
#
# This COMPLETELY REMOVES Mac Performance Monitor and gives you a clean slate:
#   • Quits the app and its auto-updater, then force-kills any leftover processes.
#   • Stops and unregisters the privileged helper (the demand-launched
#     SMAppService LaunchDaemon "uk.co.bzwrd.macperfmonitor.helper").
#   • Deletes EVERY copy of the app bundle it can find (this is what stops the
#     "multiple copies keep relaunching" problem — duplicate/registered copies).
#   • Removes the app's data, caches, preferences and saved state.
#   • Removes the stored licence from the Keychain.
#
# It only ever touches files that belong to THIS app (matched by name, bundle id
# "uk.co.bzwrd.macperfmonitor", or helper label). It does not touch anything else.
#
# It asks you to confirm before deleting, and needs your admin password once to
# remove the privileged helper.
#
# It writes a log to your Desktop. Please email that file back to us.
#
# If double-clicking shows "unidentified developer" / "cannot be opened":
#   right-click the file → Open → Open. (Downloaded scripts are blocked by default.)
# Or in Terminal:  chmod +x "<this file>"  then run it.

set -u

APP_NAME="Mac Performance Monitor"
LEGACY_APP_NAME="MacPerfMonitor"                 # pre-rename bundle name
BUNDLE_ID="uk.co.bzwrd.macperfmonitor"
HELPER_LABEL="uk.co.bzwrd.macperfmonitor.helper"
HELPER_BIN="MacPerfMonitorHelper"
TEAM_ID="8352865GK4"                             # Developer ID team of every release
KEYCHAIN_SERVICE="uk.co.bzwrd.macperfmonitor.license"
SUPPORT_DIR_NAME="MacPerformanceMonitor"         # ~/Library/Application Support/<this>
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$HOME/Desktop/MacPerfMonitor-uninstall-${STAMP}.txt"

# Mirror everything to the log file as well as the screen.
exec > >(tee "$LOG") 2>&1

echo "Mac Performance Monitor — uninstaller"
echo "When:  $(date)"
echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))   arch: $(uname -m)"
echo "Log file: $LOG"
echo "==========================================================================="

section() { echo; echo "===== $1 ====="; }

# --------------------------------------------------------------------------- #
# Confirmation
# --------------------------------------------------------------------------- #
echo
echo "This will permanently remove Mac Performance Monitor, its helper, all its"
echo "data, preferences and the stored licence from this Mac."
echo
printf "Type  yes  and press Return to continue (anything else cancels): "
read -r CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo
  echo "Cancelled. Nothing was changed."
  echo
  read -r -p "Press Return to close this window..." _ || true
  exit 0
fi

# Ask for admin rights once, up front, and keep the timestamp fresh while we run
# so the privileged steps below don't each re-prompt.
section "0. Administrator access (needed to remove the privileged helper)"
if sudo -v; then
  HAVE_SUDO=1
  # Keep sudo alive in the background until this script exits.
  ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 30; done ) &
  SUDO_KEEPALIVE_PID=$!
  echo "Administrator access granted."
else
  HAVE_SUDO=0
  echo "WARNING: no administrator access — the privileged helper may not be fully"
  echo "removed. Everything else will still be cleaned up."
fi

# --------------------------------------------------------------------------- #
# 1. Quit the app and updater, then force-kill every related process
# --------------------------------------------------------------------------- #
section "1. Quitting and killing running processes"

echo "Asking the app to quit cleanly..."
osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
sleep 1

echo "Force-killing any remaining app / updater / helper processes..."
# Anything running from inside the app bundle (main app + bundled Sparkle helpers).
pkill -f "${APP_NAME}.app/Contents"        2>/dev/null && echo "  killed: ${APP_NAME} bundle processes"
pkill -f "${LEGACY_APP_NAME}.app/Contents" 2>/dev/null && echo "  killed: legacy ${LEGACY_APP_NAME} bundle processes"
# The privileged helper (runs from inside the bundle, matched by exec name).
pkill -x "$HELPER_BIN"                      2>/dev/null && echo "  killed: ${HELPER_BIN}"
# Sparkle auto-updater scoped to this app only.
pkill -f "${APP_NAME}.app.*Autoupdate"     2>/dev/null && echo "  killed: Sparkle Autoupdate"
sleep 1

echo
echo "Still running after kill (should be none):"
ps -axww -o pid,ppid,command \
  | grep -iE "${APP_NAME}|${LEGACY_APP_NAME}|${HELPER_BIN}" | grep -v grep \
  | grep -v "Uninstall.command" || echo "  (none)"

# --------------------------------------------------------------------------- #
# 2. Stop and unregister the privileged helper (SMAppService LaunchDaemon)
# --------------------------------------------------------------------------- #
section "2. Removing the privileged helper / LaunchDaemon"

if [ "$HAVE_SUDO" = "1" ]; then
  echo "Booting out the system daemon (stops + unloads it)..."
  sudo launchctl bootout "system/${HELPER_LABEL}" 2>/dev/null \
    && echo "  unloaded: system/${HELPER_LABEL}" \
    || echo "  (daemon was not loaded — fine)"
  # Older fallback.
  sudo launchctl remove "$HELPER_LABEL" 2>/dev/null || true

  echo "Removing any on-disk daemon plist / privileged binary left by older installs..."
  for f in \
    "/Library/LaunchDaemons/${HELPER_LABEL}.plist" \
    "/Library/PrivilegedHelperTools/${HELPER_LABEL}" \
    "/Library/PrivilegedHelperTools/${BUNDLE_ID}"; do
    if [ -e "$f" ]; then
      sudo rm -rf "$f" && echo "  removed: $f"
    fi
  done
else
  echo "Skipped (no administrator access)."
fi

# Per-user LaunchAgents are not used by this app, but clean them defensively.
for f in \
  "$HOME/Library/LaunchAgents/${HELPER_LABEL}.plist" \
  "$HOME/Library/LaunchAgents/${BUNDLE_ID}.plist"; do
  if [ -e "$f" ]; then
    launchctl bootout "gui/$(id -u)/${HELPER_LABEL}" 2>/dev/null || true
    rm -f "$f" && echo "  removed: $f"
  fi
done

# --------------------------------------------------------------------------- #
# 3. Delete every copy of the app bundle
# --------------------------------------------------------------------------- #
section "3. Deleting the app bundle(s)"

# Find every installed copy via Spotlight, with common-folder fallbacks.
COPIES="$(mdfind "kMDItemCFBundleIdentifier == '${BUNDLE_ID}'" 2>/dev/null)"
COPIES="$COPIES
$(ls -d \
  "/Applications/${APP_NAME}.app" \
  "/Applications/${LEGACY_APP_NAME}.app" \
  "$HOME/Applications/${APP_NAME}.app" \
  "$HOME/Applications/${LEGACY_APP_NAME}.app" \
  "$HOME/Downloads/${APP_NAME}.app" \
  "$HOME/Downloads/${LEGACY_APP_NAME}.app" \
  "$HOME/Desktop/${APP_NAME}.app" \
  "$HOME/Desktop/${LEGACY_APP_NAME}.app" 2>/dev/null)"

# Spotlight indexes every account's folders, and any app can claim our bundle
# ID in its Info.plist. So a copy is only touched when it belongs to you or to
# root, and its binary is only run when the signature is really ours.
ME="$(id -u)"
OUR_SIGNATURE="=identifier \"${BUNDLE_ID}\" and anchor apple generic and certificate leaf[subject.OU] = \"${TEAM_ID}\""

# De-duplicate the list of real, existing paths.
echo "$COPIES" | awk 'NF' | sort -u | while IFS= read -r app; do
  [ -z "$app" ] && continue
  [ -e "$app" ] || continue
  owner="$(stat -f %u "$app" 2>/dev/null || echo '?')"
  if [ "$owner" != "$ME" ] && [ "$owner" != "0" ]; then
    echo "  skipping (belongs to another account): $app"
    continue
  fi
  build="$(defaults read "$app/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo '?')"

  # Tear down THIS bundle's registrations from inside the bundle itself, BEFORE
  # deleting it. The app's "--uninstall" mode unregisters its Login Item
  # (SMAppService.mainApp) and helper LaunchDaemon (SMAppService.daemon), which
  # removes their Background Task Management records. Deleting the bundle while
  # those registrations are still live is what leaves orphaned "Open at Login" /
  # daemon entries that macOS then relaunches. Run as the user (NOT sudo) so it
  # acts on this login session's registrations.
  exe="$(defaults read "$app/Contents/Info.plist" CFBundleExecutable 2>/dev/null || true)"
  if [ -n "$exe" ] && [ -x "$app/Contents/MacOS/$exe" ]; then
    if codesign --verify --test-requirement="$OUR_SIGNATURE" "$app" 2>/dev/null; then
      echo "  unregistering login item & helper from: $app"
      "$app/Contents/MacOS/$exe" --uninstall 2>&1 | sed 's/^/    /' || true
    else
      echo "  not running this copy (not signed by Mac Performance Monitor's developer): $app"
    fi
  fi

  echo "  removing: $app  (build $build)"
  if ! rm -rf "$app" 2>/dev/null; then
    # Bundle in /Applications may be root-owned.
    [ "$HAVE_SUDO" = "1" ] && sudo rm -rf "$app" && echo "    (removed with admin rights)"
  fi
done

# Re-check.
LEFT="$(mdfind "kMDItemCFBundleIdentifier == '${BUNDLE_ID}'" 2>/dev/null | awk 'NF')"
if [ -z "$LEFT" ]; then
  echo "  no app bundles remain."
else
  echo "  STILL PRESENT (may need manual drag-to-Trash):"
  echo "$LEFT" | sed 's/^/    /'
fi

# --------------------------------------------------------------------------- #
# 4. Remove user data, caches, preferences and saved state
# --------------------------------------------------------------------------- #
section "4. Removing app data, caches, preferences and saved state"

# Make sure the preferences daemon forgets the cached defaults first.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 && echo "  cleared cached defaults for ${BUNDLE_ID}"

PATHS=(
  "$HOME/Library/Application Support/${SUPPORT_DIR_NAME}"
  "$HOME/Library/Application Support/${LEGACY_APP_NAME}"
  "$HOME/Library/Caches/${BUNDLE_ID}"
  "$HOME/Library/Preferences/${BUNDLE_ID}.plist"
  "$HOME/Library/Preferences/${BUNDLE_ID}.helper.plist"
  "$HOME/Library/Saved Application State/${BUNDLE_ID}.savedState"
  "$HOME/Library/HTTPStorages/${BUNDLE_ID}"
  "$HOME/Library/HTTPStorages/${BUNDLE_ID}.binarycookies"
  "$HOME/Library/WebKit/${BUNDLE_ID}"
  "$HOME/Library/Logs/${SUPPORT_DIR_NAME}"
)
for p in "${PATHS[@]}"; do
  if [ -e "$p" ]; then
    rm -rf "$p" && echo "  removed: $p"
  fi
done

# Sparkle leaves its update cache under the app's caches sandbox; the line above
# already removes ~/Library/Caches/<bundle id>, which contains it.

# --------------------------------------------------------------------------- #
# 5. Remove the stored licence from the Keychain
# --------------------------------------------------------------------------- #
section "5. Removing the stored licence from the Keychain"

removed_any=0
# The app stores its few secrets as generic-password items under one service;
# delete them all (loops because there can be several accounts).
while security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; do
  removed_any=1
done
if [ "$removed_any" = "1" ]; then
  echo "  removed Keychain items for service ${KEYCHAIN_SERVICE}"
else
  echo "  (no Keychain items found)"
fi

# --------------------------------------------------------------------------- #
# 6. Check Background Items / Login Items registration
# --------------------------------------------------------------------------- #
section "6. Background Items (Login Items) check"

if [ "$HAVE_SUDO" = "1" ]; then
  BTM="$(sudo sfltool dumpbtm 2>/dev/null | grep -i -A2 'macperfmonitor' || true)"
  if [ -n "$BTM" ]; then
    echo "Background-item records that still mention this app:"
    echo "$BTM" | sed 's/^/  /'
    echo
    echo "The current registrations were just unregistered above. Any records"
    echo "still listed are ORPHANED generations from earlier installs (their app"
    echo "bundle is already gone, so they cannot be unregistered directly)."
    echo "macOS only prunes these on login, so:"
    echo
    echo "  >>> LOG OUT AND BACK IN (or restart) to clear the leftovers. <<<"
    echo
    echo "If any entry STILL shows after a restart, open"
    echo "  System Settings > General > Login Items & Extensions"
    echo "and remove the 'Mac Performance Monitor' row by hand."
  else
    echo "No background-item records reference this app. Clean."
  fi
else
  echo "Skipped (no administrator access). If you ever see a leftover entry, open"
  echo "System Settings > General > Login Items & Extensions and remove it,"
  echo "then log out and back in so macOS prunes the record."
fi

# --------------------------------------------------------------------------- #
# Done
# --------------------------------------------------------------------------- #
section "Finished"
echo "Mac Performance Monitor has been removed."
echo
echo "If the menu-bar icon is still showing, it is a process from before the"
echo "uninstall — log out and back in (or restart) and it will be gone for good."
echo
echo "A log of everything done is on your Desktop:"
echo "  $LOG"
echo "Please email that file back to us so we can confirm the clean-up."
echo "==========================================================================="

# Stop the sudo keep-alive helper.
if [ -n "${SUDO_KEEPALIVE_PID:-}" ]; then
  kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
fi

echo
read -r -p "Press Return to close this window..." _ || true
exit 0
