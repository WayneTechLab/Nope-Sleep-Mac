#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER_PATH="$SCRIPT_DIR/resources/uninstall-helper.sh"

if [ ! -f "$HELPER_PATH" ]; then
  echo "Error: uninstall helper not found at $HELPER_PATH"
  exit 1
fi

exec /bin/zsh "$HELPER_PATH" "$@"
