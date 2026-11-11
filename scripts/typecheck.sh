#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${WINBROWSE_TYPECHECK_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
CATALYST="$SDK/System/iOSSupport"
[ -d "$CATALYST/System/Library/Frameworks/UIKit.framework" ] || { echo "the macOS SDK at $SDK has no Mac Catalyst frameworks" >&2; exit 1; }
TESTING="$(dirname "$(dirname "$(xcrun --find swiftc)")")/../Library/Developer/Frameworks"
[ -d "$TESTING/Testing.framework" ] || TESTING="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FLAGS=(-target arm64-apple-ios17.0-macabi -sdk "$SDK" -Fsystem "$CATALYST/System/Library/Frameworks" -I "$CATALYST/usr/lib/swift" -swift-version 5 -D DEBUG)

run() {
  local label=$1; shift
  set +e
  "$@" >"$WORK/log" 2>&1
  local rc=$?
  set -e
  grep -E "^(App|Tests)/.*(error|warning):" "$WORK/log" | sort -u >&2 || true
  if [ "$rc" -ne 0 ]; then
    grep -q "plugin for module 'SwiftUIMacros' not found" "$WORK/log" && echo "this SDK needs the SwiftUI macro plugin, which only Xcode has; set WINBROWSE_TYPECHECK_SDK to an older macOS SDK" >&2
    echo "$label failed" >&2
    exit 1
  fi
  if grep -qE "^(App|Tests)/.*warning:" "$WORK/log"; then echo "$label produced warnings" >&2; exit 1; fi
}

APP=()
while IFS= read -r -d '' f; do APP+=("$f"); done < <(find App -name '*.swift' -print0 | sort -z)
TESTS=()
while IFS= read -r -d '' f; do TESTS+=("$f"); done < <(find Tests -name '*.swift' -print0 | sort -z)

run "app type check" swiftc "${FLAGS[@]}" -module-name WinBrowse -enable-testing -emit-module -emit-module-path "$WORK/WinBrowse.swiftmodule" ${APP[@]+"${APP[@]}"}
PLUGINS=()
MACROS="$(dirname "$(dirname "$(xcrun --find swiftc)")")/lib/swift/host/plugins/testing/libTestingMacros.dylib"
[ -f "$MACROS" ] && PLUGINS=(-load-plugin-library "$MACROS")
run "test type check" swiftc -typecheck "${FLAGS[@]}" ${PLUGINS[@]+"${PLUGINS[@]}"} -I "$WORK" -F "$TESTING" -module-name WinBrowseTests ${TESTS[@]+"${TESTS[@]}"}
