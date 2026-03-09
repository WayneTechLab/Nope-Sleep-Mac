#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Nope-Sleep Mac"
VERSION="${VERSION:-1.1.0}"
DIST_DIR="$SCRIPT_DIR/dist"
STAGE_DIR="$DIST_DIR/terminal-root"
PACKAGE_DIR_NAME="$APP_NAME-$VERSION-terminal"
PACKAGE_DIR="$STAGE_DIR/$PACKAGE_DIR_NAME"
APP_SOURCE="$SCRIPT_DIR/build/$APP_NAME.app"
ARCHIVE_PATH="$DIST_DIR/$PACKAGE_DIR_NAME.tar.gz"
PACKAGE_BUILD_ARCHS="${BUILD_ARCHS:-arm64 x86_64}"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  VERSION="$VERSION" BUILD_ARCHS="$PACKAGE_BUILD_ARCHS" "$SCRIPT_DIR/build.sh"
fi

if [ ! -d "$APP_SOURCE" ]; then
  echo "Error: expected app bundle at $APP_SOURCE"
  exit 1
fi

rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"
mkdir -p "$DIST_DIR"

cp -R "$APP_SOURCE" "$PACKAGE_DIR/$APP_NAME.app"
cp "$SCRIPT_DIR/terminal-install.sh" "$PACKAGE_DIR/terminal-install.sh"
cp "$SCRIPT_DIR/uninstall.sh" "$PACKAGE_DIR/uninstall.sh"
cp "$SCRIPT_DIR/README.md" "$PACKAGE_DIR/README.md"

chmod +x "$PACKAGE_DIR/terminal-install.sh"
chmod +x "$PACKAGE_DIR/uninstall.sh"

rm -f "$ARCHIVE_PATH"
tar -C "$STAGE_DIR" -czf "$ARCHIVE_PATH" "$PACKAGE_DIR_NAME"

echo "Created terminal install archive: $ARCHIVE_PATH"
echo "Install on another Mac:"
echo "  tar -xzf \"$PACKAGE_DIR_NAME.tar.gz\""
echo "  \"$PACKAGE_DIR_NAME/terminal-install.sh\""
