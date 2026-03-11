#!/bin/zsh
set -euo pipefail
setopt null_glob

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Nope-Sleep Mac"
EXECUTABLE_NAME="NopeSleepMac"
SUPPORT_FOLDER="NopeSleepMac"
DEFAULT_BUNDLE_ID="${BUNDLE_ID:-com.nopesleepmac.app}"
INSTALL_MARKER=".nsm-install-package"

typeset -a BUNDLE_IDS
typeset -a LAUNCH_LABELS
typeset -a APP_PATHS
typeset -a DEFERRED_REMOVE_PATHS

BUNDLE_IDS=(
  "$DEFAULT_BUNDLE_ID"
  "com.nope_sleep_mac.app"
  "com.nosleepm.app"
)

LAUNCH_LABELS=(
  "com.nope_sleep_mac.autostart"
  "com.nosleepm.autostart"
)

DEFERRED_REMOVE_PATHS=()

if [ -n "${SUDO_USER:-}" ]; then
  TARGET_USER="$SUDO_USER"
  TARGET_UID="$(id -u "$SUDO_USER")"
  TARGET_HOME="$(eval echo "~$SUDO_USER")"
else
  TARGET_USER="${USER:-$(id -un)}"
  TARGET_UID="$(id -u)"
  TARGET_HOME="$HOME"
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/tmp/NopeSleepMac-uninstall-$TIMESTAMP.log"
SUPPORT_DIR="$TARGET_HOME/Library/Application Support/$SUPPORT_FOLDER"
INSTALL_METADATA_PATH="$SUPPORT_DIR/install-metadata.env"
INSTALL_SOURCE_DIR=""
INSTALL_SOURCE_DISPOSABLE="0"
INSTALL_ARCHIVE_PATH=""
FAILURES=0

CURRENT_APP_BUNDLE=""
if [[ "$SCRIPT_DIR" == *.app/Contents/Resources ]]; then
  CURRENT_APP_BUNDLE="${SCRIPT_DIR%/Contents/Resources}"
fi

APP_PATHS=(
  "$CURRENT_APP_BUNDLE"
  "/Applications/$APP_NAME.app"
  "$TARGET_HOME/Applications/$APP_NAME.app"
  "/Applications/NoSleepM.app"
  "$TARGET_HOME/Applications/NoSleepM.app"
)

log() {
  local message="$1"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" | tee -a "$LOG_FILE"
}

record_failure() {
  FAILURES=$((FAILURES + 1))
  log "$1"
}

path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

remove_path() {
  local path="$1"
  local label="${2:-$1}"

  if [ -z "$path" ]; then
    return 0
  fi

  if ! path_exists "$path"; then
    log "Missing, skipped: $label ($path)"
    return 0
  fi

  if [ "$SCRIPT_DIR" = "$path" ] || [[ "$SCRIPT_DIR" == "$path/"* ]]; then
    DEFERRED_REMOVE_PATHS+=("$path")
    log "Deferred removal scheduled: $label ($path)"
    return 0
  fi

  if rm -rf "$path" >>"$LOG_FILE" 2>&1; then
    log "Removed: $label ($path)"
  else
    record_failure "Failed to remove: $label ($path)"
  fi
}

load_install_metadata() {
  if [ -f "$INSTALL_METADATA_PATH" ]; then
    set +u
    source "$INSTALL_METADATA_PATH"
    set -u
    log "Loaded install metadata: $INSTALL_METADATA_PATH"
  fi

  if [ -f "$SCRIPT_DIR/$INSTALL_MARKER" ]; then
    INSTALL_SOURCE_DIR="$SCRIPT_DIR"
    INSTALL_SOURCE_DISPOSABLE="1"

    if [ -z "$INSTALL_ARCHIVE_PATH" ]; then
      local archive_candidate
      archive_candidate="$(dirname "$SCRIPT_DIR")/$(basename "$SCRIPT_DIR").tar.gz"
      if [ -f "$archive_candidate" ]; then
        INSTALL_ARCHIVE_PATH="$archive_candidate"
      fi
    fi
  fi
}

stop_running_processes() {
  if pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
    log "Stopped running app process: $EXECUTABLE_NAME"
  else
    log "No running app process found."
  fi
}

remove_launch_items() {
  local launch_label
  local launch_agent_path

  for launch_label in "${LAUNCH_LABELS[@]}"; do
    launch_agent_path="$TARGET_HOME/Library/LaunchAgents/$launch_label.plist"
    if launchctl bootout "gui/$TARGET_UID/$launch_label" >>"$LOG_FILE" 2>&1; then
      log "Disabled launch agent: $launch_label"
    else
      log "Launch agent not active or bootout failed: $launch_label"
    fi
    remove_path "$launch_agent_path" "LaunchAgent plist"
  done
}

cancel_wake_schedule_if_needed() {
  local domain
  local has_app_schedule="0"

  for domain in "${BUNDLE_IDS[@]}"; do
    if /usr/bin/defaults read "$domain" wakeScheduleDate >/dev/null 2>&1; then
      has_app_schedule="1"
      break
    fi
  done

  if [ "$has_app_schedule" != "1" ]; then
    log "No app-managed wake schedule recorded in preferences."
    return 0
  fi

  if ! /usr/bin/pmset -g sched | grep -qi "wakeorpoweron"; then
    log "No system wake or power-on schedule is currently active."
    return 0
  fi

  if [ "$(id -u)" -eq 0 ]; then
    if /usr/bin/pmset schedule cancel wakeorpoweron >>"$LOG_FILE" 2>&1; then
      log "Canceled wake or power-on schedule."
    else
      record_failure "Failed to cancel wake or power-on schedule."
    fi
    return 0
  fi

  if command -v osascript >/dev/null 2>&1; then
    if /usr/bin/osascript -e 'do shell script "/usr/bin/pmset schedule cancel wakeorpoweron" with administrator privileges' >>"$LOG_FILE" 2>&1; then
      log "Canceled wake or power-on schedule with administrator privileges."
      return 0
    fi
  fi

  record_failure "Could not cancel wake or power-on schedule. Re-run this cleanup command with sudo to remove system power scheduling."
}

remove_preferences_and_state() {
  local domain
  local byhost_path

  for domain in "${BUNDLE_IDS[@]}"; do
    remove_path "$TARGET_HOME/Library/Preferences/$domain.plist" "Preferences plist"
    remove_path "$TARGET_HOME/Library/Saved Application State/$domain.savedState" "Saved application state"
    remove_path "$TARGET_HOME/Library/Caches/$domain" "Cache directory"
    remove_path "$TARGET_HOME/Library/HTTPStorages/$domain" "HTTP storage"

    for byhost_path in "$TARGET_HOME/Library/Preferences/ByHost/$domain".*; do
      remove_path "$byhost_path" "ByHost preference"
    done
  done
}

remove_support_and_logs() {
  local report_path

  remove_path "$SUPPORT_DIR" "Application Support"
  remove_path "$TARGET_HOME/Library/Logs/NopeSleepMac.launchd.out.log" "Launch log"
  remove_path "$TARGET_HOME/Library/Logs/NopeSleepMac.launchd.err.log" "Launch error log"

  for report_path in "$TARGET_HOME/Library/Logs/DiagnosticReports/$EXECUTABLE_NAME"*; do
    remove_path "$report_path" "Crash or diagnostic report"
  done
}

remove_app_bundles() {
  local app_path

  for app_path in "${APP_PATHS[@]}"; do
    remove_path "$app_path" "App bundle"
  done
}

cleanup_installer_files() {
  if [ "${REMOVE_INSTALLER_FILES:-1}" != "1" ]; then
    log "Installer file cleanup disabled by REMOVE_INSTALLER_FILES=0."
    return 0
  fi

  if [ "$INSTALL_SOURCE_DISPOSABLE" != "1" ]; then
    log "No disposable installer files were recorded."
    return 0
  fi

  remove_path "$INSTALL_ARCHIVE_PATH" "Installer archive"
  remove_path "$INSTALL_SOURCE_DIR" "Installer working directory"
}

schedule_deferred_cleanup() {
  local cleanup_script
  local deferred_path

  if [ "${#DEFERRED_REMOVE_PATHS[@]}" -eq 0 ]; then
    return 0
  fi

  cleanup_script="/tmp/NopeSleepMac-post-uninstall-$TIMESTAMP.sh"

  {
    echo "#!/bin/zsh"
    echo "sleep 2"
    for deferred_path in "${DEFERRED_REMOVE_PATHS[@]}"; do
      printf 'rm -rf -- %q >/dev/null 2>&1\n' "$deferred_path"
    done
    printf 'rm -f -- %q >/dev/null 2>&1\n' "$cleanup_script"
  } >"$cleanup_script"

  chmod +x "$cleanup_script"
  /bin/zsh "$cleanup_script" >/dev/null 2>&1 &!
  log "Deferred cleanup scheduled for ${#DEFERRED_REMOVE_PATHS[@]} path(s)."
}

log "Starting full cleanup for $APP_NAME"
log "Target user: $TARGET_USER"
log "Cleanup log: $LOG_FILE"

load_install_metadata
stop_running_processes
remove_launch_items
cancel_wake_schedule_if_needed
remove_preferences_and_state
remove_support_and_logs
remove_app_bundles
cleanup_installer_files
schedule_deferred_cleanup

if [ "$FAILURES" -eq 0 ]; then
  log "Cleanup completed successfully."
  exit 0
fi

log "Cleanup completed with $FAILURES issue(s). Review $LOG_FILE for details."
exit 1
