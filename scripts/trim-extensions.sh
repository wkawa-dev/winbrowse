#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../App/Extensions-bundle/ubo"

rm -rf rulesets/regex rulesets/scripting/popup
find rulesets -name 'ubol-tests.*' -delete
find rulesets -name 'ublock-experimental.*' -delete
find img -type f ! -name icon_64.png -delete
find img -type d -empty -delete
