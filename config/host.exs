import Config

# Add configuration that is only needed when running on the host here.

# Supervisor-API emulator (P2-T1/T2). Port must match
# scripts/dev-core.sh's SUPERVISOR_PORT default (8888) — that script
# points a real Home Assistant Core container at this port on the host.
config :vagus, :api_port, 8888

# Same file scripts/dev-core.sh itself reads/writes (its `token_file`,
# defaulting to "${repo_root}/.dev/supervisor_token"), so both sides agree
# on the token without any handshake. Resolved as an absolute path here
# (anchored to this file's own location, not the current working
# directory) so it works regardless of where `mix` is invoked from.
config :vagus, :token_path, Path.expand("../.dev/supervisor_token", __DIR__)

# Core-facing token handshake (P3-T1/T2). Same file-backed-JSON pattern as
# :token_path above, persisting POST core/options fields (most importantly
# the Supervisor-user refresh token, contract §5/§22) across dev-loop
# restarts.
config :vagus, :core_token_path, Path.expand("../.dev/core_token.json", __DIR__)

# Installed/latest HA Core version state (CL-P2-T1). Same file-backed-JSON
# pattern as :core_token_path above.
config :vagus, :core_versions_path, Path.expand("../.dev/core.json", __DIR__)

# Persisted POST supervisor/options fields (timezone/country/diagnostics,
# audit E5). Same file-backed-JSON pattern as :core_token_path above.
config :vagus, :supervisor_options_path, Path.expand("../.dev/supervisor_options.json", __DIR__)

# Persisted runtime-added store repositories (issue #5 / D4). Same
# file-backed-JSON pattern as :core_token_path above.
config :vagus, :store_repositories_path, Path.expand("../.dev/store_repositories.json", __DIR__)

# Device-managed SSH access keypair (`Vagus.SSHAccess`). A DETS file rather
# than JSON, but the same `__DIR__`-anchored .dev/ path idiom as
# :core_token_path above; config/target.exs puts it on /data.
config :vagus, :ssh_access_path, Path.expand("../.dev/ssh_access.dets", __DIR__)

# Base URL Vagus.Core.Client/EventPusher use to reach Core itself (distinct
# from :api_port above, which is the port THIS emulator listens on for
# Core to call INTO). On a device this is only a fallback — every real call
# rides the unix socket below (:core_socket_path); Core there binds :80, not
# 8123. This TCP URL matters for the host dev loop, where there's no socket
# unless `scripts/dev-core.sh` mounted one: its defaults publish the dev Core
# container's :80 to host :8123, so localhost:8123 remains the correct
# default dial address even though the container itself binds :80.
#
# `VAGUS_CORE_BASE_URL` env override for the host dev loop: when
# `scripts/dev-core.sh` publishes Core on a non-8123 host port (its
# `HOST_PORT`, e.g. to dodge a host 8123 collision), the emulator must dial
# that port instead. `mix run` re-evaluates this file per invocation, so the
# env var is read at emulator boot; dev-core.sh prints the exact export to
# use. Unset → the dev-loop default above (localhost:8123 → container :80).
config :vagus,
       :core_base_url,
       System.get_env("VAGUS_CORE_BASE_URL") || "http://localhost:8123"

# Supervisor↔Core unix socket (`Vagus.Core.Transport`, socket-first — see its
# moduledoc). Real HAOS — and a vagus device — runs every Core call over it;
# a bare workstation has no `/run/supervisor/core.sock`, so leaving this
# unset means everything above stays on the TCP :core_base_url with today's
# token auth, exactly as before the socket existed. `scripts/dev-core.sh up`
# mkdirs a host directory, bind-mounts it into the dev Core container at
# `/run/supervisor` (with `SUPERVISOR_CORE_API_SOCKET` set to match — the
# same path `Vagus.Core.Container` uses on-device), and prints the
# `VAGUS_CORE_SOCKET` export to start (or restart) the emulator with so
# `Transport.current/1` finds the socket instead of falling back to TCP.
if core_socket = System.get_env("VAGUS_CORE_SOCKET") do
  config :vagus, :core_socket_path, core_socket
end

# Host-management backends (P4-T1) — plausible-but-honest stubs, some of
# which (OS) read the same Nerves.Runtime.KV pre-populated below.
config :vagus, :backends, %{
  network: Vagus.Backend.Network.HostStub,
  host: Vagus.Backend.Host.HostStub,
  os: Vagus.Backend.OS.HostStub
}

config :nerves_runtime,
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       # The KV store on Nerves systems is typically read from UBoot-env, but
       # this allows us to use a pre-populated InMemory store when running on
       # host for development and testing.
       #
       # https://nerves-runtime.hexdocs.pm/readme.html#using-nerves_runtime-in-tests
       # https://nerves-runtime.hexdocs.pm/readme.html#nerves-system-and-firmware-metadata

       "nerves_fw_active" => "a",
       "a.nerves_fw_architecture" => "generic",
       "a.nerves_fw_description" => "N/A",
       "a.nerves_fw_platform" => "host",
       "a.nerves_fw_version" => "0.0.0",
       "a.nerves_fw_uuid" => "00000000-0000-0000-0000-000000000000"
     }}

# Board identity reported by `Vagus.API.StaticData` (P3-T3). The host dev
# loop emulates the rpi3_64 appliance against a real Core container, so it
# reports that board's machine string. Per-target values live in
# config/rpi3_64.exs and config/dragon_q6a.exs.
config :vagus, :machine, "raspberrypi3-64"
