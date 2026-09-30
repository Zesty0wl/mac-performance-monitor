#!/usr/bin/env bash
#
# sign.sh — Developer ID code signing for release builds.
#
# Used by install.sh (local build) and deploy.sh, never in the dev inner loop:
# run.sh ad-hoc signs instead, so contributors need no certificate. The signing
# identity is read from the DEVELOPER_ID_APP environment variable (install.sh /
# deploy.sh auto-detect it from the keychain when unset).
#
#   DEVELOPER_ID_APP   e.g. "Developer ID Application: Your Name (TEAMID)"
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Mac Performance Monitor.app"
ENTITLEMENTS="Resources/MacPerfMonitor.entitlements"
IDENTITY="${DEVELOPER_ID_APP:-Developer ID Application: YOUR NAME (TEAMID)}"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found. Run Scripts/bundle.sh first." >&2
  exit 1
fi

echo "==> Signing $APP"
# Hardened Runtime (--options runtime) and a secure timestamp (--timestamp) are
# both required for notarisation. No App Sandbox: see Resources/MacPerfMonitor.entitlements.
#
# Sign inside out: the nested privileged helper executable must be signed before
# the enclosing app, or codesign rejects the bundle as containing unsigned
# nested code. The helper runs as root and needs no entitlements of its own.
HELPER="$APP/Contents/MacOS/MacPerfMonitorHelper"
if [[ -f "$HELPER" ]]; then
  echo "==> Signing helper $HELPER"
  # Pin an explicit code-signing identifier matching the Mach service name and
  # LaunchDaemon Label, so it satisfies the app's helperRequirement (which is
  # `identifier "uk.co.bzwrd.macperfmonitor.helper"`). Without this, codesign would
  # derive the identifier from the filename ("MacPerfMonitorHelper") and the app would
  # reject the connection.
  codesign --force --options runtime --timestamp \
    --identifier "uk.co.bzwrd.macperfmonitor.helper" \
    --sign "$IDENTITY" \
    "$HELPER"
fi

# Sparkle.framework: sign inside-out — the XPC services, the Updater.app progress
# UI, and the Autoupdate helper, then the framework bundle itself — all before the
# enclosing app, or codesign rejects the app as containing unsigned nested code.
# Each gets Hardened Runtime (--options runtime) and a secure timestamp so the
# notary accepts them. No App Sandbox, so the XPC services need no entitlements.
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
      codesign --force --options runtime --timestamp --sign "$IDENTITY" "$nested"
    fi
  done
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE"
fi

codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" \
  "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Signed and verified $APP"
