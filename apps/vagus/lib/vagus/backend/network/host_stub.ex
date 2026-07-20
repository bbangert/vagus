defmodule Vagus.Backend.Network.HostStub do
  @moduledoc """
  Host-dev `Vagus.Backend.Network`: one static, fully
  `NetworkInterface`-conformant `"eth-host"` ethernet interface —
  deliberately not named `"eth0"` (nothing on a dev host really is a
  network interface by that name); the distinct name makes it obvious in
  logs/tests that this is the emulator's stand-in, not a real device
  read. `access_points/1` and `configure/2` apply the same honest
  validation the real `Vagus.Backend.Network.VintageNet` backend does
  (wireless-only for scans, whitelisted fields for configure) even though
  this backend has no real hardware behind either — a dev/test caller
  gets the same error shapes it would against a real device.
  """

  @behaviour Vagus.Backend.Network

  require Logger

  @configurable_fields ~w(ipv4 wifi)

  @impl true
  def info do
    %{
      interfaces: [interface()],
      docker: docker_network(),
      host_internet: true,
      supervisor_internet: true
    }
  end

  @impl true
  def interface_info("eth-host"), do: {:ok, interface()}
  def interface_info(ifname), do: {:error, "interface #{ifname} not found"}

  @impl true
  def access_points(ifname) do
    if String.starts_with?(ifname, "wlan") do
      {:ok, []}
    else
      {:error, "#{ifname} is not a wireless interface"}
    end
  end

  @impl true
  def configure(ifname, params) do
    unsupported = params |> Map.keys() |> Enum.reject(&(&1 in @configurable_fields))

    if unsupported == [] do
      Logger.info(
        "Vagus.Backend.Network.HostStub: configure(#{ifname}, #{inspect(redact(params))}) — " <>
          "no-op on :host"
      )

      :ok
    else
      {:error, "unsupported field(s): #{Enum.join(unsupported, ", ")}"}
    end
  end

  # `params["wifi"]["psk"]` is the wifi network password - never let it
  # reach the log verbatim.
  defp redact(%{"wifi" => %{"psk" => _psk} = wifi} = params) do
    %{params | "wifi" => Map.put(wifi, "psk", "[redacted]")}
  end

  defp redact(params), do: params

  defp interface do
    %{
      interface: "eth-host",
      type: "ethernet",
      enabled: true,
      connected: true,
      primary: true,
      mac: "02:00:00:00:00:01",
      ipv4: %{
        method: "static",
        ready: true,
        address: ["192.168.1.50/24"],
        nameservers: ["1.1.1.1", "8.8.8.8"],
        gateway: "192.168.1.1",
        route_metric: nil
      },
      ipv6: nil,
      wifi: nil,
      vlan: nil,
      mdns: nil,
      llmnr: nil
    }
  end

  defp docker_network do
    %{
      interface: "docker0",
      address: "172.30.32.0/23",
      gateway: "172.30.32.1",
      dns: "172.30.32.1"
    }
  end
end
