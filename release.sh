#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Nope-Sleep Mac"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SIGN_DMG="${SIGN_DMG:-1}"
RELEASE_BUILD_ARCHS="${BUILD_ARCHS:-arm64 x86_64}"
UPLOAD_TO_GITHUB="${UPLOAD_TO_GITHUB:-0}"
GITHUB_REPO_INPUT="${GITHUB_REPO:-}"
GITHUB_TAG="${GITHUB_TAG:-v$VERSION}"

APP_PATH="$SCRIPT_DIR/build/$APP_NAME.app"
DMG_PATH="$SCRIPT_DIR/dist/$APP_NAME-$VERSION.dmg"
TERMINAL_ARCHIVE_PATH="$SCRIPT_DIR/dist/$APP_NAME-$VERSION-terminal.tar.gz"

normalize_github_repo() {
  local input="$1"

  if [ -z "$input" ]; then
    return 1
  fi

  if [[ "$input" == git@github.com:* ]]; then
    input="${input#git@github.com:}"
  elif [[ "$input" == ssh://git@github.com/* ]]; then
    input="${input#ssh://git@github.com/}"
  elif [[ "$input" == https://github.com/* ]]; then
    input="${input#https://github.com/}"
  elif [[ "$input" == http://github.com/* ]]; then
    input="${input#http://github.com/}"
  fi

  input="${input%.git}"
  input="${input#/}"
  input="${input%/}"

  if [[ "$input" == */* ]]; then
    printf '%s\n' "$input"
    return 0
  fi

  return 1
}

resolve_github_repo() {
  local remote_name
  local remote_url

  if normalize_github_repo "$GITHUB_REPO_INPUT" >/dev/null 2>&1; then
    normalize_github_repo "$GITHUB_REPO_INPUT"
    return 0
  fi

  if command -v git >/dev/null 2>&1; then
    remote_url="$(git remote get-url origin 2>/dev/null || true)"
    if normalize_github_repo "$remote_url" >/dev/null 2>&1; then
      normalize_github_repo "$remote_url"
      return 0
    fi

    remote_name="$(git remote 2>/dev/null | head -n 1 || true)"
    if [ -n "$remote_name" ]; then
      remote_url="$(git remote get-url "$remote_name" 2>/dev/null || true)"
      if normalize_github_repo "$remote_url" >/dev/null 2>&1; then
        normalize_github_repo "$remote_url"
        return 0
      fi
    fi
  fi

  return 1
}

if [ -z "$SIGN_IDENTITY" ]; then
  echo "Error: SIGN_IDENTITY is required (Developer ID Application certificate name)."
  echo "Example: SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./release.sh"
  exit 1
fi

VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" BUILD_ARCHS="$RELEASE_BUILD_ARCHS" SIGN_IDENTITY="$SIGN_IDENTITY" "$SCRIPT_DIR/build.sh"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dv --verbose=4 "$APP_PATH" 2>&1 | sed -n '1,30p'

VERSION="$VERSION" BUILD_ARCHS="$RELEASE_BUILD_ARCHS" SKIP_BUILD=1 "$SCRIPT_DIR/package-dmg.sh"
VERSION="$VERSION" BUILD_ARCHS="$RELEASE_BUILD_ARCHS" SKIP_BUILD=1 "$SCRIPT_DIR/package-terminal.sh"

if [ "$SIGN_DMG" = "1" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi

if [ -n "$NOTARY_PROFILE" ]; then
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "Error: xcrun not found; cannot notarize."
    exit 1
  fi

  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_PATH"
  xcrun stapler staple "$DMG_PATH"
fi

if [ "$UPLOAD_TO_GITHUB" = "1" ] || [ -n "$GITHUB_REPO_INPUT" ]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI is required for GitHub release upload."
    exit 1
  fi

  GITHUB_REPO_RESOLVED="$(resolve_github_repo || true)"
  if [ -z "$GITHUB_REPO_RESOLVED" ]; then
    echo "Error: could not resolve GitHub repo. Set GITHUB_REPO=owner/repo."
    exit 1
  fi

  if gh release view "$GITHUB_TAG" --repo "$GITHUB_REPO_RESOLVED" >/dev/null 2>&1; then
    gh release upload "$GITHUB_TAG" "$DMG_PATH" "$TERMINAL_ARCHIVE_PATH" --clobber --repo "$GITHUB_REPO_RESOLVED"
  else
    gh release create "$GITHUB_TAG" "$DMG_PATH" "$TERMINAL_ARCHIVE_PATH" --repo "$GITHUB_REPO_RESOLVED" --title "$APP_NAME $VERSION" --notes "$APP_NAME $VERSION"
  fi

  echo "GitHub release updated: https://github.com/$GITHUB_REPO_RESOLVED/releases/tag/$GITHUB_TAG"
  echo "GitHub terminal install command:"
  echo "  curl -fsSL https://raw.githubusercontent.com/$GITHUB_REPO_RESOLVED/main/install-from-github.sh | zsh -s -- $GITHUB_REPO_RESOLVED $GITHUB_TAG"
fi

echo "Release artifact ready: $DMG_PATH"
echo "Terminal artifact ready: $TERMINAL_ARCHIVE_PATH"
if [ -n "$NOTARY_PROFILE" ]; then
  echo "Notarization completed and ticket stapled."
else
  echo "Notarization skipped (set NOTARY_PROFILE to enable)."
fi
