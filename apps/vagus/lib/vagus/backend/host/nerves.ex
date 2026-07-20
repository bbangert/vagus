defmodule Vagus.Backend.Host.Nerves do
  @moduledoc """
  Target `Vagus.Backend.Host` for real Nerves hardware: hostname via
  `:inet.gethostname/0`, disk usage via `df -k /data`
  (`Vagus.Backend.Host.DiskUsage`, shared with `Vagus.Backend.Host.HostStub`),
  kernel via `uname -r`, `operating_system` via `/etc/os-release`'s
  `PRETTY_NAME`, and `reboot/0`/`shutdown/0` via `Nerves.Runtime`.

  No `Mix.target()` compile guard needed: every function used here
  (`Nerves.Runtime`, `System.cmd/2`, `File.read/1`, `:inet.gethostname/0`)
  is available on `:host` too — this module is simply never *selected*
  there (`config/host.exs` points at `Vagus.Backend.Host.HostStub`
  instead). Compare `Vagus.Backend.Network.VintageNet`, which DOES need a
  guard (its dependency, `vintage_net`, is target-scoped and genuinely
  absent from the `:host` build).

  `startup_time`/`boot_timestamp` are a best-effort approximation: this
  project doesn't separately track real OS boot-to-running duration (a
  genuine HAOS host derives `startup_time` from `systemd-analyze`); the
  BEAM node's own wall-clock uptime (`:erlang.statistics/1`) is the
  closest proxy available, and `boot_timestamp` is derived from it the
  same way (current time minus that uptime) — an approximation, not a
  real boot timestamp, flagged here since the contract doesn't specify
  the intended source.
  """

  @behaviour Vagus.Backend.Host

  require Logger

  alias Vagus.Backend.Host.DiskUsage

  @features ["reboot", "shutdown", "network"]

  @impl true
  def info do
    {free, total, used} = DiskUsage.usage_gb("/data")

    %{
      agent_version: nil,
      apparmor_version: nil,
      chassis: nil,
      virtualization: nil,
      cpe: nil,
      deployment: nil,
      disk_free: free,
      disk_total: total,
      disk_used: used,
      disk_life_time: nil,
      features: @features,
      hostname: hostname(),
      llmnr_hostname: nil,
      kernel: kernel(),
      operating_system: operating_system(),
      timezone: nil,
      dt_utc: nil,
      dt_synchronized: nil,
      use_ntp: nil,
      startup_time: startup_time(),
      boot_timestamp: boot_timestamp(),
      broadcast_llmnr: nil,
      broadcast_mdns: nil
    }
  end

  @impl true
  def reboot do
    Logger.warning("Vagus.Backend.Host.Nerves: reboot requested")
    Nerves.Runtime.reboot()
    :ok
  end

  @impl true
  def shutdown do
    Logger.warning("Vagus.Backend.Host.Nerves: shutdown requested")
    Nerves.Runtime.poweroff()
    :ok
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      {:error, _reason} -> nil
    end
  end

  defp kernel do
    case System.cmd("uname", ["-r"]) do
      {output, 0} -> String.trim(output)
      _error -> nil
    end
  rescue
    ErlangError -> nil
  end

  defp operating_system do
    case File.read("/etc/os-release") do
      {:ok, contents} -> parse_pretty_name(contents)
      {:error, _reason} -> nil
    end
  end

  defp parse_pretty_name(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn
      "PRETTY_NAME=" <> rest -> String.trim(rest, "\"")
      _other -> nil
    end)
  end

  defp startup_time do
    {uptime_ms, _wall_clock_diff} = :erlang.statistics(:wall_clock)
    uptime_ms / 1000
  end

  defp boot_timestamp do
    {uptime_ms, _wall_clock_diff} = :erlang.statistics(:wall_clock)
    System.os_time(:second) - div(uptime_ms, 1000)
  end
end
