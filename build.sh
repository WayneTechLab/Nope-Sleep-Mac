#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Nope-Sleep Mac"
EXECUTABLE_NAME="NopeSleepMac"
BUNDLE_ID="${BUNDLE_ID:-com.nopesleepmac.app}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUILD_DIR="$SCRIPT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
EXECUTABLE_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
SOURCE_FILE="$SCRIPT_DIR/src/NoSleepM.swift"
RESOURCE_SOURCE_DIR="$SCRIPT_DIR/resources"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Error: swiftc is required. Install Xcode command line tools first."
  exit 1
fi

if [ ! -f "$SOURCE_FILE" ]; then
  echo "Error: source file not found at $SOURCE_FILE"
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$EXECUTABLE_DIR"
mkdir -p "$RESOURCES_DIR"

swiftc \
  -O \
  -framework AppKit \
  -framework IOKit \
  -framework ServiceManagement \
  "$SOURCE_FILE" \
  -o "$EXECUTABLE_DIR/$EXECUTABLE_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Nope-Sleep Mac uses automation to run scheduled shutdown actions.</string>
</dict>
</plist>
PLIST

chmod +x "$EXECUTABLE_DIR/$EXECUTABLE_NAME"

if [ -d "$RESOURCE_SOURCE_DIR" ]; then
  cp -R "$RESOURCE_SOURCE_DIR"/. "$RESOURCES_DIR"/
fi

if [ -f "$RESOURCES_DIR/service-worker.sh" ]; then
  chmod +x "$RESOURCES_DIR/service-worker.sh"
fi

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null
fi

echo "Built app: $APP_DIR"
