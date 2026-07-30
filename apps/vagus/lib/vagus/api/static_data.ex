defmodule Vagus.API.StaticData do
  @moduledoc """
  Static (Phase 2) response data for the Supervisor-API emulator.

  Every function here returns a plain attrs map ready to hand to the
  matching `Vagus.API.Models.*` `build!/1` — a clean seam: a later phase
  can replace any of these functions with a real backend behaviour without
  touching `Vagus.API.Router` or the model layer at all. `os_info/0`,
  `host_info/0`, and `network_info/0` have already been replaced this way
  (P4) — see `Vagus.Backend` and `Vagus.Backend.{OS,Host,Network}` — so
  this module no longer defines them.

  Values follow the static defaults pinned in the Phase 2 plan: `healthy:
  true`, `supported: true`, `arch: "aarch64"`, `state: "running"`,
  `channel: "stable"`, Supervisor version
  `"2026.07.3"`, Core version `"2026.7.2"` (`docs/contract-2026.7.md`,
  header). Fields the emulator has no real data for (and that the wire
  format allows to be `null`) are left `nil`; idle list-type fields are
  `[]`, never `nil`.

  `machine` is the one board-varying value here and is read from config
  (`config :vagus, :machine`) rather than pinned — `"raspberrypi3-64"` on
  rpi3_64, `"generic-aarch64"` on dragon_q6a.

  `arch/0` and `machine/0` are public (not just used internally by
  `root_info/0`/`core_info/0`) because `Vagus.Addon.Availability` (phase 6
  chunk A, audit G1) needs this device's own facts to decide whether an
  add-on can run here at all — the single source both call sites read from,
  so a store card and `/info` can never disagree about what device this is.
  """

  @supervisor_version "2026.07.3"
  @core_version "2026.7.2"
  @arch "aarch64"

  @doc "This device's emulated CPU architecture. See the moduledoc."
  @spec arch() :: String.t()
  def arch, do: @arch

  # The board identity, read at runtime (not a compile-time attribute) so
  # each target — and :host/:test — sets it independently in config. See
  # config/rpi3_64.exs ("raspberrypi3-64") and config/dragon_q6a.exs
  # ("generic-aarch64"); both values are real HAOS machines, which matters
  # because Supervisor validates add-on `machine:` allowlists against a
  # fixed regex.
  #
  # `fetch_env!/2`, deliberately: there is NO default. A defaulted read would
  # let a new board that forgets `config :vagus, :machine` silently report
  # some other board's identity to Core — the exact failure this indirection
  # exists to prevent. Every config path that can reach this code
  # (rpi3_64, dragon_q6a, host, test) sets the key, so raising here means a
  # genuine misconfiguration, not a missing convenience.
  @doc "This device's board/machine identity. See the moduledoc."
  @spec machine() :: String.t()
  def machine, do: Application.fetch_env!(:vagus, :machine)

  @doc """
  Attrs for `Vagus.API.Models.RootInfo` (`GET info`).

  `hassos` must be non-null: Core's `system_info` helper classifies the
  installation as "Home Assistant OS" only when it is (observed on device
  2026-07-20 — `nil` here made Core raise the deprecated-"Supervised"-
  installation repair issue). We report the OS backend's firmware version,
  which is the honest HAOS-role equivalent on this appliance.
  """
  @spec root_info() :: map()
  def root_info do
    os_info = Vagus.Backend.os().info()

    %{
      supervisor: @supervisor_version,
      homeassistant: @core_version,
      hassos: os_info[:version],
      docker: "24.0.7",
      hostname: hostname(),
      operating_system: "Vagus OS #{os_info[:version]}",
      features: [],
      machine: machine(),
      machine_id: nil,
      arch: @arch,
      state: "running",
      supported_arch: [@arch],
      supported: true,
      channel: "stable",
      logging: "info",
      timezone: "UTC"
    }
  end

  defp hostname do
    {:ok, hostname} = :inet.gethostname()
    to_string(hostname)
  end

  @doc """
  The emulated Supervisor version — the one claim the whole wire agrees on
  (`/info`, `/supervisor/info`, and since phase 4 every `backup.json`'s
  `supervisor_version`). Public so `Vagus.Backups` reads THIS constant
  rather than duplicating it: a restoring HAOS compares the tar's value
  against its own Supervisor with AwesomeVersion, so it must be a real
  version string, and it should be the same version the API reports.
  """
  @spec supervisor_version() :: String.t()
  def supervisor_version, do: @supervisor_version

  @doc "Attrs for `Vagus.API.Models.SupervisorInfo` (`GET supervisor/info`)."
  @spec supervisor_info() :: map()
  def supervisor_info do
    %{
      version: @supervisor_version,
      version_latest: nil,
      update_available: false,
      channel: "stable",
      arch: @arch,
      supported: true,
      healthy: true,
      ip_address: "127.0.0.1",
      timezone: nil,
      logging: "info",
      debug: false,
      debug_block: false,
      diagnostics: nil,
      auto_update: true,
      country: nil,
      detect_blocking_io: false,
      feature_flags: %{}
    }
  end

  @doc "Attrs for `Vagus.API.Models.HomeAssistantInfo` (`GET core/info`)."
  @spec core_info() :: map()
  def core_info do
    %{
      version: @core_version,
      version_latest: nil,
      update_available: false,
      machine: machine(),
      ip_address: "127.0.0.1",
      arch: @arch,
      image: "ghcr.io/home-assistant/home-assistant",
      boot: true,
      port: 8123,
      ssl: false,
      watchdog: true,
      audio_input: nil,
      audio_output: nil,
      backups_exclude_database: false,
      duplicate_log_file: false
    }
  end

  @doc "Attrs for `Vagus.API.Models.ResolutionInfo` (`GET resolution/info`)."
  @spec resolution_info() :: map()
  def resolution_info do
    %{
      suggestions: [],
      unsupported: [],
      unhealthy: [],
      issues: [],
      checks: []
    }
  end

  @doc "Attrs for `Vagus.API.Models.AddonsList` (`GET addons`)."
  @spec addons_list() :: map()
  def addons_list do
    %{addons: []}
  end

  @doc """
  Attrs for `Vagus.API.Models.CoreStats`, shared by `GET core/stats` and
  `GET supervisor/stats`.
  """
  @spec core_stats() :: map()
  def core_stats do
    %{
      cpu_percent: 0.0,
      memory_usage: 0,
      memory_limit: 536_870_912,
      memory_percent: 0.0,
      network_rx: 0,
      network_tx: 0,
      blk_read: 0,
      blk_write: 0
    }
  end

  @doc "Attrs for `Vagus.API.Models.StoreInfo` (`GET store`)."
  @spec store_info() :: map()
  def store_info do
    %{addons: [], repositories: []}
  end

  @doc "Attrs for `Vagus.API.Models.MountsInfo` (`GET mounts`)."
  @spec mounts_info() :: map()
  def mounts_info do
    %{default_backup_mount: nil, mounts: []}
  end

  @doc "Attrs for `Vagus.API.Models.AvailableUpdates` (`GET available_updates`)."
  @spec available_updates() :: map()
  def available_updates do
    %{available_updates: []}
  end
end
