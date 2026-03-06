#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Nope-Sleep Mac"
APP_SOURCE="$SCRIPT_DIR/build/$APP_NAME.app"
APP_DEST_DIR="${APP_DEST_DIR:-/Applications}"
APP_DEST="$APP_DEST_DIR/$APP_NAME.app"

"$SCRIPT_DIR/build.sh"

if [ ! -d "$APP_SOURCE" ]; then
  echo "Build output missing: $APP_SOURCE"
  exit 1
fi

rm -rf "$APP_DEST" 2>/dev/null || true

if ! cp -R "$APP_SOURCE" "$APP_DEST"; then
  echo "Failed to copy to $APP_DEST_DIR. Try running: sudo $SCRIPT_DIR/install.sh"
  exit 1
fi

open "$APP_DEST" >/dev/null 2>&1 || true

echo "Installed: $APP_DEST"
echo "Event log file: $HOME/Library/Application Support/NopeSleepMac/events.log"
echo "Use the menu option 'Launch at Boot' to enable or disable startup."
