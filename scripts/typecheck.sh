#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${WINBROWSE_TYPECHECK_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
CATALYST="$SDK/System/iOSSupport"
[ -d "$CATALYST/System/Library/Frameworks/UIKit.framework" ] || { echo "the macOS SDK at $SDK has no Mac Catalyst frameworks" >&2; exit 1; }

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
set +e
git ls-files -co --exclude-standard -z 'App/*.swift' | xargs -0 swiftc -typecheck -target arm64-apple-ios17.0-macabi -sdk "$SDK" \
  -Fsystem "$CATALYST/System/Library/Frameworks" -I "$CATALYST/usr/lib/swift" \
  -swift-version 5 -D DEBUG -module-name WinBrowse >"$LOG" 2>&1
RC=$?
set -e
grep -E "^App/.*(error|warning):" "$LOG" | sort -u >&2 || true
if [ "$RC" -ne 0 ]; then
  grep -q "plugin for module 'SwiftUIMacros' not found" "$LOG" && echo "this SDK needs the SwiftUI macro plugin, which only Xcode has; set WINBROWSE_TYPECHECK_SDK to an older macOS SDK" >&2
  exit 1
fi
if grep -qE "^App/.*warning:" "$LOG"; then echo "type check produced warnings" >&2; exit 1; fi
