# podman fixtures

Recorded from podman 6.1.4 (mgoltzsche/podman-static v6.1.4, amd64: crun,
netavark, fuse-overlayfs, conmon, catatonit) in a privileged Debian
container, with `--transient-store --log-level=error` on every call. The
JSON shapes and error texts do not depend on the architecture; the numbers
do (the nested cgroup reports `MemUsage` 0). Re-record on every podman bump:
the error classifier (`Vagus.Runtime.Podman.Error`) matches these texts.

The events logger was already `file` (the image's `containers.conf` sets
`events_logger = "file"`; `podman info --format '{{.Host.EventLogger}}'`
says `file`), writing `/run/libpod/events/events.log`.

Setup, inside the container:

    podman network create --disable-dns --interface-name hassio \
      --subnet 172.30.32.0/23 --gateway 172.30.32.1 \
      --ip-range 172.30.33.0-172.30.33.255 hassio
    podman run -d --name fx_running --network hassio --label supervisor_managed \
      --label io.hass.version=1.2.0 --env TZ=UTC --hostname local-x \
      --network-alias local-x docker.io/library/alpine:3.20 sleep 3600
    podman run -d --name fx_exited --network hassio docker.io/library/alpine:3.20 sh -c 'exit 3'
    podman run -d --name fx_stopped --network hassio docker.io/library/alpine:3.20 sleep 3600
    podman run -d --name fx_health --network hassio --health-cmd 'test -e /tmp' \
      --health-interval 30s --health-timeout 5s --health-retries 3 \
      docker.io/library/alpine:3.20 sleep 3600
    podman stop -t 0 fx_stopped
    podman healthcheck run fx_health

| File | Command |
|---|---|
| `inspect_{running,exited,stopped,health}.json` | `podman container inspect fx_<name>` |
| `ps_all.json` | `podman ps --all --format json` |
| `network_inspect_hassio.json` | `podman network inspect hassio` |
| `stats_sample1.json`, `stats_sample2.json` | `podman stats --no-stream --no-reset --format '{{json .ContainerStats}}' fx_running`, 3 s apart |
| `stats_stopped.json` | the same, for `fx_stopped` |
| `stats_format_json.json` | `podman stats --no-stream --format json fx_running`: the human-string form the adapter does not use |
| `events.log` | the `fx_*` lines of `/run/libpod/events/events.log` |
| `cli_results.txt` | each command, its exit status and its merged stdout+stderr |

In `cli_results.txt`, `fx_unhealthy` ran `--health-cmd false --health-retries 2`,
`fx_startp` ran `--health-cmd false --health-start-period 300s`,
`fx_created` was created and never started, `fx_paused` was started and
paused, and `fx_logs` printed one line to stdout and one to stderr. Its
`pull` entry was captured to a file inside the container, because
`docker exec` of a `podman pull` returns early and loses the output and status.
