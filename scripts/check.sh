#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { echo "usage: scripts/check.sh [--lint-only]" >&2; exit 2; }
LINT_ONLY=
case "${1:-}" in
  "") ;;
  --lint-only) LINT_ONLY=1 ;;
  *) usage ;;
esac

step() { printf '\n== %s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null || { echo "$1 is required: $2" >&2; exit 1; }; }

need swiftformat "brew install swiftformat"
need npm "brew install node"

step "no code comments"
if git grep -n -E '^\s*//' -- 'App/*.swift' 'App/Resources/*.js' 'Tests/*.swift' 'Tests/Fixtures/*.js'; then
  echo "remove these comments: CLAUDE.md asks for code that explains itself" >&2
  exit 1
fi

step "vendored extensions"
python3 -I scripts/vendor-hash.py --check

step "swiftformat"
swiftformat --lint --quiet .

step "eslint"
[ -d node_modules ] || npm ci --silent --no-audit --no-fund
npx --no-install eslint

step "triage tool tests"
python3 -I -m unittest discover -s tools/webcompat

step "type check (Mac Catalyst SDK)"
scripts/typecheck.sh

if [ -z "$LINT_ONLY" ]; then
  need xcodegen "brew install xcodegen"
  step "xcodegen"
  xcodegen generate -q

  step "unit and WebKit tests (simulator)"
  if [ -z "${WINBROWSE_SIM:-}" ]; then
    WINBROWSE_SIM=$(xcrun simctl list devices available | sed -nE 's/^ +iPhone[^(]*\(([0-9A-F-]{36})\).*/\1/p' | head -1)
  fi
  [ -n "$WINBROWSE_SIM" ] || { echo "no iPhone simulator is available; set WINBROWSE_SIM to a simulator UDID" >&2; exit 1; }
  mkdir -p build
  rm -rf build/test.xcresult
  set +e
  xcodebuild -project WinBrowse.xcodeproj -scheme WinBrowse -configuration Debug \
    -destination "id=$WINBROWSE_SIM" -derivedDataPath build/test -resultBundlePath build/test.xcresult \
    test >build/test.log 2>&1
  RC=$?
  set -e
  grep -E "error:|✘|recorded an issue|Test run with|BUILD FAILED|TEST FAILED|TEST SUCCEEDED" build/test.log >&2 || true
  if [ "$RC" -ne 0 ]; then
    echo "xcodebuild test failed (exit $RC); last 40 lines of build/test.log:" >&2
    tail -40 build/test.log >&2
    exit 1
  fi
fi

echo "check passed" >&2
