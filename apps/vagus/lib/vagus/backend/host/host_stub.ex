defmodule Vagus.Backend.Host.HostStub do
  @moduledoc """
  Host-dev `Vagus.Backend.Host`: real hostname + a real `df` of the dev
  machine's own filesystem (there's no `/data` mount on a dev box, so the
  current working directory's filesystem is the honest stand-in) is
  plausible enough for local development; every other `HostInfo` field
  this emulator doesn't track stays `nil` per contract §14.
  `reboot/0`/`shutdown/0` never touch the dev machine — they just log.
  """

  @behaviour Vagus.Backend.Host

  require Logger

  alias Vagus.Backend.Host.DiskUsage

  @features ["reboot", "shutdown", "network"]

  @impl true
  def info do
    {free, total, used} = DiskUsage.usage_gb(".")

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
      kernel: nil,
      operating_system: nil,
      timezone: nil,
      dt_utc: nil,
      dt_synchronized: nil,
      use_ntp: nil,
      startup_time: nil,
      boot_timestamp: nil,
      broadcast_llmnr: nil,
      broadcast_mdns: nil
    }
  end

  @impl true
  def reboot do
    Logger.warning("Vagus.Backend.Host.HostStub: reboot requested (no-op on :host)")
    :ok
  end

  @impl true
  def shutdown do
    Logger.warning("Vagus.Backend.Host.HostStub: shutdown requested (no-op on :host)")
    :ok
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      {:error, _reason} -> nil
    end
  end
end
