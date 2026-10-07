defmodule Vagus.App.Pulls do
  @moduledoc """
  Image pulls, one in flight per image reference, each in a task of its own.

  A pull takes minutes and says nothing for long stretches, so it cannot be
  an action of a controller's pass: the pass would hold its resource's place
  in the runtime for all of it, and a stop arriving meanwhile would wait.
  Instead a pass asks for the image (`request/3`, which returns at once),
  reads how the pull is doing (`state/2`), and is looked at again when the
  pull ends. A second request for a reference being pulled joins that pull.

  This process owns which pulls are in flight, who waits for each, and the
  table `state/2` reads; the pulls themselves run under the task supervisor
  started after it (`child_specs/1` is the pair, in that order), each
  holding the `:pull` lane of `Vagus.Resource.Lanes` for as long as it runs. It does no engine work and runs nobody's code, so
  it answers at once whatever a pull is doing.

  ## State

  `state/2` is a table read and never waits for this process:

    * `:idle`: nothing is known. Whether the image is there is the engine's
      to say, and a pull that succeeded leaves just this.
    * `{:pulling, progress}`: in flight, or waiting for the lane with
      `progress` still `nil`.
    * `{:failed, reason, stamp}`: the last pull failed then. It is not
      retried here; the next `request/3` starts another. `reason` is a
      `t:Vagus.Runtime.Docker.failure/0`, so an engine that was away
      (`{:unreachable, _}`) reads differently from an image that does not
      exist, or `{:crashed, reason}` for a pull that died.

  ## Waiters

  A pull exists for its waiters and for as long as it has one. A waiter is
  `{controller, resource name}`: data, so it means the same after either
  side restarts. Every request names its waiter; when the pull ends, by
  success, failure or its last waiter's `cancel/3`, each waiter gets
  `Vagus.Resource.Runtime.enqueue/3`.

  `cancel/3` withdraws one waiter. The pull ends when the waiter withdrawn
  was the last on its list, and a cancel by anyone not on the list changes
  nothing about it. Ending a pull kills its task, which closes its
  connection, which is what makes the engine stop.

  ## Progress

  A pull reports far more often than anyone can use. Its task summarises the
  lines and passes a summary on at most once per `:progress_interval`: to
  the table, and to the `:on_progress` function of each waiter. A waiter has
  one such function, that of its latest request, and none once it has
  withdrawn. They run in the pull's task, between two reads of the stream,
  and one that is slow slows the pull.

  The task is given the functions for a summary when it hands the summary
  over, and calls them afterwards, outside this process. So a function may
  be called once more, for a summary already on its way, after the request
  that replaced it or the cancel that withdrew it has returned. It is never
  called for a later summary. A function must therefore tolerate one call
  that arrives after its waiter has moved on.

  ## When this process is absent

  `state/2` reads `:idle`, and `request/3` and `cancel/3` exit. Its
  supervisor restarts everything after it with it: the tasks, so that no
  pull outlives the process that would have reported it, and the runtimes,
  whose resources are the waiters it has forgotten and which look at
  everything when they start.

  ## Options

  `:instance`; `:client` (default `Vagus.Runtime.Docker`) and `:engine`, a
  keyword given to its `pull_image_stream/4` (`:socket`, `:idle_timeout`,
  `:total_timeout`); `:clock`; `:progress_interval`, milliseconds (default
  500).
  """

  use GenServer

  require Logger

  alias Vagus.Resource
  alias Vagus.Resource.{Clock, Lanes, Runtime, Stamp}
  alias Vagus.Runtime.Docker

  @type waiter :: {controller :: module(), Resource.name()}

  @typedoc """
  `current` and `total` are bytes to download, over the layers announced so
  far; `layers_done` counts those with nothing left to download.
  """
  @type progress :: %{
          status: String.t() | nil,
          current: non_neg_integer(),
          total: non_neg_integer(),
          layers: non_neg_integer(),
          layers_done: non_neg_integer()
        }

  @type state ::
          :idle
          | {:pulling, progress() | nil}
          | {:failed, Docker.failure() | {:crashed, term()}, Stamp.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: name(instance(opts)))

  @spec name(atom()) :: atom()
  def name(instance), do: Module.concat(instance, Pulls)

  @doc "The name of the task supervisor the pulls run under."
  @spec tasks(atom()) :: atom()
  def tasks(instance), do: Module.concat(instance, PullTasks)

  @doc "The table of `{image, state}` rows."
  @spec table(atom()) :: atom()
  def table(instance), do: Module.concat(instance, PullStates)

  @doc """
  The worker and the task supervisor its pulls run under, in the order they
  must start: placed so in a `:rest_for_one` supervisor, the tasks end with
  the worker. Options are the worker's.
  """
  @spec child_specs(keyword()) :: [Supervisor.child_spec() | {module(), keyword()}]
  def child_specs(opts \\ []) do
    [
      {__MODULE__, opts},
      # No `:max_children`: one task per image being pulled, and those are
      # the images of the apps installed.
      Supervisor.child_spec({Task.Supervisor, name: tasks(instance(opts))},
        id: tasks(instance(opts))
      )
    ]
  end

  @doc """
  Has `image` pulled for `waiter`, unless it is being pulled already, in
  which case `waiter` joins. Options: `:instance`; `:platform`; `:priority`,
  the pull's place among those waiting for the lane; `:on_progress`, which
  replaces the function of an earlier request by the same waiter for every
  summary not already on its way (see "Progress"). Platform
  and priority are those of the request that started the pull.
  """
  @spec request(String.t(), waiter(), keyword()) :: :ok
  def request(image, {controller, _name} = waiter, opts \\ [])
      when is_binary(image) and is_atom(controller) do
    GenServer.call(
      name(instance(opts)),
      {:request, image, waiter, Keyword.take(opts, [:platform, :priority, :on_progress])}
    )
  end

  @doc """
  Withdraws `waiter` from the pull of `image`, ending the pull if it was the
  last. Its progress function may still be called once, for a summary
  already on its way. With no pull in flight, a remembered failure is forgotten. A pull
  this ends has its task gone when this returns.
  """
  @spec cancel(String.t(), waiter(), keyword()) :: :ok
  def cancel(image, {controller, _name} = waiter, opts \\ [])
      when is_binary(image) and is_atom(controller),
      do: GenServer.call(name(instance(opts)), {:cancel, image, waiter})

  @spec state(String.t(), keyword()) :: state()
  def state(image, opts \\ []) do
    case :ets.lookup(table(instance(opts)), image) do
      [{^image, state}] -> state
      [] -> :idle
    end
  rescue
    # No table: no worker, and so no pull.
    ArgumentError -> :idle
  end

  @doc "The pulls in flight: each one's task and waiters."
  @spec info(keyword()) :: %{optional(String.t()) => %{task: pid(), waiters: [waiter()]}}
  def info(opts \\ []), do: GenServer.call(name(instance(opts)), :info)

  defp instance(opts), do: Keyword.get(opts, :instance, Resource)

  @impl true
  def init(opts) do
    instance = instance(opts)

    # Owned here and not inherited: a row is about a task, and no task
    # outlives this process.
    table = :ets.new(table(instance), [:named_table, :set, :protected, read_concurrency: true])

    {:ok,
     %{
       instance: instance,
       table: table,
       tasks: tasks(instance),
       clock: Keyword.get(opts, :clock, Clock.System),
       pull: %{
         worker: self(),
         instance: instance,
         client: Keyword.get(opts, :client, Docker),
         engine: Keyword.get(opts, :engine, []),
         interval: Keyword.get(opts, :progress_interval, 500)
       },
       pulls: %{},
       refs: %{}
     }}
  end

  @impl true
  def handle_call({:request, image, waiter, opts}, _from, state) do
    pull =
      case state.pulls do
        %{^image => pull} -> pull
        _none -> start(state, image, opts)
      end

    pull = %{pull | waiters: Map.put(pull.waiters, waiter, opts[:on_progress])}

    state = %{
      state
      | pulls: Map.put(state.pulls, image, pull),
        refs: Map.put(state.refs, pull.task.ref, image)
    }

    {:reply, :ok, state}
  end

  def handle_call({:cancel, image, waiter}, _from, state) do
    case state.pulls do
      %{^image => %{waiters: %{^waiter => _callback} = waiters} = pull}
      when map_size(waiters) == 1 ->
        # Synchronous, so the row is not cleared while the pull still runs.
        _ = Task.Supervisor.terminate_child(state.tasks, pull.task.pid)
        Process.demonitor(pull.task.ref, [:flush])
        {:reply, :ok, ended(state, image, pull, :idle)}

      %{^image => pull} ->
        pull = %{pull | waiters: Map.delete(pull.waiters, waiter)}
        {:reply, :ok, %{state | pulls: Map.put(state.pulls, image, pull)}}

      _none ->
        :ets.delete(state.table, image)
        {:reply, :ok, state}
    end
  end

  # The pid is the token: a task that was cancelled may have this call in
  # the mailbox still, and the reference may be pulled again since.
  def handle_call({:progress, image, progress}, {pid, _tag}, state) do
    case state.pulls do
      %{^image => %{task: %Task{pid: ^pid}, waiters: waiters}} ->
        :ets.insert(state.table, {image, {:pulling, progress}})
        {:reply, for({_waiter, callback} <- waiters, callback != nil, do: callback), state}

      _another ->
        {:reply, [], state}
    end
  end

  def handle_call(:info, _from, state) do
    info =
      Map.new(state.pulls, fn {image, pull} ->
        {image, %{task: pull.task.pid, waiters: pull.waiters |> Map.keys() |> Enum.sort()}}
      end)

    {:reply, info, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_map_key(state.refs, ref) do
    Process.demonitor(ref, [:flush])

    outcome =
      case result do
        :ok -> :idle
        {:error, failure} -> {:failed, failure, Clock.now(state.clock)}
      end

    {:noreply, ended(state, ref, outcome)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_map_key(state.refs, ref),
    do: {:noreply, ended(state, ref, {:failed, {:crashed, reason}, Clock.now(state.clock)})}

  def handle_info(_other, state), do: {:noreply, state}

  defp start(state, image, opts) do
    pull =
      Map.merge(state.pull, %{
        image: image,
        platform: opts[:platform],
        priority: Keyword.get(opts, :priority, 0)
      })

    :ets.insert(state.table, {image, {:pulling, nil}})
    task = Task.Supervisor.async_nolink(state.tasks, __MODULE__, :pull, [pull])
    %{task: task, waiters: %{}}
  end

  defp ended(state, ref, outcome) when is_reference(ref) do
    image = Map.fetch!(state.refs, ref)
    ended(state, image, Map.fetch!(state.pulls, image), outcome)
  end

  # The table before the wake-ups: a waiter that is looked at reads the end.
  defp ended(state, image, pull, outcome) do
    case outcome do
      :idle -> :ets.delete(state.table, image)
      failed -> :ets.insert(state.table, {image, failed})
    end

    for {{controller, name}, _callback} <- pull.waiters,
        do: Runtime.enqueue(controller, name, instance: state.instance)

    %{state | pulls: Map.delete(state.pulls, image), refs: Map.delete(state.refs, pull.task.ref)}
  end

  @doc false
  @spec pull(map()) :: :ok | {:error, Docker.failure()}
  def pull(%{client: client, image: image} = pull) do
    Lanes.run(:pull, [instance: pull.instance, priority: pull.priority], fn ->
      opts = if pull.platform, do: [platform: pull.platform] ++ pull.engine, else: pull.engine
      seen = %{layers: %{}, status: nil, sent: nil}

      case client.pull_image_stream(image, seen, &line(&1, &2, pull), opts) do
        {:ok, _seen} -> :ok
        {:error, reason} -> {:error, client.failure(reason)}
      end
    end)
  end

  # What is kept of the stream is one entry per layer, a few dozen at most.
  defp line(line, seen, pull) do
    seen = %{seen | status: line["status"] || seen.status, layers: layer(seen.layers, line)}
    now = System.monotonic_time(:millisecond)

    if seen.sent == nil or now - seen.sent >= pull.interval do
      progress = summary(seen)
      # A call, so that this task is paced by the worker and cannot fill its
      # mailbox whatever the interval.
      for callback <- GenServer.call(pull.worker, {:progress, pull.image, progress}),
          do: report(callback, progress, pull.image)

      %{seen | sent: now}
    else
      seen
    end
  end

  # A layer is `{downloaded, to_download, done?}`. The engine names a layer
  # in any of these lines first, and skips whichever do not apply: one it
  # already has is announced as existing and nothing else, a small one may
  # go from waiting to complete with no `Downloading` between.
  defp layer(layers, %{"id" => id, "status" => status} = line) when is_binary(id) do
    case {status, line["progressDetail"]} do
      # The line that announces the tag carries it as its `id`.
      {"Pulling from " <> _repository, _detail} ->
        layers

      {"Downloading", %{"current" => current, "total" => total}}
      when is_integer(current) and is_integer(total) ->
        Map.put(layers, id, {current, total, false})

      {done, _detail} when done in ["Download complete", "Pull complete", "Already exists"] ->
        {_current, total, _done?} = Map.get(layers, id, {0, 0, false})
        Map.put(layers, id, {total, total, true})

      _waiting_verifying_or_extracting ->
        Map.put_new(layers, id, {0, 0, false})
    end
  end

  defp layer(layers, _line), do: layers

  defp summary(%{layers: layers, status: status}) do
    layers = Map.values(layers)

    %{
      status: status,
      current: layers |> Enum.map(&elem(&1, 0)) |> Enum.sum(),
      total: layers |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
      layers: length(layers),
      layers_done: Enum.count(layers, &elem(&1, 2))
    }
  end

  # Somebody else's function: what it raises is its own failure, not the
  # pull's.
  defp report(callback, progress, image) do
    callback.(progress)
  catch
    kind, reason ->
      Logger.warning("pull of #{image}: a progress function failed: #{inspect({kind, reason})}")
  end
end
