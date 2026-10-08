defmodule Vagus.Test.AppWorld do
  @moduledoc """
  What a scenario of the App controller runs in: the real controller in a
  `Vagus.Resource.Harness` system, against a `Vagus.Test.FakeEngine.Model`,
  a data root in a temporary directory, a probe the test answers for, and
  the harness's clock in the pull worker too.

  ## The journal

  What was done for an app is what the things done to say, never the
  controller: the engine's requests as they arrived there, the calls the
  token table and the pull worker handled, the children the native
  supervisor was asked to start and end, and an app's data directory going
  away. Each tells the harness's world as it happens, in a call, so the
  journal is in the order things were done. An action that never reached
  any of them, a create whose preparation failed, is not in it.

  Some entries say more than their action. A start that arrived while the
  token table did not resolve the container's token to the app is
  `{:start, :token_unknown}`, and a create that arrived before the app's
  options were written is `{:create, :unprepared}`: both are looked at
  where the request lands, at the moment it lands. A start, stop or remove
  of a container that was there and is gone is `{action, :gone}`: asked
  for by an id the engine has no container for any more.

  `new/1` makes a world, a map of what stays the same across the systems
  started in it; `system/2` is the `Vagus.Resource.Harness.start_system/1`
  options for one. Every system started from them begins with an engine
  that has nothing in it and an empty data root, which is what lets the
  fault harness run a scenario many times over: the engine is a child of
  the system, and `:seed` is called with it before anything else starts.
  """

  import ExUnit.Assertions

  alias Vagus.App.{AuthIndex, Backend, Controller, EngineObserver, Facts, Prepare, Pulls}
  alias Vagus.App.Container.Config
  alias Vagus.Resource.{Harness, Runtime, Store, TestClock}
  alias Vagus.Test.{AppManifests, FakeEngine, Recording}
  alias Vagus.Test.FakeEngine.Model

  @doc """
  Options: `:gates`; `:seed`, a function of the engine called at each
  system's start, and `:before`, one called before anything of the system
  starts; `:boot_marker`, with which `Vagus.App.Boot` is among the
  services; `:native`, whether a supervisor for native apps is part of each
  system (they bind a port: such a test is not async).
  """
  @spec new(keyword()) :: map()
  def new(opts \\ []) do
    # With the OS process: the counter starts over in every VM.
    id = "#{System.pid()}-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "vagus-app-#{id}")
    File.mkdir_p!(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)

    %{
      id: id,
      root: root,
      data: Path.join(root, "data"),
      socket: Path.join(root, "engine.sock"),
      # 1 while the app's probe is to go unanswered.
      probe: :atomics.new(1, []),
      # 1 while the API is not accepting.
      api: :atomics.new(1, []),
      gates: Keyword.get(opts, :gates, []),
      seed: Keyword.get(opts, :seed, fn _engine -> :ok end),
      before: Keyword.get(opts, :before, fn -> :ok end),
      boot_marker: Keyword.get(opts, :boot_marker),
      # Port 0: the broker binds whichever port is free at that moment. One
      # picked here would be anybody's by the time the broker asked for it.
      native:
        if(Keyword.get(opts, :native, false),
          do: %{supervisor: Module.concat(__MODULE__, "Native#{id}"), port: 0}
        ),
      facts: Facts.read(data_root: Path.join(root, "data"))
    }
  end

  @doc "`extra` is merged into the options: `:path`, `:observers`, `:resync`, `:context`."
  @spec system(map(), keyword()) :: keyword()
  def system(world, extra \\ []) do
    {context, extra} = Keyword.pop(extra, :context, %{})

    [
      controllers: [{Controller, context: Map.merge(context(world), context)}],
      services: &services(world, &1)
    ] ++ extra
  end

  @spec context(map()) :: map()
  def context(world) do
    probe = world.probe
    api = world.api

    %{
      facts: world.facts,
      backends: %{
        Backend.Container => [engine: [socket: world.socket]],
        Backend.Native =>
          if(world.native,
            do: [supervisor: world.native.supervisor, port: world.native.port, provider: nil],
            else: []
          )
      },
      gates: world.gates,
      api_ready: fn -> :atomics.get(api, 1) == 0 end,
      prober: fn _target, _timeout -> probed(probe) end,
      host_address: fn _port -> "127.0.0.1" end,
      supervisor_token: fn -> "the-supervisor-token" end,
      prepare: [network: fn -> :ok end, dsp_state: fn -> :unsupported end]
    }
  end

  # 0 answers, 1 does not, and 2 raises once and answers from then on.
  defp probed(probe) do
    case :atomics.get(probe, 1) do
      0 -> :ok
      1 -> :error
      2 -> :atomics.put(probe, 1, 0) && raise "the prober fell over"
    end
  end

  # Called by `start_system/1` in the test process, before the subtree
  # starts: the place where a run gets its own engine and data.
  defp services(world, instance) do
    File.rm_rf!(world.data)
    world.before.()
    clock = TestClock.clock(sibling(instance, :clock))
    journal = %{world: sibling(instance, :world)}
    Harness.put_fact(journal, :data_root, world.data)
    Harness.put_fact(journal, :facts, world.facts)
    Harness.put_fact(journal, :socket, world.socket)

    native =
      if world.native do
        flags = DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 50, max_seconds: 1)
        name = world.native.supervisor

        [
          {Recording,
           {DynamicSupervisor, {Supervisor.Default, flags, name}, name, &native(journal, &1, &2)}}
        ]
      else
        []
      end

    [pulls, tasks] =
      Pulls.child_specs(instance: instance, engine: [socket: world.socket], clock: clock)

    [
      %{id: :engine, start: {__MODULE__, :start_engine, [world, instance, journal]}},
      {Recording, {AuthIndex, instance, AuthIndex.name(instance), &token(journal, &1, &2)}}
    ] ++
      native ++
      [
        {Recording, {Pulls, elem(pulls, 1), Pulls.name(instance), &pull(journal, &1, &2)}},
        tasks
      ] ++
      if(world.boot_marker,
        do: [Vagus.App.Boot.child_spec(instance: instance, marker: world.boot_marker)],
        else: []
      )
  end

  ## What the things done to report

  defp token(journal, {:put, app, _digest}, :ok), do: did(journal, app, :put_token)
  defp token(journal, {:remove, app}, :ok), do: did(journal, app, :remove_token)
  defp token(_journal, _request, _reply), do: :ok

  defp pull(journal, {:request, _image, {Controller, app}, _opts}, :ok),
    do: did(journal, app, :request_pull)

  defp pull(journal, {:cancel, _image, {Controller, app}}, :ok),
    do: did(journal, app, :cancel_pull)

  defp pull(_journal, _request, _reply), do: :ok

  # The supervisor has no word for whose child it ends, so the pid it gave
  # each app's start is kept.
  defp native(journal, {:start_child, {{_module, _start, [opts]}, _, _, _, _}}, reply) do
    app = opts[:auth][:slug]
    did(journal, app, :start_process)
    with {:ok, pid} <- reply, do: Harness.put_fact(journal, {:native, pid}, app)
  end

  defp native(journal, {:terminate_child, pid}, _reply) do
    if app = Harness.fact(journal, {:native, pid}), do: did(journal, app, :stop_process)
  end

  defp native(_journal, _request, _reply), do: :ok

  # Called in the engine, with a request that has arrived and done nothing yet.
  defp engine(%{method: method, path: path} = entry, containers, instance, journal) do
    # An id outlives its container here, so that a request for one that is
    # gone is still somebody's.
    for {name, %{id: id}} <- containers, do: Harness.put_fact(journal, {:container, id}, name)

    case {method, String.split(path, "/", trim: true)} do
      {:post, ["containers", "create"]} ->
        {app, _leftover?} = owner(entry.query["name"])
        prepared? = File.exists?(Prepare.options_path(app, Harness.fact(journal, :facts)))
        did(journal, app, if(prepared?, do: :create, else: {:create, :unprepared}))

      {:post, ["containers", ref, "start"]} ->
        {app, _leftover?, container} = target(ref, containers, journal)
        known? = AuthIndex.lookup(token_of(container), instance: instance) == {:ok, app}

        did(
          journal,
          app,
          there(container, if(known?, do: :start, else: {:start, :token_unknown}))
        )

      {:post, ["containers", ref, "stop"]} ->
        {app, leftover?, container} = target(ref, containers, journal)
        action = if(leftover?, do: :stop_leftover, else: :stop)
        did(journal, app, if(leftover?, do: action, else: there(container, action)))

      {:delete, ["containers", ref]} ->
        {app, leftover?, container} = target(ref, containers, journal)
        action = if(leftover?, do: :remove_leftover, else: :remove)
        did(journal, app, if(leftover?, do: action, else: there(container, action)))

      {:delete, ["images" | reference]} ->
        did(journal, image_owner(Enum.join(reference, "/"), instance, journal), :remove_image)

      _a_read_or_a_pull ->
        :ok
    end
  end

  # Whose container a request names, by name or by id, and the container
  # if it is there.
  defp target(ref, containers, journal) do
    by_id = Enum.find_value(containers, fn {name, %{id: id}} -> if id == ref, do: name end)
    name = by_id || Harness.fact(journal, {:container, ref}) || ref
    {app, leftover?} = owner(name)
    {app, leftover?, if(by_id || is_map_key(containers, ref), do: containers[name])}
  end

  defp there(nil, {action, _mark}), do: {action, :gone}
  defp there(nil, action), do: {action, :gone}
  defp there(_container, action), do: action

  defp owner("app_" <> app), do: {app, false}
  defp owner("addon_" <> app), do: {app, true}
  defp owner(name), do: {name, false}

  defp token_of(%{env: env}) do
    Enum.find_value(env, fn
      "SUPERVISOR_TOKEN=" <> token -> token
      _other -> nil
    end)
  end

  defp token_of(nil), do: nil

  # The request names an image and nobody. The app whose spec asks for that
  # image is still in the store: its finalizer is what the removal precedes.
  defp image_owner(image, instance, journal) do
    facts = Harness.fact(journal, :facts)

    Enum.find_value(Store.list(:app, instance: instance), "?", fn app ->
      if Config.image(app.spec, facts) == {:ok, image}, do: app.name
    end)
  end

  # In one step with the journal's write: a data directory that is gone
  # since the entry before went before this one was done.
  defp did(journal, app, action) do
    Harness.transact(journal, fn facts ->
      {facts, gone} = swept(facts)
      {facts, gone ++ [{{Controller, app}, action}]}
    end)
  end

  defp swept(%{data_root: root} = facts) do
    there =
      case File.ls(Path.join([root, "addons", "data"])) do
        {:ok, slugs} -> MapSet.new(slugs)
        {:error, _none} -> MapSet.new()
      end

    before = Map.get(facts, :data, MapSet.new())

    gone =
      for slug <- Enum.sort(MapSet.difference(before, there)),
          do: {{Controller, slug}, :remove_data}

    {Map.put(facts, :data, there), gone}
  end

  @doc "The journal of a system, oldest first, as `{{controller, app}, action}`."
  @spec journal(map()) :: [{{module(), String.t()}, term()}]
  def journal(sys) do
    Harness.transact(sys, fn facts -> swept(facts) end)
    Harness.journal(sys)
  end

  @doc "Takes the engine of a running system away, and `engine_up/1` brings one back, seeded."
  @spec engine_down(map()) :: :ok
  def engine_down(sys) do
    :ok = Supervisor.terminate_child(Module.concat(sys.instance, Supervisor), :engine)
    # The engine's socket closes some time after its process has ended, and
    # a connection made until then is taken and dropped: an engine that
    # fails, not one that is away. With no file there is nothing to connect to.
    File.rm(Harness.fact(sys, :socket))
    :ok
  end

  @spec engine_up(map()) :: :ok
  def engine_up(sys) do
    {:ok, _model} = Supervisor.restart_child(Module.concat(sys.instance, Supervisor), :engine)
    :ok
  end

  @doc "The engine as a child of a system that keeps no journal."
  def start_engine(world), do: start_engine(world, nil, nil)

  @doc false
  def start_engine(world, instance, journal) do
    # A socket file left by the engine before this one refuses the address.
    File.rm(world.socket)
    seen = if journal, do: &engine(&1, &2, instance, journal), else: fn _entry, _all -> :ok end

    with {:ok, model} <- Model.start_link(socket: world.socket, on_request: seen) do
      world.seed.(%{model: model, socket: world.socket})
      {:ok, model}
    end
  end

  # The harness starts its clock and its world under the test's supervisor,
  # by these ids.
  defp sibling(instance, part) do
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()

    Enum.find_value(Supervisor.which_children(supervisor), fn {id, pid, _type, _modules} ->
      if id == {instance, part}, do: pid
    end)
  end

  @doc "An observer as the application has it, without the engine's events."
  @spec observer(map(), atom(), keyword()) :: {module(), keyword()}
  def observer(world, instance, opts \\ []) do
    {EngineObserver,
     [
       controller: Controller,
       instance: instance,
       events: nil,
       interval: :infinity,
       backend_opts: [engine: [socket: world.socket]]
     ] ++ opts}
  end

  @doc "The engine of a running system."
  @spec engine(map(), map()) :: map()
  def engine(world, sys) do
    supervisor = Module.concat(sys.instance, Supervisor)

    model =
      Enum.find_value(Supervisor.which_children(supervisor), fn {id, pid, _type, _modules} ->
        if id == :engine, do: pid
      end)

    %{model: model, socket: world.socket}
  end

  @doc "The spec of an app from the manifest corpus, by slug, with `fields` over it."
  @spec spec(map(), String.t() | Vagus.Addon.Config.t(), map()) :: map()
  def spec(world, manifest, fields \\ %{})

  def spec(world, slug, fields) when is_binary(slug),
    do: spec(world, AppManifests.get(slug), fields)

  def spec(world, config, fields),
    do: Vagus.App.Spec.Schema.from_manifest(config, world.facts, fields)

  @doc "The image an app's container is made from, as the controller names it."
  @spec image(map(), map()) :: String.t()
  def image(world, spec) do
    {:ok, spec} = Vagus.App.Spec.Schema.validate(spec, world.facts)
    {:ok, image} = Vagus.App.Container.Config.image(spec, world.facts)
    image
  end

  @doc "Installs an app whose image the engine has, and returns once the system is at rest."
  @spec install(map(), map(), String.t(), map()) :: Vagus.Resource.t()
  def install(world, sys, slug, fields \\ %{}) do
    spec = spec(world, slug, fields)
    Model.put_image(engine(world, sys), image(world, spec))
    {:ok, _app} = Store.create(:app, slug, spec, sys.i)
    Harness.settle(sys)
    Store.get(:app, slug, sys.i)
  end

  @doc "Writes to an app's spec and returns once the system is at rest."
  @spec write(map(), String.t(), map() | list()) :: Vagus.Resource.t()
  def write(sys, app, ops) do
    {:ok, _app} = Store.update_spec(:app, app, ops, sys.i)
    Harness.settle(sys)
    Store.get(:app, app, sys.i)
  end

  @doc "Has the app looked at again, as the observer would after an event, and waits for rest."
  @spec wake(map(), String.t()) :: Vagus.Resource.t() | nil
  def wake(sys, app) do
    :ok = Runtime.enqueue(Controller, app, sys.i)
    heard(sys, Controller)
    Harness.settle(sys)
    Store.get(:app, app, sys.i)
  end

  @doc """
  Returns once a controller's runtime has read everything this process
  sent it before: a call from here is behind those messages, and a settle
  might not be.

  The pass such a message brings may reach the boundary the fault harness
  kills at before the runtime gets to answer, and the call then exits with
  the runtime. That is as good an answer: the replacement looks at every
  resource, which is what the message asked for.
  """
  @spec heard(map(), module()) :: :ok
  def heard(sys, controller) do
    _info = Runtime.info(controller, sys.i)
    :ok
  catch
    :exit, _killed when sys.faults != nil -> :ok
  end

  @doc """
  Moves the clock, delivers the pending timer of every app, and waits for
  rest. Returns `app`.

  The runtime's timers run on real time and the clock here does not. So a
  move of the clock is time passing for every app: one whose pause is over
  by the clock would otherwise go on waiting for as long as the scenario is
  quicker than its timer, and act only in the run that happened to be slow,
  or was interrupted and looked at everything again. An app that is not yet
  due arms its timer anew and writes nothing.

  A timer that fired by itself is no trouble: the runtime takes a timer's
  message once, whoever sent it. `timers: [app]` delivers only those.
  """
  @spec advance(map(), String.t(), non_neg_integer(), keyword()) :: Vagus.Resource.t() | nil
  def advance(sys, app, ms, opts \\ []) do
    TestClock.advance(sys.clock, ms)
    Harness.settle(sys)
    runtime = Process.whereis(Runtime.name(sys.instance, Controller))

    for {name, %{uid: uid, timer: {_timer, token}}} <- timers(sys, runtime),
        Keyword.get(opts, :timers, :all) == :all or name in opts[:timers],
        do: send(runtime, {:requeue, name, uid, token})

    heard(sys, Controller)
    Harness.settle(sys)
    Store.get(:app, app, sys.i)
  end

  # A timer that fired by itself just now may have brought the pass the
  # fault harness kills at: no timers then, as in `heard/2`.
  defp timers(sys, runtime) do
    :sys.get_state(runtime).known
  catch
    :exit, _killed when sys.faults != nil -> %{}
  end

  @doc """
  Whether the actions performed for an app are `expected`, or, in a run
  the fault harness has interrupted, `expected` with one of them done twice
  in a row: what a scenario with several apps may assert of each, since
  the harness may cut one app's action while it interrupts another's pass.
  """
  @spec acted?(map(), String.t(), [atom()]) :: boolean()
  def acted?(sys, app, expected) do
    # Only a run that has been interrupted may have done anything twice.
    cut? = sys.faults != nil and Vagus.Resource.Harness.Faults.report(sys.faults).kill == :done
    found = actions(sys, app)
    found == expected or (cut? and Vagus.Resource.Harness.Faults.replay?(expected, found))
  end

  @doc "What was done for an app, oldest first, whatever came of it. See \"The journal\"."
  @spec actions(map(), String.t()) :: [term()]
  def actions(sys, app),
    do: for({{Controller, ^app}, action} <- journal(sys), do: action)

  @doc "An app's conditions as `{ready, progressing, failed, reason}`, and its state."
  @spec verdict(Vagus.Resource.t()) :: {boolean(), boolean(), boolean(), atom(), atom()}
  def verdict(app) do
    [ready, progressing, failed] =
      for type <- [:ready, :progressing, :failed], do: Vagus.Resource.get_condition(app, type)

    assert ready.reason == progressing.reason and ready.reason == failed.reason
    {ready.status, progressing.status, failed.status, ready.reason, app.status.state}
  end

  @doc """
  A final store as two runs of a scenario must leave it: every resource
  with its spec, its conditions and everything the controller keeps in
  status. Only what the engine numbers differently from run to run is
  replaced: it counts every container and event it ever had, so an
  instance's id is named for where it first appears here, and its address,
  process and start time are kept as whether there is one. Instants are
  kept as they are: the clock moves only when the scenario moves it.
  """
  @spec normalize([Vagus.Resource.t()]) :: [map()]
  def normalize(resources) do
    ids =
      for %{status: status} <- resources,
          id <- [get_in(status, [:instance, :id]), status[:expected_exit], status[:recreate]],
          id != nil,
          uniq: true,
          do: id

    names = for {id, n} <- Enum.with_index(ids, 1), into: %{}, do: {id, "instance-#{n}"}

    for resource <- resources do
      {conditions, status} = Map.pop(resource.status, :conditions, %{})

      %{
        key: {resource.kind, resource.name},
        generation: resource.generation,
        spec: resource.spec,
        finalizers: resource.finalizers,
        deleting?: resource.deleting?,
        conditions:
          for({type, condition} <- conditions, into: %{}) do
            {type, renamed(Map.delete(condition, :type), names)}
          end,
        status: status |> Map.replace_lazy(:instance, &there/1) |> renamed(names)
      }
    end
  end

  defp there(nil), do: nil

  defp there(instance) do
    Enum.reduce([:address, :process, :started_at], instance, fn key, instance ->
      Map.replace_lazy(instance, key, &(&1 != nil))
    end)
  end

  defp renamed(%_struct{} = term, _names), do: term

  defp renamed(%{} = map, names),
    do: Map.new(map, fn {key, value} -> {key, renamed(value, names)} end)

  defp renamed(list, names) when is_list(list), do: Enum.map(list, &renamed(&1, names))
  defp renamed(id, names) when is_map_key(names, id), do: names[id]
  defp renamed(term, _names), do: term

  @doc "A fake engine request log as `{method, path}`, without the reads."
  @spec writes(map()) :: [{atom(), String.t()}]
  def writes(engine) do
    for %{method: method, path: path} <- FakeEngine.requests(engine),
        method != :get,
        do: {method, path}
  end
end
