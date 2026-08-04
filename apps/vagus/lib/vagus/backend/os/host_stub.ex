defmodule Vagus.Backend.OS.HostStub do
  @moduledoc """
  Host-dev `Vagus.Backend.OS`: reads the same `Nerves.Runtime.KV` the real
  target reads (`Vagus.Backend.OS.FirmwareKV`, InMemory-backed on `:host`
  per `config/host.exs`) so local dev shows plausible version/board/
  boot-slot data. `data_disk` and `datadisk_list/0` are honest-empty — a
  dev host has no `/data` device to report.
  """

  @behaviour Vagus.Backend.OS

  alias Vagus.Backend.OS.FirmwareKV

  @impl true
  def info do
    active = FirmwareKV.active_slot()
    version = FirmwareKV.version(active)

    %{
      version: version,
      version_latest: version,
      update_available: false,
      board: FirmwareKV.platform(active),
      boot: String.upcase(active),
      data_disk: nil,
      boot_slots: FirmwareKV.boot_slots()
    }
  end

  # Honest "latest = what's installed" — there is no update feed for a
  # dev host, and inventing one would sprout an update button that can't
  # work (same nil-safety stance as `Vagus.Version.update_available?/2`).
  @impl true
  def version_latest, do: FirmwareKV.version(FirmwareKV.active_slot())

  @impl true
  def update(_version), do: {:error, :not_supported}

  @impl true
  def datadisk_list, do: []
end
