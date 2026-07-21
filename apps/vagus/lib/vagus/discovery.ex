defmodule Vagus.Discovery do
  @moduledoc """
  The Supervisor discovery registry (`docs/contract-2026.7-m4-addendum.md`
  §A3.2) — add-ons publish discovery messages (e.g. Mosquitto → `mqtt`) that
  Core turns into config-flow entries.

  Each message is `%{uuid, addon, service, config}` where `addon` is the
  provider slug (taken from the authenticated caller, never the body) and
  `uuid` is a `uuid4().hex`-shaped 32-char lowercase hex string. `add/3`
  mints the uuid; `delete/2` is owner-only.

  This module only holds state; the Core push
  (`POST/DELETE api/hassio_push/discovery/{uuid}`) and access checks live in
  `Vagus.API.Router`.
  """

  use GenServer

  @type message :: %{
          uuid: String.t(),
          addon: String.t(),
          service: String.t(),
          config: map()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Stores a discovery message from `slug` for `service` with `config`, minting a
  fresh uuid. Returns `{:ok, message}` (the stored map, incl. its uuid).
  """
  @spec add(String.t(), String.t(), map(), GenServer.server()) :: {:ok, message()}
  def add(slug, service, config, server \\ __MODULE__) do
    GenServer.call(server, {:add, slug, service, config})
  end

  @doc "Returns the message for `uuid`, or `:error` if unknown."
  @spec get(String.t(), GenServer.server()) :: {:ok, message()} | :error
  def get(uuid, server \\ __MODULE__) do
    GenServer.call(server, {:get, uuid})
  end

  @doc "Lists all stored discovery messages."
  @spec list(GenServer.server()) :: [message()]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @doc """
  Deletes `uuid`, but only if `slug` is its owning add-on. Returns the removed
  message on success so the caller can push the deletion to Core.
  """
  @spec delete(String.t(), String.t(), GenServer.server()) ::
          {:ok, message()} | {:error, :not_found | :not_owner}
  def delete(uuid, slug, server \\ __MODULE__) do
    GenServer.call(server, {:delete, uuid, slug})
  end

  @doc "Removes every message owned by `slug` (e.g. on add-on stop/uninstall)."
  @spec delete_by_slug(String.t(), GenServer.server()) :: {:ok, [message()]}
  def delete_by_slug(slug, server \\ __MODULE__) do
    GenServer.call(server, {:delete_by_slug, slug})
  end

  ## GenServer

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:add, slug, service, config}, _from, state) do
    uuid = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    message = %{uuid: uuid, addon: slug, service: service, config: config}
    {:reply, {:ok, message}, Map.put(state, uuid, message)}
  end

  def handle_call({:get, uuid}, _from, state) do
    {:reply, Map.fetch(state, uuid), state}
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state), state}
  end

  def handle_call({:delete, uuid, slug}, _from, state) do
    case Map.get(state, uuid) do
      nil -> {:reply, {:error, :not_found}, state}
      %{addon: ^slug} = message -> {:reply, {:ok, message}, Map.delete(state, uuid)}
      _other -> {:reply, {:error, :not_owner}, state}
    end
  end

  def handle_call({:delete_by_slug, slug}, _from, state) do
    {owned, rest} = Enum.split_with(Map.values(state), &(&1.addon == slug))
    new_state = Map.new(rest, &{&1.uuid, &1})
    {:reply, {:ok, owned}, new_state}
  end
end
