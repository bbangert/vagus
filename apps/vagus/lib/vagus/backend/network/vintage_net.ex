defmodule Vagus.Backend.Network.VintageNet do
  @moduledoc """
  Target-only `Vagus.Backend.Network`, backed by real `vintage_net`
  property reads.

  `vintage_net` is a target-scoped-only dependency
  (`apps/vagus/mix.exs`, `targets: @all_targets` — every Nerves board, but
  no `:host`) — it is genuinely absent
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

    alias Vagus.Backend.Network.{Builder, WireConfig}

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
      with {:ok, resolved} <- resolve_ifname(ifname) do
        best_connection = VintageNet.get(["connection"], :disconnected)
        {:ok, Builder.build_interface(resolved, interface_properties(resolved), best_connection)}
      end
    end

    @impl true
    def access_points(ifname) do
      # Resolution (404) happens BEFORE the wireless check — an unknown
      # name is "this interface doesn't exist", not "it's not wireless".
      with {:ok, resolved} <- resolve_ifname(ifname) do
        if String.starts_with?(resolved, "wlan") do
          {:ok, scan_access_points(resolved)}
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
        apply_fragments(resolved, fragments)
      end
    end

    # `VintageNetEthernet.normalize/1` passes a foreign `vintage_net_wifi`
    # key straight through into the persisted `source_config` (only the
    # wireless stack hashes `psk` via `WPA2.to_psk/2` first) — a wifi
    # fragment applied to a non-wireless interface would land the
    # plaintext psk on flash and in the property table. Refuse before
    # anything is built/applied, mirroring `access_points/1`'s check.
    defp check_wireless(_resolved, nil), do: :ok

    defp check_wireless(resolved, _wifi_fragment) do
      if String.starts_with?(resolved, "wlan") do
        :ok
      else
        {:error, "#{resolved} is not a wireless interface"}
      end
    end

    # Nothing derived changed (params validated but had nothing this
    # backend can act on, e.g. `%{"enabled" => true}` alone) — skip the
    # `VintageNet.configure` call entirely rather than needlessly bounce
    # the link by re-applying an unchanged config (the D3-empty-body
    # cousin: a no-op body must be a no-op action, not a reconnect).
    defp apply_fragments(_ifname, %{ipv4: nil, wifi: nil}), do: :ok

    defp apply_fragments(ifname, fragments) do
      merged =
        ifname
        |> current_config()
        |> maybe_put_ipv4(fragments.ipv4)
        |> maybe_put_wifi(fragments.wifi)

      case VintageNet.configure(ifname, merged) do
        :ok -> :ok
        {:error, reason} -> {:error, inspect(reason)}
      end
    end

    defp maybe_put_ipv4(config, nil), do: config
    defp maybe_put_ipv4(config, ipv4_fragment), do: Map.put(config, :ipv4, ipv4_fragment)

    defp maybe_put_wifi(config, nil), do: config

    defp maybe_put_wifi(config, wifi_fragment),
      do: Map.put(config, :vintage_net_wifi, %{networks: [wifi_fragment]})

    # `"default"` (case-insensitive) resolves to the primary interface —
    # the same rule `Builder.build_interface/3` uses to set `primary`:
    # connected (not `:disconnected`) and matching the aggregate
    # `["connection"]` value. Kept consistent with that function
    # deliberately, since both answer "which interface is the box's main
    # one" from the same underlying `vintage_net` state.
    defp resolve_ifname(ifname) do
      if String.downcase(ifname) == "default" do
        case primary_interface() do
          nil -> {:error, :not_found}
          primary -> {:ok, primary}
        end
      else
        if ifname in configured_interfaces() do
          {:ok, ifname}
        else
          {:error, :not_found}
        end
      end
    end

    defp primary_interface do
      best_connection = VintageNet.get(["connection"], :disconnected)

      Enum.find(configured_interfaces(), fn ifname ->
        connection = VintageNet.get(["interface", ifname, "connection"], :disconnected)
        connection != :disconnected and connection == best_connection
      end)
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

    defp current_config(ifname) do
      case VintageNet.get(["interface", ifname, "config"], %{}) do
        %{} = config -> config
        _other -> %{}
      end
    end
  end
end
