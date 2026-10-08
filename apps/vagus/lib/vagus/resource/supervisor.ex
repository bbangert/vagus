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

  `:observers` are children that only tell runtimes where to look and hold
  nothing a runtime relies on. They stand after the controllers, so one
  that is replaced takes nothing with it, and it is replaced with the
  controllers' supervisor when that ends. An observer makes up for what it
  missed by itself, by having its runtime look at everything.
  """

  use Supervisor

  alias Vagus.Resource
  alias Vagus.Resource.{Controller, Controllers, Lanes, Runtime, Store, Tables, Watch}

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

      An entry is a module, or `{module, options}` with options for that
      controller's runtime alone
      (`Vagus.Resource.Runtime.controller_options/0`), which are merged
      over `:runtime`; a `:context` is merged into the shared one key by
      key. An option not among those, or a controller listed twice with
      different options, fails this start with the controller's name.
    * `:runtime`, options for every `Vagus.Resource.Runtime`.
    * `:lanes`, `Vagus.Resource.Lanes` caps.
    * `:services`, child specs started after `Vagus.Resource.Lanes` and
      before the controllers.
    * `:observers`, child specs started after the controllers.

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

    {own, store} = Keyword.split(opts, [:controllers, :runtime, :lanes, :services, :observers])
    # Every controller is asked what it declares here, once. A declaration
    # that raises fails this start with its name, and nothing started below
    # has to call a controller to know its kind or its conditions.
    entries = own |> Keyword.get(:controllers, []) |> entries()

    declarations =
      Enum.map(entries, fn {controller, _options} -> Controller.declare(controller) end)

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
           instance: instance,
           controllers: declarations,
           runtime: Keyword.get(own, :runtime, []),
           options: Map.new(entries)}
        ] ++ Keyword.get(own, :observers, [])

    # What fails outside the VM, flash or the engine, reaches a caller as an
    # error, not as a child's exit; the store, which does stop over it, has
    # its own budget. A child that ends here is a defect to escalate.
    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 30)
  end

  # Checked here, where a mistake fails the start with a name. Passed on
  # unchecked, a misspelt option would be a runtime that silently runs with
  # the default.
  defp entries(controllers) do
    controllers
    |> Enum.map(fn
      {controller, options} when is_atom(controller) and is_list(options) ->
        {controller, options!(controller, options)}

      controller when is_atom(controller) ->
        {controller, []}

      other ->
        raise ArgumentError,
              "#{inspect(other)} is not a controller: expected a module or {module, options}"
    end)
    |> Enum.uniq()
    |> Enum.reduce([], fn {controller, _options} = entry, seen ->
      if List.keymember?(seen, controller, 0) do
        raise ArgumentError, "#{inspect(controller)} is listed twice, with different options"
      end

      seen ++ [entry]
    end)
  end

  defp options!(controller, options) do
    known = Runtime.controller_options()

    if not Keyword.keyword?(options) do
      raise ArgumentError, "#{inspect(controller)}: options must be a keyword list"
    end

    keys = Keyword.keys(options)

    # The runtime would read one of the two, and nobody could say which.
    case keys -- Enum.uniq(keys) do
      [] ->
        :ok

      [twice | _] ->
        raise ArgumentError,
              "#{inspect(controller)}: runtime option #{inspect(twice)} is given twice"
    end

    for {key, value} <- options, key in known, not Runtime.controller_option?(key, value) do
      raise ArgumentError,
            "#{inspect(controller)}: runtime option #{inspect(key)} cannot be #{inspect(value)}"
    end

    case keys -- known do
      [] ->
        Enum.sort(options)

      [unknown | _] ->
        raise ArgumentError,
              "#{inspect(controller)}: unknown runtime option #{inspect(unknown)} " <>
                "(known: #{Enum.map_join(known, ", ", &inspect/1)})"
    end
  end
end
