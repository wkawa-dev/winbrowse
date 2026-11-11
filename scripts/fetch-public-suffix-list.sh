#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

COMMIT=3db7776283b0874634fea8b01168f785360d64f2
SHA256=22dd3a3a2bca93a9542e65998b301c751339af72681d5f47378eb355face16bc
OUT=App/Resources/public_suffix_list.dat
TESTS=Tests/Fixtures/test_psl.txt
BASE="https://raw.githubusercontent.com/publicsuffix/list/$COMMIT"

verified() { [ -f "$OUT" ] && [ "$(shasum -a 256 "$OUT" | cut -d' ' -f1)" = "$SHA256" ]; }

if ! verified; then
  curl -fsSL --retry 3 "$BASE/public_suffix_list.dat" -o "$OUT.tmp"
  mv "$OUT.tmp" "$OUT"
  verified || { rm -f "$OUT"; echo "public_suffix_list.dat does not match the pinned SHA-256" >&2; exit 1; }
fi
[ -f "$TESTS" ] || curl -fsSL --retry 3 "$BASE/tests/test_psl.txt" -o "$TESTS"
