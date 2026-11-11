#!/usr/bin/env bash
# Builds an UNSIGNED Release IPA. SideStore re-signs it on the phone with your free Apple ID.
# Usage: scripts/build-ipa.sh [build-number]   (defaults to $BUILD_NUMBER, else a timestamp)
# CI sets WINBROWSE_VERSION (marketing version) and BUILD_NUMBER; locally the version comes from project.yml.
# Only the IPA path goes to stdout (callers do IPA=$(scripts/build-ipa.sh)); everything else goes to stderr.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD="${1:-${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}}"
VERSION="${WINBROWSE_VERSION:-$(grep 'MARKETING_VERSION' project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')}"
OUT=dist
DD=build/release

command -v xcodegen >/dev/null && xcodegen generate -q >&2
rm -rf "$DD/Build/Products/Release-iphoneos" "$OUT/Payload"
LOG=build/xcodebuild.log
mkdir -p build
set +e
xcodebuild -project WinBrowse.xcodeproj -scheme WinBrowse -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  "WB_REPORTS_URL=${WB_REPORTS_URL:-}" \
  CURRENT_PROJECT_VERSION="$BUILD" MARKETING_VERSION="$VERSION" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build >"$LOG" 2>&1
RC=$?
set -e
grep -E "error:|warning: unable|BUILD" "$LOG" >&2 || true
if [ "$RC" -ne 0 ]; then
  echo "xcodebuild failed (exit $RC); last 40 lines of $LOG:" >&2
  tail -40 "$LOG" >&2
  exit 1
fi

APP="$DD/Build/Products/Release-iphoneos/WinBrowse.app"
[ -d "$APP" ] || { echo "build failed: $APP missing" >&2; exit 1; }

mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
IPA="$OUT/winbrowse-$VERSION-$BUILD.ipa"
(cd "$OUT" && rm -f "$(basename "$IPA")" && zip -qry "$(basename "$IPA")" Payload)
rm -rf "$OUT/Payload"
echo "$IPA"
