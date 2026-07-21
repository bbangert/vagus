defmodule Vagus.DNS do
  @moduledoc """
  Authoritative DNS for the `hassio` bridge (`docs/contract-2026.7-m4-addendum.md`
  §A6) — the Elixir counterpart of the Supervisor's CoreDNS at `172.30.32.3:53`.

  Serves `A` records for the fixed anchors (supervisor/hassio → `.2`,
  homeassistant/home-assistant → gateway `.1`, dns → `.3`, observer → `.6`,
  localhost → `127.0.0.1`), each also under the `.local.hass.io` search suffix,
  plus per-add-on records (`<slug-with-dashes>`) registered/removed on
  start/stop. Names we don't own are forwarded verbatim to the configured
  upstream resolver (`locals`); with no upstream we answer `NXDOMAIN`.

  Bridged add-ons already get `Dns=[172.30.32.3]` injected into their
  `/etc/resolv.conf` (the Spec builder, P1-T3), so once this server is up they
  resolve each other and the supervisor by name. A host-networked Core is
  pointed here with `--dns 172.30.32.3`.

  Bind address/port and upstream are configurable (`opts`/`config :vagus, :dns_*`)
  so the server is unit-testable on loopback without `CAP_NET_BIND_SERVICE`.
  """

  use GenServer

  require Logger

  alias Vagus.DNS.Message
  alias Vagus.Network

  @forward_timeout 2_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Registers/updates `hostname` → `ip` (a `{a,b,c,d}` tuple or dotted string)."
  @spec register(String.t(), :inet.ip4_address() | String.t(), GenServer.server()) :: :ok
  def register(hostname, ip, server \\ __MODULE__) do
    GenServer.call(server, {:register, String.downcase(hostname), to_ip(ip)})
  end

  @doc "Removes a dynamic record."
  @spec unregister(String.t(), GenServer.server()) :: :ok
  def unregister(hostname, server \\ __MODULE__) do
    GenServer.call(server, {:unregister, String.downcase(hostname)})
  end

  @doc "Resolves `name` against the static + dynamic zone (no forwarding); for tests/inspection."
  @spec resolve(String.t(), GenServer.server()) :: {:ok, :inet.ip4_address()} | :error
  def resolve(name, server \\ __MODULE__) do
    GenServer.call(server, {:resolve, String.downcase(name)})
  end

  ## GenServer

  @impl GenServer
  def init(opts) do
    # Listen address (distinct from the `.3` anchor used in records): on target
    # this is `0.0.0.0` so the bind doesn't depend on `.3` already being
    # assigned to the bridge iface (which happens later, at add-on install).
    ip =
      to_ip(Keyword.get(opts, :ip, Application.get_env(:vagus, :dns_bind_ip, Network.dns_ip())))

    port = Keyword.get(opts, :port, Application.get_env(:vagus, :dns_port, 53))

    upstream =
      parse_upstream(Keyword.get(opts, :upstream, Application.get_env(:vagus, :dns_upstream)))

    case :gen_udp.open(port, [:binary, :inet, {:ip, ip}, active: true, reuseaddr: true]) do
      {:ok, socket} ->
        {:ok, %{socket: socket, static: static_zone(), dynamic: %{}, upstream: upstream}}

      {:error, reason} ->
        # Don't take down the app if :53 can't bind (e.g. missing capability or
        # port taken) — log and stay idle; add-on /etc/hosts still covers the
        # supervisor anchor.
        Logger.error("Vagus.DNS: failed to bind #{fmt(ip)}:#{port} (#{inspect(reason)})")
        {:ok, %{socket: nil, static: static_zone(), dynamic: %{}, upstream: upstream}}
    end
  end

  @impl GenServer
  def handle_call({:register, host, ip}, _from, state) do
    {:reply, :ok, %{state | dynamic: Map.put(state.dynamic, host, ip)}}
  end

  def handle_call({:unregister, host}, _from, state) do
    {:reply, :ok, %{state | dynamic: Map.delete(state.dynamic, host)}}
  end

  def handle_call({:resolve, name}, _from, state) do
    {:reply, lookup(strip_suffix(name), state), state}
  end

  @impl GenServer
  def handle_info({:udp, socket, host, port, packet}, %{socket: socket} = state) do
    handle_packet(packet, host, port, state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Query handling

  defp handle_packet(packet, host, port, state) do
    case Message.parse_query(packet) do
      {:ok, %{qtype: qtype} = query} ->
        a_type = Message.type_a()

        cond do
          qtype == a_type and match?({:ok, _}, lookup(strip_suffix(query.qname), state)) ->
            {:ok, ip} = lookup(strip_suffix(query.qname), state)
            reply(state.socket, host, port, Message.answer(query, [ip]))

          true ->
            forward_or_nxdomain(packet, query, host, port, state)
        end

      {:error, _reason} ->
        # Unparseable (e.g. multi-question) — forward raw if we can, else drop.
        if state.upstream, do: forward(packet, host, port, state)
    end
  end

  defp forward_or_nxdomain(packet, query, host, port, state) do
    if state.upstream do
      forward(packet, host, port, state)
    else
      reply(state.socket, host, port, Message.nxdomain(query))
    end
  end

  # Relay the raw query to the upstream resolver from a throwaway process so a
  # slow upstream never blocks the server; the answer goes back out our socket.
  defp forward(packet, host, port, %{socket: socket, upstream: upstream}) do
    spawn(fn ->
      with {:ok, s} <- :gen_udp.open(0, [:binary, active: false]),
           :ok <- :gen_udp.send(s, upstream, 53, packet),
           {:ok, {_ip, _p, resp}} <- :gen_udp.recv(s, 0, @forward_timeout) do
        :gen_udp.send(socket, host, port, resp)
        :gen_udp.close(s)
      else
        _ -> :ok
      end
    end)

    :ok
  end

  defp reply(nil, _host, _port, _packet), do: :ok
  defp reply(socket, host, port, packet), do: :gen_udp.send(socket, host, port, packet)

  defp lookup(name, %{static: static, dynamic: dynamic}) do
    case Map.get(dynamic, name) || Map.get(static, name) do
      nil -> :error
      ip -> {:ok, ip}
    end
  end

  # Strip the search suffix so `<name>` and `<name>.local.hass.io` both resolve.
  defp strip_suffix(name) do
    case String.replace_suffix(name, ".local.hass.io", "") do
      ^name -> name
      stripped -> stripped
    end
  end

  ## Zone

  defp static_zone do
    a = Network.anchors()

    %{
      "supervisor" => to_ip(a.supervisor),
      "hassio" => to_ip(a.supervisor),
      "homeassistant" => to_ip(a.gateway),
      "home-assistant" => to_ip(a.gateway),
      "dns" => to_ip(a.dns),
      "observer" => to_ip(a.observer),
      "localhost" => {127, 0, 0, 1}
    }
  end

  defp parse_upstream(nil), do: nil
  defp parse_upstream(%{} = _), do: nil
  defp parse_upstream(ip), do: to_ip(ip)

  defp to_ip({_, _, _, _} = ip), do: ip

  defp to_ip(str) when is_binary(str) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(str))
    ip
  end

  defp fmt(ip), do: ip |> :inet.ntoa() |> to_string()
end
