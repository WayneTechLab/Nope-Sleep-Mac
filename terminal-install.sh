#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Nope-Sleep Mac"
APP_BUNDLE="$APP_NAME.app"
EXECUTABLE_NAME="NopeSleepMac"
APP_DEST_DIR="${APP_DEST_DIR:-/Applications}"
LAUNCH_AFTER_INSTALL="${LAUNCH_AFTER_INSTALL:-1}"
INSTALL_MARKER_FILE=".nsm-install-package"
WARNING_TITLE="Important Safety, Warranty, and Liability Notice"
WARNING_MESSAGE=$'Nope-Sleep Mac can keep a Mac awake for extended or indefinite periods. This can increase heat, battery wear, display wear, and general component stress.\n\nThe software is provided as-is, without warranties or guarantees of performance, fitness, compatibility, or uninterrupted operation. Use is at your own risk.\n\nDo not rely on it for unattended, shared, public-facing, regulated, or safety-critical systems unless you have independently determined that use is appropriate. Damage caused by misuse or prolonged operation may affect warranty, support, or AppleCare coverage.'

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

resolve_target_home() {
  if [ -n "${SUDO_USER:-}" ]; then
    eval echo "~$SUDO_USER"
  else
    printf '%s\n' "$HOME"
  fi
}

write_install_metadata() {
  local target_home="$1"
  local metadata_dir="$target_home/Library/Application Support/NopeSleepMac"
  local metadata_path="$metadata_dir/install-metadata.env"
  local install_source_disposable="0"
  local install_archive_path=""
  local archive_candidate

  if [ -f "$SCRIPT_DIR/$INSTALL_MARKER_FILE" ]; then
    install_source_disposable="1"
  fi

  archive_candidate="$(dirname "$SCRIPT_DIR")/$(basename "$SCRIPT_DIR").tar.gz"
  if [ -f "$archive_candidate" ]; then
    install_archive_path="$archive_candidate"
  fi

  mkdir -p "$metadata_dir"

  {
    printf 'INSTALL_SOURCE_DIR=%q\n' "$SCRIPT_DIR"
    printf 'INSTALL_SOURCE_DISPOSABLE=%q\n' "$install_source_disposable"
    printf 'INSTALL_ARCHIVE_PATH=%q\n' "$install_archive_path"
    printf 'APP_DEST=%q\n' "$APP_DEST"
  } >"$metadata_path"
}

show_install_warning() {
  local osa_result=""

  if [ "${NSM_SKIP_INSTALL_WARNING:-0}" = "1" ]; then
    return 0
  fi

  if command -v osascript >/dev/null 2>&1; then
    osa_result="$(
      /usr/bin/osascript - "$WARNING_TITLE" "$WARNING_MESSAGE" 2>/dev/null <<'APPLESCRIPT'
on run argv
  set warningTitle to item 1 of argv
  set warningMessage to item 2 of argv
  try
    display alert warningTitle message warningMessage as warning buttons {"Cancel", "Accept Risk"} default button "Accept Risk" cancel button "Cancel"
    return "accept"
  on error number -128
    return "cancel"
  end try
end run
APPLESCRIPT
    )"

    if [ "$osa_result" = "accept" ]; then
      return 0
    fi

    if [ "$osa_result" = "cancel" ]; then
      echo "Installation canceled."
      exit 1
    fi
  fi

  echo
  echo "WARNING: $APP_NAME can keep a Mac awake for extended or indefinite periods."
  echo "WARNING: This can increase heat, battery wear, display wear, and hardware stress."
  echo "WARNING: The software is provided as-is, without warranties or guarantees."
  echo "WARNING: Use is at your own risk."
  echo "WARNING: Avoid unattended, shared, public-facing, regulated, or safety-critical use"
  echo "unless you have independently determined it is appropriate."
  echo "WARNING: Damage caused by misuse or prolonged operation may affect warranty,"
  echo "support, or AppleCare coverage."
  echo

  if [ ! -t 0 ]; then
    echo "Installation canceled because the warning could not be acknowledged interactively."
    exit 1
  fi

  printf "Type AGREE to accept the risk and continue installation: "
  read -r reply

  if [ "$reply" = "AGREE" ]; then
    return 0
  fi

  echo "Installation canceled."
  exit 1
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

show_install_warning

if [ "$APP_DEST_DIR" = "/Applications" ] && [ ! -w "$APP_DEST_DIR" ] && [ "$(id -u)" -ne 0 ]; then
  APP_DEST_DIR="$HOME/Applications"
fi

mkdir -p "$APP_DEST_DIR"
APP_DEST="$APP_DEST_DIR/$APP_BUNDLE"

pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
rm -rf "$APP_DEST" 2>/dev/null || true
ditto "$APP_SOURCE" "$APP_DEST"
xattr -dr com.apple.quarantine "$APP_DEST" >/dev/null 2>&1 || true

TARGET_HOME="$(resolve_target_home)"
write_install_metadata "$TARGET_HOME"

if [ "$LAUNCH_AFTER_INSTALL" = "1" ]; then
  open "$APP_DEST" >/dev/null 2>&1 || true
fi

ARCH_LABEL="unknown"
if command -v lipo >/dev/null 2>&1; then
  ARCH_LABEL="$(lipo -archs "$APP_DEST/Contents/MacOS/$EXECUTABLE_NAME" 2>/dev/null || echo "unknown")"
fi

echo "Installed: $APP_DEST"
echo "Architectures: $ARCH_LABEL"
echo "Event log file: $TARGET_HOME/Library/Application Support/NopeSleepMac/events.log"
echo "Use the menu option 'Launch at Boot' to enable or disable startup."
if [ "$APP_DEST_DIR" = "/Applications" ]; then
  echo "Full cleanup command:"
  echo "  sudo zsh \"$APP_DEST/Contents/Resources/uninstall-helper.sh\""
else
  echo "Full cleanup command:"
  echo "  zsh \"$APP_DEST/Contents/Resources/uninstall-helper.sh\""
fi
