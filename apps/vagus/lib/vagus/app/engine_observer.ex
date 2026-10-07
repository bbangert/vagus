defmodule Vagus.App.EngineObserver do
  @moduledoc """
  Tells one controller's runtime which apps to look at again because
  something happened to their instance outside the store: the only
  subscriber to the engine's events, the only reader of its inventory, and
  the monitor of the native apps' processes.

  It owns three things, none durable:

    * the subscription to `Vagus.Runtime.Events`. An event about a
      container wakes the app the container is named for
      (`Vagus.App.Profile.app_of_container/1`), and no other.
    * the last listing of our containers. On each notice that events were
      missed, at its own start and every `:interval` it lists them once and
      wakes the apps whose container appeared, went or changed (`row/1`).
      The first listing after its start has nothing to compare with and
      wakes every app that has a container.
    * a monitor on each native instance it was told of (`watch/3`), whose
      end wakes its app. Nothing restarts such an instance but its app's
      next pass.

  A wake is `Vagus.Resource.Runtime.enqueue/3`, a hint to look: what the
  app's state is, the controller finds by observing. So the listing stays
  private, and a wake for a name that is no app is dropped by the runtime.

  Events can arrive faster than they are handled. Each is only made a
  member of the set of apps to wake, which is emptied once per burst: a
  thousand events about one container are one wake.

  A listing is an engine call made in this process, bounded by
  `:list_timeout`. While it is out, events wait in the mailbox, at the
  engine's pace and each a few hundred bytes. When the engine cannot be
  listed the last listing is kept and compared with the next that succeeds:
  the engine's return is announced by the events worker as a gap, and the
  interval is there for when it is not.

  ## The events worker

  It is not in this subtree and keeps its subscribers in its own memory, so
  its replacement has never heard of this process. It is monitored, and
  when it goes, or was not there to begin with, subscribing is tried again
  after `:resubscribe`, `{first_ms, max_ms}`, doubling. A retry, because
  nothing announces that a name is registered again; bounded, because the
  worker's supervisor has it back within milliseconds, and where there is
  no worker at all the cost is one failed call per `max_ms`. Nothing is
  lost by the wait: a subscriber that joins a running stream is sent a gap
  notice at once, and that is a listing.

  ## When this process is absent

  Nothing wakes an app for what happens in the engine, and `watch/3` is
  dropped. Its supervisor replaces the controllers with it, and their
  runtimes start by looking at every app, native ones included, which is
  how the replacement is told again what to watch.

  ## Options

    * `:controller`, the controller whose runtime is woken (required), and
      `:instance`
    * `:enqueue`, `(controller, app, [instance: instance] -> term)`
      (default `Vagus.Resource.Runtime.enqueue/3`)
    * `:events`, `{module, server}` to subscribe with, or `nil` for none
      (default `{Vagus.Runtime.Events, Vagus.Runtime.Events}`)
    * `:backend`, the module whose `list/1` is the inventory (default
      `Vagus.App.Backend.Container`), and `:backend_opts` for it
    * `:interval`, milliseconds or `:infinity` (default five minutes)
    * `:list_timeout`, milliseconds (default 15 s), and `:resubscribe`
      (default `{100, 30_000}`)
  """

  use GenServer

  require Logger

  alias Vagus.App.Backend
  alias Vagus.App.Profile
  alias Vagus.Resource
  alias Vagus.Resource.Runtime
  alias Vagus.Runtime.{Docker, Events}

  @typedoc """
  What of a listed container counts as a change. `detail` is the exit code
  and the health the engine's status text carries, without the durations
  that make the text differ from one listing to the next.
  """
  @type row :: %{
          id: String.t(),
          image: String.t() | nil,
          state: String.t() | nil,
          detail: {exit_code :: integer() | nil, health :: String.t() | nil}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: name(instance(opts)))

  @spec name(atom()) :: atom()
  def name(instance), do: Module.concat(instance, EngineObserver)

  @doc """
  Has `app` woken when `pid`, its native instance, ends. For whoever
  observed the instance: there is no other way to hear of it. An app has
  one watch: told again, of the same pid or another, it watches the one
  just named. A pid that has already ended wakes the app at once.
  """
  @spec watch(Resource.name(), pid(), keyword()) :: :ok
  def watch(app, pid, opts \\ []) when is_binary(app) and is_pid(pid),
    do: GenServer.cast(name(instance(opts)), {:watch, app, pid})

  @doc "One container of a listing as what is compared."
  @spec row(Docker.summary()) :: row()
  def row(%{id: id, image: image, state: state, status: status}),
    do: %{id: id, image: image, state: state, detail: detail(status)}

  # `Up 3 seconds`, `Up 2 minutes (healthy)`, `Exited (137) 4 hours ago`,
  # `Restarting (1) 2 seconds ago`, `Up 5 minutes (Paused)`.
  defp detail(status) when is_binary(status) do
    code =
      case Regex.run(~r/^\w+ \((-?\d+)\)/, status) do
        [_all, code] -> String.to_integer(code)
        nil -> nil
      end

    health =
      case Regex.run(~r/\((healthy|unhealthy|health: starting|Paused)\)/, status) do
        [_all, health] -> health
        nil -> nil
      end

    {code, health}
  end

  defp detail(_none), do: {nil, nil}

  defp instance(opts), do: Keyword.get(opts, :instance, Resource)

  @impl true
  def init(opts) do
    instance = instance(opts)
    list_timeout = Keyword.get(opts, :list_timeout, 15_000)

    state = %{
      controller: Keyword.fetch!(opts, :controller),
      i: [instance: instance],
      enqueue: Keyword.get(opts, :enqueue, &Runtime.enqueue/3),
      events: Keyword.get(opts, :events, {Events, Events}),
      backend: Keyword.get(opts, :backend, Backend.Container),
      backend_opts:
        opts
        |> Keyword.get(:backend_opts, [])
        |> Keyword.update(:engine, [recv_timeout: list_timeout], fn engine ->
          Keyword.put_new(engine, :recv_timeout, list_timeout)
        end),
      interval: Keyword.get(opts, :interval, :timer.minutes(5)),
      resubscribe: Keyword.get(opts, :resubscribe, {100, 30_000}),
      # `{:subscribed, monitor}`, or `{:retrying, next_delay}` while a timer
      # is out; `nil` with no worker to subscribe to.
      subscription: nil,
      # The interval's timer; `nil` when there is none.
      ticker: nil,
      # `nil` until a listing has succeeded.
      rows: nil,
      wake: MapSet.new(),
      list?: true,
      drain?: false,
      # `app => {pid, monitor}` and `monitor => app`.
      natives: %{},
      monitors: %{}
    }

    {:ok, state, {:continue, :start}}
  end

  # Not in `init/1`: the first listing waits for the engine, and nothing
  # that starts after this process needs it done.
  @impl true
  def handle_continue(:start, state) do
    {first, _max} = state.resubscribe
    {:noreply, state |> subscribe(first) |> tick() |> drain()}
  end

  @impl true
  def handle_cast({:watch, app, pid}, state) do
    state = unwatch(state, state.natives[app])
    monitor = Process.monitor(pid)

    {:noreply,
     %{
       state
       | natives: Map.put(state.natives, app, {pid, monitor}),
         monitors: Map.put(state.monitors, monitor, app)
     }}
  end

  @impl true
  def handle_info({:docker_event, %{name: name}}, state),
    do: {:noreply, state |> wake(Profile.app_of_container(name)) |> soon()}

  def handle_info({:docker_events, :gap}, state), do: {:noreply, soon(%{state | list?: true})}

  def handle_info(:tick, state),
    do: {:noreply, state |> tick() |> Map.put(:list?, true) |> soon()}

  def handle_info(:drain, state), do: {:noreply, drain(state)}

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{subscription: {:subscribed, monitor}} = state
      ) do
    {first, _max} = state.resubscribe
    {:noreply, retry(state, first)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state)
      when is_map_key(state.monitors, monitor) do
    {app, monitors} = Map.pop(state.monitors, monitor)
    state = %{state | monitors: monitors, natives: Map.delete(state.natives, app)}
    {:noreply, state |> wake(app) |> soon()}
  end

  def handle_info(:subscribe, %{subscription: {:retrying, delay}} = state),
    do: {:noreply, subscribe(state, delay)}

  def handle_info(_other, state), do: {:noreply, state}

  defp unwatch(state, nil), do: state

  defp unwatch(state, {_pid, monitor}) do
    Process.demonitor(monitor, [:flush])
    %{state | monitors: Map.delete(state.monitors, monitor)}
  end

  defp wake(state, nil), do: state
  defp wake(state, app), do: %{state | wake: MapSet.put(state.wake, app)}

  # After whatever is in the mailbox now, so that a burst is one drain.
  defp soon(%{drain?: true} = state), do: state

  defp soon(state) do
    send(self(), :drain)
    %{state | drain?: true}
  end

  defp drain(state) do
    state = if state.list?, do: list(%{state | list?: false}), else: state
    for app <- Enum.sort(state.wake), do: state.enqueue.(state.controller, app, state.i)
    %{state | wake: MapSet.new(), drain?: false}
  end

  defp list(state) do
    case listing(state) do
      {:ok, containers} ->
        rows =
          for summary <- containers, name <- summary.names, into: %{}, do: {name, row(summary)}

        changed = changed(state.rows, rows)
        Enum.reduce(changed, %{state | rows: rows}, &wake(&2, Profile.app_of_container(&1)))

      {:unavailable, _reason} ->
        state

      failed ->
        Logger.warning(
          "Vagus.App.EngineObserver: the containers could not be listed: #{inspect(failed)}"
        )

        state
    end
  end

  # The backend is the engine's client, and its failures are values. One
  # that raised or exited instead is a listing that did not happen, as for
  # an engine that is away, and must not end the process the runtimes are
  # replaced with.
  defp listing(state) do
    state.backend.list(state.backend_opts)
  catch
    kind, reason -> {kind, reason}
  end

  defp changed(nil, rows), do: Map.keys(rows)

  defp changed(before, rows) do
    for name <- Enum.uniq(Map.keys(before) ++ Map.keys(rows)),
        before[name] != rows[name],
        do: name
  end

  defp tick(%{interval: :infinity} = state), do: state

  defp tick(state),
    do: %{state | ticker: Process.send_after(self(), :tick, state.interval)}

  defp subscribe(%{events: nil} = state, _delay), do: state

  defp subscribe(%{events: {module, server}} = state, delay) do
    # Before the call: a worker that dies between the two is then heard of.
    monitor = Process.monitor(server)

    if subscribed?(module, server) do
      %{state | subscription: {:subscribed, monitor}}
    else
      Process.demonitor(monitor, [:flush])
      retry(state, delay)
    end
  end

  defp subscribed?(module, server) do
    module.subscribe(server) == :ok
  catch
    :exit, _reason -> false
  end

  defp retry(state, delay) do
    {_first, max} = state.resubscribe
    Process.send_after(self(), :subscribe, delay)
    %{state | subscription: {:retrying, min(delay * 2, max)}}
  end
end
