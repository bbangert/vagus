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
# Supervisor↔Core unix socket (Vagus.Core.Transport, socket-first): `up`
# mkdirs a host directory for the socket (Vagus.Core.Container's own mkdir is
# target-only — nothing does this for the dev loop) and bind-mounts it into
# the Core container at /run/supervisor, the same path Container.socket_dir/0
# uses on-device, with SUPERVISOR_CORE_API_SOCKET set to match. `up` prints
# the matching `VAGUS_CORE_SOCKET` export; start (or restart) the emulator
# with it so Vagus.Core.Transport.current/1 finds the socket instead of
# falling back to TCP (config/host.exs reads that env var). Not exporting it
# is fine — everything then dials `VAGUS_CORE_BASE_URL`/`:core_base_url`
# exactly as before the socket existed.
#
# Socket permissions: Core creates the socket file itself (root:root, mode
# 0600 — its own hardening, confirmed against a live 2026.8.0 container) once
# its HTTP server is up, which can take up to ~30s after `docker run`. Real
# HAOS never notices because Supervisor is root too; this dev loop's
# "supervisor" is a normal host-user BEAM process, so `up` polls for the
# socket to appear and `chmod 666`s it (via `docker exec`, i.e. as the
# container's root, no host sudo needed) so a non-root emulator can connect.
#
# Devcontainer/host path split (only matters if `docker` here talks to a
# DIFFERENT machine's daemon than the one running this shell — e.g. the vagus
# devcontainer, which is `docker-outside-of-docker`: `docker` commands issued
# from inside it are executed by the HOST's dockerd, and `-v` bind-mount
# SOURCE paths are resolved in the HOST's filesystem, not this container's).
# SOCKET_DIR (below) is what THIS shell — and thus the emulator, started from
# here — sees. HOST_SOCKET_DIR is what gets handed to `docker run -v`; it
# defaults to the same path, which is correct whenever this script's `docker`
# already talks to a same-filesystem daemon. Inside a devcontainer like this
# repo's, SOCKET_DIR (e.g. /workspaces/vagus/.dev/core-socket) is a bind-mount
# view of a directory that lives elsewhere on the real host, so it must NOT be
# handed to dockerd verbatim — set HOST_SOCKET_DIR to that directory's actual
# host-side absolute path (`docker inspect <this devcontainer> --format
# '{{json .Mounts}}'` shows the Source for the /workspaces/vagus bind mount;
# append the same suffix, e.g. .dev/core-socket, that SOCKET_DIR uses under
# repo_root). Getting this wrong doesn't error — it silently bind-mounts an
# unrelated, empty host directory into Core, and the emulator never finds a
# socket there (falls back to TCP, which still works).
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
#   # Example from inside a docker-outside-of-docker devcontainer whose
#   # workspace bind-mount source (on the real host) is /home/ben/src/vagus:
#   HOST_SOCKET_DIR=/home/ben/src/vagus/.dev/core-socket scripts/dev-core.sh up
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

# In-container mount point + env var — matches Vagus.Core.Container's device
# paths (socket_dir/0, socket_path/0) so the dev loop exercises the same
# SUPERVISOR_CORE_API_SOCKET value Core sees on-target.
CORE_SOCKET_DIR="/run/supervisor"
CORE_SOCKET_PATH="${CORE_SOCKET_DIR}/core.sock"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
token_file="${TOKEN_FILE:-${repo_root}/.dev/supervisor_token}"

# SOCKET_DIR: this shell's (and thus the emulator's) view of the socket dir.
# HOST_SOCKET_DIR: the dockerd's view of the SAME directory — see the
# devcontainer/host path split note above; defaults to SOCKET_DIR, correct
# whenever `docker` here already shares a filesystem with this shell.
SOCKET_DIR="${SOCKET_DIR:-${repo_root}/.dev/core-socket}"
HOST_SOCKET_DIR="${HOST_SOCKET_DIR:-$SOCKET_DIR}"
SOCKET_PATH="${SOCKET_DIR}/core.sock"

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
    mkdir -p "$SOCKET_DIR"
    docker run -d --name "$CONTAINER_NAME" \
      -p "${HOST_PORT}:8123" \
      -e SUPERVISOR="${SUPERVISOR_HOST}:${SUPERVISOR_PORT}" \
      -e SUPERVISOR_TOKEN="$(token)" \
      -e SUPERVISOR_CORE_API_SOCKET="${CORE_SOCKET_PATH}" \
      -e TZ="${TZ:-UTC}" \
      -v "${CONFIG_VOLUME}:/config" \
      -v "${HOST_SOCKET_DIR}:${CORE_SOCKET_DIR}" \
      "$CORE_IMAGE"
    echo "Core ${CORE_VERSION} up: http://localhost:${HOST_PORT} — supervisor expected at ${SUPERVISOR_HOST}:${SUPERVISOR_PORT}"
    echo
    echo "Waiting for Core to create the supervisor socket..."
    socket_ready=0
    for _ in $(seq 1 30); do
      if docker exec "$CONTAINER_NAME" test -S "$CORE_SOCKET_PATH" 2>/dev/null; then
        socket_ready=1
        break
      fi
      sleep 2
    done
    if [[ "$socket_ready" -eq 1 ]]; then
      # Core creates the socket root:root mode 0600 (its own hardening); chmod
      # it from inside the container (root there) so a non-root host emulator
      # can connect — no host sudo required.
      docker exec "$CONTAINER_NAME" chmod 666 "$CORE_SOCKET_PATH"
      echo "Supervisor socket: ${CORE_SOCKET_PATH} (in container) <- ${HOST_SOCKET_DIR} (docker daemon's view)."
      echo "Start (or restart) the emulator with a matching socket path so it's preferred over TCP:"
      echo "  export VAGUS_CORE_SOCKET=${SOCKET_PATH}"
    else
      echo "WARNING: socket didn't appear within 60s — Core may still be starting, or"
      echo "         HOST_SOCKET_DIR may be wrong for this docker daemon (see the"
      echo "         devcontainer/host path split note above). Once it exists, fix"
      echo "         permissions yourself and export the path:"
      echo "  docker exec ${CONTAINER_NAME} chmod 666 ${CORE_SOCKET_PATH}"
      echo "  export VAGUS_CORE_SOCKET=${SOCKET_PATH}"
    fi
    if [[ "$HOST_PORT" != "8123" ]]; then
      echo
      echo "NOTE: Core is on host port ${HOST_PORT}, not 8123. Start the emulator with a matching"
      echo "      callback URL so EventPusher/Client reach Core:"
      echo "        export VAGUS_CORE_BASE_URL=http://localhost:${HOST_PORT}"
    fi
    ;;
  down)
    docker rm -f "$CONTAINER_NAME"
    # The socket file isn't unlinked when Core stops (it's a plain file in a
    # bind mount, not cleaned up by the kernel) — remove it so a stale file
    # can't make Transport.current/1 think a socket is live when nothing's
    # listening. The directory stays (next `up` reuses it).
    rm -f "$SOCKET_PATH"
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
    rm -f "$SOCKET_PATH"
    ;;
  *)
    echo "usage: $0 {up|down|restart|logs|reset}" >&2
    exit 1
    ;;
esac
