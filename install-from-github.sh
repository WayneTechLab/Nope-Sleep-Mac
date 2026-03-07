#!/bin/zsh
set -euo pipefail

REPO_SLUG="${1:-${GITHUB_REPO:-}}"
RELEASE_REF="${2:-${GITHUB_TAG:-latest}}"
APP_DEST_DIR="${APP_DEST_DIR:-/Applications}"
LAUNCH_AFTER_INSTALL="${LAUNCH_AFTER_INSTALL:-1}"
GITHUB_API_BASE="${GITHUB_API_BASE:-https://api.github.com}"

if [ -z "$REPO_SLUG" ]; then
  echo "Usage: $0 owner/repo [tag|latest]"
  echo "Example:"
  echo "  curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install-from-github.sh | zsh -s -- OWNER/REPO"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required."
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required."
  exit 1
fi

typeset -a API_HEADERS
API_HEADERS=(-H "Accept: application/vnd.github+json")
if [ -n "${GITHUB_TOKEN:-}" ]; then
  API_HEADERS+=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

if [ "$RELEASE_REF" = "latest" ]; then
  RELEASE_API_URL="$GITHUB_API_BASE/repos/$REPO_SLUG/releases/latest"
else
  RELEASE_API_URL="$GITHUB_API_BASE/repos/$REPO_SLUG/releases/tags/$RELEASE_REF"
fi

RELEASE_JSON="$(curl -fsSL "${API_HEADERS[@]}" "$RELEASE_API_URL")"

ASSET_INFO="$(
  RELEASE_JSON="$RELEASE_JSON" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["RELEASE_JSON"])
assets = data.get("assets") or []

for asset in assets:
    name = asset.get("name", "")
    if name.endswith("-terminal.tar.gz"):
        print(data.get("tag_name", "unknown"))
        print(name)
        print(asset.get("url", ""))
        sys.exit(0)

sys.exit(1)
PY
)" || {
  echo "Error: no '*-terminal.tar.gz' asset found in release '$RELEASE_REF' for $REPO_SLUG."
  exit 1
}

RELEASE_TAG="$(printf '%s\n' "$ASSET_INFO" | sed -n '1p')"
ARCHIVE_NAME="$(printf '%s\n' "$ASSET_INFO" | sed -n '2p')"
ASSET_API_URL="$(printf '%s\n' "$ASSET_INFO" | sed -n '3p')"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

ARCHIVE_PATH="$TEMP_DIR/$ARCHIVE_NAME"
typeset -a ASSET_HEADERS
ASSET_HEADERS=(-H "Accept: application/octet-stream")
if [ -n "${GITHUB_TOKEN:-}" ]; then
  ASSET_HEADERS+=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

curl -fsSL "${ASSET_HEADERS[@]}" "$ASSET_API_URL" -o "$ARCHIVE_PATH"
tar -xzf "$ARCHIVE_PATH" -C "$TEMP_DIR"

INSTALLER_PATH="$(find "$TEMP_DIR" -maxdepth 2 -type f -name 'terminal-install.sh' | head -n 1)"
if [ -z "$INSTALLER_PATH" ]; then
  echo "Error: downloaded archive did not contain terminal-install.sh"
  exit 1
fi

chmod +x "$INSTALLER_PATH"

echo "Installing $REPO_SLUG release $RELEASE_TAG..."
APP_DEST_DIR="$APP_DEST_DIR" LAUNCH_AFTER_INSTALL="$LAUNCH_AFTER_INSTALL" "$INSTALLER_PATH"
