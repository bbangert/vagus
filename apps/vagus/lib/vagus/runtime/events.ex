defmodule Vagus.Runtime.Events do
  @moduledoc """
  The engine's container-event stream, the container-event half of the
  watchdog (`docs/contract-2026.7-m4b-ingress-watchdog.md` §B6.1, real
  Supervisor's `DockerMonitor._run()`). The transport is a
  `Vagus.Runtime.Events.Source` (`:source`, default the engine's own); this
  process fans its events out to subscribers as
  `{:engine_event, %Vagus.Runtime.Engine.Event{}}`. An app container's event
  also goes to that app's process, looked up in `Vagus.App.Directory` as each
  event is sent, so a restarted app process gets the next one without
  subscribing.

  ## After a reconnect

  Events missed while the stream was down are never replayed, so each time
  the source reports the stream ready (the first time included) the app
  containers are listed and each app process is sent its container's state
  as the event it missed: a running one as `:start`, an exited one as `:die`
  with its exit code. The app process ignores one about a container it does
  not hold, so a repeat is harmless. The list runs in a task; only the
  default-named instance lists unless `:resync` or `:list` is given.

  A listing is older than any event that arrives while it runs, so the task
  only returns it, tagged with its connection's generation: app events that
  arrive meanwhile are held back and sent after the listing's, and a listing
  from an earlier connection is dropped.

  ## The managed gate

  Only events for a container the engine reports as `managed` (the
  `supervisor_managed` label), whose name starts with `addon_`, or whose name
  equals `Vagus.Core.Container.name()` (the adopted Core container carries
  no Vagus label until its first rebuild — name is its only stable identity)
  are ever sent to a subscriber, so unrelated host containers cannot flood
  them.

  ## Reconnect

  A closed stream or a failed connect is followed by a reconnect with
  exponential backoff — 1s, 2s, 4s, ... capped at 30s — so an engine restart
  doesn't spin. The backoff resets as soon as the engine answers; a
  connection that never gets that far keeps escalating. Each drop is logged
  once at `warning`; the retry ticks themselves log at `debug`.

  Gated at the application-supervisor level by `config :vagus, :events_enabled`
  (default `true`, `false` in `config/test.exs`) — mirrors `Vagus.DNS`'s
  `:dns_enabled` gating in `Vagus.Application`. This module itself always
  runs (and always tries to connect) once started; it doesn't gate itself.
  """

  use GenServer

  require Logger

  alias Vagus.Runtime.Engine
  alias Vagus.Runtime.Engine.{Container, Event}

  @initial_backoff_ms 1_000
  @max_backoff_ms 30_000

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Subscribes the calling process to `{:engine_event, event}` messages. The
  server monitors the caller and drops it from the subscriber list on
  `:DOWN` — a crashed/dead subscriber is pruned automatically, never leaked.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc "Unsubscribes the calling process."
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__) do
    GenServer.call(server, {:unsubscribe, self()})
  end

  ## GenServer

  # `:engine_opts` reach the source (its choice and `init/1`) and the resync
  # listing alike.
  @impl GenServer
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    engine_opts = Keyword.get(opts, :engine_opts, [])
    source = Keyword.get_lazy(opts, :source, fn -> Engine.event_source(engine_opts) end)

    state = %{
      source: source,
      src: source.init(engine_opts),
      connected: false,
      subscribers: %{},
      backoff_ms: @initial_backoff_ms,
      # The pending :connect retry timer, if any — kept so a second drop can
      # never arm a second retry loop beside it.
      reconnect_timer: nil,
      route: Keyword.get(opts, :route, &route/1),
      list: list(opts, name, engine_opts),
      generation: 0,
      # While a listing runs: its task's monitor and the app events held back.
      resync: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state), do: {:noreply, do_connect(state)}

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, %{subscribers: subs} = state) do
    subs =
      if Map.has_key?(subs, pid) do
        subs
      else
        Map.put(subs, pid, Process.monitor(pid))
      end

    {:reply, :ok, %{state | subscribers: subs}}
  end

  def handle_call({:unsubscribe, pid}, _from, %{subscribers: subs} = state) do
    case Map.pop(subs, pid) do
      {nil, ^subs} ->
        {:reply, :ok, state}

      {ref, rest} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | subscribers: rest}}
    end
  end

  @impl GenServer
  # Every message Events owns is tagged with this module or is a `:DOWN` for a
  # ref it holds; everything else belongs to the source.
  #
  # The retry timer: the debug-level counterpart to the warning logged once
  # when the drop that scheduled it happened (see schedule_reconnect/2).
  def handle_info({__MODULE__, :connect}, state) do
    Logger.debug("Vagus.Runtime.Events: attempting to (re)connect")
    {:noreply, do_connect(%{state | reconnect_timer: nil})}
  end

  def handle_info(
        {__MODULE__, :resync, gen, result},
        %{generation: gen, resync: {ref, held}} = state
      ) do
    Process.demonitor(ref, [:flush])

    missed =
      case result do
        {:ok, containers} ->
          Enum.flat_map(containers, &missed/1)

        {:error, reason} ->
          Logger.warning("Vagus.Runtime.Events: no resync: #{inspect(reason)}")
          []
      end

    Enum.each(missed ++ Enum.reverse(held), state.route)
    {:noreply, %{state | resync: nil}}
  end

  def handle_info({__MODULE__, :resync, _gen, _result}, state), do: {:noreply, state}

  # The listing died without an answer: what it held back goes out unordered
  # against nothing.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{resync: {ref, held}} = state) do
    Logger.warning("Vagus.Runtime.Events: no resync: the listing died (#{inspect(reason)})")
    Enum.each(Enum.reverse(held), state.route)
    {:noreply, %{state | resync: nil}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason} = msg, %{subscribers: subs} = state) do
    case Map.fetch(subs, pid) do
      {:ok, ^ref} -> {:noreply, %{state | subscribers: Map.delete(subs, pid)}}
      _ -> to_source(msg, state)
    end
  end

  def handle_info(msg, state), do: to_source(msg, state)

  # Only a connected source is asked: after `close/1` it has nothing to own.
  defp to_source(msg, %{connected: true} = state) do
    case state.source.handle_info(msg, state.src) do
      {:ok, notices, src} ->
        {:noreply, Enum.reduce(notices, %{state | src: src}, &notice/2)}

      # Whatever arrived before the close still counts.
      {:closed, reason, notices, src} ->
        state = Enum.reduce(notices, %{state | src: src}, &notice/2)
        {:noreply, schedule_reconnect(reason, close(state))}

      :unknown ->
        {:noreply, state}
    end
  end

  defp to_source(_msg, state), do: {:noreply, state}

  defp do_connect(state) do
    case state.source.connect(state.src) do
      {:ok, notices, src} -> Enum.reduce(notices, %{state | src: src, connected: true}, &notice/2)
      {:error, reason} -> schedule_reconnect(reason, state)
    end
  end

  defp close(state), do: %{state | src: state.source.close(state.src), connected: false}

  # Logs the drop exactly once (warning) and arms the retry timer; the retry
  # tick itself (handle_info({__MODULE__, :connect}, ...)) logs at debug. Backoff for the
  # *next* drop is doubled (capped) here; an engine that answered resets it
  # to the floor first (see notice/2).
  #
  # One drop is scheduled once: when a retry is already pending, nothing
  # more happens — no second warning, no second timer, no extra doubling.
  # Public (`@doc false`) for its unit test.
  @doc false
  @spec schedule_reconnect(term(), map()) :: map()
  def schedule_reconnect(_reason, %{reconnect_timer: timer} = state) when timer != nil, do: state

  def schedule_reconnect(reason, state) do
    delay = state.backoff_ms

    Logger.warning(
      "Vagus.Runtime.Events: event stream dropped (#{inspect(reason)}); reconnecting in #{delay}ms"
    )

    %{
      state
      | reconnect_timer: Process.send_after(self(), {__MODULE__, :connect}, delay),
        backoff_ms: min(delay * 2, @max_backoff_ms)
    }
  end

  defp notice(:answered, state), do: %{state | backoff_ms: @initial_backoff_ms}
  defp notice(:ready, state), do: resync(%{state | backoff_ms: @initial_backoff_ms})
  defp notice(%Event{} = event, state), do: dispatch(event, state)

  # Core-name pass-through: the adopted Core container has no Vagus label
  # (and won't until a rebuild), so its fixed name is its identity here.
  defp dispatch(%Event{name: name} = event, state) do
    managed? =
      event.managed or
        (is_binary(name) and
           (String.starts_with?(name, "addon_") or name == Vagus.Core.Container.name()))

    if managed? do
      Enum.each(state.subscribers, fn {pid, _ref} -> send(pid, {:engine_event, event}) end)
      route_live(event, state)
    else
      state
    end
  end

  defp route_live(payload, %{resync: {ref, held}} = state),
    do: %{state | resync: {ref, [payload | held]}}

  defp route_live(payload, state) do
    state.route.(payload)
    state
  end

  defp route(%{name: "addon_" <> slug} = payload) do
    case Registry.lookup(Vagus.App.Directory, {:slug, slug}) do
      [{pid, _value}] -> send(pid, {:engine_event, payload})
      [] -> :ok
    end
  rescue
    # The directory is restarting; its app processes start over without it.
    ArgumentError -> :ok
  end

  defp route(_payload), do: :ok

  defp list(opts, name, engine_opts) do
    cond do
      list = opts[:list] -> list
      Keyword.get(opts, :resync, name == __MODULE__) -> fn -> list_apps(engine_opts) end
      true -> nil
    end
  end

  defp list_apps(engine_opts), do: Engine.list([all: true, name_prefix: "addon_"] ++ engine_opts)

  defp resync(%{list: nil} = state), do: state

  # What an earlier listing still held back is older than this connection.
  # A listing that cannot start is a listing that failed: nothing is held.
  defp resync(%{list: list} = state) do
    state = flush_held(state)
    gen = state.generation + 1
    %{state | generation: gen, resync: start_listing(list, gen)}
  end

  defp start_listing(list, gen) do
    parent = self()

    case Task.Supervisor.start_child(Vagus.TaskSupervisor, fn ->
           send(parent, {__MODULE__, :resync, gen, list.()})
         end) do
      {:ok, pid} -> {Process.monitor(pid), []}
      {:error, reason} -> no_listing(reason)
    end
  catch
    :exit, reason -> no_listing(reason)
  end

  defp no_listing(reason) do
    Logger.warning(
      "Vagus.Runtime.Events: no resync: the listing did not start (#{inspect(reason)})"
    )

    nil
  end

  defp flush_held(%{resync: {ref, held}} = state) do
    Process.demonitor(ref, [:flush])
    Enum.each(Enum.reverse(held), state.route)
    %{state | resync: nil}
  end

  defp flush_held(state), do: state

  # Running and exited only: what an app process acts on.
  defp missed(%Container{name: "addon_" <> _ = name, state: :running} = c),
    do: [%Event{action: :start, name: name, id: c.id}]

  defp missed(%Container{name: "addon_" <> _ = name, state: :exited} = c),
    do: [%Event{action: :die, name: name, id: c.id, exit_code: c.exit_code}]

  defp missed(_container), do: []
end
