defmodule Vagus.DNS do
  @moduledoc """
  Authoritative DNS for the `hassio` bridge (`docs/contract-2026.7-m4-addendum.md`
  §A6) — the Elixir counterpart of the Supervisor's CoreDNS at `172.30.32.3:53`.

  Serves `A` records for the fixed anchors (supervisor/hassio → `.2`,
  homeassistant/home-assistant → gateway `.1`, dns → `.3`, observer → `.6`,
  localhost → `127.0.0.1`), each also under the `.local.hass.io` search suffix,
  plus one record per running app (`<slug-with-dashes>`). Names we don't own
  are forwarded verbatim to the configured upstream resolver (`locals`); with
  no upstream we answer `NXDOMAIN`.

  Bridged add-ons already get `Dns=[172.30.32.3]` injected into their
  `/etc/resolv.conf` (the Spec builder, P1-T3), so once this server is up they
  resolve each other and the supervisor by name. A host-networked Core is
  pointed here with `--dns 172.30.32.3`.

  Bind address/port and upstream are configurable (`opts`/`config :vagus, :dns_*`)
  so the server is unit-testable on loopback without `CAP_NET_BIND_SERVICE`.

  An app's record is its process's `{:dns, name}` key in
  `Vagus.App.Directory`, valued with its IP, read on each query: it goes
  with the process, and this server holds none of it. A running container
  app has one; a host-network app has none; a native app's is the
  supervisor's address. An app record wins over an anchor of the same name.
  `foo_bar` and `foo-bar` share a name, and the directory's unique keys give
  it to whichever app started first; the second runs without one.
  """

  use GenServer

  require Logger

  alias Vagus.DNS.Message
  alias Vagus.Network

  @forward_timeout 2_000
  # Cap concurrent upstream relays so a flood of un-owned queries can't exhaust
  # processes/file descriptors.
  @max_inflight 64

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
      upstream:
        parse_upstream(Keyword.get(opts, :upstream, Application.get_env(:vagus, :dns_upstream)))
    }

    {:ok, try_bind(state)}
  end

  defp try_bind(%{ip: ip, port: port} = state) do
    case :gen_udp.open(port, [:binary, :inet, {:ip, ip}, active: true, reuseaddr: true]) do
      {:ok, socket} ->
        Logger.info("Vagus.DNS: listening on #{fmt(ip)}:#{port}")
        %{state | socket: socket}

      {:error, reason} ->
        Logger.warning(
          "Vagus.DNS: bind #{fmt(ip)}:#{port} failed (#{inspect(reason)}), retrying in #{@bind_retry_ms}ms"
        )

        Process.send_after(self(), :retry_bind, @bind_retry_ms)
        state
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

  def handle_info(:retry_bind, %{socket: nil} = state), do: {:noreply, try_bind(state)}
  def handle_info(:retry_bind, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  ## Query handling

  # Returns the (possibly inflight-incremented) state.
  defp handle_packet(packet, host, port, state) do
    case Message.parse_query(packet) do
      {:ok, %{qtype: qtype} = query} ->
        case lookup(strip_suffix(query.qname), state) do
          {:ok, ip} ->
            # We're authoritative for this name: answer A with the record, and
            # any other type (e.g. AAAA) as NOERROR-with-no-answers. Never
            # forward an owned name — a stub resolver doing A+AAAA would take
            # upstream's NXDOMAIN for the AAAA as "the name doesn't exist".
            ips = if qtype == Message.type_a(), do: [ip], else: []
            reply(state.socket, host, port, Message.answer(query, ips))
            state

          :error ->
            forward_or_nxdomain(packet, query, host, port, state)
        end

      {:error, _reason} ->
        # Unparseable (e.g. multi-question) — forward raw if we can, else drop.
        if state.upstream, do: forward(packet, host, port, state), else: state
    end
  end

  defp forward_or_nxdomain(packet, query, host, port, state) do
    if state.upstream do
      forward(packet, host, port, state)
    else
      reply(state.socket, host, port, Message.nxdomain(query))
      state
    end
  end

  # Relay the raw query to the upstream resolver from a throwaway (supervised,
  # so a crash is logged) task so a slow upstream never blocks the server; the
  # answer goes back out our socket.
  # Bounded by `@max_inflight` (drop over the cap) so a flood of misses can't
  # exhaust processes/FDs; the ephemeral socket is always closed (`try/after`,
  # and the port dies with the relay if it is killed). The server monitors
  # each relay and counts it out on its `:DOWN`, however it ended.
  defp forward(_packet, _host, _port, %{relays: relays} = state)
       when map_size(relays) >= @max_inflight,
       do: state

  defp forward(packet, host, port, %{socket: socket, upstream: upstream} = state) do
    relay = fn ->
      case :gen_udp.open(0, [:binary, active: false]) do
        {:ok, s} ->
          try do
            with :ok <- :gen_udp.send(s, upstream, 53, packet),
                 {:ok, {_ip, _p, resp}} <- :gen_udp.recv(s, 0, @forward_timeout) do
              :gen_udp.send(socket, host, port, resp)
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

  defp lookup(name, %{static: static} = state) do
    case app_ip(name, state.directory) || Map.get(static, name) do
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
end
