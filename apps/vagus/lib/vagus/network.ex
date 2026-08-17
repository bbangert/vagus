defmodule Vagus.Network do
  @moduledoc """
  The `hassio` container bridge — the Elixir counterpart of the Supervisor's
  `docker/network.py` (`docs/contract-2026.7-m4-addendum.md` §A6). Owns the
  fixed IP plan add-ons and the plugins share, and creates/adopts the bridge
  via the Engine API (`Vagus.Runtime.Docker`).

  IPv4-only for now (sufficient for Gate 1 and all add-on traffic); the real
  Supervisor also runs dual-stack ULA IPv6 (`fd0c:ac1e:2100::/48`) — deferred.

  Fixed anchors (offsets into the subnet): gateway `.1`, **supervisor `.2`**,
  **dns (CoreDNS/erldns) `.3`**, audio `.4`, cli `.5`, observer `.6`; add-ons
  get dynamic IPs from the `.33.0/24` range. Core is host-networked and is
  reached by bridged containers via the gateway.
  """

  require Logger

  alias Vagus.Runtime.Docker

  @name "hassio"
  @subnet "172.30.32.0/23"
  @ip_range "172.30.33.0/24"
  @prefix "23"

  @loopback {127, 0, 0, 1}

  # A loopback connect either completes or is refused within a syscall — no
  # network hop, no ARP, no route. The timeout only exists so a *dropped*
  # (rather than refused) SYN can't stall an ingress request for the OS
  # connect timeout.
  @loopback_probe_timeout_ms 250

  @anchors %{
    gateway: "172.30.32.1",
    supervisor: "172.30.32.2",
    dns: "172.30.32.3",
    audio: "172.30.32.4",
    cli: "172.30.32.5",
    observer: "172.30.32.6"
  }

  @doc "The bridge network name (`hassio`)."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The fixed IP anchors (`:gateway`, `:supervisor`, `:dns`, `:audio`, `:cli`, `:observer`)."
  @spec anchors() :: %{atom() => String.t()}
  def anchors, do: @anchors

  @doc "The bridge gateway (`172.30.32.1`) — the host's own address on the `hassio` bridge."
  @spec gateway() :: String.t()
  def gateway, do: @anchors.gateway

  @doc "Supervisor's bridge IP (`172.30.32.2`) — where bridged containers reach the emulator."
  @spec supervisor_ip() :: String.t()
  def supervisor_ip, do: @anchors.supervisor

  @doc "The DNS server IP (`172.30.32.3`) — erldns, injected as containers' nameserver."
  @spec dns_ip() :: String.t()
  def dns_ip, do: @anchors.dns

  @doc """
  Which host address a `host_network: true` add-on's `port` is reached on:
  loopback when something is listening there, the bridge gateway otherwise.

  Upstream (`docker/app.py`) answers the gateway unconditionally for these
  add-ons, and has no alternative — its Supervisor is itself a container on
  the bridge, where loopback is that container's own. Vagus's supervisor is
  the host BEAM process, so loopback is genuinely available to it and is
  strictly more local. It has to be preferred, because the two addresses are
  not interchangeable to the add-ons themselves (both device-observed):

    * ESPHome listens on `0.0.0.0` but refuses anything that did not arrive
      on loopback with a `403` — reproduced with and without the anchor bind,
      with `Host` rewritten, and with `X-HA-Ingress`/`X-Ingress-Path`/
      `X-Hass-Source`/`X-Forwarded-For` set. Only the peer address unlocks it.
    * Music Assistant binds its ingress port to the gateway alone
      (`0.0.0.0` for its LAN UI, gateway-only for ingress — deliberately
      keeping ingress off the LAN), so loopback is refused outright.

  Hence a connect decides, and **only** a connection-level failure falls back:
  an add-on answering `403`/`404`/`500` on loopback has connected, and that
  status is its answer rather than evidence of a wrong address.

  Deliberately uncached: the fallback path costs one refused loopback connect
  (a syscall, no network hop), while a cached answer goes stale the moment an
  add-on rebinds or restarts — and a stale answer here is a 502 for the whole
  panel.
  """
  @spec host_network_ip(:inet.port_number()) :: String.t()
  def host_network_ip(port) do
    # `active: false` so a chatty add-on's greeting can never land in the
    # mailbox of whatever process is deciding — on the ingress path that's
    # Bandit's own connection handler.
    case :gen_tcp.connect(@loopback, port, [active: false], @loopback_probe_timeout_ms) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        format_ip(@loopback)

      {:error, _refused_or_unreachable} ->
        gateway()
    end
  end

  @doc """
  Socket options that make an outbound connection *originate from* the
  supervisor anchor (`172.30.32.2`) instead of the bridge's primary address.

  Vagus runs on the host, so a connection to an add-on on the `hassio`
  bridge takes that bridge's primary source address (`172.30.32.1`, the
  gateway) unless told otherwise. In HAOS the Supervisor is a container that
  genuinely *holds* `.2`, so add-ons see `.2` as the client IP — and several
  filter on it. Device-observed 2026-07-27: `core_configurator` answered
  ingress with `Client IP not within allowed networks` / `420` and banned
  `172.30.32.1`, surfacing to Core as a 502.

  Returns `[]` unless `config :vagus, :ingress_source_ip` is set, so `:host`
  and `:test` (where no `.2` is bound and binding would fail
  `:eaddrnotavail`) are unaffected.
  """
  @spec source_bind_opts() :: [{:ip, :inet.ip_address()}]
  def source_bind_opts do
    case Application.get_env(:vagus, :ingress_source_ip) do
      nil -> []
      ip -> parse_source_ip(ip)
    end
  end

  @doc """
  `source_bind_opts/0`, narrowed to the destination being dialled: `[]` for a
  loopback destination, the anchor bind for anything else.

  A `host_network: true` add-on has no `hassio` bridge address at all — it is
  reached on the host itself, on loopback whenever it listens there
  (`host_network_ip/1`). Binding a *non-loopback* source for a *loopback*
  destination makes the add-on see a peer that isn't local, and an add-on
  that filters on that refuses the request.

  Device-observed on the rpi3, 2026-07-29, against ESPHome's device builder
  (`host_network: true`): byte-identical requests to `127.0.0.1:63642` got
  `200 OK` from an unbound socket and `403 Forbidden` from one bound to
  `172.30.32.2`. The whole dashboard was unreachable through ingress.

  Note the two rules pull in opposite directions and both are real — the
  bridge case in `source_bind_opts/0`'s docs is a different add-on
  (`core_configurator`) banning `172.30.32.1`. Hence keying on the
  destination rather than picking one globally.
  """
  @spec source_bind_opts(:inet.ip_address() | String.t()) :: [{:ip, :inet.ip_address()}]
  def source_bind_opts(destination) do
    if loopback?(destination), do: [], else: source_bind_opts()
  end

  @doc """
  Whether `ip` (a tuple or a string) is a loopback address.

  Unparseable input is `false` — a destination we can't read is treated as
  remote, which keeps the anchor bind rather than silently dropping it.
  """
  @spec loopback?(:inet.ip_address() | String.t()) :: boolean()
  def loopback?(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, addr} -> loopback?(addr)
      {:error, _reason} -> false
    end
  end

  def loopback?({127, _, _, _}), do: true
  def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback?(_ip), do: false

  @doc """
  Parses an IP-address config value into an `:inet.ip_address()` tuple.

  Accepts either a string (`"172.30.32.2"`, `"::1"`) or an already-parsed
  tuple; `:error` for anything else — including a wrong-sized tuple or an
  out-of-range octet, which would otherwise sail through and only fail later
  inside a socket call as an opaque `:einval`.

  Shared by every config key that names an address (`:ingress_source_ip`,
  `:api_bind_ip`, `Vagus.Network.Nat`'s DNAT destination) so they cannot
  drift on what they accept.
  """
  @spec parse_ip(term()) :: {:ok, :inet.ip_address()} | :error
  def parse_ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, addr} -> {:ok, addr}
      {:error, _reason} -> :error
    end
  end

  def parse_ip(ip) when is_tuple(ip) do
    # `:inet.ntoa/1` is the cheap real validator for a tuple.
    case :inet.ntoa(ip) do
      {:error, :einval} -> :error
      _charlist -> {:ok, ip}
    end
  end

  # Anything else (integer, list, map, atom...). Without this clause the
  # `case` in `parse_source_ip/1` raised CaseClauseError and took ingress
  # connection setup down at runtime over a config typo.
  def parse_ip(_other), do: :error

  @doc "Renders an `:inet.ip_address()` tuple back as a string."
  @spec format_ip(:inet.ip_address()) :: String.t()
  def format_ip(ip), do: to_string(:inet.ntoa(ip))

  defp parse_source_ip(value) do
    case parse_ip(value) do
      {:ok, addr} -> [ip: addr]
      :error -> invalid_source_ip(value)
    end
  end

  # Degrade to "no source bind" rather than raising: ingress still works
  # (from the gateway address), and the warning makes the misconfiguration
  # diagnosable instead of fatal.
  defp invalid_source_ip(value) do
    Logger.warning(
      "Vagus.Network: ignoring invalid :ingress_source_ip #{inspect(value)} — " <>
        "expected an IP string or :inet.ip_address() tuple"
    )

    []
  end

  @doc """
  The Engine-API `/networks/create` payload for the `hassio` bridge. Exposed so
  the IP plan can be asserted without a daemon.
  """
  @spec config() :: map()
  def config do
    %{
      "Name" => @name,
      "Driver" => "bridge",
      "IPAM" => %{
        "Driver" => "default",
        "Config" => [
          %{"Subnet" => @subnet, "Gateway" => @anchors.gateway, "IPRange" => @ip_range}
        ]
      },
      # Name the host-side bridge interface `hassio` (matches the Supervisor).
      "Options" => %{"com.docker.network.bridge.name" => @name}
    }
  end

  @doc """
  Ensures the `hassio` bridge exists (idempotent): returns the existing
  network id if present, else creates it. Returns `{:ok, id}` / `{:error, _}`.
  """
  @spec ensure(keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure(opts \\ []) do
    case Docker.inspect_network(@name, opts) do
      {:ok, %{"Id" => id}} -> {:ok, id}
      {:error, {:http, 404, _}} -> Docker.create_network(config(), opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Binds the host-served anchor IPs — supervisor `172.30.32.2` and dns
  `172.30.32.3` — to the host `hassio` bridge interface, so the host-networked
  emulator (Bandit on `.2`, `Vagus.DNS` on `0.0.0.0:53`) answers there:
  `.2` is where bridged add-ons reach `http://supervisor` and `.3` is the
  resolver they're configured with (§A6). The bridge driver already puts the
  gateway `.1` on the interface; these are added beside it once the interface
  exists (i.e. after `ensure/1` created the network).

  `.2` is also the address the API listener itself binds
  (`Vagus.API.Listener`, `config :vagus, :api_bind_ip`) — it is added here,
  well after `Vagus.Application` starts that listener, which is why the
  listener retries its bind rather than requiring the address up front.

  Idempotent + best-effort: an address already present (`ip` prints
  "File exists"), a missing interface, or a missing `ip` tool is logged and
  treated as `:ok` — never fatal to an add-on install.
  """
  @spec ensure_supervisor_ip() :: :ok
  def ensure_supervisor_ip do
    bind_anchor(supervisor_ip())
    bind_anchor(dns_ip())
    :ok
  end

  defp bind_anchor(ip) do
    case System.cmd("ip", ["addr", "add", "#{ip}/#{@prefix}", "dev", @name],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        :ok

      {out, _code} ->
        unless String.contains?(out, "File exists") do
          Logger.warning("Vagus.Network: binding #{ip} to #{@name} failed: #{String.trim(out)}")
        end

        :ok
    end
  rescue
    e ->
      Logger.warning("Vagus.Network: binding anchor #{ip} errored: #{Exception.message(e)}")
      :ok
  end
end
