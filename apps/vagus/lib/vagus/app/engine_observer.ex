defmodule Vagus.App.EngineObserver do
  @moduledoc """
  Tells one controller's runtime which apps to look at again because
  something happened to their instance outside the store: the only
  subscriber to the engine's events, the only reader of its inventory, and
  the monitor of the native apps' processes.

  It owns three things, none durable:

    * the subscription to `Vagus.Runtime.Events`. An event about a
      container wakes the app the container is named for
      (`Vagus.App.Profile.app_of_container/1`), and no other, when its
      action is one that can change what a pass decides (`waking?/1`).
    * the last listing of our containers (`row/1`), and what the next one
      owes. A notice that events were missed wakes every app with a
      container in the listing before it or after it: a listing does not
      show a restart by the engine's own policy, which leaves the same
      container running, and the events that did are the ones lost. The
      `:interval` loses nothing and wakes only the apps whose row appeared,
      went or changed. The first listing after a start wakes every app
      that has a container.
    * a monitor on each native instance it was told of (`watch/3`), whose
      end wakes its app. Nothing restarts such an instance but its app's
      next pass.

  A wake is `Vagus.Resource.Runtime.enqueue/3`, a hint to look: what the
  app's state is, the controller finds by observing. So the listing stays
  private, and a wake for a name that is no app is dropped by the runtime.

  Events can arrive faster than they are handled. Each is only made a
  member of the set of apps to wake, which is emptied once per burst: a
  thousand events about one container are one wake. Nothing paces the
  events worker, so what bounds the mailbox is that this process never
  waits for anything: handling an event is one insertion into a set, and
  the mailbox grows only while the engine emits events faster than that.

  A listing is an engine call, which can take as long as the engine stays
  silent (`:list_timeout` is that silence, not a deadline for the whole
  call), so it is not made here. It runs in a process of its own, linked
  to this one and started by it: one at a time, so a notice that arrives
  meanwhile is remembered and is one more listing after this one, however
  many such notices there were. The link is its whole supervision. It ends
  with this process, whatever ends this process; and a backend that raises
  there ends this process too, with that reason, which costs nothing else.
  Its answer comes back as a message that names the listing it answers.

  A listing that fails, whatever the reason, keeps the last one and what
  is owed, and is tried again after `:relist`, `{first_ms, max_ms}`,
  doubling, by one timer however many notices arrive meanwhile; each
  notice is also a try of its own. A backend whose call exits has failed
  the same way: the client gave up, which another try may not.

  A `rename` names two containers, the one that was and the one that is,
  and wakes the app of each.

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
  dropped. It stands after the controllers and nothing is replaced with
  it. Whatever it missed, and every watch it held, it makes up for when it
  starts: it has its runtime look at every app
  (`Vagus.Resource.Runtime.resync/2`), and each pass that observes a native
  instance watches it again.

  ## Options

    * `:controller`, the controller whose runtime is woken (required), and
      `:instance`
    * `:enqueue`, `(controller, app, [instance: instance] -> term)`
      (default `Vagus.Resource.Runtime.enqueue/3`), and `:resync`,
      `(controller, [instance: instance] -> term)` (default
      `Vagus.Resource.Runtime.resync/2`)
    * `:events`, `{module, server}` to subscribe with, or `nil` for none
      (default `{Vagus.Runtime.Events, Vagus.Runtime.Events}`)
    * `:backend`, the module whose `list/1` is the inventory (default
      `Vagus.App.Backend.Container`), and `:backend_opts` for it
    * `:interval`, milliseconds or `:infinity` (default five minutes)
    * `:list_timeout`, milliseconds (default 15 s); `:relist` (default
      `{1_000, 60_000}`) and `:resubscribe` (default `{100, 30_000}`)
    * `:timer`, `(message, ms -> reference)`, which has `message` sent to
      this process after `ms` (default `Process.send_after/3`)
  """

  use GenServer

  require Logger

  alias Vagus.App.Backend
  alias Vagus.App.Profile
  alias Vagus.Resource
  alias Vagus.Resource.Runtime
  alias Vagus.Runtime.{Docker, Events}

  # What can change what a pass decides: the container is made, runs, has
  # ended or is gone, is held, is called something else, or its health
  # changed. The rest, `exec_*` above all, which a healthcheck emits three
  # of at every probe, says nothing a pass would act on.
  @waking ~w(create start die stop kill oom destroy pause unpause restart rename)

  @doc "Whether an event with this action wakes its app."
  @spec waking?(term()) :: boolean()
  def waking?("health_status" <> _which), do: true
  def waking?(action), do: action in @waking

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
      resync: Keyword.get(opts, :resync, &Runtime.resync/2),
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
      relist: Keyword.get(opts, :relist, {1_000, 60_000}),
      timer: Keyword.get(opts, :timer, &Process.send_after(self(), &1, &2)),
      # `{:subscribed, monitor}`, or `{:retrying, next_delay}` while a timer
      # is out; `nil` with no worker to subscribe to.
      subscription: nil,
      # The interval's timer; `nil` when there is none.
      ticker: nil,
      # `nil` until a listing has succeeded.
      rows: nil,
      # Whom the next listing that succeeds wakes: `:everything` listed
      # before or after it, or only the `:changed`.
      owed: :everything,
      # Whether the next drain starts a listing, or, with one in flight,
      # whether another follows it. Apart from `owed`, which outlives a
      # failed listing while this does not: an event is no reason to ask an
      # engine again that has just failed to answer.
      due?: true,
      # `{ref, pid, owed}` of the listing in flight: what names its answer,
      # the process making it, and whom it wakes if it succeeds.
      listing: nil,
      # `{token, next_delay}` after a failed listing: the token of the
      # timer that is out, or `nil` once it has fired.
      retry: nil,
      wake: MapSet.new(),
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
    # Whatever the process before this one was about to say is lost, and
    # so is every watch it held.
    state.resync.(state.controller, state.i)
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
  def handle_info({:docker_event, %{name: name} = event}, state) do
    if waking?(event[:action]) do
      state =
        [name, former_name(event)] |> Enum.reduce(state, &wake(&2, Profile.app_of_container(&1)))

      {:noreply, soon(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:listed, ref, result}, %{listing: {ref, _pid, owed}} = state),
    do: {:noreply, state |> listed(result, owed) |> soon()}

  def handle_info({:docker_events, :gap}, state),
    do: {:noreply, soon(%{state | owed: :everything, due?: true})}

  def handle_info(:tick, state),
    do: {:noreply, state |> tick() |> owe() |> soon()}

  # The token: a listing that succeeded since has no timer, and the message
  # of the one it had may still arrive.
  def handle_info({:relist, token}, %{retry: {token, delay}} = state),
    do: {:noreply, %{state | retry: {nil, delay}} |> owe() |> soon()}

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

  defp owe(state), do: %{state | owed: state.owed || :changed, due?: true}

  # After whatever is in the mailbox now, so that a burst is one drain.
  defp soon(%{drain?: true} = state), do: state

  defp soon(state) do
    send(self(), :drain)
    %{state | drain?: true}
  end

  defp drain(state) do
    state = if state.due? and state.listing == nil, do: list(state), else: state
    for app <- Enum.sort(state.wake), do: state.enqueue.(state.controller, app, state.i)
    %{state | wake: MapSet.new(), drain?: false}
  end

  # The engine names a renamed container by its new name, and gives the
  # former one as a path from its root.
  defp former_name(%{action: "rename", attributes: %{"oldName" => former}})
       when is_binary(former),
       do: String.trim_leading(former, "/")

  defp former_name(_event), do: nil

  # Linked: the lister ends with this process, and what it raises ends this
  # process. An exit is the client giving up on a call, which is an answer.
  defp list(state) do
    observer = self()
    ref = make_ref()
    %{backend: backend, backend_opts: opts} = state

    {:ok, pid} =
      Task.start_link(fn ->
        result =
          try do
            backend.list(opts)
          catch
            :exit, reason -> {:exit, reason}
          end

        send(observer, {:listed, ref, result})
      end)

    %{state | listing: {ref, pid, state.owed}, owed: nil, due?: false}
  end

  defp listed(state, {:ok, containers}, owed) do
    rows = for summary <- containers, name <- summary.names, into: %{}, do: {name, row(summary)}

    state.rows
    |> owed(rows, owed)
    |> Enum.reduce(
      %{state | rows: rows, listing: nil, retry: nil},
      &wake(&2, Profile.app_of_container(&1))
    )
  end

  defp listed(state, failed, owed) do
    # An engine that is away is how every boot begins: no warning.
    if not match?({:unavailable, _reason}, failed) do
      Logger.warning(
        "Vagus.App.EngineObserver: the containers could not be listed: #{inspect(failed)}"
      )
    end

    # A notice that came meanwhile may owe more than this listing did.
    owed = if :everything in [owed, state.owed], do: :everything, else: owed || state.owed
    again(%{state | listing: nil, owed: owed})
  end

  defp owed(nil, rows, _owed), do: Map.keys(rows)
  defp owed(before, rows, :everything), do: Enum.uniq(Map.keys(before) ++ Map.keys(rows))

  defp owed(before, rows, _changed),
    do: for(name <- owed(before, rows, :everything), before[name] != rows[name], do: name)

  # One timer: a failure while it is out waits for it.
  defp again(%{retry: {token, _delay}} = state) when token != nil, do: state

  defp again(state) do
    {first, max} = state.relist

    delay =
      case state.retry do
        {nil, delay} -> delay
        nil -> first
      end

    token = make_ref()
    state.timer.({:relist, token}, delay)
    %{state | retry: {token, min(delay * 2, max)}}
  end

  defp tick(%{interval: :infinity} = state), do: state
  defp tick(state), do: %{state | ticker: state.timer.(:tick, state.interval)}

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
    state.timer.(:subscribe, delay)
    %{state | subscription: {:retrying, min(delay * 2, max)}}
  end
end
