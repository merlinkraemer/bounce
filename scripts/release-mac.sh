#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SENDER_YML="$ROOT_DIR/apps/BounceSender/project.yml"
SENDER_PLIST="$ROOT_DIR/apps/BounceSender/BounceSender/Info.plist"
PROJECT="$ROOT_DIR/apps/BounceSender/BounceSender.xcodeproj"
SCHEME="BounceSender"
PROD_BUNDLE_ID="com.merlinkraemer.bounce.sender"
NOTARY_PROFILE="${BOUNCE_NOTARY_PROFILE:-bounce-notary}"
DOWNLOAD_URL_PREFIX="${BOUNCE_DOWNLOAD_URL_PREFIX:-https://onbounce.app/releases/}"
PLACEHOLDER_KEY="SPARKLE_PUBLIC_KEY"
RELEASE_ROOT="$ROOT_DIR/build/release"
WORK_DIR="$RELEASE_ROOT/work"
DERIVED_DIR="$WORK_DIR/DerivedData"
APPCAST_DIR="$RELEASE_ROOT/appcast"

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

[[ "$(uname -s)" == "Darwin" ]] || die "release-mac.sh must run on macOS."

step "Checking production lane"
yml_bundle_id="$(awk '/PRODUCT_BUNDLE_IDENTIFIER:/ {print $2; exit}' "$SENDER_YML")"
[[ "$yml_bundle_id" == "$PROD_BUNDLE_ID" ]] ||
  die "project.yml bundle ID is '$yml_bundle_id', expected '$PROD_BUNDLE_ID' (no .dev lane in releases)."
TEAM_ID="$(awk '/DEVELOPMENT_TEAM:/ {print $2; exit}' "$SENDER_YML")"
[[ -n "$TEAM_ID" ]] || die "No DEVELOPMENT_TEAM in $SENDER_YML."

if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
  if [[ "$DRY_RUN" == 1 ]]; then
    warn "Git tree is not clean (allowed in dry run)."
  else
    die "Git tree is not clean. Commit or stash before releasing."
  fi
fi
COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
echo "    team $TEAM_ID, commit $COMMIT"

step "Generating Xcode projects"
"$ROOT_DIR/scripts/generate-projects.sh"

step "Checking Sparkle public key"
public_key="$(plutil -extract SUPublicEDKey raw -o - "$SENDER_PLIST" 2>/dev/null || true)"
if [[ "$public_key" == "$PLACEHOLDER_KEY" || -z "$public_key" ]]; then
  cat >&2 <<MSG
ERROR: SUPublicEDKey is still the placeholder '$PLACEHOLDER_KEY'.
Run Sparkle's generate_keys once on this Mac (it stores the private key in the login Keychain
and prints the public key), then paste the public key into SUPublicEDKey in apps/BounceSender/project.yml.
This script never generates keys.
MSG
  if [[ "$DRY_RUN" == 1 ]]; then
    warn "Continuing because of --dry-run."
  else
    exit 1
  fi
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
ARCHIVE_PATH="$WORK_DIR/Bounce.xcarchive"
EXPORT_DIR="$WORK_DIR/export"

step "Archiving $SCHEME (Release)"
archive_args=(
  archive
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration Release
  -archivePath "$ARCHIVE_PATH"
  -derivedDataPath "$DERIVED_DIR"
)
if [[ "$DRY_RUN" == 1 ]]; then
  archive_args+=(CODE_SIGNING_ALLOWED=NO)
else
  archive_args+=(-allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM_ID")
fi
xcodebuild "${archive_args[@]}"

ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/Bounce.app"
[[ -d "$ARCHIVED_APP" ]] || die "Archive did not produce $ARCHIVED_APP."
built_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$ARCHIVED_APP/Contents/Info.plist")"
[[ "$built_bundle_id" == "$PROD_BUNDLE_ID" ]] ||
  die "Archived app bundle ID is '$built_bundle_id', expected '$PROD_BUNDLE_ID'."

EXPORT_OPTIONS="$WORK_DIR/ExportOptions-developer-id.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
</dict>
</plist>
PLIST
plutil -lint "$EXPORT_OPTIONS"

if [[ "$DRY_RUN" == 1 ]]; then
  step "Exporting archive"
  skipped "xcodebuild -exportArchive (needs signing)"
  APP="$ARCHIVED_APP"
else
  step "Exporting archive (Developer ID)"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_DIR" \
    -allowProvisioningUpdates
  APP="$EXPORT_DIR/Bounce.app"
  [[ -d "$APP" ]] || die "Export did not produce $APP."
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
OUT_DIR="$RELEASE_ROOT/$VERSION"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
echo "    version $VERSION -> $OUT_DIR"

step "Notarizing app"
if [[ "$DRY_RUN" == 1 ]]; then
  skipped "notarytool submit, stapler staple"
else
  ditto -c -k --keepParent "$APP" "$WORK_DIR/Bounce.app.zip"
  xcrun notarytool submit "$WORK_DIR/Bounce.app.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

step "Building DMG"
DMG="$OUT_DIR/Bounce-$VERSION.dmg"
STAGE_DIR="$WORK_DIR/dmg-stage"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
ditto "$APP" "$STAGE_DIR/Bounce.app"
ln -s /Applications "$STAGE_DIR/Applications"
hdiutil create -volname "Bounce $VERSION" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG"

step "Signing and notarizing DMG"
if [[ "$DRY_RUN" == 1 ]]; then
  skipped "codesign, notarytool submit, stapler staple for DMG"
else
  identity="$(security find-identity -v -p codesigning | awk -F'"' -v team="($TEAM_ID)" '/Developer ID Application/ && index($2, team) {print $2; exit}')"
  [[ -n "$identity" ]] || die "No 'Developer ID Application' identity for team $TEAM_ID in the keychain."
  codesign --sign "$identity" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

step "Validating"
if [[ "$DRY_RUN" == 1 ]]; then
  skipped "spctl, stapler validate"
else
  spctl -a -vv "$APP"
  xcrun stapler validate "$APP"
  spctl -a -t open --context context:primary-signature -vv "$DMG"
  xcrun stapler validate "$DMG"
fi

step "Appcast"
find_generate_appcast() {
  local candidate
  for candidate in \
    "$DERIVED_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
    "$HOME"/Library/Developer/Xcode/DerivedData/BounceSender-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}
GENERATE_APPCAST="$(find_generate_appcast || true)"
if [[ -z "$GENERATE_APPCAST" ]]; then
  if [[ "$DRY_RUN" == 1 ]]; then
    warn "Sparkle generate_appcast not found under $DERIVED_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin/."
  else
    die "Sparkle generate_appcast not found. Expected $DERIVED_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast after the archive resolved the Sparkle package."
  fi
fi
mkdir -p "$APPCAST_DIR"
cp "$DMG" "$APPCAST_DIR/"
if [[ "$DRY_RUN" == 1 ]]; then
  skipped "generate_appcast (signs with the Keychain EdDSA key)"
else
  "$GENERATE_APPCAST" --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$APPCAST_DIR"
  [[ -f "$APPCAST_DIR/appcast.xml" ]] || die "generate_appcast did not write appcast.xml."
fi

step "Result"
cp "$DMG" "$OUT_DIR/Bounce.dmg"
echo "DMG:    $DMG"
echo "GitHub: $OUT_DIR/Bounce.dmg (attach to the GitHub release under this name; the site links releases/latest/download/Bounce.dmg)"
DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
cat > "$OUT_DIR/bounce.rb" <<CASK
cask "bounce" do
  version "$VERSION"
  sha256 "$DMG_SHA256"

  url "https://github.com/merlinkraemer/bounce/releases/download/v#{version}/Bounce-#{version}.dmg"
  name "Bounce"
  desc "Music library for unfinished tracks, synced to your iPhone"
  homepage "https://onbounce.app"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :tahoe

  app "Bounce.app"

  uninstall quit: "$PROD_BUNDLE_ID"

  zap trash: [
    "~/Library/Application Support/Bounce",
    "~/Library/Caches/$PROD_BUNDLE_ID",
    "~/Library/HTTPStorages/$PROD_BUNDLE_ID",
    "~/Library/Preferences/$PROD_BUNDLE_ID.plist",
  ]
end
CASK
echo "Cask:   $OUT_DIR/bounce.rb (copy to merlinkraemer/homebrew-tap Casks/bounce.rb after the GitHub release v$VERSION exists)"
shasum -a 256 "$DMG"
if [[ "$DRY_RUN" == 1 ]]; then
  echo "Dry run complete: nothing signed, notarized or appcast-signed."
else
  echo "Appcast: $APPCAST_DIR/appcast.xml (URL prefix $DOWNLOAD_URL_PREFIX)"
  echo "Upload the DMG and appcast.xml to onbounce.app manually."
fi
