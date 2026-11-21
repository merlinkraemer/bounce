#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECEIVER_YML="$ROOT_DIR/apps/BounceReceiver/project.yml"
PROJECT="$ROOT_DIR/apps/BounceReceiver/BounceReceiver.xcodeproj"
SCHEME="BounceReceiver"
PROD_BUNDLE_ID="com.merlinkraemer.bounce.receiver"
WORK_DIR="$ROOT_DIR/build/release/ios"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
  esac
done

step() { echo ""; echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }
skipped() { echo "    [dry-run] skipped: $*"; }

[[ "$(uname -s)" == "Darwin" ]] || die "release-ios.sh must run on macOS."

step "Checking production lane"
yml_bundle_id="$(awk '/PRODUCT_BUNDLE_IDENTIFIER:/ {print $2; exit}' "$RECEIVER_YML")"
[[ "$yml_bundle_id" == "$PROD_BUNDLE_ID" ]] ||
  die "project.yml bundle ID is '$yml_bundle_id', expected '$PROD_BUNDLE_ID' (no .dev lane in releases)."
TEAM_ID="$(awk '/DEVELOPMENT_TEAM:/ {print $2; exit}' "$RECEIVER_YML")"
[[ -n "$TEAM_ID" ]] || die "No DEVELOPMENT_TEAM in $RECEIVER_YML."

if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
  if [[ "$DRY_RUN" == 1 ]]; then
    warn "Git tree is not clean (allowed in dry run)."
  else
    die "Git tree is not clean. Commit or stash before releasing."
  fi
fi
echo "    team $TEAM_ID, commit $(git -C "$ROOT_DIR" rev-parse --short HEAD)"

step "Generating Xcode projects"
"$ROOT_DIR/scripts/generate-projects.sh"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
ARCHIVE_PATH="$WORK_DIR/Bounce.xcarchive"

step "Archiving $SCHEME (Release)"
archive_args=(
  archive
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration Release
  -destination "generic/platform=iOS"
  -archivePath "$ARCHIVE_PATH"
  -derivedDataPath "$WORK_DIR/DerivedData"
)
if [[ "$DRY_RUN" == 1 ]]; then
  archive_args+=(CODE_SIGNING_ALLOWED=NO)
else
  archive_args+=(-allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM_ID")
fi
xcodebuild "${archive_args[@]}"

ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/Bounce.app"
[[ -d "$ARCHIVED_APP" ]] || die "Archive did not produce $ARCHIVED_APP."
built_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$ARCHIVED_APP/Info.plist")"
[[ "$built_bundle_id" == "$PROD_BUNDLE_ID" ]] ||
  die "Archived app bundle ID is '$built_bundle_id', expected '$PROD_BUNDLE_ID'."

EXPORT_OPTIONS="$WORK_DIR/ExportOptions-app-store-connect.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>upload</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
</dict>
</plist>
PLIST
plutil -lint "$EXPORT_OPTIONS"

step "Exporting and uploading to App Store Connect"
if [[ "$DRY_RUN" == 1 ]]; then
  skipped "xcodebuild -exportArchive (signing and upload)"
  echo "Dry run complete: nothing signed or uploaded."
else
  ASC_KEY_ID="${BOUNCE_ASC_KEY_ID:-PH4ND94R26}"
  ASC_ISSUER_ID="${BOUNCE_ASC_ISSUER_ID:-5bf6c3c7-93b6-4b36-a56e-eca8f92b001c}"
  ASC_KEY_PATH="${BOUNCE_ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
  auth_args=()
  if [[ -f "$ASC_KEY_PATH" ]]; then
    auth_args=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  else
    warn "No App Store Connect API key at $ASC_KEY_PATH; using the Xcode account."
  fi
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$WORK_DIR/export" \
    -allowProvisioningUpdates \
    ${auth_args[@]+"${auth_args[@]}"}
  echo "Uploaded. Finish the build in App Store Connect / TestFlight."
fi
