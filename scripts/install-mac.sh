#!/usr/bin/env bash
set -euo pipefail

# Builds Bounce (Mac, Release) and installs to /Applications/Bounce.app.
#
# - Preserves pairing/sync state by default. Pass --reset or --reset-pairing
#   to wipe keychain pairing state and transport device IDs.
#
# - Signs with the developer's Apple Development identity (auto-detected
#   team) instead of ad-hoc. Ad-hoc binaries get a new code identity
#   on every rebuild, which makes macOS prompt for the keychain password
#   on every launch (once per protected item — i.e. the "asks twice" bug).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="Release"

step() { echo ""; echo "▸ $*"; }
warn() { echo "⚠  $*" >&2; }
reset_requested() {
  [[ " $* " == *" --reset "* ]] ||
    [[ " $* " == *" --reset-pairing "* ]] ||
    [[ "${npm_config_reset:-false}" == "true" ]] ||
    [[ "${npm_config_reset_pairing:-false}" == "true" ]] ||
    [[ "${BOUNCE_RESET_PAIRING:-0}" == "1" ]]
}

detect_team_id() {
  if [[ -n "${BOUNCE_DEVELOPMENT_TEAM:-}" ]]; then
    echo "$BOUNCE_DEVELOPMENT_TEAM"
    return
  fi
  local sender_yml="$ROOT_DIR/apps/BounceSender/project.yml"
  if [[ -f "$sender_yml" ]]; then
    awk '/DEVELOPMENT_TEAM:/ {print $2; exit}' "$sender_yml"
  fi
}

"$ROOT_DIR/scripts/generate-projects.sh"

TEAM_ID="$(detect_team_id || true)"
if [[ -z "$TEAM_ID" ]]; then
  warn "No Apple development team detected. Set BOUNCE_DEVELOPMENT_TEAM."
  exit 1
fi

PROJECT_DIR="$ROOT_DIR/apps/BounceSender"
PROJECT="$PROJECT_DIR/BounceSender.xcodeproj"
SCHEME="BounceSender"
BUILD_DIR="$PROJECT_DIR/build/macos-release"
APP_PATH="$BUILD_DIR/Build/Products/$CONFIG/Bounce.app"

step "Stopping any running Bounce instance..."
pkill -x Bounce 2>/dev/null || true
sleep 0.3

if reset_requested "$@"; then
  step "Resetting pairing/sync state..."
  "$ROOT_DIR/scripts/reset-mac-pairing-state.sh"
fi
# Old /Applications copy → drop so the new identity's keychain ACL is clean.
rm -rf /Applications/Bounce.app

step "Building Bounce (Mac, $CONFIG, team $TEAM_ID)..."
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic

step "Installing Bounce.app to /Applications..."
cp -R "$APP_PATH" /Applications/Bounce.app

echo ""
echo "✓ Installed: /Applications/Bounce.app"
