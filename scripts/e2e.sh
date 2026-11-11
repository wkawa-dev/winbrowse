#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TOKEN=/tmp/winbrowse-debug-token
SIM="${WINBROWSE_SIM:-$(xcrun simctl list devices available | sed -nE 's/^ +iPhone[^(]*\(([0-9A-F-]{36})\).*/\1/p' | head -1)}"
[ -n "$SIM" ] || { echo "no iPhone simulator is available" >&2; exit 1; }

xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null
rm -f "$TOKEN"
scripts/sim.sh "$SIM" >/dev/null

python3 -I tools/webcompat/wb.py serve &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true; xcrun simctl terminate "$SIM" dev.winbrowse.browser 2>/dev/null || true' EXIT

for _ in $(seq 60); do
  [ -f "$TOKEN" ] && python3 -I tools/webcompat/wb.py --json state >/dev/null 2>&1 && break
  sleep 1
done
python3 -I tools/webcompat/wb.py repro Tests/Fixtures/cases/*.json
