#!/bin/zsh
set -euo pipefail

APP_NAME="Nope-Sleep Mac"
APP_DEST_DIR="${APP_DEST_DIR:-/Applications}"
APP_DEST="$APP_DEST_DIR/$APP_NAME.app"
LAUNCH_LABELS=("com.nope_sleep_mac.autostart" "com.nosleepm.autostart")

if [ -n "${SUDO_USER:-}" ]; then
  TARGET_USER="$SUDO_USER"
  TARGET_UID="$(id -u "$SUDO_USER")"
  TARGET_HOME="$(eval echo "~$SUDO_USER")"
else
  TARGET_UID="$(id -u)"
  TARGET_HOME="$HOME"
fi

USER_APP_DEST="$TARGET_HOME/Applications/$APP_NAME.app"

for LAUNCH_LABEL in "${LAUNCH_LABELS[@]}"; do
  LAUNCH_AGENT_PATH="$TARGET_HOME/Library/LaunchAgents/$LAUNCH_LABEL.plist"
  launchctl bootout "gui/$TARGET_UID/$LAUNCH_LABEL" >/dev/null 2>&1 || true
  rm -f "$LAUNCH_AGENT_PATH"
done

rm -rf "$APP_DEST"
rm -rf "$USER_APP_DEST"
rm -rf "$APP_DEST_DIR/NoSleepM.app"
rm -rf "$TARGET_HOME/Applications/NoSleepM.app"

echo "Uninstalled app and auto-start agent."
echo "Kept event logs at: $TARGET_HOME/Library/Application Support/NopeSleepMac/events.log"
