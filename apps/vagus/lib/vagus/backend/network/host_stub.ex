defmodule Vagus.Backend.Network.HostStub do
  @moduledoc """
  Host-dev `Vagus.Backend.Network`: one static, fully
  `NetworkInterface`-conformant `"eth-host"` ethernet interface —
  deliberately not named `"eth0"` (nothing on a dev host really is a
  network interface by that name); the distinct name makes it obvious in
  logs/tests that this is the emulator's stand-in, not a real device
  read. `"eth-host"` is also this stub's only, and therefore primary,
  interface, so `"default"`/`"DEFAULT"` (case-insensitive) resolves to
  it. `access_points/1` and `configure/2` apply the same honest
  validation the real `Vagus.Backend.Network.VintageNet` backend does
  (interface resolution before the wireless check, full
  `Vagus.Backend.Network.WireConfig` body validation) even though this
  backend has no real hardware behind either — a dev/test caller gets the
  same error shapes it would against a real device. `configure/2` never
  actually applies anything (no `vintage_net` to apply to) — it validates
  and logs, then no-ops.
  """

  @behaviour Vagus.Backend.Network

  require Logger

  alias Vagus.Backend.Network.WireConfig

  @impl true
  def info do
    %{
      interfaces: [interface()],
      docker: docker_network(),
      host_internet: true,
      supervisor_internet: true
    }
  end

  @spec interface_info(String.t()) :: {:ok, map()} | {:error, :not_found | String.t()}
  @impl true
  def interface_info(ifname) do
    with {:ok, _resolved} <- resolve_ifname(ifname) do
      {:ok, interface()}
    end
  end

  @spec access_points(String.t()) :: {:ok, [map()]} | {:error, :not_found | String.t()}
  @impl true
  def access_points(ifname) do
    with {:ok, resolved} <- resolve_ifname(ifname) do
      # `resolved` is always `"eth-host"` in practice (this stub's only
      # interface, not wireless) — the `String.starts_with?/2` check below
      # is dead at runtime, but it keeps this function's static return
      # type genuinely `{:ok, _} | {:error, _}` rather than
      # unconditionally erroring. A body that always errors makes the
      # compiler's type checker treat this whole function's result as an
      # error-only type FOR THIS COMPILE-TIME-SELECTED BACKEND, which
      # would then flag `Vagus.API.Router`'s generic `{:ok, ...}` clause
      # (needed for the real `Vagus.Backend.Network.VintageNet` backend,
      # which genuinely can return access points) as unreachable dead
      # code under `--warnings-as-errors` on a `:host` build. Same
      # reasoning as `Vagus.Engine.Manager`'s `Mix.target()` split.
      if String.starts_with?(resolved, "wlan") do
        {:ok, []}
      else
        {:error, "#{resolved} is not a wireless interface"}
      end
    end
  end

  @impl true
  def configure(ifname, params) do
    with {:ok, resolved} <- resolve_ifname(ifname),
         {:ok, fragments} <- WireConfig.translate(params),
         :ok <- check_wireless(resolved, fragments.wifi) do
      Logger.info(
        "Vagus.Backend.Network.HostStub: configure(#{resolved}, #{inspect(redact(params))}) — " <>
          "no-op on :host"
      )

      :ok
    end
  end

  # eth-host is never wireless — mirrors the real `VintageNet` backend's
  # check (and the wire reason: `VintageNetEthernet.normalize/1` would
  # otherwise pass a foreign `vintage_net_wifi` key, plaintext psk
  # included, straight into the persisted config on a real target) so
  # dev/test callers see identical semantics.
  defp check_wireless(_resolved, nil), do: :ok

  defp check_wireless(resolved, _wifi_fragment) do
    if String.starts_with?(resolved, "wlan") do
      :ok
    else
      {:error, "#{resolved} is not a wireless interface"}
    end
  end

  # Only interface is "eth-host" (also the primary, so "default"
  # resolves to it too); anything else is an honest 404.
  defp resolve_ifname(ifname) do
    if ifname == "eth-host" or String.downcase(ifname) == "default" do
      {:ok, "eth-host"}
    else
      {:error, :not_found}
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
