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

  @doc "Supervisor's bridge IP (`172.30.32.2`) — where bridged containers reach the emulator."
  @spec supervisor_ip() :: String.t()
  def supervisor_ip, do: @anchors.supervisor

  @doc "The DNS server IP (`172.30.32.3`) — erldns, injected as containers' nameserver."
  @spec dns_ip() :: String.t()
  def dns_ip, do: @anchors.dns

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
  Binds the Supervisor anchor IP (`172.30.32.2/23`) to the host `hassio` bridge
  interface, so the host-networked emulator (Bandit on `0.0.0.0`) answers there
  — the address bridged add-ons reach via `http://supervisor` (§A6). The bridge
  driver already puts the gateway `.1` on the interface; this adds `.2` beside
  it once the interface exists (i.e. after `ensure/1` created the network).

  Idempotent + best-effort: an address already present (`ip` prints
  "File exists"), a missing interface, or a missing `ip` tool is logged and
  treated as `:ok` — never fatal to an add-on install.
  """
  @spec ensure_supervisor_ip() :: :ok
  def ensure_supervisor_ip do
    args = ["addr", "add", "#{supervisor_ip()}/#{@prefix}", "dev", @name]

    case System.cmd("ip", args, stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, _code} ->
        if String.contains?(out, "File exists") do
          :ok
        else
          Logger.warning(
            "Vagus.Network: binding #{supervisor_ip()} to #{@name} failed: #{String.trim(out)}"
          )

          :ok
        end
    end
  rescue
    e ->
      Logger.warning("Vagus.Network: ensure_supervisor_ip errored: #{Exception.message(e)}")
      :ok
  end
end
