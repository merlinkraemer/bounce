#!/usr/bin/env bash
set -euo pipefail

# Builds + installs both apps (Mac → /Applications, iOS → paired iPhone).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/scripts/install-mac.sh"
"$ROOT_DIR/scripts/install-ios.sh"
