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
# HOST_PORT is the host-side port Core's web UI is published on (container
# side is always 8123). Override it when host 8123 is already taken (e.g. a
# port-forward to a real HA). Because the emulator's EventPusher/Client dial
# Core back at `config :vagus, :core_base_url`, a non-8123 HOST_PORT also
# requires the emulator to be started with a matching VAGUS_CORE_BASE_URL —
# `up` prints the exact export to use (config/host.exs reads that env var).
#
# Usage:
#   scripts/dev-core.sh up        # start (pulls image on first run)
#   scripts/dev-core.sh down      # stop + remove container (keeps /config volume)
#   scripts/dev-core.sh restart   # bounce Core to force an immediate full poll
#   scripts/dev-core.sh logs      # follow Core logs
#   scripts/dev-core.sh reset     # down + delete the /config volume (fresh onboarding)
#
#   # Example when host 8123 is occupied:
#   HOST_PORT=8124 scripts/dev-core.sh up
#
# Start the emulator (host BEAM) BEFORE `up` — if Core boots first it logs
# one-shot "connecting to supervisor" errors from discovery/addon_panel and a
# hassio ConfigEntryNotReady (hassio self-heals on retry; the other two need a
# Core `restart`). Emulator-first avoids the noise entirely.

CORE_VERSION="${CORE_VERSION:-2026.7.2}"
CORE_IMAGE="ghcr.io/home-assistant/home-assistant:${CORE_VERSION}"
CONTAINER_NAME="${CONTAINER_NAME:-vagus-dev-core}"
CONFIG_VOLUME="${CONFIG_VOLUME:-vagus-dev-core-config}"
SUPERVISOR_HOST="${SUPERVISOR_HOST:-172.17.0.1}"
SUPERVISOR_PORT="${SUPERVISOR_PORT:-8888}"
HOST_PORT="${HOST_PORT:-8123}"

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
      -p "${HOST_PORT}:8123" \
      -e SUPERVISOR="${SUPERVISOR_HOST}:${SUPERVISOR_PORT}" \
      -e SUPERVISOR_TOKEN="$(token)" \
      -e TZ="${TZ:-UTC}" \
      -v "${CONFIG_VOLUME}:/config" \
      "$CORE_IMAGE"
    echo "Core ${CORE_VERSION} up: http://localhost:${HOST_PORT} — supervisor expected at ${SUPERVISOR_HOST}:${SUPERVISOR_PORT}"
    if [[ "$HOST_PORT" != "8123" ]]; then
      echo
      echo "NOTE: Core is on host port ${HOST_PORT}, not 8123. Start the emulator with a matching"
      echo "      callback URL so EventPusher/Client reach Core:"
      echo "        export VAGUS_CORE_BASE_URL=http://localhost:${HOST_PORT}"
    fi
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
