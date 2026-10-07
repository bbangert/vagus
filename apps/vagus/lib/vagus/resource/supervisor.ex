defmodule Vagus.Resource.Supervisor do
  @moduledoc """
  The resource store and what it stands on.

  `:rest_for_one` because each child's replacement invalidates the ones
  after it and none before: new tables mean an empty store, and a new
  `Watch` registry has forgotten every subscriber. A store that restarts
  alone finds its rows in `Tables` and its subscribers in `Watch`.
  """

  use Supervisor

  alias Vagus.Resource
  alias Vagus.Resource.{Store, Tables, Watch}

  @doc """
  Options are `Vagus.Resource.Store.start_link/1`'s. `:path` defaults to
  `config :vagus, :resources_path`, and only for the application's instance.
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
      if instance == Resource,
        do: Keyword.put_new(opts, :path, Application.get_env(:vagus, :resources_path)),
        else: opts

    children = [
      {Tables, instance},
      Watch.child_spec(instance),
      {Store, Keyword.put(opts, :instance, instance)}
    ]

    # None of these children waits on anything outside the VM, so a crash is
    # a bug to escalate, on the budget the application's other subtrees use.
    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 30)
  end
end
