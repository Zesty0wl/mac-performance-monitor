#!/usr/bin/env bash
# Launch the app in one of macOS's pseudolanguages to find untranslated strings
# and layouts that will break in a longer language.
#
# Xcode exposes these through its scheme editor, but they are ordinary
# NSUserDefaults argument-domain keys, so they work on a hand-built .app with no
# Xcode project. Anything still rendering plain English is a string that never
# reaches the strings table; anything clipped is a layout that will overflow in
# German, which runs roughly 30% longer than English.
#
# Usage:  Scripts/pseudolocalize.sh [surround|double|accented|rtl]
#
# surround   [# text #]        DEFAULT. The only format-safe option, and the
#                              best truncation detector.
# double     text text         Width stress. WARNING: strips % from the first
#                              copy, so "%lld items" renders "lld items".
# accented   Ténxt             Glyph and vertical-clipping check. WARNING:
#                              accents the characters inside %lld and %.1f,
#                              which destroys them.
# rtl                          Right-to-left preview.
#
# Formats matter here: this app is full of "%lld" and "%.1f", so prefer
# surround unless you are specifically testing width on a screen with no
# numbers in it.
set -euo pipefail

APP="build/Mac Performance Monitor.app"
MODE="${1:-surround}"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found. Run Scripts/run.sh first." >&2
  exit 1
fi

case "$MODE" in
  surround) ARGS=(-NSSurroundLocalizedStrings YES) ;;
  double)   ARGS=(-NSDoubleLocalizedStrings YES) ;;
  accented) ARGS=(-NSAccentuateLocalizedStrings YES) ;;
  rtl)      ARGS=(-NSForceRightToLeftLocalizedStrings YES -NSForceRightToLeftWritingDirection YES -AppleTextDirection YES) ;;
  *) echo "error: unknown mode '$MODE'. Use surround, double, accented or rtl." >&2; exit 1 ;;
esac

echo "==> Launching in pseudolanguage: $MODE"
echo "    Plain English text is a string that never reaches the table."
echo "    Clipped text is a layout that will break in a longer language."
pkill -f "$APP/Contents/MacOS" 2>/dev/null || true
sleep 1
open -n "$APP" --args "${ARGS[@]}"
