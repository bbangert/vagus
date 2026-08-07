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
# Core to call INTO). Real Home Assistant OS installs run Core and
# Supervisor on the same host-networked machine, so localhost:8123 is
# correct on both host and target (contract §5 auth exchange, §4 WS URL).
#
# `VAGUS_CORE_BASE_URL` env override for the host dev loop: when
# `scripts/dev-core.sh` publishes Core on a non-8123 host port (its
# `HOST_PORT`, e.g. to dodge a host 8123 collision), the emulator must dial
# that port instead. `mix run` re-evaluates this file per invocation, so the
# env var is read at emulator boot; dev-core.sh prints the exact export to
# use. Unset → the correct default for real HAOS (Core host-networked on 8123).
config :vagus,
       :core_base_url,
       System.get_env("VAGUS_CORE_BASE_URL") || "http://localhost:8123"

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
