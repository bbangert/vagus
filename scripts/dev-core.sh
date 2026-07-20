#!/usr/bin/env bash
set -euo pipefail

# Host dev-loop harness (P0-T2): run a stock Home Assistant Core container
# pointed at the Vagus supervisor-API emulator running on the host BEAM.
#
# Contract facts (docs/contract-2026.7.md §1): Core uses the SUPERVISOR env
# var verbatim as "http://{SUPERVISOR}" — host:port works, no port-80
# assumption. The hassio integration activates iff SUPERVISOR and
# SUPERVISOR_TOKEN are both set.
#
# From inside the Core container (default bridge network) the host network
# namespace is reachable via the docker0 gateway, hence the 172.17.0.1
# default. Override SUPERVISOR_HOST if your bridge differs.
#
# Usage:
#   scripts/dev-core.sh up        # start (pulls image on first run)
#   scripts/dev-core.sh down      # stop + remove container (keeps /config volume)
#   scripts/dev-core.sh restart   # bounce Core to force an immediate full poll
#   scripts/dev-core.sh logs      # follow Core logs
#   scripts/dev-core.sh reset     # down + delete the /config volume (fresh onboarding)

CORE_VERSION="${CORE_VERSION:-2026.7.2}"
CORE_IMAGE="ghcr.io/home-assistant/home-assistant:${CORE_VERSION}"
CONTAINER_NAME="${CONTAINER_NAME:-vagus-dev-core}"
CONFIG_VOLUME="${CONFIG_VOLUME:-vagus-dev-core-config}"
SUPERVISOR_HOST="${SUPERVISOR_HOST:-172.17.0.1}"
SUPERVISOR_PORT="${SUPERVISOR_PORT:-8888}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
token_file="${TOKEN_FILE:-${repo_root}/.dev/supervisor_token}"

token() {
  if [[ -n "${VAGUS_SUPERVISOR_TOKEN:-}" ]]; then
    echo "$VAGUS_SUPERVISOR_TOKEN"
    return
  fi
  if [[ ! -f "$token_file" ]]; then
    mkdir -p "$(dirname "$token_file")"
    openssl rand -hex 32 > "$token_file"
    echo "generated new supervisor token at ${token_file}" >&2
  fi
  cat "$token_file"
}

case "${1:-up}" in
  up)
    docker run -d --name "$CONTAINER_NAME" \
      -p 8123:8123 \
      -e SUPERVISOR="${SUPERVISOR_HOST}:${SUPERVISOR_PORT}" \
      -e SUPERVISOR_TOKEN="$(token)" \
      -e TZ="${TZ:-UTC}" \
      -v "${CONFIG_VOLUME}:/config" \
      "$CORE_IMAGE"
    echo "Core ${CORE_VERSION} up: http://localhost:8123 — supervisor expected at ${SUPERVISOR_HOST}:${SUPERVISOR_PORT}"
    ;;
  down)
    docker rm -f "$CONTAINER_NAME"
    ;;
  restart)
    docker restart "$CONTAINER_NAME"
    ;;
  logs)
    docker logs -f "$CONTAINER_NAME"
    ;;
  reset)
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    docker volume rm "$CONFIG_VOLUME"
    ;;
  *)
    echo "usage: $0 {up|down|restart|logs|reset}" >&2
    exit 1
    ;;
esac
