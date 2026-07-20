defmodule Vagus.Backend.OS.Nerves do
  @moduledoc """
  Target `Vagus.Backend.OS` for real Nerves/fwup hardware. Firmware
  version/board/boot-slot data comes from `Nerves.Runtime.KV`
  (`Vagus.Backend.OS.FirmwareKV`, shared with `Vagus.Backend.OS.HostStub`
  — identical mechanism, InMemory-backed on `:host` vs. UBoot-env-backed
  here). `data_disk` is read from `/proc/mounts` for the real `/data`
  mountpoint's device.

  No `Mix.target()` compile guard needed here: `nerves_runtime` is a
  regular (non target-scoped) dependency, present on `:host` too
  (`apps/vagus/mix.exs`) — this module compiles cleanly everywhere, it's
  simply never *selected* on `:host` (`config/host.exs`'s `:backends`
  points at `Vagus.Backend.OS.HostStub` instead). Compare
  `Vagus.Backend.Network.VintageNet`, which DOES need a guard, since
  `vintage_net` is target-scoped and genuinely absent from the `:host`
  build.
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
      data_disk: data_disk_device(),
      boot_slots: FirmwareKV.boot_slots()
    }
  end

  @impl true
  def datadisk_list, do: []

  defp data_disk_device do
    case File.read("/proc/mounts") do
      {:ok, contents} -> find_data_mount(contents)
      {:error, _reason} -> nil
    end
  end

  # Nerves mounts the application partition at `/root` with `/data` as a
  # symlink to it (verified on nerves_system_vagus 2026-07-20 — /proc/mounts
  # has no `/data` entry); newer systems mount `/data` directly. Prefer the
  # `/data` entry, fall back to `/root`.
  defp find_data_mount(contents) do
    lines = String.split(contents, "\n", trim: true)

    Enum.find_value(["/data", "/root"], fn mountpoint ->
      Enum.find_value(lines, fn line ->
        case String.split(line, " ") do
          [device, ^mountpoint | _rest] -> device
          _other -> nil
        end
      end)
    end)
  end
end
