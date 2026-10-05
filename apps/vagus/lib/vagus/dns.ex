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

  The per-add-on records live in memory only, so on (re)start `init/1`
  continues into a rebuild: every add-on `Vagus.Addon.State.running/1`
  (`opts[:addon_state]`, default `Vagus.Addon.State`) lists gets the record
  `Vagus.Addon.Manager.dns_record/3` gives it (a Docker inspect of its
  container, `opts[:docker]` the inspect options) — so a crash here no
  longer leaves running add-ons nameless until each restarts. On the normal
  boot path `State` lists nothing running yet and the rebuild is a no-op.

  The inspects run in a task under the relay task supervisor, so a slow or
  hung engine never stops the server answering queries or taking
  `register/3`/`unregister/2` calls. A name registered or unregistered while
  the rebuild is in flight keeps that newer outcome when the task's records
  are merged in.
  """

  use GenServer

  require Logger

  alias Vagus.Addon.Manager
  alias Vagus.DNS.Message
  alias Vagus.Network

  @forward_timeout 2_000
  # Cap concurrent upstream relays so a flood of un-owned queries can't exhaust
  # processes/file descriptors.
  @max_inflight 64

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
      dynamic: %{},
      # Monitor ref -> relay pid for each upstream relay in flight; its size
      # is the in-flight count (see forward/4).
      relays: %{},
      # The in-flight post-restart rebuild: its task ref plus the names
      # (un)registered since it started, which its records must not overwrite.
      rebuild: nil,
      # Where upstream relays run (a test seam for the supervisor-down path).
      task_supervisor: Keyword.get(opts, :task_supervisor, Vagus.TaskSupervisor),
      upstream:
        parse_upstream(Keyword.get(opts, :upstream, Application.get_env(:vagus, :dns_upstream)))
    }

    rebuild = {:rebuild, Keyword.get(opts, :addon_state, Vagus.Addon.State), opts[:docker] || []}
    {:ok, try_bind(state), {:continue, rebuild}}
  end

  @impl GenServer
  def handle_continue({:rebuild, addon_state, docker_opts}, state) do
    case running_addons(addon_state) do
      [] -> {:noreply, state}
      running -> {:noreply, start_rebuild(fn -> addon_records(running, docker_opts) end, state)}
    end
  end

  # Docker inspects can each take up to the client's receive timeout, so they
  # run off the server process; with no task supervisor (it's restarting),
  # fall back to doing them inline rather than dropping the rebuild.
  defp start_rebuild(fun, state) do
    task = Task.Supervisor.async_nolink(state.task_supervisor, fun)
    %{state | rebuild: %{ref: task.ref, touched: MapSet.new()}}
  catch
    :exit, reason ->
      Logger.warning("Vagus.DNS: rebuild task not started (#{inspect(reason)}), running inline")
      merge_rebuild(fun.(), MapSet.new(), state)
  end

  defp addon_records(running, docker_opts) do
    for {config, _token} <- running,
        {:ok, host, ip} <-
          [Manager.dns_record(config, Manager.container_name(config.slug), docker_opts)],
        into: %{},
        do: {String.downcase(host), to_ip(ip)}
  end

  # Names (un)registered since the rebuild started already hold their newer
  # outcome, so the rebuilt records never overwrite or resurrect them.
  defp merge_rebuild(records, touched, state) do
    records = Map.drop(records, MapSet.to_list(touched))
    %{state | dynamic: Map.merge(records, state.dynamic), rebuild: nil}
  end

  defp touch(%{rebuild: %{touched: touched} = rebuild} = state, host),
    do: %{state | rebuild: %{rebuild | touched: MapSet.put(touched, host)}}

  defp touch(state, _host), do: state

  # Best-effort: `State` not running (isolated tests) or exiting mid-call
  # leaves nothing to rebuild.
  defp running_addons(addon_state) do
    if GenServer.whereis(addon_state), do: Vagus.Addon.State.running(addon_state), else: []
  catch
    :exit, _reason -> []
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
  def handle_call({:register, host, ip}, _from, state) do
    {:reply, :ok, touch(%{state | dynamic: Map.put(state.dynamic, host, ip)}, host)}
  end

  def handle_call({:unregister, host}, _from, state) do
    {:reply, :ok, touch(%{state | dynamic: Map.delete(state.dynamic, host)}, host)}
  end

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

  def handle_info({ref, records}, %{rebuild: %{ref: ref, touched: touched}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, merge_rebuild(records, touched, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{rebuild: %{ref: ref}} = state) do
    Logger.warning("Vagus.DNS: add-on record rebuild failed: #{inspect(reason)}")
    {:noreply, %{state | rebuild: nil}}
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
  # crash this server and lose its dynamic records.
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
