#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Nope-Sleep Mac"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SIGN_DMG="${SIGN_DMG:-1}"

APP_PATH="$SCRIPT_DIR/build/$APP_NAME.app"
DMG_PATH="$SCRIPT_DIR/dist/$APP_NAME-$VERSION.dmg"

if [ -z "$SIGN_IDENTITY" ]; then
  echo "Error: SIGN_IDENTITY is required (Developer ID Application certificate name)."
  echo "Example: SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./release.sh"
  exit 1
fi

VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" SIGN_IDENTITY="$SIGN_IDENTITY" "$SCRIPT_DIR/build.sh"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dv --verbose=4 "$APP_PATH" 2>&1 | sed -n '1,30p'

VERSION="$VERSION" SKIP_BUILD=1 "$SCRIPT_DIR/package-dmg.sh"

if [ "$SIGN_DMG" = "1" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi

if [ -n "$NOTARY_PROFILE" ]; then
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "Error: xcrun not found; cannot notarize."
    exit 1
  fi

  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_PATH"
  xcrun stapler staple "$DMG_PATH"
fi

echo "Release artifact ready: $DMG_PATH"
if [ -n "$NOTARY_PROFILE" ]; then
  echo "Notarization completed and ticket stapled."
else
  echo "Notarization skipped (set NOTARY_PROFILE to enable)."
fi
