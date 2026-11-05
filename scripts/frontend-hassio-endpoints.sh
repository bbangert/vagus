#!/usr/bin/env bash
# Print every Supervisor endpoint the Home Assistant frontend can request at a
# tag, as the JSON apps/vagus/test/fixtures/frontend-<tag>-hassio-endpoints.json
# holds.
#
# Both the fixture and .github/workflows/core-contract-drift.yml run THIS
# script, so a regeneration can never disagree with the check that demanded it.
#
#   scripts/frontend-hassio-endpoints.sh 20261028.4
#
# The tag Core pins is the `home-assistant-frontend==` requirement in
# homeassistant/components/frontend/manifest.json.
set -euo pipefail

TAG="${1:?usage: frontend-hassio-endpoints.sh <frontend-tag>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The whole src/ tree, not a list of data modules: components and panels call
# supervisorUrl()/fetchHassioStats() directly (the app icon, logo and stats).
curl -sfL "https://codeload.github.com/home-assistant/frontend/tar.gz/refs/tags/${TAG}" -o "$WORK/frontend.tgz"
mkdir "$WORK/frontend"
tar -xzf "$WORK/frontend.tgz" -C "$WORK/frontend" --strip-components=1 --wildcards '*/src/*'

if [ -z "$(find "$WORK/frontend/src" -name '*.ts' -print -quit 2>/dev/null)" ]; then
  echo "no frontend sources fetched for tag ${TAG}" >&2
  exit 1
fi

python3 -I "${HERE}/frontend_hassio_endpoints.py" "$WORK/frontend/src" "$TAG"
