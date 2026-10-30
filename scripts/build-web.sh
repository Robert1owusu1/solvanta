#!/usr/bin/env bash
# Builds the web app into build/web, with its API address in
# build/web/config.json — read by the app at startup, so the same build can
# be pointed elsewhere by editing that one file (no rebuild).
#
#   scripts/build-web.sh https://api.yourschool.com   # API on its own host
#   scripts/build-web.sh :8080                        # API on the page's host
#   SOLVANTA_API=https://api.yourschool.com scripts/build-web.sh
#
# Without config.json the app runs as an offline demo. Upload the contents of
# build/web to any static host. The app uses #/ links, so the host needs no
# rewrite rules. If it is served from a sub-path rather than the domain root,
# pass BASE_HREF, e.g. BASE_HREF=/portal/.
#
# On a machine with little memory, OPT=-O1 makes a lighter (slightly larger)
# build.
set -euo pipefail

api="${1:-${SOLVANTA_API:-}}"
if [ -z "$api" ]; then
  echo "usage: scripts/build-web.sh <API base URL | :port>   e.g. https://api.yourschool.com" >&2
  exit 1
fi
api="${api%/}"

case "$api" in
  https://*|:[0-9]*) ;;
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
    echo "The API address must start with https:// or be :port (got: $api)" >&2
    exit 1
    ;;
esac

cd "$(dirname "$0")/.."
args=(--release ${OPT:-})
if [ -n "${BASE_HREF:-}" ]; then
  args+=(--base-href="$BASE_HREF")
fi
flutter build web "${args[@]}"
printf '{"api": "%s"}\n' "$api" > build/web/config.json

echo
echo "Built build/web for API $api (build/web/config.json)"
echo "Remember: the API needs ALLOWED_ORIGINS set to this site's address."
