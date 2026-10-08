defmodule Vagus.Test.AppWorld do
  @moduledoc """
  What a scenario of the App controller runs in: the real controller in a
  `Vagus.Resource.Harness` system, against a `Vagus.Test.FakeEngine.Model`,
  a data root in a temporary directory, a probe the test answers for, and
  the harness's clock in the pull worker too.

  `new/1` makes a world, a map of what stays the same across the systems
  started in it; `system/2` is the `Vagus.Resource.Harness.start_system/1`
  options for one. Every system started from them begins with an engine
  that has nothing in it and an empty data root, which is what lets the
  fault harness run a scenario many times over: the engine is a child of
  the system, and `:seed` is called with it before anything else starts.
  """

  import ExUnit.Assertions

  alias Vagus.App.{AuthIndex, Backend, Controller, EngineObserver, Facts, Pulls}
  alias Vagus.Resource.{Harness, Runtime, Store, TestClock}
  alias Vagus.Test.{AppManifests, FakeEngine}
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
      native: if(Keyword.get(opts, :native, false), do: native(id)),
      facts: Facts.read(data_root: Path.join(root, "data"))
    }
  end

  defp native(id) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    %{supervisor: Module.concat(__MODULE__, "Native#{id}"), port: port}
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
      prepare: [network: fn -> :ok end, dsp_state: fn -> :unsupported end],
      audit: fn key, action, context -> Harness.record(context, key, action) end
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
    clock = TestClock.clock(clock(instance))

    native =
      if world.native,
        do: [
          {DynamicSupervisor,
           name: world.native.supervisor, strategy: :one_for_one, max_restarts: 50, max_seconds: 1}
        ],
        else: []

    [
      %{id: :engine, start: {__MODULE__, :start_engine, [world]}},
      {AuthIndex, instance: instance}
    ] ++
      native ++
      Pulls.child_specs(instance: instance, engine: [socket: world.socket], clock: clock) ++
      if(world.boot_marker,
        do: [Vagus.App.Boot.child_spec(instance: instance, marker: world.boot_marker)],
        else: []
      )
  end

  @doc "Takes the engine of a running system away, and `engine_up/1` brings one back, seeded."
  @spec engine_down(map()) :: :ok
  def engine_down(sys),
    do: Supervisor.terminate_child(Module.concat(sys.instance, Supervisor), :engine)

  @spec engine_up(map()) :: :ok
  def engine_up(sys) do
    {:ok, _model} = Supervisor.restart_child(Module.concat(sys.instance, Supervisor), :engine)
    :ok
  end

  @doc false
  def start_engine(world) do
    # A socket file left by the engine before this one refuses the address.
    File.rm(world.socket)

    with {:ok, model} <- Model.start_link(socket: world.socket) do
      world.seed.(%{model: model, socket: world.socket})
      {:ok, model}
    end
  end

  # The harness starts its clock under the test's supervisor, by this id.
  defp clock(instance) do
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()

    Enum.find_value(Supervisor.which_children(supervisor), fn {id, pid, _type, _modules} ->
      if id == {instance, :clock}, do: pid
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
    # A call from here is behind that cast.
    _info = Runtime.info(Controller, sys.i)
    Harness.settle(sys)
    Store.get(:app, app, sys.i)
  end

  @doc "Moves the clock and delivers the app's pending timer, then waits for rest."
  @spec advance(map(), String.t(), non_neg_integer()) :: Vagus.Resource.t() | nil
  def advance(sys, app, ms) do
    TestClock.advance(sys.clock, ms)
    Harness.fire_timer(sys, Controller, app)
    Harness.settle(sys)
    Store.get(:app, app, sys.i)
  end

  @doc """
  Whether the actions performed for an app are `expected`, or `expected`
  with one of them done twice in a row: what a scenario with several apps
  may assert of each, since the fault harness may cut one app's action
  while it interrupts another's pass.
  """
  @spec acted?(map(), String.t(), [atom()]) :: boolean()
  def acted?(sys, app, expected),
    do: Vagus.Resource.Harness.Faults.replay?(expected, actions(sys, app))

  @doc "The actions asked for on behalf of an app, oldest first, whatever came of them."
  @spec actions(map(), String.t()) :: [atom()]
  def actions(sys, app),
    do: for({{Controller, ^app}, action} <- Harness.journal(sys), do: action)

  @doc "An app's conditions as `{ready, progressing, failed, reason}`, and its state."
  @spec verdict(Vagus.Resource.t()) :: {boolean(), boolean(), boolean(), atom(), atom()}
  def verdict(app) do
    [ready, progressing, failed] =
      for type <- [:ready, :progressing, :failed], do: Vagus.Resource.get_condition(app, type)

    assert ready.reason == progressing.reason and ready.reason == failed.reason
    {ready.status, progressing.status, failed.status, ready.reason, app.status.state}
  end

  @doc """
  A final store with everything left out that differs from run to run
  without meaning anything: instants, and the ids and addresses the engine
  gives, which count every container it ever made.
  """
  @spec normalize([Vagus.Resource.t()]) :: [map()]
  def normalize(resources) do
    for resource <- resources do
      status = resource.status

      %{
        key: {resource.kind, resource.name},
        spec: resource.spec,
        finalizers: resource.finalizers,
        deleting?: resource.deleting?,
        conditions:
          for({type, condition} <- Map.get(status, :conditions, %{}), into: %{}) do
            {type, {condition.status, condition.reason}}
          end,
        state: status[:state],
        running?: match?(%{instance: %{running?: true}}, status),
        attempts: get_in(status, [:restarts, :attempts]),
        failure: status[:failure] && Map.take(status.failure, [:action, :class, :cause])
      }
    end
  end

  @doc "A fake engine request log as `{method, path}`, without the reads."
  @spec writes(map()) :: [{atom(), String.t()}]
  def writes(engine) do
    for %{method: method, path: path} <- FakeEngine.requests(engine),
        method != :get,
        do: {method, path}
  end
end
