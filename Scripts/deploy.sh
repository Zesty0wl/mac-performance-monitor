#!/usr/bin/env bash
#
# deploy.sh: cut a GitHub Release. Bump the version, build, sign, notarize, publish.
#
# deploy.sh owns the marketing-version bump (--dot / --minor / --major) and then
# delegates the release build to Scripts/install.sh (which bumps the build number,
# builds, Developer ID signs, notarizes, staples, and installs to /Applications).
# It then packages and publishes that bundle to GitHub Releases, via BOTH channels:
#
#   • Sparkle (existing users) -> <archive>.zip + appcast.xml (Release assets)
#   • Manual download          -> MacPerformanceMonitor.pkg   (Release asset)
#
# Everything is hosted on GitHub Releases — there is no private server. The app's
# SUFeedURL points at releases/latest/download/appcast.xml, and every appcast
# enclosure plus the .pkg live as assets of the tagged release this script creates.
# Signing/notarization stay LOCAL (on this Mac); only the publish step talks to
# GitHub, so no Apple or Sparkle secrets ever leave the machine.
#
# Why a .pkg (not a .zip or .dmg) for manual downloads: a downloaded .zip can be
# corrupted by the `unzip` CLI / third-party unarchivers (AppleDouble `._` files
# break the code-signature seal, so Gatekeeper rejects the app), and a .dmg is a
# clunky drag-install. A flat, signed installer .pkg double-clicks straight into
# /Applications and can't be corrupted that way. Sparkle keeps using the .zip (its
# own extractor handles it correctly). The .pkg payload is the already-stapled app.
#
# The app bundle is Developer ID signed, notarized and stapled (by install.sh);
# this script additionally signs the .pkg (Developer ID Installer) and notarizes +
# staples it. It refuses to publish an app that isn't already notarized + stapled.
#
# Usage:
#   Scripts/deploy.sh [--dot|--minor|--major] [--skip-upload]
#     --dot           bump the patch version (default), e.g. 1.2.0 -> 1.2.1
#     --minor         bump the minor version,           e.g. 1.2.0 -> 1.3.0
#     --major         bump the major version,           e.g. 1.2.0 -> 2.0.0
#     --skip-upload   build the zip + pkg + appcast locally, but do NOT create the
#                     GitHub Release (no gh calls). Handy for a dry run.
#
# Prerequisites (run from Terminal.app so notarization can reach the keychain):
#   - Developer ID Application + Developer ID Installer certs in the keychain.
#   - notarytool keychain profile (NOTARY_PROFILE, default macperfmon-notary).
#   - Sparkle EdDSA key: secrets/sparkle_private_key.pem (or the login keychain).
#   - gh CLI authenticated with write access to $REPO (GITHUB_REPO to override).
set -euo pipefail
cd "$(dirname "$0")/.."

# ---- configuration ---------------------------------------------------------
APP_NAME="Mac Performance Monitor"
APP="build/$APP_NAME.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-macperfmon-notary}"
SPARKLE_TOOLS="Scripts/sparkle-tools"
KEY_FILE="secrets/sparkle_private_key.pem"
REPO="${GITHUB_REPO:-Zesty0wl/mac-performance-monitor}"
PRODUCT_URL="https://macperformancemonitor.com"

DIST_DIR="dist/updates"                    # Sparkle zip + appcast (fed to generate_appcast)
PKG_DIR="dist"                             # the installer .pkg, kept OUT of DIST_DIR
ARCHIVE_BASENAME="MacPerformanceMonitor"   # no spaces — it ends up in a URL

# ---- argument parsing ------------------------------------------------------
SKIP_UPLOAD=0
BUMP="dot"  # version bump: dot (default) | minor | major
for arg in "$@"; do
  case "$arg" in
    --skip-upload) SKIP_UPLOAD=1 ;;
    --major) BUMP="major" ;;
    --minor) BUMP="minor" ;;
    --dot|--patch) BUMP="dot" ;;
    *) echo "deploy.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

# ---- bump the version, then build/sign/notarize via install.sh -------------
# deploy owns the marketing-version bump; install.sh does the release build
# (build-number bump, Developer ID sign, notarize, staple, install). The version
# must be set before the build, since it is baked into the signed, notarized app.
INFO_PLIST="Resources/Info.plist"
CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
if [[ "$CURRENT_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  V_MAJOR="${BASH_REMATCH[1]}"; V_MINOR="${BASH_REMATCH[2]}"; V_PATCH="${BASH_REMATCH[3]}"
  case "$BUMP" in
    major) V_MAJOR=$((V_MAJOR + 1)); V_MINOR=0; V_PATCH=0 ;;
    minor) V_MINOR=$((V_MINOR + 1)); V_PATCH=0 ;;
    dot)   V_PATCH=$((V_PATCH + 1)) ;;
  esac
  NEXT_VERSION="$V_MAJOR.$V_MINOR.$V_PATCH"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT_VERSION" "$INFO_PLIST"
  echo "==> Version ($BUMP bump): $CURRENT_VERSION -> $NEXT_VERSION"
else
  echo "error: CFBundleShortVersionString '$CURRENT_VERSION' is not X.Y.Z; cannot bump." >&2
  exit 1
fi

echo "==> Building the release (install.sh: build, sign, notarize, staple, install)"
if ! Scripts/install.sh --no-launch; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $CURRENT_VERSION" "$INFO_PLIST"
  echo "error: release build failed; reverted the version to $CURRENT_VERSION. Fix the" >&2
  echo "       issue (often notarization: run deploy.sh from Terminal.app), then retry." >&2
  exit 1
fi

# ---- validate the built app ------------------------------------------------
if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found; the install.sh build step did not produce it." >&2
  exit 1
fi
# Sanity-check the freshly built app is notarized + stapled: Sparkle downloaders
# (and the pkg payload) verify Gatekeeper offline, so an unstapled build fails.
if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
  echo "error: $APP is not notarized + stapled after the build." >&2
  exit 1
fi

# ---- detect the Developer ID Installer identity (for pkg signing) ----------
detect_installer_id() {
  security find-identity -v 2>/dev/null \
    | grep "Developer ID Installer" | head -1 \
    | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-Fa-f]+[[:space:]]+"(.*)"$/\1/'
}
INSTALLER_ID="${DEVELOPER_ID_INSTALLER:-$(detect_installer_id)}"
if [[ -z "$INSTALLER_ID" ]]; then
  echo "error: no 'Developer ID Installer' certificate found in the keychain." >&2
  echo "       Install it, or set DEVELOPER_ID_INSTALLER to the identity string." >&2
  exit 1
fi

# ---- Sparkle EdDSA key (prompt-free file, else the login keychain) ---------
ED_KEY_ARGS=()
if [[ -f "$KEY_FILE" ]]; then
  ED_KEY_ARGS=(--ed-key-file "$KEY_FILE")
  echo "==> Using Sparkle key file: $KEY_FILE"
else
  echo "==> $KEY_FILE not found; generate_appcast will use the login keychain key."
fi

# ---- versions read from the bundle (no bump) -------------------------------
INFO="$APP/Contents/Info.plist"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
STEM="${ARCHIVE_BASENAME}-${SHORT_VERSION}.${BUILD}"
# One release per build. The tag embeds the build so successive builds of the same
# short version never collide, and it is a 4-part string (not semver) so GitHub
# will not mistake it for a pre-release; --latest below marks it the current one.
TAG="v${SHORT_VERSION}.${BUILD}"
# Baked into every enclosure URL in the appcast — points at THIS release's assets.
DOWNLOAD_PREFIX="https://github.com/${REPO}/releases/download/${TAG}/"
echo "==> Releasing $SHORT_VERSION (build $BUILD) as $TAG from $APP — no bump, no rebuild"
echo "==> Installer identity: $INSTALLER_ID"

# ---- 1) Sparkle update zip (only the current build → single-item appcast) --
mkdir -p "$DIST_DIR"
# Keep only THIS build in the feed dir so generate_appcast emits exactly one item
# and no deltas (delta filenames contain spaces, which GitHub Releases would
# rename — and full ~9 MB downloads are fine for a menu-bar app).
rm -f "$DIST_DIR"/*.zip "$DIST_DIR"/*.delta "$DIST_DIR"/appcast.xml
ARCHIVE="$DIST_DIR/${STEM}.zip"
echo "==> Archiving Sparkle zip: $ARCHIVE"
/usr/bin/ditto -c -k --keepParent "$APP" "$ARCHIVE"

# ---- 2) signed installer .pkg (manual download) ----------------------------
# Stable name (no version) so releases/latest/download/MacPerformanceMonitor.pkg
# always resolves for the website button; the per-tag URL is in the appcast link.
# pkgbuild --component reads the app's identifier + version from Info.plist and
# --install-location drops it in /Applications. The payload is the already-stapled
# app, so the installed copy launches offline.
mkdir -p "$PKG_DIR"
PKG="$PKG_DIR/${ARCHIVE_BASENAME}.pkg"
echo "==> Building signed installer pkg: $PKG"
rm -f "$PKG"
pkgbuild \
  --component "$APP" \
  --install-location "/Applications" \
  --sign "$INSTALLER_ID" \
  "$PKG"

# ---- 3) notarize + staple the pkg ------------------------------------------
echo "==> Notarizing the pkg (profile: $NOTARY_PROFILE — can take a few minutes)"
SUBMIT="$(xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
echo "$SUBMIT"
if ! grep -q "status: Accepted" <<<"$SUBMIT"; then
  echo "error: pkg notarization did not return Accepted." >&2
  SUBID="$(awk '/^[[:space:]]*id:/{print $2; exit}' <<<"$SUBMIT")"
  if [[ -n "$SUBID" ]]; then
    echo "       Apple's per-file reasons:" >&2
    xcrun notarytool log "$SUBID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  fi
  exit 1
fi
echo "==> Stapling the pkg"
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"

# ---- 4) regenerate the EdDSA-signed appcast (single zip, no deltas) ---------
echo "==> Generating signed appcast"
"$SPARKLE_TOOLS/generate_appcast" \
  "${ED_KEY_ARGS[@]}" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --link "$PRODUCT_URL" \
  "$DIST_DIR"
echo "==> Appcast written: $DIST_DIR/appcast.xml"

# ---- 5) publish the GitHub Release -----------------------------------------
if [[ "$SKIP_UPLOAD" -eq 1 ]]; then
  echo "==> --skip-upload set; built locally but not published:"
  echo "    Sparkle zip: $ARCHIVE"
  echo "    Installer:   $PKG"
  echo "    Appcast:     $DIST_DIR/appcast.xml"
  exit 0
fi

echo "==> Creating GitHub Release $TAG on $REPO"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "    release $TAG already exists — clobbering its assets"
  gh release upload "$TAG" "$ARCHIVE" "$DIST_DIR/appcast.xml" "$PKG" --repo "$REPO" --clobber
else
  gh release create "$TAG" \
    "$ARCHIVE" "$DIST_DIR/appcast.xml" "$PKG" \
    --repo "$REPO" \
    --title "Mac Performance Monitor ${SHORT_VERSION} (build ${BUILD})" \
    --notes "Mac Performance Monitor ${SHORT_VERSION} (build ${BUILD}). See CHANGELOG.md for what's new." \
    --latest
fi

echo
echo "==> Released $SHORT_VERSION (build $BUILD) as $TAG."
echo "    Appcast:  https://github.com/${REPO}/releases/latest/download/appcast.xml"
echo "    Sparkle:  ${DOWNLOAD_PREFIX}$(basename "$ARCHIVE")"
echo "    Download: https://github.com/${REPO}/releases/latest/download/${ARCHIVE_BASENAME}.pkg"
echo "    Sparkle clients pick it up on next cold start / wake / 24h check."
