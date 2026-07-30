defmodule Vagus.Backend.Network.WireConfig do
  @moduledoc """
  Pure translation from a `POST network/interface/:ifname/update` JSON
  body (already-parsed, string keys) to `vintage_net` config *fragments*
  — the counterpart of `Vagus.Backend.Network.Builder` (which handles the
  outbound, read direction). No `VintageNet` calls anywhere in this
  module — every function is a plain data transform, unit-testable on
  `:host`, shared by `Vagus.Backend.Network.VintageNet` (real target) and
  `Vagus.Backend.Network.HostStub` (dev/test) so both validate the wire
  body identically.

  Upstream's `SCHEMA_UPDATE` (`supervisor/api/network.py`, fetched from
  2026.07.5) accepts more than `vintage_net` can act on: `ipv6`,
  `enabled`, `mdns`, `llmnr`, `route_metric`, and `nameservers` on a DHCP
  interface are all real, HA-frontend-sent fields this emulator has no
  way to apply. The standing rule here is "validate shape, then ignore"
  for those — never reject a field the real frontend always sends just
  because Vagus can't act on it. Only a field upstream itself would
  reject (unknown keys, wrong types, bad enums) is a `{:error, _}`.

  Specifically NOT supported, by design, with the reason:

    * `ipv6` — `vintage_net` has no per-interface IPv6 method control;
      validated (types/enums/CIDR-parseable) then dropped.
    * `nameservers` under `ipv4.method: "auto"` — DHCP-assigned DNS is
      whatever the DHCP lease gives; `vintage_net` has no per-interface
      static-DNS-on-DHCP override. Validated then dropped.
    * `ipv4.address` beyond the first entry — `vintage_net` configures
      one static address per interface. Extra entries are validated
      (must still be well-formed CIDRs) but only the first is applied.
    * `wifi.mode` other than `"infrastructure"` (`mesh`/`adhoc`/`ap`) —
      honestly unsupported (`{:error, _}`) rather than silently applied
      as an infrastructure wpa-psk join, which is what the pre-fix code
      did.
    * `wifi.auth: "wep"` — honestly unsupported (`{:error, _}`); WEP
      isn't something `vintage_net_wifi`'s `key_mgmt` enum offers a safe
      mapping for.
  """

  @type fragments :: %{ipv4: map() | nil, wifi: map() | nil}

  @top_level_keys ~w(ipv4 ipv6 wifi enabled mdns llmnr)
  @ipv4_keys ~w(address method gateway route_metric nameservers)
  @ipv6_keys ~w(address method addr_gen_mode ip6_privacy gateway route_metric nameservers)
  @wifi_keys ~w(mode auth ssid psk)
  @mdns_llmnr_values ~w(default off resolve announce)

  @doc """
  Translates an already-JSON-decoded update body into `vintage_net`
  config fragments. `{:ok, %{ipv4: nil, wifi: nil}}` means the body was
  entirely valid but contained nothing this backend can act on (e.g.
  `%{"enabled" => true}` alone, or only `"ipv6"`) — callers should treat
  that as a successful no-op, not re-apply a derived config.
  """
  @spec translate(map()) :: {:ok, fragments()} | {:error, String.t()}
  def translate(body) when body == %{} do
    {:error, "You need to supply at least one option to update"}
  end

  def translate(body) when is_map(body) do
    with :ok <- check_unknown_keys(body, @top_level_keys, nil),
         :ok <- check_enabled(body["enabled"]),
         :ok <- check_mdns_llmnr(body["mdns"], "mdns"),
         :ok <- check_mdns_llmnr(body["llmnr"], "llmnr"),
         :ok <- check_ipv6(body["ipv6"]),
         {:ok, ipv4_fragment} <- ipv4_fragment(body["ipv4"]),
         {:ok, wifi_fragment} <- wifi_fragment(body["wifi"]) do
      {:ok, %{ipv4: ipv4_fragment, wifi: wifi_fragment}}
    end
  end

  def translate(_other), do: {:error, "invalid request body"}

  # Caller values are echoed into 400 messages for diagnosability, but a
  # container can smuggle a secret (a psk inside a misplaced map/list) into
  # Core's logs — echo scalars only, truncated; name the container's type
  # otherwise.
  defp safe_inspect(value) when is_map(value), do: "a map"
  defp safe_inspect(value) when is_list(value), do: "a list"
  defp safe_inspect(value), do: inspect(value, printable_limit: 64, limit: 10)

  # -- top-level / ignored-but-validated fields ------------------------------

  defp check_unknown_keys(map, known, section) do
    unknown = map |> Map.keys() |> Enum.reject(&(&1 in known)) |> Enum.sort()

    case unknown do
      [] -> :ok
      keys -> {:error, "unknown #{section_prefix(section)}field(s): #{Enum.join(keys, ", ")}"}
    end
  end

  defp section_prefix(nil), do: ""
  defp section_prefix(section), do: "#{section} "

  defp check_enabled(nil), do: :ok
  defp check_enabled(value) when is_boolean(value), do: :ok

  defp check_enabled(other),
    do: {:error, ~s(enabled must be a boolean, got #{safe_inspect(other)})}

  defp check_mdns_llmnr(nil, _field), do: :ok

  defp check_mdns_llmnr(value, _field) when value in @mdns_llmnr_values, do: :ok

  defp check_mdns_llmnr(other, field) do
    {:error,
     ~s[invalid #{field} #{safe_inspect(other)} (expected #{Enum.join(@mdns_llmnr_values, ", ")})]}
  end

  # ipv6: validated for shape/enums, then always ignored — Vagus
  # configures IPv4 only (see moduledoc).
  defp check_ipv6(nil), do: :ok

  defp check_ipv6(map) when is_map(map) do
    with :ok <- check_unknown_keys(map, @ipv6_keys, "ipv6"),
         :ok <- check_ipv6_addresses(map["address"]),
         :ok <- check_ipv6_method(map["method"]),
         :ok <- check_ipv6_addr_gen_mode(map["addr_gen_mode"]),
         :ok <- check_ipv6_privacy(map["ip6_privacy"]),
         :ok <- check_optional_ipv6_address(map["gateway"], "ipv6 gateway"),
         :ok <- check_ipv6_route_metric(map["route_metric"]) do
      check_ipv6_nameservers(map["nameservers"])
    end
  end

  defp check_ipv6(other), do: {:error, ~s(ipv6 must be an object, got #{safe_inspect(other)})}

  defp check_ipv6_addresses(nil), do: :ok

  defp check_ipv6_addresses(list) when is_list(list) do
    Enum.reduce_while(list, :ok, fn address, :ok ->
      case parse_cidr(address, 6) do
        {:ok, _ip, _prefix} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check_ipv6_addresses(other),
    do: {:error, ~s(ipv6 address must be a list, got #{safe_inspect(other)})}

  defp check_ipv6_method(nil), do: :ok
  defp check_ipv6_method(value) when value in ~w(disabled static auto), do: :ok
  defp check_ipv6_method(other), do: {:error, ~s(invalid ipv6 method #{safe_inspect(other)})}

  defp check_ipv6_addr_gen_mode(nil), do: :ok

  defp check_ipv6_addr_gen_mode(v) when v in ~w(eui64 stable-privacy default-or-eui64 default),
    do: :ok

  defp check_ipv6_addr_gen_mode(other),
    do: {:error, ~s(invalid addr_gen_mode #{safe_inspect(other)})}

  defp check_ipv6_privacy(nil), do: :ok
  defp check_ipv6_privacy(v) when v in ~w(default disabled enabled-prefer-public enabled), do: :ok
  defp check_ipv6_privacy(other), do: {:error, ~s(invalid ip6_privacy #{safe_inspect(other)})}

  defp check_ipv6_route_metric(nil), do: :ok
  defp check_ipv6_route_metric(v) when is_integer(v), do: :ok

  defp check_ipv6_route_metric(other),
    do: {:error, ~s(ipv6 route_metric must be an integer, got #{safe_inspect(other)})}

  defp check_ipv6_nameservers(nil), do: :ok

  defp check_ipv6_nameservers(list) when is_list(list) do
    Enum.reduce_while(list, :ok, fn ns, :ok ->
      case parse_ip(ns, 6) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check_ipv6_nameservers(other),
    do: {:error, ~s(ipv6 nameservers must be a list, got #{safe_inspect(other)})}

  defp check_optional_ipv6_address(nil, _label), do: :ok

  defp check_optional_ipv6_address(value, label) do
    case parse_ip(value, 6) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, ~s(invalid #{label} #{safe_inspect(value)})}
    end
  end

  # -- ipv4 -------------------------------------------------------------------

  defp ipv4_fragment(nil), do: {:ok, nil}

  # Upstream's `_SCHEMA_IPV4_CONFIG` validates every declared key
  # independent of `method` — shape-validate everything present once
  # here, THEN build the fragment per method. Keeps the "validate shape,
  # then ignore what this backend can't act on" rule (see moduledoc)
  # honest for `auto`/`disabled` too, not just `static`.
  defp ipv4_fragment(map) when is_map(map) do
    method = Map.get(map, "method", "static")

    with :ok <- check_unknown_keys(map, @ipv4_keys, "ipv4"),
         :ok <- check_ipv4_method(method),
         :ok <- check_ipv4_addresses(map["address"]),
         :ok <- check_optional_ipv4_address(map["gateway"], "ipv4 gateway"),
         :ok <- check_ipv4_route_metric(map["route_metric"]),
         :ok <- check_ipv4_nameservers(map["nameservers"]) do
      build_ipv4_fragment(method, map)
    end
  end

  defp ipv4_fragment(other), do: {:error, ~s(ipv4 must be an object, got #{safe_inspect(other)})}

  defp check_ipv4_method(value) when value in ~w(disabled static auto), do: :ok

  defp check_ipv4_method(other) do
    {:error, ~s[invalid ipv4 method #{safe_inspect(other)} (expected disabled, static or auto)]}
  end

  defp check_ipv4_addresses(nil), do: :ok

  defp check_ipv4_addresses(list) when is_list(list) do
    Enum.reduce_while(list, :ok, fn address, :ok ->
      case parse_cidr(address, 4) do
        {:ok, _ip, _prefix} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check_ipv4_addresses(other),
    do: {:error, ~s(ipv4 address must be a list, got #{safe_inspect(other)})}

  defp check_ipv4_route_metric(nil), do: :ok
  defp check_ipv4_route_metric(v) when is_integer(v), do: :ok

  defp check_ipv4_route_metric(other),
    do: {:error, ~s(ipv4 route_metric must be an integer, got #{safe_inspect(other)})}

  defp check_optional_ipv4_address(nil, _label), do: :ok

  defp check_optional_ipv4_address(value, label) do
    case parse_ip(value, 4) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, ~s(invalid #{label} #{safe_inspect(value)})}
    end
  end

  defp check_ipv4_nameservers(nil), do: :ok

  defp check_ipv4_nameservers(list) when is_list(list) do
    Enum.reduce_while(list, :ok, fn ns, :ok ->
      case parse_ip(ns, 4) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check_ipv4_nameservers(other),
    do: {:error, ~s(ipv4 nameservers must be a list, got #{safe_inspect(other)})}

  defp build_ipv4_fragment("auto", _map), do: {:ok, %{method: :dhcp}}

  defp build_ipv4_fragment("disabled", _map), do: {:ok, %{method: :disabled}}

  # `address`/`gateway`/`route_metric`/`nameservers` already passed shape
  # validation above — this only picks the first address apart and drops
  # the pieces `vintage_net` can't take (route_metric; nameservers beyond
  # an empty-list-to-nil normalization).
  defp build_ipv4_fragment("static", map) do
    with {:ok, address, prefix_length} <- first_ipv4_address(map["address"]) do
      fragment =
        %{method: :static, address: address, prefix_length: prefix_length}
        |> maybe_put(:gateway, map["gateway"])
        |> maybe_put(:name_servers, present_ipv4_nameservers(map["nameservers"]))

      {:ok, fragment}
    end
  end

  defp first_ipv4_address([first | _rest]), do: parse_cidr(first, 4)

  defp first_ipv4_address(_empty),
    do: {:error, "static ipv4 configuration needs at least one address"}

  defp present_ipv4_nameservers(nil), do: nil
  defp present_ipv4_nameservers([]), do: nil
  defp present_ipv4_nameservers(list), do: list

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # -- wifi ---------------------------------------------------------------

  defp wifi_fragment(nil), do: {:ok, nil}

  defp wifi_fragment(map) when is_map(map) do
    with :ok <- check_unknown_keys(map, @wifi_keys, "wifi"),
         {:ok, ssid} <- wifi_ssid(map["ssid"]),
         :ok <- wifi_mode(Map.get(map, "mode", "infrastructure")) do
      wifi_auth_fragment(Map.get(map, "auth", "open"), ssid, map["psk"])
    end
  end

  defp wifi_fragment(other), do: {:error, ~s(wifi must be an object, got #{safe_inspect(other)})}

  defp wifi_ssid(ssid) when is_binary(ssid) and byte_size(ssid) > 0, do: {:ok, ssid}
  defp wifi_ssid(_other), do: {:error, "wifi configuration needs an ssid"}

  defp wifi_mode("infrastructure"), do: :ok

  defp wifi_mode(mode) when mode in ~w(mesh adhoc ap),
    do: {:error, ~s(wifi mode #{safe_inspect(mode)} is not supported)}

  defp wifi_mode(other), do: {:error, ~s(invalid wifi mode #{safe_inspect(other)})}

  defp wifi_auth_fragment("open", ssid, _psk) do
    {:ok, %{ssid: ssid, key_mgmt: :none}}
  end

  defp wifi_auth_fragment("wpa-psk", ssid, psk) when is_binary(psk) and byte_size(psk) > 0 do
    {:ok, %{ssid: ssid, psk: psk, key_mgmt: :wpa_psk}}
  end

  defp wifi_auth_fragment("wpa-psk", _ssid, _psk) do
    {:error, "psk is required for wpa-psk"}
  end

  defp wifi_auth_fragment("wep", _ssid, _psk) do
    {:error, "auth method wep is not supported"}
  end

  defp wifi_auth_fragment(other, _ssid, _psk) do
    {:error, ~s(invalid wifi auth #{safe_inspect(other)})}
  end

  # -- shared address parsing -------------------------------------------------

  # `address` is either "a.b.c.d/n" (ipv4, family 4) or "addr/n" (ipv6,
  # family 6) — validates the IP part via `:inet.parse_address/1` (so it
  # rejects garbage like "not-an-ip") and the prefix length range.
  defp parse_cidr(value, family) when is_binary(value) do
    max_prefix = if family == 4, do: 32, else: 128

    case String.split(value, "/", parts: 2) do
      [ip_part, prefix_part] ->
        with {:ok, ip} <- parse_ip(ip_part, family),
             {prefix, ""} <- Integer.parse(prefix_part),
             true <- prefix in 0..max_prefix do
          {:ok, ip, prefix}
        else
          _ -> {:error, ~s(invalid address #{safe_inspect(value)})}
        end

      _no_slash ->
        {:error, ~s[invalid address #{safe_inspect(value)} (expected CIDR notation)]}
    end
  end

  defp parse_cidr(value, _family), do: {:error, ~s(invalid address #{safe_inspect(value)})}

  defp parse_ip(value, family) when is_binary(value) do
    charlist = String.to_charlist(value)

    case :inet.parse_address(charlist) do
      {:ok, tuple} when family == 4 and tuple_size(tuple) == 4 -> {:ok, value}
      {:ok, tuple} when family == 6 and tuple_size(tuple) == 8 -> {:ok, value}
      _mismatch_or_error -> {:error, ~s(invalid address #{safe_inspect(value)})}
    end
  end

  defp parse_ip(value, _family), do: {:error, ~s(invalid address #{safe_inspect(value)})}
end
