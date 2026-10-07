defmodule Vagus.Resource.Supervisor do
  @moduledoc """
  The resource store, what it stands on, and the controllers that run
  against it.

  `:rest_for_one` because each child's replacement invalidates the ones
  after it and none before: new tables mean an empty store, a new `Watch`
  registry has forgotten every subscriber, a new store has forgotten who
  registered for which kind, and new lanes have forgotten who holds a slot.
  A store that restarts alone finds its rows in `Tables` and its subscribers
  in `Watch`; the runtimes, which hold the registrations, restart with it.
  """

  use Supervisor

  alias Vagus.Resource
  alias Vagus.Resource.{Controller, Controllers, Lanes, Store, Tables, Watch}

  @doc """
  Options are `Vagus.Resource.Store.start_link/1`'s, and:

    * `:controllers`, the `Vagus.Resource.Controller` modules to run. Each
      owning one contributes its kind to the store's `:kinds`.
    * `:runtime`, options for every `Vagus.Resource.Runtime`.
    * `:lanes`, `Vagus.Resource.Lanes` caps.

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

    {own, store} = Keyword.split(opts, [:controllers, :runtime, :lanes])
    # Every controller is asked what it declares here, once. A declaration
    # that raises fails this start with its name, and nothing started below
    # has to call a controller to know its kind or its conditions.
    declarations =
      own |> Keyword.get(:controllers, []) |> Enum.uniq() |> Enum.map(&Controller.declare/1)

    # Derived here and given to the store as a start option because the
    # store reads its file before any controller exists to register a kind.
    kinds = Map.merge(Map.new(Keyword.get(store, :kinds, %{})), Controller.kinds(declarations))

    children = [
      {Tables, instance},
      Watch.child_spec(instance),
      {Store, Keyword.merge(store, instance: instance, kinds: kinds)},
      {Lanes, instance: instance, caps: Keyword.get(own, :lanes)},
      {Controllers.Supervisor,
       instance: instance, controllers: declarations, runtime: Keyword.get(own, :runtime, [])}
    ]

    # None of these children waits on anything outside the VM, so a crash is
    # a bug to escalate, on the budget the application's other subtrees use.
    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 30)
  end
end
