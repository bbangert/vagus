defmodule Vagus.Backend.Host.Nerves do
  @moduledoc """
  Target `Vagus.Backend.Host` for real Nerves hardware: hostname via
  `:inet.gethostname/0`, disk usage via `df -k /data`
  (`Vagus.Backend.Host.DiskUsage`, shared with `Vagus.Backend.Host.HostStub`),
  kernel via `/proc/sys/kernel/osrelease`, `operating_system` via
  `/etc/os-release`, and `reboot/0`/`shutdown/0` via `Vagus.Host.Shutdown`,
  which gracefully stops Core + add-on containers first, then delegates to
  `Nerves.Runtime`.

  `kernel/0` originally shelled out to `uname -r`, matching HAOS. The
  Nerves rootfs ships no `uname` binary, so that call always failed and
  `kernel` was silently `nil` on every real device. The kernel already
  publishes its own release string at `/proc/sys/kernel/osrelease` (a
  plain `"7.1.4\\n"`-shaped file) — reading it directly needs no shelled
  command and works unconditionally.

  `operating_system/0` originally looked only for `PRETTY_NAME` in
  `/etc/os-release`, matching HAOS. Nerves' `/etc/os-release` has no
  `PRETTY_NAME` — it's Buildroot-generated and instead carries `NAME`,
  `NERVES_SYSTEM_NAME`, and `NERVES_SYSTEM_VERSION` (among other
  Nerves-specific keys). `PRETTY_NAME` is still preferred when present
  (e.g. a non-Nerves `:host` build's real os-release); otherwise the
  three Nerves keys are composed, in that order, space-joined — e.g.
  `"Nerves dragon_q6a 0.2.0"`. No `NAME` at all (an unreadable or
  unrecognized file) stays honest-`nil` rather than fabricating a label.

  No `Mix.target()` compile guard needed: every function used here
  (`Nerves.Runtime`, `File.read/1`, `:inet.gethostname/0`,
  `:erlang.statistics/1`) is available on `:host` too — this module is
  simply never *selected*
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

  @osrelease_path "/proc/sys/kernel/osrelease"
  @os_release_path "/etc/os-release"

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
    Vagus.Host.Shutdown.reboot()
    :ok
  end

  @impl true
  def shutdown do
    Logger.warning("Vagus.Backend.Host.Nerves: shutdown requested")
    Vagus.Host.Shutdown.poweroff()
    :ok
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      {:error, _reason} -> nil
    end
  end

  # Public + @doc false (not @impl, not part of the Host behaviour) so
  # tests can point these at fixture files instead of real system paths.
  #
  # `path` is never request input — `info/0` always calls these with the
  # compile-time default; the argument exists only for test fixtures.
  # sobelow_skip ["Traversal.FileModule"]
  @doc false
  def kernel(path \\ @osrelease_path) do
    case File.read(path) do
      {:ok, contents} -> String.trim(contents)
      {:error, _reason} -> nil
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  @doc false
  def operating_system(path \\ @os_release_path) do
    case File.read(path) do
      {:ok, contents} -> parse_os_release(contents)
      {:error, _reason} -> nil
    end
  end

  defp parse_os_release(contents) do
    fields =
      contents
      |> String.split("\n", trim: true)
      # trim: tolerates CRLF line endings (a trailing \r would otherwise
      # ride on every value) and stray indentation before a key.
      |> Enum.map(&String.trim/1)
      |> Enum.flat_map(fn line ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> [{key, String.trim(value, "\"")}]
          _other -> []
        end
      end)
      |> Map.new()

    case fields do
      %{"PRETTY_NAME" => pretty_name} ->
        pretty_name

      %{"NAME" => _name} ->
        ["NAME", "NERVES_SYSTEM_NAME", "NERVES_SYSTEM_VERSION"]
        |> Enum.flat_map(fn key -> List.wrap(fields[key]) end)
        |> Enum.join(" ")

      _no_name ->
        nil
    end
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
