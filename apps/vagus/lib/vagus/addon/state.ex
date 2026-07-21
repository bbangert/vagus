defmodule Vagus.Addon.State do
  @moduledoc """
  Tracks installed/running add-ons by slug — the minimal per-add-on state store
  the add-on-info endpoint (`GET /addons/{slug}/info`) needs to answer for a
  slug the caller names (e.g. Core resolving a discovery message's provider).

  Holds the parsed `Vagus.Addon.Config` plus a lifecycle `state`
  (`:started`/`:stopped`). `Vagus.Addon.Manager.start/2` records `:started`
  here; this is the seam the fuller per-add-on supervision (P3-T1) will grow
  into.
  """

  use GenServer

  alias Vagus.Addon.Config

  @type entry :: %{config: Config.t(), state: :started | :stopped}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Records `config` with lifecycle `state` (default `:started`), keyed by slug."
  @spec put(Config.t(), :started | :stopped, GenServer.server()) :: :ok
  def put(%Config{} = config, state \\ :started, server \\ __MODULE__) do
    GenServer.call(server, {:put, config, state})
  end

  @doc "Returns the `%{config, state}` entry for `slug`, or `:error` if unknown."
  @spec get(String.t(), GenServer.server()) :: {:ok, entry()} | :error
  def get(slug, server \\ __MODULE__) do
    GenServer.call(server, {:get, slug})
  end

  @doc "Removes `slug` (e.g. on uninstall). Returns `:ok` even if absent."
  @spec delete(String.t(), GenServer.server()) :: :ok
  def delete(slug, server \\ __MODULE__) do
    GenServer.call(server, {:delete, slug})
  end

  @doc "Lists all tracked entries."
  @spec list(GenServer.server()) :: [entry()]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  ## GenServer

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:put, %Config{slug: slug} = config, state}, _from, entries) do
    {:reply, :ok, Map.put(entries, slug, %{config: config, state: state})}
  end

  def handle_call({:get, slug}, _from, entries) do
    {:reply, Map.fetch(entries, slug), entries}
  end

  def handle_call({:delete, slug}, _from, entries) do
    {:reply, :ok, Map.delete(entries, slug)}
  end

  def handle_call(:list, _from, entries) do
    {:reply, Map.values(entries), entries}
  end
end
