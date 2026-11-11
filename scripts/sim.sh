#!/usr/bin/env bash
# Build Debug for the simulator, install on the booted device and launch. Usage: scripts/sim.sh [device-udid]
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
xcodegen generate -q
xcodebuild -project WinBrowse.xcodeproj -scheme WinBrowse -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/sim build 2>&1 | grep -E "error:|BUILD FAILED" && exit 1
DEV="${1:-booted}"
xcrun simctl terminate "$DEV" dev.winbrowse.browser 2>/dev/null || true
xcrun simctl install "$DEV" build/sim/Build/Products/Debug-iphonesimulator/WinBrowse.app
xcrun simctl launch "$DEV" dev.winbrowse.browser
