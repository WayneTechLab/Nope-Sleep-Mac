#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Nope-Sleep Mac"
EXECUTABLE_NAME="NopeSleepMac"
BUNDLE_ID="${BUNDLE_ID:-com.nopesleepmac.app}"
VERSION="${VERSION:-1.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-13.0}"
HOST_ARCH="$(uname -m)"
BUILD_ARCHS_RAW="${BUILD_ARCHS:-$HOST_ARCH}"
BUILD_DIR="$SCRIPT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
EXECUTABLE_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
SOURCE_FILE="$SCRIPT_DIR/src/NoSleepM.swift"
RESOURCE_SOURCE_DIR="$SCRIPT_DIR/resources"
TEMP_BUILD_DIR="$BUILD_DIR/.build-tmp"

typeset -a BUILD_ARCHS
BUILD_ARCHS=(${=BUILD_ARCHS_RAW})

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Error: swiftc is required. Install Xcode command line tools first."
  exit 1
fi

if [ ! -f "$SOURCE_FILE" ]; then
  echo "Error: source file not found at $SOURCE_FILE"
  exit 1
fi

SDK_PATH=""
if command -v xcrun >/dev/null 2>&1; then
  SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
fi

rm -rf "$APP_DIR"
rm -rf "$TEMP_BUILD_DIR"
mkdir -p "$EXECUTABLE_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$TEMP_BUILD_DIR"

typeset -a SWIFTC_COMMON_ARGS
SWIFTC_COMMON_ARGS=(
  -O
  -framework AppKit
  -framework IOKit
  -framework ServiceManagement
)

if [ -n "$SDK_PATH" ]; then
  SWIFTC_COMMON_ARGS+=(-sdk "$SDK_PATH")
fi

compile_arch_binary() {
  local arch="$1"
  local output_path="$2"
  swiftc \
    "${SWIFTC_COMMON_ARGS[@]}" \
    -target "${arch}-apple-macos${MIN_MACOS_VERSION}" \
    "$SOURCE_FILE" \
    -o "$output_path"
}

if [ "${#BUILD_ARCHS[@]}" -eq 1 ]; then
  compile_arch_binary "${BUILD_ARCHS[1]}" "$EXECUTABLE_DIR/$EXECUTABLE_NAME"
else
  if ! command -v lipo >/dev/null 2>&1; then
    echo "Error: lipo is required for a universal build."
    exit 1
  fi

  typeset -a ARCH_BINARIES
  ARCH_BINARIES=()

  for arch in "${BUILD_ARCHS[@]}"; do
    arch_output="$TEMP_BUILD_DIR/$EXECUTABLE_NAME-$arch"
    compile_arch_binary "$arch" "$arch_output"
    ARCH_BINARIES+=("$arch_output")
  done

  lipo -create "${ARCH_BINARIES[@]}" -output "$EXECUTABLE_DIR/$EXECUTABLE_NAME"
fi

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
  <string>$MIN_MACOS_VERSION</string>
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

if [ -f "$RESOURCES_DIR/uninstall-helper.sh" ]; then
  chmod +x "$RESOURCES_DIR/uninstall-helper.sh"
fi

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

rm -rf "$TEMP_BUILD_DIR"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null
fi

if command -v lipo >/dev/null 2>&1; then
  ARCH_LABEL="$(lipo -archs "$EXECUTABLE_DIR/$EXECUTABLE_NAME" 2>/dev/null || echo "${BUILD_ARCHS[*]}")"
else
  ARCH_LABEL="${BUILD_ARCHS[*]}"
fi

echo "Built app: $APP_DIR"
echo "Architectures: $ARCH_LABEL"
