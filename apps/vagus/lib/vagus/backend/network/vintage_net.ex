defmodule Vagus.Backend.Network.VintageNet do
  @moduledoc """
  Target-only `Vagus.Backend.Network`, backed by real `vintage_net`
  property reads.

  `vintage_net` is a target-scoped-only dependency
  (`apps/vagus/mix.exs`, `targets: [:rpi3_64]`) — it is genuinely absent
  from the `:host` build, so every `VintageNet.*` reference below must
  never reach the compiler when `Mix.target() == :host` (an "undefined
  remote function" warning, fatal under `--warnings-as-errors`). The
  whole module body is wrapped in a compile-time `if Mix.target() !=
  :host do ... end` — since `Mix.target()` resolves at compile time, the
  untaken branch's `defp`/`def` calls (themselves compile-time,
  side-effecting registrations of function clauses on this module) never
  execute on `:host`, leaving this module an empty shell there (no
  functions, no `@behaviour` declaration — so no "missing callback"
  warnings either). Same pattern `Vagus.Engine.Manager` uses for its own
  `VintageNet` references, just applied to the whole module instead of
  per-function, since every function here touches `VintageNet`.

  Never selected on `:host` regardless (`config/host.exs`'s `:backends`
  points at `Vagus.Backend.Network.HostStub`) — this guard is strictly a
  compile-safety measure, not the actual runtime selection mechanism.

  All wire-shape translation (property map -> `NetworkInterface` attrs)
  lives in `Vagus.Backend.Network.Builder`, a plain-data module with no
  `VintageNet` dependency of its own — this module's job is only to read
  properties and hand them to `Builder` in the shape it expects.
  """

  if Mix.target() != :host do
    @behaviour Vagus.Backend.Network

    alias Vagus.Backend.Network.Builder

    @docker_network %{
      interface: "docker0",
      address: "172.30.32.0/23",
      gateway: "172.30.32.1",
      dns: "172.30.32.1"
    }

    @impl true
    def info do
      best_connection = VintageNet.get(["connection"], :disconnected)

      interfaces =
        Enum.map(configured_interfaces(), fn ifname ->
          Builder.build_interface(ifname, interface_properties(ifname), best_connection)
        end)

      %{
        interfaces: interfaces,
        docker: @docker_network,
        host_internet: best_connection == :internet,
        supervisor_internet: true
      }
    end

    @impl true
    def interface_info(ifname) do
      if ifname in configured_interfaces() do
        best_connection = VintageNet.get(["connection"], :disconnected)
        {:ok, Builder.build_interface(ifname, interface_properties(ifname), best_connection)}
      else
        {:error, "interface #{ifname} not found"}
      end
    end

    @impl true
    def access_points(ifname) do
      cond do
        not String.starts_with?(ifname, "wlan") ->
          {:error, "#{ifname} is not a wireless interface"}

        ifname not in configured_interfaces() ->
          {:error, "interface #{ifname} not found"}

        true ->
          {:ok, scan_access_points(ifname)}
      end
    end

    @impl true
    def configure(ifname, params) do
      unsupported = params |> Map.keys() |> Enum.reject(&(&1 in ~w(ipv4 wifi)))

      cond do
        unsupported != [] ->
          {:error, "unsupported field(s): #{Enum.join(unsupported, ", ")}"}

        ifname not in configured_interfaces() ->
          {:error, "interface #{ifname} not found"}

        true ->
          case VintageNet.configure(ifname, build_config(ifname, params)) do
            :ok -> :ok
            {:error, reason} -> {:error, inspect(reason)}
          end
      end
    end

    defp configured_interfaces, do: VintageNet.configured_interfaces()

    defp interface_properties(ifname) do
      %{
        connection: VintageNet.get(["interface", ifname, "connection"], :disconnected),
        mac_address: VintageNet.get(["interface", ifname, "mac_address"], ""),
        addresses: VintageNet.get(["interface", ifname, "addresses"], []),
        config: VintageNet.get(["interface", ifname, "config"], %{}),
        nameservers: name_servers(),
        wifi_signal: VintageNet.get(["interface", ifname, "wifi", "rssi"], nil)
      }
    end

    # Raw `["name_servers"]` entries, unnormalized — `Builder.build_ipv4/1`
    # does the `%{address: ...}`/tuple/string normalization (see its
    # moduledoc for the on-device shape), since that's the pure,
    # host-tested seam for wire-shape translation.
    defp name_servers, do: VintageNet.get(["name_servers"], [])

    defp scan_access_points(ifname) do
      ["interface", ifname, "wifi", "access_points"]
      |> VintageNet.get([])
      |> Enum.map(fn ap ->
        %{
          mode: "infrastructure",
          ssid: Map.get(ap, :ssid, ""),
          frequency: Map.get(ap, :frequency, 0),
          signal: Map.get(ap, :signal_percent, 0),
          mac: Map.get(ap, :bssid, "")
        }
      end)
    end

    defp build_config(ifname, params) do
      ifname
      |> current_config()
      |> put_ipv4(params["ipv4"])
      |> put_wifi(params["wifi"])
    end

    defp current_config(ifname) do
      case VintageNet.get(["interface", ifname, "config"], %{}) do
        %{} = config -> config
        _other -> %{}
      end
    end

    defp put_ipv4(config, nil), do: config
    defp put_ipv4(config, %{"method" => "dhcp"}), do: Map.put(config, :ipv4, %{method: :dhcp})

    defp put_ipv4(config, %{"method" => "static"} = ipv4) do
      Map.put(config, :ipv4, %{
        method: :static,
        address: Map.get(ipv4, "address"),
        prefix_length: Map.get(ipv4, "prefix_length"),
        gateway: Map.get(ipv4, "gateway")
      })
    end

    defp put_wifi(config, nil), do: config

    defp put_wifi(config, %{"ssid" => ssid, "psk" => psk}) do
      Map.put(config, :vintage_net_wifi, %{
        networks: [%{ssid: ssid, psk: psk, key_mgmt: :wpa_psk}]
      })
    end
  end
end
