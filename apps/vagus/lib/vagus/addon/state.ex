defmodule Vagus.Addon.State do
  @moduledoc """
  Tracks installed/running add-ons by slug — the per-add-on state store the
  add-on-info endpoint (`GET /addons/{slug}/info`) and the lifecycle routes
  (`docs/contract-2026.7-m4-addendum.md` §A1.1) need to answer for a slug the
  caller names (e.g. Core resolving a discovery message's provider, or the
  `POST /addons/{slug}/start` handler restarting a previously-installed
  add-on with its saved options).

  Holds the parsed `Vagus.Addon.Config`, a lifecycle `state`
  (`:started`/`:stopped`), and the add-on's stored `user_options` (the raw
  user-supplied options map, independent of the config's own defaults —
  `Vagus.Addon.OptionsSchema.effective/3` merges the two at start time).
  `Vagus.Addon.Manager` records `:started`/`:stopped` here across
  install/start/stop/restart/uninstall; `POST /addons/{slug}/options`
  updates `user_options` directly via `put_options/2` without touching
  lifecycle state or restarting the add-on.
  """

  use GenServer

  alias Vagus.Addon.Config

  @type entry :: %{config: Config.t(), state: :started | :stopped, user_options: map()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Records `config` with lifecycle `state` (default `:started`), keyed by
  slug. `opts[:user_options]` sets the stored user options; when omitted, any
  user options already stored for this slug are preserved (a start/stop
  transition must not wipe out previously-configured options) — a genuinely
  new install starts with no entry, so it correctly defaults to `%{}`.
  `opts[:server]` overrides the target GenServer (default `#{inspect(__MODULE__)}`).
  """
  @spec put(Config.t(), :started | :stopped, keyword()) :: :ok
  def put(%Config{} = config, state \\ :started, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    user_options = Keyword.get(opts, :user_options)
    GenServer.call(server, {:put, config, state, user_options})
  end

  @doc "Returns the `%{config, state, user_options}` entry for `slug`, or `:error` if unknown."
  @spec get(String.t(), GenServer.server()) :: {:ok, entry()} | :error
  def get(slug, server \\ __MODULE__) do
    GenServer.call(server, {:get, slug})
  end

  @doc """
  Replaces `slug`'s stored user options (`POST /addons/{slug}/options`).
  `:error` if `slug` isn't tracked (not installed).
  """
  @spec put_options(String.t(), map(), GenServer.server()) :: :ok | :error
  def put_options(slug, user_options, server \\ __MODULE__) when is_map(user_options) do
    GenServer.call(server, {:put_options, slug, user_options})
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
  def handle_call({:put, %Config{slug: slug} = config, state, user_options}, _from, entries) do
    resolved_options = user_options || existing_user_options(entries, slug)
    entry = %{config: config, state: state, user_options: resolved_options}
    {:reply, :ok, Map.put(entries, slug, entry)}
  end

  def handle_call({:get, slug}, _from, entries) do
    {:reply, Map.fetch(entries, slug), entries}
  end

  def handle_call({:put_options, slug, user_options}, _from, entries) do
    case Map.fetch(entries, slug) do
      {:ok, entry} -> {:reply, :ok, Map.put(entries, slug, %{entry | user_options: user_options})}
      :error -> {:reply, :error, entries}
    end
  end

  def handle_call({:delete, slug}, _from, entries) do
    {:reply, :ok, Map.delete(entries, slug)}
  end

  def handle_call(:list, _from, entries) do
    {:reply, Map.values(entries), entries}
  end

  defp existing_user_options(entries, slug) do
    case Map.get(entries, slug) do
      %{user_options: opts} -> opts
      nil -> %{}
    end
  end
end
