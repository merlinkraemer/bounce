#!/usr/bin/env bash
set -euo pipefail

KEYCHAIN_SERVICE="${BOUNCE_KEYCHAIN_SERVICE:-com.bounce.pairingKey}"
APP_BUNDLE_ID="${BOUNCE_APP_BUNDLE_ID:-com.merlinkraemer.bounce.sender}"

echo "▸ Resetting macOS pairing state..."

# Pairing key + bonded peer stores (sender + receiver) in the app keychain domain.
for account in "localPairingKey" "bondedPeers.sender" "bondedPeers.receiver"; do
  security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" >/dev/null 2>&1 || true
done

# Persisted transport device IDs for both roles.
defaults delete "$APP_BUNDLE_ID" "com.bounce.sync.senderDeviceID" >/dev/null 2>&1 || true
defaults delete "$APP_BUNDLE_ID" "com.bounce.sync.receiverDeviceID" >/dev/null 2>&1 || true
defaults delete "$APP_BUNDLE_ID" "com.bounce.senderID" >/dev/null 2>&1 || true

echo "✓ macOS pairing state reset"
