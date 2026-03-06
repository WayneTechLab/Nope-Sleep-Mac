#!/bin/zsh
set -eu

LOG_PATH="${1:-}"
if [ -z "$LOG_PATH" ]; then
  exit 1
fi

PARENT_PID="${2:-}"
if [ -z "$PARENT_PID" ] || ! [[ "$PARENT_PID" == <-> ]]; then
  exit 1
fi

LOG_DIR="$(dirname "$LOG_PATH")"
mkdir -p "$LOG_DIR"

MAX_LOG_BYTES=$((1024 * 1024))
KEEP_LOG_BYTES=$((MAX_LOG_BYTES / 2))

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

rotate_log_if_needed() {
  if [ ! -f "$LOG_PATH" ]; then
    return
  fi

  local current_size
  current_size="$(wc -c < "$LOG_PATH" | tr -d ' ')"

  if [ -n "$current_size" ] && [ "$current_size" -gt "$MAX_LOG_BYTES" ]; then
    local temp_path="${LOG_PATH}.tmp"
    tail -c "$KEEP_LOG_BYTES" "$LOG_PATH" > "$temp_path" 2>/dev/null || : > "$temp_path"
    mv "$temp_path" "$LOG_PATH"
  fi
}

log() {
  rotate_log_if_needed
  printf '[%s] %s\n' "$(timestamp)" "$1" >> "$LOG_PATH"
}

parent_alive() {
  kill -0 "$PARENT_PID" >/dev/null 2>&1
}

cleanup() {
  log "Nope-Sleep Mac background service stopped (pid $$)."
  exit 0
}

trap cleanup TERM INT

log "Nope-Sleep Mac background service started (pid $$)."

while true; do
  if ! parent_alive; then
    log "Nope-Sleep Mac background service stopping because parent process $PARENT_PID is gone."
    exit 0
  fi

  log "Nope-Sleep Mac background service heartbeat."
  sleep 60
done
