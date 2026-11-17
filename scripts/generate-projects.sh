#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SENDER_PLIST="$ROOT_DIR/apps/BounceSender/BounceSender/Info.plist"
RECEIVER_PLIST="$ROOT_DIR/apps/BounceReceiver/BounceReceiver/Info.plist"
rm -rf "$ROOT_DIR/apps/BounceSender/BounceSender.xcodeproj"
rm -rf "$ROOT_DIR/apps/BounceReceiver/BounceReceiver.xcodeproj"

echo "Generating BounceSender.xcodeproj"
xcodegen generate \
  --spec "$ROOT_DIR/apps/BounceSender/project.yml" \
  --project "$ROOT_DIR/apps/BounceSender"

echo "Generating BounceReceiver.xcodeproj"
xcodegen generate \
  --spec "$ROOT_DIR/apps/BounceReceiver/project.yml" \
  --project "$ROOT_DIR/apps/BounceReceiver"

plutil -replace CFBundleShortVersionString -string '$(MARKETING_VERSION)' "$SENDER_PLIST"
plutil -replace CFBundleVersion -string '$(CURRENT_PROJECT_VERSION)' "$SENDER_PLIST"
plutil -replace ITSAppUsesNonExemptEncryption -bool NO "$SENDER_PLIST"
plutil -replace LSApplicationCategoryType -string "public.app-category.music" "$SENDER_PLIST"
plutil -replace NSHumanReadableCopyright -string "Copyright 2026 Merlin Kraemer. MIT License." "$SENDER_PLIST"
plutil -replace NSBonjourServices -json '["_bounce-sync._tcp","_bounce-dev._tcp"]' "$SENDER_PLIST"
plutil -replace NSLocalNetworkUsageDescription -string "Bounce uses your local network to send audio files to your iPhone." "$SENDER_PLIST"

plutil -replace CFBundleShortVersionString -string '$(MARKETING_VERSION)' "$RECEIVER_PLIST"
plutil -replace CFBundleVersion -string '$(CURRENT_PROJECT_VERSION)' "$RECEIVER_PLIST"
plutil -replace LSRequiresIPhoneOS -bool YES "$RECEIVER_PLIST"
plutil -replace ITSAppUsesNonExemptEncryption -bool NO "$RECEIVER_PLIST"
plutil -replace NSBonjourServices -json '["_bounce-sync._tcp","_bounce-dev._tcp"]' "$RECEIVER_PLIST"
plutil -replace NSLocalNetworkUsageDescription -string "Bounce uses your local network to receive audio files from your Mac." "$RECEIVER_PLIST"
plutil -replace NSAppTransportSecurity -json '{"NSAllowsLocalNetworking":true}' "$RECEIVER_PLIST"
plutil -replace UIBackgroundModes -json '["audio"]' "$RECEIVER_PLIST"
plutil -replace UIApplicationSceneManifest -json '{"UIApplicationSupportsMultipleScenes":false}' "$RECEIVER_PLIST"
plutil -replace UILaunchScreen -json '{}' "$RECEIVER_PLIST"
plutil -replace UIRequiresFullScreen -bool YES "$RECEIVER_PLIST"
plutil -replace UISupportedInterfaceOrientations -json '["UIInterfaceOrientationPortrait"]' "$RECEIVER_PLIST"
