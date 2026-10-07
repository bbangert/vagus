defmodule Vagus.Resource.Supervisor do
  @moduledoc """
  The resource store, what it stands on, and the controllers that run
  against it.

  `:rest_for_one` because a child's replacement invalidates the ones after
  it and none before: new tables mean an empty store, a new `Watch`
  registry has forgotten every subscriber, and new lanes have forgotten who
  holds a slot.

  The store is the exception, and stands in that order under a supervisor
  of its own, which absorbs its restart: a new store finds its rows and the
  claims in `Tables`, its subscribers in `Watch` and who owns what in its
  start options, and it stops on purpose when it cannot tell whether a write
  reached flash. Replacing the runtimes with it would end every step in the
  middle of an engine call and cancel the running pulls. Those who outlive
  it see a write that exits and may have been applied (for a step a crashed
  pass, retried with back-off), reads that go on, and the new store's word
  that it is new (`Vagus.Resource.Watch`), on which each runtime looks at
  everything.

  That supervisor allows three restarts in thirty seconds. One replacement
  is the recovery, since it reads the file again; a store that keeps
  stopping is flash that keeps failing, or a defect, and then that
  supervisor ends and everything after it is replaced with it.

  `:services` are children a controller's actions use and that hold lane
  slots or remember who among the resources waits for them. They stand
  after the lanes and before the controllers, in the order given, so each
  is replaced with the lanes and the services before it, and the runtimes
  with any of them: a runtime that starts looks at every resource, which is
  how a service that has forgotten its waiters hears from them again.
  """

  use Supervisor

  alias Vagus.Resource
  alias Vagus.Resource.{Controller, Controllers, Lanes, Store, Tables, Watch}

  @doc "The name of the supervisor that holds the store alone."
  @spec store_supervisor(atom()) :: atom()
  def store_supervisor(instance), do: Module.concat(instance, StoreSupervisor)

  @doc """
  Options are `Vagus.Resource.Store.start_link/1`'s, and:

    * `:controllers`, the `Vagus.Resource.Controller` modules to run. Each
      owning one contributes its kind to the store's `:kinds`, with who
      owns it and who writes which condition type. A list that cannot run
      fails this start (`Vagus.Resource.Controller.kinds/1`), as does a
      kind given in `:kinds` that a controller owns.
    * `:runtime`, options for every `Vagus.Resource.Runtime`.
    * `:lanes`, `Vagus.Resource.Lanes` caps.
    * `:services`, child specs started after `Vagus.Resource.Lanes` and
      before the controllers.

  `:path` and `:controllers` default to `config :vagus, :resources_path` and
  `config :vagus, :controllers`, and only for the application's instance.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    instance = Keyword.get(opts, :instance, Resource)
    Supervisor.start_link(__MODULE__, opts, name: Module.concat(instance, Supervisor))
  end

  @impl true
  def init(opts) do
    instance = Keyword.get(opts, :instance, Resource)

    opts =
      if instance == Resource do
        opts
        |> Keyword.put_new(:path, Application.get_env(:vagus, :resources_path))
        |> Keyword.put_new(:controllers, Application.get_env(:vagus, :controllers, []))
      else
        opts
      end

    {own, store} = Keyword.split(opts, [:controllers, :runtime, :lanes, :services])
    # Every controller is asked what it declares here, once. A declaration
    # that raises fails this start with its name, and nothing started below
    # has to call a controller to know its kind or its conditions.
    declarations =
      own |> Keyword.get(:controllers, []) |> Enum.uniq() |> Enum.map(&Controller.declare/1)

    # Derived here and given to the store as a start option: the store reads
    # its file, and checks who may write status, before any runtime exists.
    given = Map.new(Keyword.get(store, :kinds, %{}))
    derived = Controller.kinds(declarations)

    # Merged, the controller's kind would silently replace the given one.
    for {kind, %{owner: owner}} <- derived, is_map_key(given, kind) do
      raise ArgumentError,
            "kind #{inspect(kind)} is given in :kinds and owned by #{inspect(owner)}"
    end

    store = Keyword.merge(store, instance: instance, kinds: Map.merge(given, derived))

    alone = [
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 30,
      name: store_supervisor(instance)
    ]

    children =
      [
        {Tables, instance},
        Watch.child_spec(instance),
        %{
          id: Store,
          type: :supervisor,
          start: {Supervisor, :start_link, [[{Store, store}], alone]}
        },
        {Lanes, instance: instance, caps: Keyword.get(own, :lanes)}
      ] ++
        Keyword.get(own, :services, []) ++
        [
          {Controllers.Supervisor,
           instance: instance, controllers: declarations, runtime: Keyword.get(own, :runtime, [])}
        ]

    # What fails outside the VM, flash or the engine, reaches a caller as an
    # error, not as a child's exit; the store, which does stop over it, has
    # its own budget. A child that ends here is a defect to escalate.
    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 30)
  end
end
