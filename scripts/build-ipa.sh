#!/usr/bin/env bash
# Builds an UNSIGNED Release IPA. SideStore re-signs it on the phone with your free Apple ID.
# Usage: scripts/build-ipa.sh [build-number]   (defaults to a timestamp so every build is an update)
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD="${1:-$(date +%Y%m%d%H%M)}"
VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')
OUT=dist
DD=build/release

command -v xcodegen >/dev/null && xcodegen generate -q
rm -rf "$DD/Build/Products/Release-iphoneos" "$OUT/Payload"
xcodebuild -project WinBrowse.xcodeproj -scheme WinBrowse -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build | grep -E "error:|warning: unable|BUILD" || true

APP="$DD/Build/Products/Release-iphoneos/WinBrowse.app"
[ -d "$APP" ] || { echo "build failed"; exit 1; }

mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
IPA="$OUT/winbrowse-$VERSION-$BUILD.ipa"
(cd "$OUT" && rm -f "$(basename "$IPA")" && zip -qry "$(basename "$IPA")" Payload)
rm -rf "$OUT/Payload"
echo "$IPA"
