#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/apps/BounceReceiver"
PROJECT="$PROJECT_DIR/BounceReceiver.xcodeproj"
SCHEME="BounceReceiver"
CONFIG="Debug"
BUILD_BASE="$PROJECT_DIR/build"

# Dev bundle ID — coexists with the persistent "Bounce" (com.merlinkraemer.bounce.receiver) app
BUNDLE_ID="${BOUNCE_IOS_BUNDLE_ID:-com.merlinkraemer.bounce.receiver.dev}"
DEVICE_DERIVED="$BUILD_BASE/device-dev"
DEVICE_APP_PATH="$DEVICE_DERIVED/Build/Products/$CONFIG-iphoneos/Bounce Dev.app"

step() { echo ""; echo "▸ $*"; }
warn() { echo "⚠  $*" >&2; }
reset_requested_from_env() {
  [[ "${npm_config_reset:-false}" == "true" ]] ||
    [[ "${npm_config_reset_pairing:-false}" == "true" ]] ||
    [[ "${BOUNCE_RESET_PAIRING:-0}" == "1" ]]
}

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
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    sys.exit(1)

data = json.loads(path.read_text())
for device in data.get("result", {}).get("devices", []):
    if device.get("hardwareProperties", {}).get("platform") == "iOS":
        pairing = device.get("connectionProperties", {}).get("pairingState")
        if pairing == "paired":
            udid = device.get("hardwareProperties", {}).get("udid")
            if udid:
                print(udid)
                sys.exit(0)
sys.exit(1)
PY
  rm -f "$json_output"
}

RESET_PAIRING=0
if reset_requested_from_env; then
  RESET_PAIRING=1
fi
for arg in "$@"; do
  case "$arg" in
    --clean)
      step "Cleaning build directory..."
      rm -rf "$DEVICE_DERIVED"
      ;;
    --reset|--reset-pairing)
      RESET_PAIRING=1
      ;;
    *)
      warn "Unknown argument: $arg"
      exit 1
      ;;
  esac
done

"$ROOT_DIR/scripts/generate-projects.sh"

TEAM_ID="$(detect_team_id || true)"
DEVICE_UDID="$(detect_device_udid || true)"

if [[ -z "$DEVICE_UDID" ]]; then
  warn "No paired iPhone detected via devicectl."
  exit 1
elif [[ -z "$TEAM_ID" ]]; then
  warn "No Apple development team detected. Set BOUNCE_DEVELOPMENT_TEAM to enable device builds."
  exit 1
fi

echo "Using device UDID: $DEVICE_UDID"
echo "Using development team: $TEAM_ID"
echo "Using dev bundle ID: $BUNDLE_ID (coexists with persistent Bounce app)"

step "Building Bounce (dev) for device..."
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -allowProvisioningUpdates \
  -sdk iphoneos \
  -destination "id=$DEVICE_UDID" \
  -derivedDataPath "$DEVICE_DERIVED" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  BOUNCE_URL_SCHEME="bounce-dev" \
  PRODUCT_NAME="Bounce Dev" \
  INFOPLIST_KEY_CFBundleDisplayName="Bounce Dev" \
  CURRENT_PROJECT_VERSION="$(date +%m%d.%H%M)"

step "Installing dev app on device..."
xcrun devicectl device install app --device "$DEVICE_UDID" "$DEVICE_APP_PATH"

step "Launching dev app. Press Ctrl-C to stop."
launch_args=(
  --device "$DEVICE_UDID"
  --terminate-existing
  --console
  "$BUNDLE_ID"
)
# Pass --reset (or --reset-pairing) to wipe iOS keychain bonds + receiver deviceID before
# launch. Off by default so the bond store stays stable across `npm run ios`
# restarts; otherwise every launch mints a new receiver deviceID, leaving
# stale bonds on the Mac and forcing a re-pair every time.
if [[ "$RESET_PAIRING" -eq 1 ]]; then
  launch_args+=(--reset-pairing-state)
fi
exec xcrun devicectl device process launch "${launch_args[@]}"
