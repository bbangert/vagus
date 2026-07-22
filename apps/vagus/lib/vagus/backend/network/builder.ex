defmodule Vagus.Backend.Network.Builder do
  @moduledoc """
  Pure translation from `vintage_net`-shaped interface properties to
  `Vagus.API.Models.NetworkInterface` attrs (`docs/contract-2026.7.md`
  §15). No `VintageNet`/`Nerves` calls anywhere in this module — every
  function is a plain data transform, unit-testable on `:host` against
  captured property fixtures, and shared by `Vagus.Backend.Network.VintageNet`
  (which supplies real reads) as the one place the wire-shape translation
  logic actually lives.

  The expected `props` map (assembled by the caller from
  `VintageNet.get/2`/`get_by_prefix/1` reads) has the keys:

    * `:connection` — `:internet | :lan | :disconnected`
      (`["interface", ifname, "connection"]`)
    * `:mac_address` — `String.t()` (`["interface", ifname, "mac_address"]`)
    * `:addresses` — list of `%{address: :inet.ip_address(), prefix_length:
      non_neg_integer(), family: :inet | :inet6}`
      (`["interface", ifname, "addresses"]`)
    * `:config` — the raw `vintage_net` interface config map, e.g.
      `%{ipv4: %{method: :dhcp}}` or `%{ipv4: %{method: :static, ...},
      vintage_net_wifi: %{networks: [%{ssid: ...}]}}`
      (`["interface", ifname, "config"]`)
    * `:nameservers` — the raw aggregate `["name_servers"]` property
      (shared across interfaces — `vintage_net` doesn't track per-interface
      DNS servers), unnormalized: entries are `%{address: ip_tuple, from:
      [...]}` maps on-device (verified 2026-07-20), but `build_ipv4/1`
      also tolerates bare address tuples/strings and drops anything else
    * `:wifi_signal` — signal reading for the currently-associated AP (or
      `nil`), for `wlan*` interfaces only
  """

  @doc """
  Builds `NetworkInterface` attrs for `ifname` from its `props` and the
  aggregate `best_connection` (`["connection"]`) — used to decide
  `primary`.
  """
  @spec build_interface(String.t(), map(), atom()) :: map()
  def build_interface(ifname, props, best_connection) do
    connection = Map.get(props, :connection, :disconnected)

    %{
      interface: ifname,
      type: interface_type(ifname),
      enabled: true,
      connected: connection in [:lan, :internet],
      primary: connection != :disconnected and connection == best_connection,
      mac: Map.get(props, :mac_address, ""),
      ipv4: build_ipv4(props),
      ipv6: build_ipv6(props),
      wifi: build_wifi(ifname, props),
      vlan: nil,
      mdns: nil,
      llmnr: nil
    }
  end

  @doc ~S(`"ethernet"` or `"wireless"`, by `vintage_net`'s interface naming convention.)
  @spec interface_type(String.t()) :: String.t()
  def interface_type(ifname) do
    if String.starts_with?(ifname, "wlan"), do: "wireless", else: "ethernet"
  end

  @doc """
  The `IPv4` attrs, or `nil` if the interface is explicitly configured
  `method: :disabled`.
  """
  @spec build_ipv4(map()) :: map() | nil
  def build_ipv4(props) do
    case get_in(props, [:config, :ipv4, :method]) do
      :disabled ->
        nil

      method ->
        addresses = addresses_for_family(props, :inet)

        nameservers =
          props
          |> Map.get(:nameservers, [])
          |> Enum.map(&normalize_nameserver/1)
          |> Enum.filter(&ipv4_string?/1)

        %{
          method: wire_method(method || :dhcp),
          ready: Map.get(props, :connection, :disconnected) != :disconnected,
          address: Enum.map(addresses, &format_cidr/1),
          nameservers: nameservers,
          gateway: format_optional_address(get_in(props, [:config, :ipv4, :gateway])),
          route_metric: nil
        }
    end
  end

  # The contract's InterfaceMethod enum is disabled/static/auto (§15) —
  # vintage_net's `:dhcp` maps to the wire's `"auto"`.
  defp wire_method(:dhcp), do: "auto"
  defp wire_method(method), do: to_string(method)

  # `["name_servers"]` entries are `%{address: ip_tuple, from: [...]}` maps
  # on-device (verified 2026-07-20); also tolerate a bare address
  # tuple/string directly, and drop (-> nil) anything else rather than
  # crash on an unrecognized shape.
  defp normalize_nameserver(%{address: address}), do: normalize_nameserver(address)

  defp normalize_nameserver(address) when tuple_size(address) in [4, 8] do
    address |> :inet.ntoa() |> to_string()
  end

  defp normalize_nameserver(address) when is_binary(address), do: address
  defp normalize_nameserver(_other), do: nil

  defp ipv4_string?(address) when is_binary(address), do: not String.contains?(address, ":")
  defp ipv4_string?(_other), do: false

  defp format_optional_address(nil), do: nil
  defp format_optional_address(address), do: format_address(address)

  @doc """
  The `IPv6` attrs, or `nil` when the interface has no `:inet6` address —
  minimal-honest: this emulator doesn't track real SLAAC/privacy-extension
  state, so `addr_gen_mode`/`ip6_privacy` are fixed, documented defaults
  rather than genuinely-read values.
  """
  @spec build_ipv6(map()) :: map() | nil
  def build_ipv6(props) do
    case addresses_for_family(props, :inet6) do
      [] ->
        nil

      addresses ->
        %{
          method: "auto",
          ready: Map.get(props, :connection, :disconnected) != :disconnected,
          address: Enum.map(addresses, &format_cidr/1),
          nameservers: [],
          gateway: nil,
          route_metric: nil,
          addr_gen_mode: "eui64",
          ip6_privacy: "default"
        }
    end
  end

  @doc """
  The `Wifi` attrs for `wlan*` interfaces with a configured SSID, else
  `nil` (including for non-wireless interfaces).
  """
  @spec build_wifi(String.t(), map()) :: map() | nil
  def build_wifi(ifname, props) do
    if String.starts_with?(ifname, "wlan") do
      case get_in(props, [:config, :vintage_net_wifi, :networks]) do
        [%{ssid: ssid} | _rest] ->
          %{
            mode: "infrastructure",
            auth: "wpa-psk",
            ssid: ssid,
            signal: Map.get(props, :wifi_signal)
          }

        _no_configured_network ->
          nil
      end
    end
  end

  defp addresses_for_family(props, family) do
    props
    |> Map.get(:addresses, [])
    |> Enum.filter(&(Map.get(&1, :family) == family))
  end

  defp format_cidr(%{address: address, prefix_length: prefix_length}) do
    "#{format_address(address)}/#{prefix_length}"
  end

  defp format_address(address) when is_tuple(address) do
    address |> :inet.ntoa() |> to_string()
  end

  defp format_address(address) when is_binary(address), do: address
end
