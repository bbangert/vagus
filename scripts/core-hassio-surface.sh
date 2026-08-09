#!/usr/bin/env bash
# Print Core's Supervisor-reserved surface at a tag, as the JSON shape
# apps/vagus/test/fixtures/core-<tag>-hassio-views.json holds: every view URL
# its hassio integration registers, plus every WS command type that integration
# dispatches on.
#
# Both the fixture and .github/workflows/core-contract-drift.yml run THIS
# script, so a regeneration can never disagree with the check that demanded it.
#
#   scripts/core-hassio-surface.sh 2026.7.3
#
# Command types are read via the constants they dispatch on, never from the
# handler names: `websocket_supervisor_event` dispatches on WS_TYPE_EVENT,
# which is "supervisor/event" — reading the handler name suggests "hassio/event"
# and yields a rule that blocks nothing.
set -euo pipefail

TAG="${1:?usage: core-hassio-surface.sh <core-tag>}"
RAW="https://raw.githubusercontent.com/home-assistant/core/${TAG}"
SRC="$(mktemp -d)"
trap 'rm -rf "$SRC"' EXIT

gh api "repos/home-assistant/core/git/trees/${TAG}?recursive=1" --jq '.tree[].path' \
  | grep -E '^homeassistant/components/hassio/.*\.py$' \
  | while read -r path; do
      curl -sfL "${RAW}/${path}" -o "${SRC}/$(basename "$path")"
    done

urls=$(grep -ohE 'url = "/api/[^"]+"' "$SRC"/*.py | sed 's/^url = //' | tr -d '"' | sort -u)

# WS command types: the "domain/action" string literals, wherever they are
# defined (const.py's WS_TYPE_* or inline in websocket_api.py's schemas).
commands=$(grep -ohE '"(supervisor|hassio)/[a-z0-9/_]+"' "$SRC"/*.py | tr -d '"' | sort -u)

json_array() {
  if [ -z "$1" ]; then printf '[]'; else printf '%s\n' "$1" | jq -R . | jq -s .; fi
}

jq -n \
  --arg version "$TAG" \
  --argjson urls "$(json_array "$urls")" \
  --argjson commands "$(json_array "$commands")" \
  '{
     _core_version: $version,
     _source: "homeassistant/components/hassio/**/*.py at tag \($version)",
     urls: $urls,
     ws_commands: $commands
   }'
