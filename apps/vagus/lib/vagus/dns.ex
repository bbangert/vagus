defmodule Vagus.DNS do
  @moduledoc """
  Authoritative DNS for the `hassio` bridge (`docs/contract-2026.7-m4-addendum.md`
  §A6) — the Elixir counterpart of the Supervisor's CoreDNS at `172.30.32.3:53`.

  Serves `A` records for the fixed anchors (supervisor/hassio → `.2`,
  homeassistant/home-assistant → gateway `.1`, dns → `.3`, observer → `.6`,
  localhost → `127.0.0.1`), each also under the `.local.hass.io` search suffix,
  plus one record per running app (`<slug-with-dashes>`). Names we don't own
  are forwarded verbatim to the board's LAN name servers, as upstream's
  CoreDNS forwards to the host's, then to the configured fallback
  (`:dns_upstream`); with neither we answer `NXDOMAIN`.

  Every container that asks for DNS resolves here, Core and host-network apps
  included: bridged ones through podman's `--dns`, host-network ones through
  the resolv.conf `Vagus.Runtime.Engine.Podman` binds in. So LAN-local names
  keep resolving for Core only because the forward follows the LAN.

  It answers over TCP too, on the same address and port, as CoreDNS does: a
  reply too large for UDP comes back truncated, and the client asks again
  over TCP (`Vagus.DNS.TCP`).

  Bind address/port and upstream are configurable (`opts`/`config :vagus, :dns_*`)
  so the server is unit-testable on loopback without `CAP_NET_BIND_SERVICE`.

  An app's record is its process's `{:dns, name}` key in
  `Vagus.App.Directory`, valued with its IP, read on each query: it goes
  with the process, and this server holds none of it. A running container
  app has one, the gateway for a host-network app; a native app's is the
  supervisor's address. An app record wins over an anchor of the same name.
  `foo_bar` and `foo-bar` share a name, and the directory's unique keys give
  it to whichever app started first; the second runs without one.
  """

  use GenServer

  require Logger

  alias Vagus.DNS.{Message, TCP}
  alias Vagus.Network

  # The stub's `timeout:10` is musl's whole budget, resent every 5 s (two
  # attempts): a relay done within 4 s never overlaps the resend of its own
  # query. The budget is shared out among the servers not yet tried, so the
  # fallback, last, still gets a real slice after dead LAN servers; the floor
  # keeps a long list from slicing it too thin for any of them to answer.
  @relay_ms 4_000
  @min_slice_ms 250
  # Cap concurrent upstream relays and TCP connections so a flood can't
  # exhaust processes/file descriptors.
  @max_inflight 64
  @max_tcp 16
  @drop_report_ms 60_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "Resolves `name` against the apps and the anchors (no forwarding); for tests/inspection."
  @spec resolve(String.t(), GenServer.server()) :: {:ok, :inet.ip4_address()} | :error
  def resolve(name, server \\ __MODULE__) do
    GenServer.call(server, {:resolve, String.downcase(name)})
  end

  ## GenServer

  @bind_retry_ms 5_000

  @impl GenServer
  def init(opts) do
    # Bind the DNS socket to the `.3` anchor itself (not `0.0.0.0`): a client's
    # stub resolver drops replies whose source IP isn't the server it queried,
    # and only a socket bound to `.3` sources its replies from `.3`. Because
    # `.3` is assigned to the hassio iface later (at first add-on install), a
    # failed bind is retried rather than fatal.
    state = %{
      socket: nil,
      listen: nil,
      # Monitor ref -> pid of each TCP connection's task.
      conns: %{},
      tcp_idle_ms: Keyword.get(opts, :tcp_idle_ms, TCP.idle_ms()),
      ip:
        to_ip(Keyword.get(opts, :ip, Application.get_env(:vagus, :dns_bind_ip, Network.dns_ip()))),
      port: Keyword.get(opts, :port, Application.get_env(:vagus, :dns_port, 53)),
      static: static_zone(),
      directory: Keyword.get(opts, :directory, Vagus.App.Directory),
      # Monitor ref -> relay pid for each upstream relay in flight; its size
      # is the in-flight count (see forward/4).
      relays: %{},
      # Where upstream relays run (a test seam for the supervisor-down path).
      task_supervisor: Keyword.get(opts, :task_supervisor, Vagus.TaskSupervisor),
      fallback:
        parse_upstream(Keyword.get(opts, :upstream, Application.get_env(:vagus, :dns_upstream))),
      name_servers: Keyword.get(opts, :name_servers, &lan_name_servers/0),
      upstream_port: Keyword.get(opts, :upstream_port, 53),
      # The LAN server that last answered, tried first among them.
      preferred: nil,
      # Queries shed at a cap since the last report, one report per interval.
      dropped: 0,
      drop_report_ms: Keyword.get(opts, :drop_report_ms, @drop_report_ms)
    }

    {:ok, try_bind(state)}
  end

  # UDP and TCP come up together or not at all: a client told to retry over
  # TCP must find it there. Port 0 (tests) takes whatever UDP is given, and
  # TCP the same, which TCP may already be using: another is drawn then.
  defp try_bind(state, draws \\ 5)

  defp try_bind(%{ip: ip, port: 0} = state, draws) when draws > 1 do
    case bind(ip, 0) do
      {:ok, bound} -> bound_to(state, bound)
      {:error, _reason} -> try_bind(state, draws - 1)
    end
  end

  defp try_bind(%{ip: ip, port: port} = state, _draws) do
    case bind(ip, port) do
      {:ok, bound} ->
        bound_to(state, bound)

      {:error, reason} ->
        Logger.warning(
          "Vagus.DNS: bind #{fmt(ip)}:#{port} failed (#{inspect(reason)}), retrying in #{@bind_retry_ms}ms"
        )

        Process.send_after(self(), :retry_bind, @bind_retry_ms)
        state
    end
  end

  defp bound_to(state, {socket, listen, port}) do
    TCP.start_acceptor(listen, self())
    Logger.info("Vagus.DNS: listening on #{fmt(state.ip)}:#{port} (UDP and TCP)")
    %{state | socket: socket, listen: listen, port: port}
  end

  defp bind(ip, port) do
    with {:ok, socket} <-
           :gen_udp.open(port, [:binary, :inet, {:ip, ip}, active: true, reuseaddr: true]),
         {:ok, port} <- :inet.port(socket),
         {:ok, listen} <- listen_tcp(socket, ip, port) do
      {:ok, {socket, listen, port}}
    end
  end

  defp listen_tcp(socket, ip, port) do
    case TCP.listen(ip, port) do
      {:ok, listen} ->
        {:ok, listen}

      {:error, _reason} = error ->
        :gen_udp.close(socket)
        error
    end
  end

  @impl GenServer
  def handle_call({:resolve, name}, _from, state) do
    {:reply, lookup(strip_suffix(name), state), state}
  end

  @impl GenServer
  def handle_info({:udp, socket, host, port, packet}, %{socket: socket} = state) do
    {:noreply, handle_packet(packet, host, port, state)}
  end

  # A relay ended — normally, crashed, or killed from outside (a task
  # supervisor restart kills its children without running their `after`).
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{relays: relays} = state)
      when is_map_key(relays, ref) do
    {:noreply, %{state | relays: Map.delete(relays, ref)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{conns: conns} = state)
      when is_map_key(conns, ref) do
    {:noreply, %{state | conns: Map.delete(conns, ref)}}
  end

  def handle_info({:tcp_accepted, sock}, %{conns: conns} = state)
      when map_size(conns) >= @max_tcp do
    :gen_tcp.close(sock)
    {:noreply, shed(state)}
  end

  def handle_info({:tcp_accepted, sock}, state), do: {:noreply, serve_tcp(sock, state)}

  def handle_info({:answered_by, ip}, state), do: {:noreply, %{state | preferred: ip}}

  def handle_info(:report_drops, state) do
    Logger.warning(
      "Vagus.DNS: #{state.dropped} queries shed at the in-flight caps " <>
        "(#{@max_inflight} relays, #{@max_tcp} TCP connections) " <>
        "in the last #{div(state.drop_report_ms, 1000)}s"
    )

    {:noreply, %{state | dropped: 0}}
  end

  def handle_info(:retry_bind, %{socket: nil} = state), do: {:noreply, try_bind(state)}
  def handle_info(:retry_bind, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  ## Query handling

  # Returns the (possibly inflight-incremented) state.
  defp handle_packet(packet, host, port, state) do
    case local_answer(packet, state) do
      {:answer, resp} ->
        reply(state.socket, host, port, resp)
        state

      {:forward, nxdomain} ->
        forward_or_nxdomain(packet, nxdomain, host, port, state)
    end
  end

  defp forward_or_nxdomain(packet, nxdomain, host, port, state) do
    case upstreams(state) do
      [] ->
        if nxdomain, do: reply(state.socket, host, port, nxdomain)
        state

      upstreams ->
        forward(packet, host, port, upstreams, state)
    end
  end

  @doc false
  # Owned names are answered here: A with the record, and any other type
  # (e.g. AAAA) as NOERROR-with-no-answers. Never forward an owned name — a
  # stub resolver doing A+AAAA would take upstream's NXDOMAIN for the AAAA as
  # "the name doesn't exist". Anything else is `{:forward, nxdomain}`, with
  # the NXDOMAIN to send when there is nobody to forward to; an unparseable
  # query (e.g. multi-question) has none and is dropped then.
  @spec local_answer(binary(), %{
          :static => map(),
          :directory => atom(),
          optional(atom()) => any()
        }) ::
          {:answer, binary()} | {:forward, binary() | nil}
  def local_answer(packet, zone) do
    case Message.parse_query(packet) do
      {:ok, query} ->
        case lookup(strip_suffix(query.qname), zone) do
          {:ok, ip} -> {:answer, owned(query, ip)}
          :error -> {:forward, Message.nxdomain(query)}
        end

      {:error, _reason} ->
        {:forward, nil}
    end
  end

  # Read per query, not subscribed to: the property is an ETS read, and a
  # lease change then reaches the very next query with no state to keep in
  # step. Only IPv4 servers, which the relay's socket can reach, and never
  # this server itself, which would relay to itself. The fallback is always
  # last, as CoreDNS's is: a public resolver knows no LAN-only name, so its
  # NXDOMAIN must never come before a LAN server's answer, and the preference
  # for the server that last answered applies among the LAN's alone.
  defp upstreams(state) do
    own = [state.ip, to_ip(Network.dns_ip())]

    lan =
      for server <- state.name_servers.(),
          {_, _, _, _} = ip <- [server_ip(server)],
          ip not in own,
          uniq: true,
          do: ip

    lan = if state.preferred in lan, do: [state.preferred | lan -- [state.preferred]], else: lan
    fallback = if state.fallback in own, do: [], else: List.wrap(state.fallback)
    lan ++ (fallback -- lan)
  end

  defp owned(%{qtype: qtype} = query, ip),
    do: Message.answer(query, if(qtype == Message.type_a(), do: [ip], else: []))

  defp server_ip(%{address: ip}), do: ip
  defp server_ip(ip) when is_tuple(ip), do: ip
  defp server_ip(_other), do: nil

  # Relay the raw query from a throwaway (supervised, so a crash is logged)
  # task so a slow upstream never blocks the server; the answer goes back out
  # our socket. Each upstream is tried in turn until one answers, all within
  # one deadline, so a dead server costs a query a slice, not its answer.
  # Bounded by `@max_inflight` (drop over the cap) so a flood of misses can't
  # exhaust processes/FDs; the ephemeral socket is always closed (`try/after`,
  # and the port dies with the relay if it is killed). The server monitors
  # each relay and counts it out on its `:DOWN`, however it ended.
  defp forward(_packet, _host, _port, _upstreams, %{relays: relays} = state)
       when map_size(relays) >= @max_inflight,
       do: shed(state)

  defp forward(packet, host, port, upstreams, %{socket: socket} = state) do
    upstream_port = state.upstream_port
    server = self()

    relay = fn ->
      case :gen_udp.open(0, [:binary, active: false]) do
        {:ok, s} ->
          try do
            with {:ok, ip, resp} <- ask_upstreams(s, upstreams, upstream_port, packet, deadline()) do
              :gen_udp.send(socket, host, port, resp)
              answered(server, upstreams, ip)
            end
          after
            :gen_udp.close(s)
          end

        {:error, _reason} ->
          :ok
      end
    end

    start_relay(state, relay)
  end

  # One socket for every try: a late answer from a server already given up
  # on answers the same query, so it is as good as the one waited for.
  defp ask_upstreams(s, [upstream | rest] = untried, port, packet, deadline) do
    with wait when wait > 0 <- slice(deadline, length(untried)),
         :ok <- :gen_udp.send(s, upstream, port, packet),
         {:ok, {ip, _p, resp}} <- :gen_udp.recv(s, 0, wait) do
      {:ok, ip, resp}
    else
      0 -> :error
      _ when rest == [] -> :error
      _ -> ask_upstreams(s, rest, port, packet, deadline)
    end
  end

  @doc false
  @spec deadline() :: integer()
  def deadline, do: System.monotonic_time(:millisecond) + @relay_ms

  @doc false
  # The wait one server gets: an equal share of what is left among the
  # servers not yet tried, so the last one keeps all that remains.
  @spec slice(integer(), pos_integer()) :: non_neg_integer()
  def slice(deadline, untried) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)
    if untried == 1, do: left, else: min(max(div(left, untried), @min_slice_ms), left)
  end

  @doc false
  # Only a change of first choice is news, and it reaches the one process
  # that keeps it.
  @spec answered(pid(), [:inet.ip4_address()], :inet.ip4_address()) :: :ok
  def answered(server, [first | _], ip) do
    if ip != first, do: send(server, {:answered_by, ip})
    :ok
  end

  defp shed(state) do
    if state.dropped == 0, do: Process.send_after(self(), :report_drops, state.drop_report_ms)
    %{state | dropped: state.dropped + 1}
  end

  # The task runs under the same supervisor as the relays and is counted
  # here like one; it owns the socket from here on, so the socket closes
  # with it however it ends.
  defp serve_tcp(sock, state) do
    conn = %{
      static: state.static,
      directory: state.directory,
      upstreams: upstreams(state),
      upstream_port: state.upstream_port,
      server: self(),
      idle_ms: state.tcp_idle_ms
    }

    case Task.Supervisor.start_child(state.task_supervisor, fn -> TCP.serve(conn) end) do
      {:ok, pid} ->
        :ok = handover(sock, pid)
        %{state | conns: Map.put(state.conns, Process.monitor(pid), pid)}

      {:error, reason} ->
        :gen_tcp.close(sock)
        relay_not_started(reason, state)
    end
  catch
    :exit, reason ->
      :gen_tcp.close(sock)
      relay_not_started(reason, state)
  end

  # A task that died before the handover leaves the socket here: closed.
  defp handover(sock, pid) do
    case :gen_tcp.controlling_process(sock, pid) do
      :ok -> send(pid, {:socket, sock})
      {:error, _reason} -> :gen_tcp.close(sock)
    end

    :ok
  end

  # No relay started means nothing to count: drop the query. start_child *exits* (rather than
  # returning an error) when the task supervisor isn't running — e.g.
  # mid-restart, as a one_for_one sibling — and that must drop one query, not
  # crash this server.
  defp start_relay(state, relay) do
    case Task.Supervisor.start_child(state.task_supervisor, relay) do
      {:ok, pid} ->
        %{state | relays: Map.put(state.relays, Process.monitor(pid), pid)}

      {:error, reason} ->
        relay_not_started(reason, state)
    end
  catch
    :exit, reason -> relay_not_started(reason, state)
  end

  defp relay_not_started(reason, state) do
    Logger.warning("Vagus.DNS: upstream relay not started (#{inspect(reason)}); query dropped")
    state
  end

  defp reply(nil, _host, _port, _packet), do: :ok
  defp reply(socket, host, port, packet), do: :gen_udp.send(socket, host, port, packet)

  defp lookup(name, %{static: static, directory: directory}) do
    case app_ip(name, directory) || Map.get(static, name) do
      nil -> :error
      ip -> {:ok, ip}
    end
  end

  # A value that is not an address must not crash the query, nor shadow an
  # anchor.
  defp app_ip(name, directory) do
    with [{_pid, ip}] when is_binary(ip) <- Registry.lookup(directory, {:dns, name}),
         {:ok, {_, _, _, _} = address} <- :inet.parse_ipv4strict_address(String.to_charlist(ip)) do
      address
    else
      _ -> nil
    end
  rescue
    # The directory is restarting.
    ArgumentError -> nil
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

  if Mix.target() == :host do
    defp lan_name_servers, do: []
  else
    defp lan_name_servers, do: VintageNet.get(["name_servers"], [])
  end
end
