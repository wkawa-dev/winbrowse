#!/usr/bin/env bash
# Builds the IPA and a SideStore/AltStore source, then deploys both as Workers static assets (deploy/).
# Add the printed source URL once in SideStore → Sources; later builds show up as updates.
# Usage: scripts/publish.sh   (override with SITE_URL=... CLOUDFLARE_ACCOUNT_ID=...)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SITE_URL:=https://example.workers.dev}"
export CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-00000000000000000000000000000000}"
SITE_URL="${SITE_URL%/}"
[ "${SKIP_EXT_UPDATE:-}" ] || scripts/update-extensions.sh   # newest SponsorBlock / X-Posed / uBO filter lists in every build
IPA=$(scripts/build-ipa.sh | tail -1)
NAME=$(basename "$IPA" .ipa)
VERSION=$(echo "$NAME" | sed -E 's/^winbrowse-(.*)-[0-9]+$/\1/')
BUILD=${NAME##*-}
SIZE=$(stat -f%z "$IPA")
SITE=deploy/public

mkdir -p "$SITE"
find "$SITE" -name '*.ipa' -delete
cp "$IPA" "$SITE/winbrowse.ipa"
cp App/Assets.xcassets/AppIcon.appiconset/icon.png "$SITE/icon.png"
python3 - "$SITE" "$SITE_URL" "$VERSION" "$BUILD" "$SIZE" <<'PY'
import json, sys, datetime
site, url, version, build, size = sys.argv[1:]
src = {
  "name": "WinBrowse",
  "identifier": "dev.winbrowse.source",
  "subtitle": "Windows 10 Mobile style browser",
  "iconURL": f"{url}/icon.png",
  "apps": [{
    "name": "WinBrowse",
    "bundleIdentifier": "dev.winbrowse.browser",
    "developerName": "WinBrowse",
    "subtitle": "Browser with SponsorBlock, uBlock Origin and X filters",
    "localizedDescription": "WebKit browser with SponsorBlock, uBlock Origin, X-Posed and The Ad Blocker for X built in, plus background playback.",
    "iconURL": f"{url}/icon.png",
    "tintColor": "0050EF",
    "category": "utilities",
    "versions": [{
      "version": version,
      "buildVersion": build,
      "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
      "downloadURL": f"{url}/winbrowse.ipa?b={build}",
      "size": int(size),
      "minOSVersion": "17.0",
    }],
    "appPermissions": {"entitlements": [], "privacy": {}},
  }],
  "news": [],
}
json.dump(src, open(f"{site}/source.json", "w"), indent=2)
open(f"{site}/_headers", "w").write("/source.json\n  Cache-Control: no-cache\n/winbrowse.ipa\n  Content-Type: application/octet-stream\n")
open(f"{site}/index.html", "w").write(f'<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>WinBrowse</title><body style="background:#000;color:#fff;font:18px -apple-system;padding:24px"><h1 style="font-weight:300">WinBrowse</h1><p>SideStore source: <code>{url}/source.json</code></p><p><a style="color:#0050EF" href="sidestore://source?url={url}/source.json">add to SideStore</a></p>')
PY
[ -d deploy/node_modules ] || (cd deploy && npm install --silent)
(cd deploy && cf deploy < /dev/null)
echo "Source: $SITE_URL/source.json"
