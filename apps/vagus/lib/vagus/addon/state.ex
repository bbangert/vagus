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

  ## Persistence (M4-P8-T1)

  Real Supervisor persists installed add-ons + their options to
  `sys_apps.data` so a device reboot doesn't forget them; without that, this
  emulator would need every add-on reinstalled by hand after every reboot.
  `opts[:persist_path]` (falling back to `config :vagus, :addon_state_path`)
  names a JSON file this GenServer loads from at `init/1` and write-throughs
  to after every mutating call (`put/3`, `put_options/3`, `delete/2`); `nil`
  (the default in `config/test.exs`, and implicitly on `:host` where it's
  never set) disables persistence entirely — pure in-memory, the original
  behavior.

  The file holds `{"version": 1, "addons": {"<slug>": {"config": <raw
  Config.to_persistable/1 map>, "state": "started"|"stopped",
  "user_options": {...}}}}`. `Config.parse/1` — not this module — is the
  single validator on reload: each entry's `config` is re-parsed (and its
  key checked against the parsed slug) at `init/1`, and anything
  invalid/mismatched, or a file that's missing/unreadable/not-JSON, is
  logged and dropped rather than crashing boot — a corrupt state file must
  never brick the device. Writes are `mkdir_p` + write-to-`.tmp` +
  `File.rename` (atomic against a mid-write power loss) and best-effort: a
  write failure is logged and the lifecycle call still succeeds, since a
  flash write failure is not a reason to fail an add-on start/stop.
  """

  use GenServer

  require Logger

  alias Vagus.Addon.Config

  @type entry :: %{config: Config.t(), state: :started | :stopped, user_options: map()}

  @persist_version 1

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
  def init(opts) do
    path = persist_path(opts)
    entries = if path, do: load_entries(path), else: %{}
    {:ok, %{path: path, entries: entries}}
  end

  @impl GenServer
  def handle_call(
        {:put, %Config{slug: slug} = config, state, user_options},
        _from,
        %{
          entries: entries
        } = s
      ) do
    resolved_options = user_options || existing_user_options(entries, slug)
    entry = %{config: config, state: state, user_options: resolved_options}
    entries = Map.put(entries, slug, entry)
    persist(s.path, entries)
    {:reply, :ok, %{s | entries: entries}}
  end

  def handle_call({:get, slug}, _from, %{entries: entries} = s) do
    {:reply, Map.fetch(entries, slug), s}
  end

  def handle_call({:put_options, slug, user_options}, _from, %{entries: entries} = s) do
    case Map.fetch(entries, slug) do
      {:ok, entry} ->
        entries = Map.put(entries, slug, %{entry | user_options: user_options})
        persist(s.path, entries)
        {:reply, :ok, %{s | entries: entries}}

      :error ->
        {:reply, :error, s}
    end
  end

  def handle_call({:delete, slug}, _from, %{entries: entries} = s) do
    entries = Map.delete(entries, slug)
    persist(s.path, entries)
    {:reply, :ok, %{s | entries: entries}}
  end

  def handle_call(:list, _from, %{entries: entries} = s) do
    {:reply, Map.values(entries), s}
  end

  defp existing_user_options(entries, slug) do
    case Map.get(entries, slug) do
      %{user_options: opts} -> opts
      nil -> %{}
    end
  end

  ## Persistence internals

  # Only falls back to the app env when `opts` doesn't carry the key at
  # all — an explicit `persist_path: nil` (as tests use to prove the
  # disabled path never touches disk) must stay disabled, not resurrect the
  # configured default.
  defp persist_path(opts) do
    Keyword.get(opts, :persist_path, Application.get_env(:vagus, :addon_state_path))
  end

  defp load_entries(path) do
    case File.read(path) do
      {:ok, content} ->
        decode_entries(path, content)

      # No file yet (nothing persisted across a reboot, or the very first
      # boot) is expected, not corruption — stay quiet. Any other read
      # failure (permission denied, path is a directory, ...) is a real
      # problem worth a log, but still starts empty rather than crashing.
      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning(
          "Vagus.Addon.State: could not read #{path} (#{inspect(reason)}), starting empty"
        )

        %{}
    end
  end

  defp decode_entries(path, content) do
    case Jason.decode(content) do
      {:ok, %{"addons" => addons}} when is_map(addons) ->
        Enum.reduce(addons, %{}, fn {slug, raw}, acc ->
          case decode_entry(slug, raw) do
            {:ok, entry} -> Map.put(acc, slug, entry)
            :error -> acc
          end
        end)

      {:ok, other} ->
        Logger.warning(
          "Vagus.Addon.State: #{path} has an unexpected shape (#{inspect(other)}), " <>
            "starting empty"
        )

        %{}

      {:error, reason} ->
        Logger.warning(
          "Vagus.Addon.State: #{path} is not valid JSON (#{inspect(reason)}), starting empty"
        )

        %{}
    end
  end

  defp decode_entry(slug, raw) when is_map(raw) do
    with %{"config" => cfg_raw, "state" => state_raw} <- raw,
         {:ok, config} <- Config.parse(cfg_raw),
         true <- config.slug == slug,
         {:ok, state} <- decode_state(state_raw) do
      user_options = Map.get(raw, "user_options", %{})
      {:ok, %{config: config, state: state, user_options: user_options}}
    else
      _ ->
        Logger.warning(
          "Vagus.Addon.State: dropping invalid/mismatched entry for #{inspect(slug)}"
        )

        :error
    end
  end

  defp decode_entry(slug, _raw) do
    Logger.warning("Vagus.Addon.State: dropping non-map entry for #{inspect(slug)}")
    :error
  end

  defp decode_state("started"), do: {:ok, :started}
  defp decode_state("stopped"), do: {:ok, :stopped}
  defp decode_state(_other), do: :error

  defp persist(nil, _entries), do: :ok

  defp persist(path, entries) do
    tmp = path <> ".tmp"

    result =
      with :ok <- File.mkdir_p(Path.dirname(path)),
           {:ok, json} <- Jason.encode(to_disk_map(entries)),
           :ok <- File.write(tmp, json) do
        File.rename(tmp, path)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Vagus.Addon.State: failed to persist #{path}: #{inspect(reason)}")
        :ok
    end
  end

  defp to_disk_map(entries) do
    %{
      "version" => @persist_version,
      "addons" =>
        Map.new(entries, fn {slug, %{config: config, state: state, user_options: user_options}} ->
          {slug,
           %{
             "config" => Config.to_persistable(config),
             "state" => Atom.to_string(state),
             "user_options" => user_options
           }}
        end)
    }
  end
end
