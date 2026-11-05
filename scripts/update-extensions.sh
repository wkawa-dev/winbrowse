#!/usr/bin/env bash
# Downloads the bundled extensions (Chrome Web Store CRX + uBO Lite's WebKit build) into App/Extensions-bundle.
# Usage: scripts/update-extensions.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=App/Extensions-bundle
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

crx() { # name id
  curl -fsSL -o "$TMP/$1.crx" "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=140.0&acceptformat=crx2,crx3&x=id%3D$2%26uc"
  rm -rf "$OUT/$1"; mkdir -p "$OUT/$1"
  unzip -qo "$TMP/$1.crx" -d "$OUT/$1" 2>/dev/null || true   # CRX3 header makes unzip warn; the payload extracts fine
  rm -rf "$OUT/$1/_metadata"
  [ -f "$OUT/$1/manifest.json" ] || { echo "failed to unpack $1"; exit 1; }
  echo "$1 $(python3 -c "import json;print(json.load(open('$OUT/$1/manifest.json'))['version'])")"
}
crx sponsorblock mnjggcdmjocbbbhaepdhchncahnbgone
crx xposed oodhljjldjdhcdopjpmfgbaoibpancfk
crx xadblock eeiplahcoljpdmmdofhdhinjkeammchg
python3 scripts/patch-xadblock.py   # keep focal tweets visible on /status pages

# uBlock Origin: its own WebKit-targeted build (uBO Lite for Safari) — compiled filter lists + scriptlets.
TAG=$(gh release view -R uBlockOrigin/uBOL-home --json tagName -q .tagName)
gh release download "$TAG" -R uBlockOrigin/uBOL-home -p '*safari.zip' -D "$TMP" --clobber
mkdir -p "$TMP/ubol"; unzip -qo "$TMP"/*safari.zip -d "$TMP/ubol"
rm -rf "$OUT/ubo"; mkdir -p "$OUT/ubo/js"
cp -R "$TMP/ubol/rulesets" "$OUT/ubo/rulesets"
rm -rf "$OUT/ubo/rulesets/strictblock" "$OUT/ubo/rulesets/urlskip"
for f in css-api isolated-api css-generic css-procedural-api; do cp "$TMP/ubol/js/scripting/$f.js" "$OUT/ubo/js/"; done
cp "$TMP/ubol/LICENSE.txt" "$OUT/ubo/"
cp -R "$TMP/ubol/img" "$OUT/ubo/img"
echo "$TAG" > "$OUT/ubo/VERSION"
echo "ubo $TAG"
