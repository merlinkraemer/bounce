#!/usr/bin/env bash
set -euo pipefail

# Builds Bounce (iOS, Release) and installs the persistent bundle
# (com.merlinkraemer.bounce.receiver, "Bounce") on the paired iPhone.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="Release"

step() { echo ""; echo "▸ $*"; }
warn() { echo "⚠  $*" >&2; }

detect_team_id() {
  if [[ -n "${BOUNCE_DEVELOPMENT_TEAM:-}" ]]; then
    echo "$BOUNCE_DEVELOPMENT_TEAM"
    return
  fi
  local receiver_yml="$ROOT_DIR/apps/BounceReceiver/project.yml"
  if [[ -f "$receiver_yml" ]]; then
    awk '/DEVELOPMENT_TEAM:/ {print $2; exit}' "$receiver_yml"
  fi
}

detect_device_udid() {
  if [[ -n "${BOUNCE_IOS_DEVICE_UDID:-}" ]]; then
    echo "$BOUNCE_IOS_DEVICE_UDID"
    return
  fi
  local json_output
  json_output="$(mktemp)"
  xcrun devicectl list devices --json-output "$json_output" >/dev/null 2>&1 || true
  python3 - "$json_output" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
if not path.exists():
    sys.exit(1)
data = json.loads(path.read_text())
for device in data.get("result", {}).get("devices", []):
    if device.get("hardwareProperties", {}).get("platform") == "iOS":
        if device.get("connectionProperties", {}).get("pairingState") == "paired":
            udid = device.get("hardwareProperties", {}).get("udid")
            if udid:
                print(udid)
                sys.exit(0)
sys.exit(1)
PY
  rm -f "$json_output"
}

"$ROOT_DIR/scripts/generate-projects.sh"

PROJECT_DIR="$ROOT_DIR/apps/BounceReceiver"
PROJECT="$PROJECT_DIR/BounceReceiver.xcodeproj"
SCHEME="BounceReceiver"
BUILD_DIR="$PROJECT_DIR/build/device-release"
BUNDLE_ID="com.merlinkraemer.bounce.receiver"
APP_PATH="$BUILD_DIR/Build/Products/$CONFIG-iphoneos/Bounce.app"

TEAM_ID="$(detect_team_id || true)"
DEVICE_UDID="$(detect_device_udid || true)"

if [[ -z "$DEVICE_UDID" ]]; then
  warn "No paired iPhone detected via devicectl."
  warn "Plug in your iPhone, trust this Mac, then re-run."
  exit 1
fi
if [[ -z "$TEAM_ID" ]]; then
  warn "No Apple development team detected. Set BOUNCE_DEVELOPMENT_TEAM."
  exit 1
fi

echo "Using device UDID: $DEVICE_UDID"
echo "Using development team: $TEAM_ID"
echo "Using bundle ID: $BUNDLE_ID"

step "Building Bounce (iOS, $CONFIG) for device..."
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -allowProvisioningUpdates \
  -sdk iphoneos \
  -destination "id=$DEVICE_UDID" \
  -derivedDataPath "$BUILD_DIR" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"

step "Installing Bounce on device..."
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH"

echo ""
echo "✓ Installed: $BUNDLE_ID on $DEVICE_UDID"
