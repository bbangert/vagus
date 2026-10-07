defmodule Vagus.Resource.Watch do
  @moduledoc """
  Subscriptions to resource changes, kept in a duplicate-key `Registry` that
  starts before the store, so a subscription outlives a store restart and
  ends only with its subscriber.

  A subscriber receives `{Vagus.Resource.Watch, :changed | :removed, meta}`.
  The message means "look again": the store writes ETS before it sends, so
  a read on receipt is at least as new as the change, and several messages
  for one resource can be answered by one read. `meta` exists for what can no
  longer be read: a removed resource still says whom it belonged to.

  With the registry gone the whole `Vagus.Resource.Supervisor` subtree is
  restarting, and `subscribe/2` raises. Subscribing links the subscriber to
  the registry, so one that does not trap exits goes down with it.
  """

  alias Vagus.Resource

  @type instance :: atom()

  @typedoc """
  `{:owner, kind, name}` is every resource that lists that one in its
  `owner_refs`.
  """
  @type key ::
          {:object, Resource.kind(), Resource.name()}
          | {:kind, Resource.kind()}
          | {:owner, Resource.kind(), Resource.name()}

  @type meta :: %{
          kind: Resource.kind(),
          name: Resource.name(),
          uid: pos_integer(),
          generation: pos_integer(),
          deleting?: boolean(),
          owner_refs: [Resource.ref()]
        }

  @type message :: {__MODULE__, :changed | :removed, meta()}

  @spec child_spec(instance()) :: Supervisor.child_spec()
  def child_spec(instance) do
    Supervisor.child_spec({Registry, keys: :duplicate, name: name(instance)}, id: __MODULE__)
  end

  @spec name(instance()) :: atom()
  def name(instance), do: Module.concat(instance, Watch)

  @spec subscribe(key(), instance: instance()) :: :ok
  def subscribe(key, opts \\ []) do
    {:ok, _owner} = Registry.register(name(instance(opts)), key, nil)
    :ok
  end

  @spec unsubscribe(key(), instance: instance()) :: :ok
  def unsubscribe(key, opts \\ []), do: Registry.unregister(name(instance(opts)), key)

  @doc false
  @spec notify(instance(), :changed | :removed, Resource.t()) :: :ok
  def notify(instance, event, %Resource{kind: kind, name: name} = resource) do
    message =
      {__MODULE__, event,
       Map.take(resource, [:kind, :name, :uid, :generation, :deleting?, :owner_refs])}

    owners = for ref <- resource.owner_refs, do: {:owner, ref.kind, ref.name}

    for key <- [{:object, kind, name}, {:kind, kind} | owners] do
      Registry.dispatch(name(instance), key, fn subscribers ->
        for {pid, _value} <- subscribers, do: send(pid, message)
      end)
    end

    :ok
  end

  defp instance(opts), do: Keyword.get(opts, :instance, Resource)
end
