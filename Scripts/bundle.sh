#!/usr/bin/env bash
#
# bundle.sh :  assemble the app bundle from the built SPM binary and resources.
#
# Usage: Scripts/bundle.sh [debug|release]   (default: release)
#
# A SwiftUI app built as an SPM executable runs fine once wrapped in a bundle
# with an Info.plist. This script does no signing; run.sh ad-hoc signs for local
# development and Scripts/sign.sh handles Developer ID signing for releases.
#
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
shift || true

# Apple Silicon (arm64) only :  no universal/x86_64 slices.
for arg in "$@"; do
  case "$arg" in
    --universal)
      echo "bundle.sh: --universal is not supported; this is an Apple Silicon (arm64) only project." >&2
      exit 2 ;;
    *) echo "bundle.sh: ignoring unknown argument '$arg'" >&2 ;;
  esac
done

# The visible product name. The bundle identifier and the SPM product/target
# stay "MacPerfMonitor" (so the approved helper and the on-disk data directory keep
# working), but the executable inside the bundle is named for the product so the
# OS reports the process as "Mac Performance Monitor" in Activity Monitor, `ps`,
# and the app's own process list :  not "MacPerfMonitor".
APP_NAME="Mac Performance Monitor"
APP="build/$APP_NAME.app"
EXECUTABLE_NAME="$APP_NAME"

BIN_DIR="$(swift build --show-bin-path -c "$CONFIG")"
BIN="$BIN_DIR/MacPerfMonitor"
if [[ ! -x "$BIN" ]]; then
  echo "error: $BIN not found. Run Scripts/build.sh first." >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# The built SPM binary is named for the product ("MacPerfMonitor"); copy it to the
# bundle executable named for the visible product. This name is what the OS
# reports as the process name, so it must match CFBundleExecutable in
# Resources/Info.plist.
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Bundled seed for the process glossary ("what is this process?"). The live,
# frequently-updated copy is downloaded + verified from /glossary/ at runtime; this
# is the offline/first-run fallback.
cp Resources/glossary.json "$APP/Contents/Resources/glossary.json"

# --- Privileged helper (LaunchDaemon) --------------------------------------
# The root helper that restores footprint coverage for system and other-user
# processes. It ships inside the app bundle and is registered at runtime via
# SMAppService. Its launchd plist lives under Contents/Library/LaunchDaemons and
# points back at this executable through BundleProgram. Both are signed inside
# out by Scripts/sign.sh (helper first, then the app).
HELPER_BIN="$BIN_DIR/MacPerfMonitorHelper"
if [[ -x "$HELPER_BIN" ]]; then
  cp "$HELPER_BIN" "$APP/Contents/MacOS/MacPerfMonitorHelper"
  mkdir -p "$APP/Contents/Library/LaunchDaemons"
  cp Resources/MacPerfMonitorHelperDaemon.plist \
    "$APP/Contents/Library/LaunchDaemons/uk.co.bzwrd.macperfmonitor.helper.plist"
  echo "Bundled privileged helper + LaunchDaemon plist"
else
  echo "warning: $HELPER_BIN not found; bundling without the privileged helper" >&2
fi

# --- Sparkle auto-update framework -----------------------------------------
# Copy the Sparkle.framework that SPM built next to the executable into the
# bundle's Frameworks dir, and add the rpath the loader needs to find it. The
# SPM-built binary links @rpath/Sparkle.framework/Versions/B/Sparkle but only
# carries an @loader_path rpath (= Contents/MacOS), so without this the framework
# would not resolve at launch. Signed by Scripts/sign.sh (inside-out, before the
# app). Stripping happens never :  the whole framework (incl. Autoupdate, the
# Updater.app progress UI, and the XPC services) is required at runtime.
SPARKLE_FW="$BIN_DIR/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/$EXECUTABLE_NAME" 2>/dev/null \
    || echo "note: @executable_path/../Frameworks rpath already present" >&2
  echo "Bundled Sparkle.framework"
else
  echo "warning: $SPARKLE_FW not found; bundling without auto-update" >&2
fi

# --- Icons -----------------------------------------------------------------
# The two PNGs in the repo root are the single source of truth. The app icon is
# compiled into a multi-resolution .icns (referenced by CFBundleIconFile); the
# menu bar glyph is downscaled to 1x/2x template PNGs the app loads at runtime
# via NSImage(named: "MenuBarIcon").
APP_ICON_SRC="MacPerformanceMonitorAppIcon.png"
MENU_ICON_SRC="MacPerformanceMonitorMenuBarIcon.png"

if [[ -f "$APP_ICON_SRC" ]] && command -v iconutil >/dev/null 2>&1; then
  ICONSET_DIR="$(mktemp -d)"
  ICONSET="$ICONSET_DIR/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$APP_ICON_SRC" \
      --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$APP_ICON_SRC" \
      --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET_DIR"
else
  echo "warning: skipping app icon ($APP_ICON_SRC or iconutil missing)" >&2
fi

if [[ -f "$MENU_ICON_SRC" ]]; then
  sips --resampleHeight 18 "$MENU_ICON_SRC" \
    --out "$APP/Contents/Resources/MenuBarIcon.png" >/dev/null
  sips --resampleHeight 36 "$MENU_ICON_SRC" \
    --out "$APP/Contents/Resources/MenuBarIcon@2x.png" >/dev/null
else
  echo "warning: skipping menu bar icon ($MENU_ICON_SRC missing)" >&2
fi

# --- Localization tables ----------------------------------------------------
# Copy every <lang>.lproj from the SPM source tree into the bundle's Resources
# directory. SwiftPM's .process("Resources") stage already merges them into the
# built executable's bundle, but the .app we assemble here ships only the SPM
# binary, so we have to repeat the merge at bundle time. macOS resolves the
# user's preferred language against these directories at runtime.
LPROJ_SRC="Sources/MacPerfMonitor/Resources"
if [[ -d "$LPROJ_SRC" ]]; then
  shopt -s nullglob
  for lproj in "$LPROJ_SRC"/*.lproj; do
    cp -R "$lproj" "$APP/Contents/Resources/"
    echo "Bundled $(basename "$lproj")"
  done
  shopt -u nullglob
else
  echo "warning: $LPROJ_SRC not found; bundling without localization tables" >&2
fi

echo "Bundled $APP"
