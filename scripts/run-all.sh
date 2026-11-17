#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Run Mac sender only — the persistent Bounce iOS app stays untouched
"$ROOT_DIR/scripts/run-mac.sh"