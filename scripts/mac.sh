#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

[ $# -gt 0 ] || { echo "usage: scripts/mac.sh <command> [args...]   e.g. scripts/mac.sh scripts/check.sh" >&2; exit 2; }

HOST="${WINBROWSE_MAC:-$(infra get STUDIO_SSH_ALIAS 2>/dev/null || true)}"
[ -n "$HOST" ] || { echo "set WINBROWSE_MAC to the SSH name of the build Mac" >&2; exit 2; }
SSH=(ssh -o ConnectTimeout=15 -o BatchMode=yes "$HOST")

"${SSH[@]}" true || { echo "cannot reach the build Mac ($HOST)" >&2; exit 3; }

BOOTED='xcrun simctl list devices booted | sed -nE "s/.*\(([0-9A-F-]{36})\) \(Booted\).*/\1/p" | tr "\n" " "'
REMOTE=$("${SSH[@]}" 'mktemp -d /tmp/winbrowse.XXXXXX')
BEFORE=$("${SSH[@]}" "$BOOTED")

cleanup() {
  if [ -n "${WINBROWSE_FETCH:-}" ]; then
    mkdir -p build/mac
    "${SSH[@]}" "cd '$REMOTE' && tar -cf - $WINBROWSE_FETCH 2>/dev/null" | tar -xf - -C build/mac || true
  fi
  "${SSH[@]}" "for u in \$($BOOTED); do case ' $BEFORE ' in *\" \$u \"*) ;; *) xcrun simctl shutdown \$u ;; esac; done; pkill -f '$REMOTE' || true; rm -rf '$REMOTE'" \
    || echo "cleanup on the build Mac failed; remove $REMOTE there by hand" >&2
}
trap cleanup EXIT

git ls-files -co --exclude-standard -z \
  | while IFS= read -r -d '' f; do { [ -e "$f" ] || [ -L "$f" ]; } && printf '%s\0' "$f"; done \
  | tar -cf - --null -T - \
  | "${SSH[@]}" "tar -xf - -C '$REMOTE'"

TTY=()
[ -t 0 ] && TTY=(-t)
set +e
ssh ${TTY[@]+"${TTY[@]}"} -o BatchMode=yes "$HOST" "export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH; cd '$REMOTE' && $(printf '%q ' "$@")"
RC=$?
set -e
exit $RC
