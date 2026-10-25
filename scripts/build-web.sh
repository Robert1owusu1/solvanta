#!/usr/bin/env bash
# Builds the production web app into build/web.
#
# The API address is compiled into the app (Flutter web cannot read
# environment variables at runtime), so it must be given here. Without it the
# app silently falls back to http://127.0.0.1:8080 and runs as an offline demo
# on every visitor's machine.
#
#   scripts/build-web.sh https://api.yourschool.com
#   SOLVANTA_API=https://api.yourschool.com scripts/build-web.sh
#
# Upload the contents of build/web to any static host. The app uses #/ links,
# so the host needs no rewrite rules. If it is served from a sub-path rather
# than the domain root, pass BASE_HREF, e.g. BASE_HREF=/portal/.
set -euo pipefail

api="${1:-${SOLVANTA_API:-}}"
if [ -z "$api" ]; then
  echo "usage: scripts/build-web.sh <API base URL>   e.g. https://api.yourschool.com" >&2
  exit 1
fi
api="${api%/}"

case "$api" in
  https://*) ;;
  http://localhost*|http://127.0.0.1*)
    if [ "${ALLOW_LOCAL:-}" != "1" ]; then
      echo "Refusing a production build that talks to $api." >&2
      echo "Set ALLOW_LOCAL=1 for a local test build." >&2
      exit 1
    fi
    ;;
  http://*)
    echo "warning: $api is not HTTPS. Browsers block it from an HTTPS page," >&2
    echo "and passwords would cross the network unencrypted." >&2
    ;;
  *)
    echo "The API address must start with https:// (got: $api)" >&2
    exit 1
    ;;
esac

cd "$(dirname "$0")/.."
args=(--release --dart-define=SOLVANTA_API="$api")
if [ -n "${BASE_HREF:-}" ]; then
  args+=(--base-href="$BASE_HREF")
fi
flutter build web "${args[@]}"

echo
echo "Built build/web for API $api"
echo "Remember: the API needs ALLOWED_ORIGINS set to this site's address."
