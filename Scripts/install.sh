#!/usr/bin/env bash
#
# install.sh — the one release step: build, sign, notarize, staple, install to
# /Applications, and launch.
#
# Signing is Developer ID Application ONLY — hardened runtime, secure timestamp,
# and the app entitlements. There is deliberately NO ad-hoc or Apple-Development
# path, so a build can never leave here signed in a way the notary (or another
# Mac's Gatekeeper) would reject. The app is then notarized and stapled, so what
# lands in /Applications is release-ready. The privileged helper signs with the
# same Developer ID, which also keeps its SMAppService registration stable.
#
# Notarization uses a notarytool keychain profile (set up ONCE):
#   xcrun notarytool store-credentials macperfmon-notary \
#     --key /path/AuthKey_XXXXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_UUID>
#   # ...or with an Apple ID + app-specific password:
#   xcrun notarytool store-credentials macperfmon-notary \
#     --apple-id you@example.com --team-id <TEAMID> --password <app-specific-pw>
# Override the profile name with the NOTARY_PROFILE environment variable.
#
# This is an Apple Silicon (arm64) only project; builds are never universal.
#
# Flags:
#   --no-launch      install but do not launch afterwards
#   --skip-notarize  sign + install + launch only (still Developer ID signed; for
#                    fast local iteration, NOT for anything you distribute)
set -euo pipefail
cd "$(dirname "$0")/.."

LAUNCH=1
NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --no-launch) LAUNCH=0 ;;
    --skip-notarize) NOTARIZE=0 ;;
    *) echo "install.sh: ignoring unknown argument '$arg'" >&2 ;;
  esac
done

APP_NAME="Mac Performance Monitor"
APP="build/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"
# The pre-rename bundle; removed so the same bundle id isn't present at two paths.
OLD_DEST="/Applications/MacPerfMonitor.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-macperfmon-notary}"

# The first "Developer ID Application" identity in the keychain; DEVELOPER_ID_APP
# wins if already set.
detect_developer_id() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" \
    | head -1 \
    | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-Fa-f]+[[:space:]]+"(.*)"$/\1/'
}

# Fail fast before a full release build.
if [[ ! -w /Applications ]]; then
  echo "error: /Applications is not writable by $(whoami)." >&2
  exit 1
fi

if [[ -z "${DEVELOPER_ID_APP:-}" ]]; then
  DEVELOPER_ID_APP="$(detect_developer_id)"
fi
if [[ -z "$DEVELOPER_ID_APP" ]]; then
  echo "error: no 'Developer ID Application' certificate found in the keychain." >&2
  echo "       Builds must be Developer ID signed — there is no fallback. Install" >&2
  echo "       the certificate, or set DEVELOPER_ID_APP to the identity string." >&2
  exit 1
fi

# Bump the build number (CFBundleVersion) by one on every install, so each build
# that lands in /Applications is uniquely versioned (LaunchServices and the notary
# both key off it), and it makes "which build is this?" answerable. The marketing
# version (CFBundleShortVersionString) is bumped by Scripts/deploy.sh at release
# time. Done before bundling, since bundle.sh copies this Info.plist into the app.
INFO_PLIST="Resources/Info.plist"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
if [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
  NEXT_BUILD=$((CURRENT_BUILD + 1))
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_BUILD" "$INFO_PLIST"
  echo "==> Build number: $CURRENT_BUILD -> $NEXT_BUILD"
else
  echo "warning: CFBundleVersion '$CURRENT_BUILD' is not a plain integer; not bumping." >&2
fi

echo "==> Building (release)"
Scripts/build.sh --release

echo "==> Bundling"
Scripts/bundle.sh release

echo "==> Signing with Developer ID: $DEVELOPER_ID_APP"
DEVELOPER_ID_APP="$DEVELOPER_ID_APP" Scripts/sign.sh

if [[ "$NOTARIZE" -eq 1 ]]; then
  echo "==> Notarizing (profile: $NOTARY_PROFILE — can take a few minutes)"
  ZIP="build/$APP_NAME.notarize.zip"
  rm -f "$ZIP"
  /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
  SUBMIT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
  rm -f "$ZIP"
  echo "$SUBMIT"
  if ! grep -q "status: Accepted" <<<"$SUBMIT"; then
    echo "error: notarization did not return Accepted." >&2
    if grep -qi "No Keychain password item found" <<<"$SUBMIT"; then
      echo "       Notary profile '$NOTARY_PROFILE' isn't set up. Create it once with:" >&2
      echo "         xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
      echo "           --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-pw>" >&2
      echo "       (or --key <AuthKey.p8> --key-id <ID> --issuer <UUID>); or set NOTARY_PROFILE." >&2
    else
      SUBID="$(awk '/^[[:space:]]*id:/{print $2; exit}' <<<"$SUBMIT")"
      if [[ -n "$SUBID" ]]; then
        echo "       Apple's per-file reasons:" >&2
        xcrun notarytool log "$SUBID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
      fi
    fi
    exit 1
  fi
  echo "==> Stapling the ticket"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

echo "==> Installing to $DEST"
# Quit any running copy (by the stable bundle id; never touches the root helper
# daemon) so the bundle can be replaced and the new build is the one that runs.
if [[ "$(osascript -e 'application id "uk.co.bzwrd.macperfmonitor" is running' 2>/dev/null)" == "true" ]]; then
  echo "Quitting running app..."
  osascript -e 'tell application id "uk.co.bzwrd.macperfmonitor" to quit' >/dev/null 2>&1 \
    || pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" || true
fi
if [[ -d "$OLD_DEST" ]]; then
  echo "Removing legacy $OLD_DEST"
  rm -rf "$OLD_DEST"
fi
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Installed $DEST"

if [[ "$LAUNCH" -eq 1 ]]; then
  echo "==> Launching"
  # A just-quit app can leave LaunchServices mid-cleanup, so the first open may
  # fail with -600; retry briefly.
  for attempt in 1 2 3 4 5; do
    if open "$DEST" 2>/dev/null; then
      echo "Launched $DEST"
      break
    fi
    if [[ "$attempt" -eq 5 ]]; then
      echo "warning: could not launch $DEST automatically; open it from /Applications." >&2
    else
      sleep 1
    fi
  done
else
  echo "Done. Launch $APP_NAME from /Applications or Spotlight when ready."
fi
