#!/usr/bin/env bash
#
# bundle.sh — assemble the app bundle from the built SPM binary and resources.
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

# Apple Silicon (arm64) only — no universal/x86_64 slices.
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
# and the app's own process list — not "MacPerfMonitor".
APP_NAME="Mac Performance Monitor"
APP="${MACPERF_BUNDLE_OUTPUT:-build/$APP_NAME.app}"
EXECUTABLE_NAME="$APP_NAME"

BIN_DIR="$(swift build --show-bin-path -c "$CONFIG")"
BIN="$BIN_DIR/MacPerfMonitor"
if [[ ! -x "$BIN" ]]; then
  echo "error: $BIN not found. Run Scripts/build.sh first." >&2
  exit 1
fi

# macOS gives an app Liquid Glass and other current-SDK behaviour only when its
# LC_BUILD_VERSION records SDK 26 or later. 2.2.0 shipped stamped "sdk 15.0"
# (#117), so refuse to bundle a binary that would lose the current look.
LINKED_SDK="$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/ {found = 1} found && $1 == "sdk" {print $2; exit}')"
if [[ -z "$LINKED_SDK" ]] || (( ${LINKED_SDK%%.*} < 26 )); then
  echo "error: $BIN records SDK '${LINKED_SDK:-unknown}', not 26 or later." >&2
  echo "       Build with Scripts/build.sh, which passes the real SDK version to the linker." >&2
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

case "$CONFIG" in
  debug) INTENTS_CONFIG="Debug" ;;
  release) INTENTS_CONFIG="Release" ;;
  *) echo "error: unsupported build configuration $CONFIG" >&2; exit 1 ;;
esac
INTENTS_OBJECTS="$PWD/.build/out/Intermediates.noindex/MacPerfMonitor.build/$INTENTS_CONFIG/MacPerfMonitor-p.build/Objects-normal/arm64"
INTENTS_SOURCES="$INTENTS_OBJECTS/MacPerfMonitor.SwiftFileList"
if [[ ! -f "$INTENTS_SOURCES" ]]; then
  echo "error: App Intents metadata inputs are missing. Build this preview with Xcode 27 before bundling." >&2
  exit 1
fi
INTENTS_VALUES="$(mktemp)"
trap 'rm -f "$INTENTS_VALUES"' EXIT
find "$INTENTS_OBJECTS" -maxdepth 1 -name '*.swiftconstvalues' -print > "$INTENTS_VALUES"
if [[ ! -s "$INTENTS_VALUES" ]]; then
  echo "error: compiled App Intents constants are missing." >&2
  exit 1
fi
XCODE_DEVELOPER_DIR="$(xcode-select -p)"
xcrun appintentsmetadataprocessor \
  --output "$APP/Contents/Resources" \
  --toolchain-dir "$XCODE_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain" \
  --module-name MacPerfMonitor \
  --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
  --platform-family macOS \
  --deployment-target 15.0 \
  --target-triple arm64-apple-macos15.0 \
  --source-file-list "$INTENTS_SOURCES" \
  --swift-const-vals-list "$INTENTS_VALUES" \
  --no-app-shortcuts-localization
INTENTS_METADATA="$APP/Contents/Resources/Metadata.appintents/extract.actionsdata"
if [[ ! -s "$INTENTS_METADATA" ]] \
  || [[ "$(plutil -extract actions.GetCurrentMonitorReportIntent.identifier raw -o - "$INTENTS_METADATA" 2>/dev/null)" != "GetCurrentMonitorReportIntent" ]] \
  || [[ "$(plutil -extract actions.OpenAskPreviewIntent.identifier raw -o - "$INTENTS_METADATA" 2>/dev/null)" != "OpenAskPreviewIntent" ]]; then
  echo "error: App Intents discovery metadata was not produced." >&2
  exit 1
fi
echo "Bundled App Intents metadata"

INFERENCE_BIN="$BIN_DIR/MacPerfMonitorInference"
if [[ ! -x "$INFERENCE_BIN" ]]; then
  echo "error: the local inference worker is missing. Run Scripts/build.sh first." >&2
  exit 1
fi
cp "$INFERENCE_BIN" "$APP/Contents/MacOS/MacPerfMonitorInference"
LLAMA_FW="$BIN_DIR/llama.framework"
if [[ ! -d "$LLAMA_FW" ]]; then
  echo "error: the GGUF inference framework is missing. Run Scripts/build.sh first." >&2
  exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
cp -R "$LLAMA_FW" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$APP/Contents/MacOS/MacPerfMonitorInference"
for resource in mlx-swift_Cmlx swift-transformers_Hub swift-crypto_Crypto; do
  if [[ ! -d "$BIN_DIR/$resource.bundle" ]]; then
    echo "error: inference resource $resource.bundle is missing." >&2
    exit 1
  fi
  cp -R "$BIN_DIR/$resource.bundle" "$APP/Contents/Resources/"
done
mkdir -p "$APP/Contents/Resources/InferenceLicenses"
cp ThirdParty/LLAMA-LICENSE "$APP/Contents/Resources/InferenceLicenses/llama.cpp-LICENSE"
for dependency in .build/checkouts/*; do
  [[ -d "$dependency" ]] || continue
  name="$(basename "$dependency")"
  for license in LICENSE LICENSE.txt LICENSE.md NOTICE NOTICE.txt; do
    if [[ -f "$dependency/$license" ]]; then
      cp "$dependency/$license" "$APP/Contents/Resources/InferenceLicenses/$name-$license"
    fi
  done
done
echo "Bundled local inference worker and resources (model weights download separately)"

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
# app). Stripping happens never — the whole framework (incl. Autoupdate, the
# Updater.app progress UI, and the XPC services) is required at runtime.
SPARKLE_FW="$BIN_DIR/Sparkle.framework"
if [[ ! -d "$SPARKLE_FW" ]]; then
  SPARKLE_FW="ThirdParty/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
fi
if [[ -d "$SPARKLE_FW" ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/$EXECUTABLE_NAME" 2>/dev/null \
    || echo "note: @executable_path/../Frameworks rpath already present" >&2
  echo "Bundled Sparkle.framework"
else
  echo "error: Sparkle.framework is missing; the app cannot launch without it." >&2
  exit 1
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
# Compile the String Catalog into the per-language .lproj directories macOS
# resolves at runtime. The catalog is the single source of truth for every
# language; the .lproj files are build output and are not in the repository.
#
# SwiftPM's native build system copies an .xcstrings verbatim rather than
# compiling it (Foundation cannot read a catalog at runtime), so the compile
# has to happen here. xcstringstool ships inside Xcode, not the Command Line
# Tools, so a contributor with only the CLT gets a warning and an
# English-only build rather than a hard failure: every key is its own English
# text, so untranslated lookups fall back to correct English.
CATALOG="Localizations/Localizable.xcstrings"
if [[ -f "$CATALOG" ]]; then
  if xcrun --find xcstringstool > /dev/null 2>&1; then
    xcrun xcstringstool compile "$CATALOG" --output-directory "$APP/Contents/Resources"
    for lproj in "$APP/Contents/Resources"/*.lproj; do
      [[ -d "$lproj" ]] && echo "==> Bundled localization $(basename "$lproj")"
    done
  else
    echo "warning: xcstringstool not found, so $CATALOG was not compiled." >&2
    echo "         The app will run in English. Install Xcode (not just the" >&2
    echo "         Command Line Tools) and re-run to include translations." >&2
  fi
fi

echo "Bundled $APP"
