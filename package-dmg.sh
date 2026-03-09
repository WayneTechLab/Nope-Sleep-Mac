#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Nope-Sleep Mac"
VERSION="${VERSION:-1.1.0}"
DIST_DIR="$SCRIPT_DIR/dist"
STAGE_DIR="$DIST_DIR/dmg-root"
APP_SOURCE="$SCRIPT_DIR/build/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
PACKAGE_BUILD_ARCHS="${BUILD_ARCHS:-arm64 x86_64}"

if ! command -v hdiutil >/dev/null 2>&1; then
  echo "Error: hdiutil not found on this system."
  exit 1
fi

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  VERSION="$VERSION" BUILD_ARCHS="$PACKAGE_BUILD_ARCHS" "$SCRIPT_DIR/build.sh"
fi

if [ ! -d "$APP_SOURCE" ]; then
  echo "Error: expected app bundle at $APP_SOURCE"
  exit 1
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
mkdir -p "$DIST_DIR"

cp -R "$APP_SOURCE" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "Created drag-install DMG: $DMG_PATH"
echo "Open it, then drag $APP_NAME.app to Applications."
