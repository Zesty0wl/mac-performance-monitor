#!/usr/bin/env bash
#
# run.sh — the dev inner loop: build, bundle, sign, and launch.
#
# Debug by default for fast iteration; pass --release to match the shipping
# build.
#
# Signing modes:
#   (default)        Ad-hoc (codesign -s -). Launches locally with no cert, but
#                    the ad-hoc signature has no certificate chain, so it cannot
#                    satisfy the app<->helper XPC code-signing pin
#                    (HelperConstants.peerRequirement, which requires
#                    `anchor apple generic` + the team OU). The privileged
#                    helper therefore stays unreachable and system / other-user
#                    processes (WindowServer, coreaudiod, root daemons) are NOT
#                    visible. Fine when you don't need elevated coverage.
#   --developer-id   Sign the helper and app with a real keychain identity so the
#                    XPC pin is satisfied and elevated coverage works. Uses
#                    $DEVELOPER_ID_APP if set, otherwise auto-picks the best
#                    available codesigning identity (Developer ID > Apple
#                    Distribution > Apple Development). An Apple Development cert
#                    (what `Xcode > Settings > Accounts` installs) is enough for
#                    local dev: it chains to Apple (`anchor apple generic`) and
#                    carries the team in subject.OU.
#
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="debug"
# Default to a real signing identity when one is available, falling back to ad-hoc
# only when there is no cert. A real identity is what makes a dev build behave like
# a release build: the privileged helper's XPC code-signing pin is satisfied (so
# Full Coverage actually works), the Keychain ACL is stable across rebuilds (no
# repeated "allow access" prompts), and CPU/energy measurements are representative.
# Ad-hoc builds fail all three, so they must never be used for perf testing.
SIGN_MODE="auto"
for arg in "$@"; do
  case "$arg" in
    --release)               CONFIG="release" ;;
    --debug)                 CONFIG="debug" ;;
    --developer-id|--sign)   SIGN_MODE="identity" ;;
    --adhoc)                 SIGN_MODE="adhoc" ;;
    *) echo "run.sh: ignoring unknown argument '$arg'" >&2 ;;
  esac
done

# Resolve a codesigning identity for --developer-id. Prefer an explicit
# DEVELOPER_ID_APP; otherwise pick the most production-like identity in the
# keychain. Echoes the SHA-1 hash (unambiguous even if names collide).
resolve_identity() {
  if [[ -n "${DEVELOPER_ID_APP:-}" ]]; then
    printf '%s' "$DEVELOPER_ID_APP"
    return 0
  fi
  local list pat line
  list="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  for pat in "Developer ID Application" "Apple Distribution" "Apple Development"; do
    line="$(printf '%s\n' "$list" | grep -F "$pat" | head -1 || true)"
    if [[ -n "$line" ]]; then
      printf '%s' "$line" | awk '{print $2}'
      return 0
    fi
  done
  return 1
}

# Resolve the default: use an identity if the keychain has one, else ad-hoc.
if [[ "$SIGN_MODE" == "auto" ]]; then
  if resolve_identity >/dev/null 2>&1; then
    SIGN_MODE="identity"
  else
    SIGN_MODE="adhoc"
    echo "run.sh: no codesigning identity found — falling back to ad-hoc." >&2
    echo "        (Helper coverage will not work and perf is unrepresentative.)" >&2
  fi
fi

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --product MacPerfMonitor
# Build the privileged helper too so the bundle is complete (the app target does
# not depend on it, so it is not built transitively).
swift build -c "$CONFIG" --product MacPerfMonitorHelper

echo "==> Bundling"
Scripts/bundle.sh "$CONFIG"

APP="build/Mac Performance Monitor.app"
HELPER="$APP/Contents/MacOS/MacPerfMonitorHelper"
ENTITLEMENTS="Resources/MacPerfMonitor.entitlements"

if [[ "$SIGN_MODE" == "identity" ]]; then
  IDENTITY="$(resolve_identity)" || {
    echo "run.sh: --developer-id requested but no codesigning identity was found." >&2
    echo "        Open Xcode > Settings > Accounts, add your Apple ID, and create a" >&2
    echo "        signing certificate; or set DEVELOPER_ID_APP to an identity name." >&2
    exit 1
  }
  echo "==> Signing with identity: $IDENTITY"
  # Inside out: sign the nested helper before the enclosing app. The helper needs
  # no entitlements (it runs as root); the explicit --identifier makes its code
  # identity "uk.co.bzwrd.macperfmonitor.helper" so it satisfies the app's
  # helperRequirement (which pins that identifier).
  if [[ -f "$HELPER" ]]; then
    codesign --force --options runtime \
      --identifier "uk.co.bzwrd.macperfmonitor.helper" \
      --sign "$IDENTITY" "$HELPER"
  fi
  # Sparkle.framework must be signed inside-out with the SAME identity before the
  # app, or hardened-runtime library validation refuses to load it and the app
  # crashes at launch ("Library not loaded: @rpath/Sparkle.framework"). Mirrors
  # Scripts/sign.sh; no --timestamp here since local dev needs no notarisation.
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$SPARKLE" ]]; then
    echo "==> Signing Sparkle.framework (inside-out)"
    SPARKLE_V="$SPARKLE/Versions/B"
    for nested in \
      "$SPARKLE_V/XPCServices/Downloader.xpc" \
      "$SPARKLE_V/XPCServices/Installer.xpc" \
      "$SPARKLE_V/Updater.app" \
      "$SPARKLE_V/Autoupdate"; do
      if [[ -e "$nested" ]]; then
        codesign --force --options runtime --sign "$IDENTITY" "$nested"
      fi
    done
    codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE"
  fi
  codesign --force --options runtime \
    --identifier "uk.co.bzwrd.macperfmonitor" \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"

  echo "==> Verifying signatures satisfy the XPC pin"
  # The pin is portable: it derives the team from the running signature, so we
  # verify against whatever team the app was just signed with (not a hardcoded
  # one) and confirm the helper shares it. codesign's verify-time requirement
  # check needs the `-R=<req>` (equals) form; the space form silently misparses.
  codesign --verify --strict "$APP"
  APP_TEAM="$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  HELPER_TEAM="$(codesign -dvvv "$HELPER" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  if [[ -n "$APP_TEAM" && "$APP_TEAM" == "$HELPER_TEAM" ]] \
    && codesign --verify -R="anchor apple generic and certificate leaf[subject.OU] = \"$APP_TEAM\" and identifier \"uk.co.bzwrd.macperfmonitor\"" "$APP" 2>/dev/null \
    && codesign --verify -R="anchor apple generic and certificate leaf[subject.OU] = \"$HELPER_TEAM\" and identifier \"uk.co.bzwrd.macperfmonitor.helper\"" "$HELPER" 2>/dev/null; then
    echo "    app + helper share team $APP_TEAM and satisfy the pin ✓"
  else
    echo "    WARNING: signatures do not satisfy the pin (app team='$APP_TEAM', helper team='$HELPER_TEAM')" >&2
  fi
else
  echo "==> Ad-hoc signing (helper coverage will NOT work; pass --developer-id to sign with your cert)"
  # Inside out: sign the nested helper before the enclosing app.
  if [[ -f "$HELPER" ]]; then
    codesign --force --options runtime \
      --identifier "uk.co.bzwrd.macperfmonitor.helper" \
      --sign - "$HELPER"
  fi
  codesign --force --options runtime --sign - "$APP"
fi

echo "==> Launching"
open "$APP"
echo "Launched $APP"
echo "Note: this is a menu bar app (no window, no Dock icon by default);"
echo "look for its read-out near the clock at the right end of the menu bar."
