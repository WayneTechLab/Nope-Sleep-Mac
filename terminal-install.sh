#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Nope-Sleep Mac"
APP_BUNDLE="$APP_NAME.app"
EXECUTABLE_NAME="NopeSleepMac"
APP_DEST_DIR="${APP_DEST_DIR:-/Applications}"
LAUNCH_AFTER_INSTALL="${LAUNCH_AFTER_INSTALL:-1}"

typeset -a SOURCE_CANDIDATES
SOURCE_CANDIDATES=(
  "$SCRIPT_DIR/$APP_BUNDLE"
  "$SCRIPT_DIR/build/$APP_BUNDLE"
)

resolve_app_source() {
  local candidate
  for candidate in "${SOURCE_CANDIDATES[@]}"; do
    if [ -d "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

if ! APP_SOURCE="$(resolve_app_source)"; then
  echo "Error: could not find $APP_BUNDLE to install."
  echo "Expected one of:"
  for candidate in "${SOURCE_CANDIDATES[@]}"; do
    echo "  $candidate"
  done
  echo "Run ./build.sh first, or use a packaged terminal archive that includes the app bundle."
  exit 1
fi

if [ "$APP_DEST_DIR" = "/Applications" ] && [ ! -w "$APP_DEST_DIR" ] && [ "$(id -u)" -ne 0 ]; then
  APP_DEST_DIR="$HOME/Applications"
fi

mkdir -p "$APP_DEST_DIR"
APP_DEST="$APP_DEST_DIR/$APP_BUNDLE"

pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
rm -rf "$APP_DEST" 2>/dev/null || true
ditto "$APP_SOURCE" "$APP_DEST"
xattr -dr com.apple.quarantine "$APP_DEST" >/dev/null 2>&1 || true

if [ "$LAUNCH_AFTER_INSTALL" = "1" ]; then
  open "$APP_DEST" >/dev/null 2>&1 || true
fi

ARCH_LABEL="unknown"
if command -v lipo >/dev/null 2>&1; then
  ARCH_LABEL="$(lipo -archs "$APP_DEST/Contents/MacOS/$EXECUTABLE_NAME" 2>/dev/null || echo "unknown")"
fi

echo "Installed: $APP_DEST"
echo "Architectures: $ARCH_LABEL"
echo "Event log file: $HOME/Library/Application Support/NopeSleepMac/events.log"
echo "Use the menu option 'Launch at Boot' to enable or disable startup."
