#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/apps/BounceSender"
PROJECT="$PROJECT_DIR/BounceSender.xcodeproj"
SCHEME="BounceSender"
CONFIG="Debug"
BUNDLE_ID="${BOUNCE_MAC_BUNDLE_ID:-com.merlinkraemer.bounce.sender.dev}"
PRODUCT_NAME="${BOUNCE_MAC_PRODUCT_NAME:-Bounce Dev}"
BUILD_DIR="$PROJECT_DIR/build/macos-dev"
APP_PATH="$BUILD_DIR/Build/Products/$CONFIG/$PRODUCT_NAME.app"
INSTALL_PATH="/Applications/$PRODUCT_NAME.app"
EXECUTABLE="$APP_PATH/Contents/MacOS/$PRODUCT_NAME"

reset_requested() {
  [[ " $* " == *" --reset "* ]] ||
    [[ " $* " == *" --reset-pairing "* ]] ||
    [[ "${npm_config_reset:-false}" == "true" ]] ||
    [[ "${npm_config_reset_pairing:-false}" == "true" ]] ||
    [[ "${BOUNCE_RESET_PAIRING:-0}" == "1" ]]
}

"$ROOT_DIR/scripts/generate-projects.sh"

# Pass --reset (or --reset-pairing) to wipe Mac-side bonds + sender deviceID before launch.
# Off by default so consecutive `npm run mac` restarts keep the existing bond
# stable; otherwise every restart mints a new sender deviceID which iOS
# (whose keychain bonds survive uninstall) can't auto-reconnect to, and the
# first pair attempt races a stale Bonjour cache.
if reset_requested "$@"; then
  pkill -x "$PRODUCT_NAME" 2>/dev/null || true
  sleep 0.2
  BOUNCE_KEYCHAIN_SERVICE="com.bounce.dev.pairingKey" \
    BOUNCE_APP_BUNDLE_ID="$BUNDLE_ID" \
    "$ROOT_DIR/scripts/reset-mac-pairing-state.sh"
fi

echo ""
echo "▸ Building $PRODUCT_NAME (Mac dev)..."
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  PRODUCT_NAME="$PRODUCT_NAME" \
  INFOPLIST_KEY_CFBundleDisplayName="$PRODUCT_NAME" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

echo ""
echo "▸ Installing to $INSTALL_PATH..."
pkill -x "$PRODUCT_NAME" 2>/dev/null || true
sleep 0.2
rm -rf "$INSTALL_PATH"
cp -R "$APP_PATH" "$INSTALL_PATH"

echo ""
echo "▸ Launching $PRODUCT_NAME (Mac dev)..."
open "$INSTALL_PATH"

echo "Installed: $INSTALL_PATH"
