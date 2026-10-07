defmodule Vagus.Resource.Tables do
  @moduledoc """
  Owns the resource store's ETS tables and does nothing else.

  The tables are `:protected`, so they need the store as owner for it to
  write them; this process is their heir, lends them out with `take/1` and
  gets them back when the store dies. A table therefore always has an owner
  and a read never finds it missing across a store restart, and the rows
  (status included, which is nowhere else) outlive the store.

  With this process itself gone the whole `Vagus.Resource.Supervisor` subtree
  is restarting: the tables die with the store and a read raises
  `ArgumentError` until the new store is up.
  """

  use GenServer

  @type instance :: atom()

  @spec start_link(instance()) :: GenServer.on_start()
  def start_link(instance), do: GenServer.start_link(__MODULE__, instance, name: name(instance))

  @spec name(instance()) :: atom()
  def name(instance), do: Module.concat(instance, Tables)

  @doc "The table of `{{kind, name}, resource}` rows."
  @spec resources(instance()) :: atom()
  def resources(instance), do: Module.concat(instance, Resources)

  @doc "The table of `{{kind, name}, pid}` operation claims."
  @spec claims(instance()) :: atom()
  def claims(instance), do: Module.concat(instance, Claims)

  @doc """
  Makes the caller the owner of both tables. `{:error, {:held, pid}}` while
  another live process has them.
  """
  @spec take(instance()) :: :ok | {:error, {:held, pid()}}
  def take(instance), do: GenServer.call(name(instance), :take)

  @impl true
  def init(instance) do
    tables = [resources(instance), claims(instance)]

    for table <- tables do
      :ets.new(table, [
        :named_table,
        :set,
        :protected,
        {:heir, self(), nil},
        read_concurrency: true
      ])
    end

    {:ok, tables}
  end

  @impl true
  def handle_call(:take, {pid, _tag}, tables) do
    case Enum.find(tables, &(:ets.info(&1, :owner) != self())) do
      nil ->
        for table <- tables, do: :ets.give_away(table, pid, nil)
        {:reply, :ok, tables}

      table ->
        {:reply, {:error, {:held, :ets.info(table, :owner)}}, tables}
    end
  end

  # Ownership has already moved back by the time this arrives; the message
  # only reports it.
  @impl true
  def handle_info({:"ETS-TRANSFER", _table, _from, _data}, tables), do: {:noreply, tables}
end
