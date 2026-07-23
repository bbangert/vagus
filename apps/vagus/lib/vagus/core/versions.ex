defmodule Vagus.Core.Versions do
  @moduledoc """
  Tracks HA Core's installed version and the latest upstream version
  (`.claude/plans/vagus-core-lifecycle/research/supervisor-semantics.md`
  §4, mirroring upstream `homeassistant.json` + the updater's 24h refresh).

  ## Persistence (TokenStore-style)

  File-backed JSON (target: `/data/vagus/core.json`, host: `.dev/core.json`,
  test: an isolated tmp path — same `config :vagus, :core_versions_path`
  pattern `Vagus.Core.TokenStore` uses for `:core_token_path`), read once at
  `init/1`. Only `%{"version" => installed}` is ever written — the fetched
  "latest" value is a 24h in-memory cache, never persisted, since it is
  cheap to re-fetch and would otherwise go stale silently across restarts.

  `set_installed/2` always overwrites; `seed/2` writes only when nothing is
  persisted yet (`installed/1` is currently `nil`) — this is what boot
  adoption calls with the running container's image tag, so it never
  clobbers a version this store already knows about.

  ## `latest/1` — upstream shape (fetched 2026-07-23)

  `GET https://version.home-assistant.io/stable.json` was fetched directly
  to confirm the real shape rather than guessing:

  ```json
  {
    "homeassistant": {
      "default": "2026.7.3",
      "qemux86": "2025.11.3",
      "generic-x86-64": "2026.7.3",
      ...
    },
    ...
  }
  ```

  `"homeassistant"` is a map keyed by machine, **not** a plain version
  string — confirming the plan's fallback branch. Since Vagus v1 always
  runs the generic image (`Vagus.Core.Container`'s `@image_repo`, no
  per-machine image switch yet), this reads the map's `"default"` key. If a
  future upstream shape ever serves `"homeassistant"` as a plain string
  instead, that is accepted directly too.

  Cached for 24h (upstream's own refresh cadence, `misc/tasks.py:44`) using
  an injectable `:now` clock so tests can fast-forward past expiry without
  sleeping. A fetch failure (offline, non-200, malformed body) never
  raises or blocks callers: it returns the last cached value if one exists,
  else `nil`, and logs at `:debug` — this is expected/frequent (e.g. no
  internet on this device class) rather than exceptional, so it does not
  warn.

  ## Options (all injectable)

    * `:name` - GenServer name, defaults to `__MODULE__`.
    * `:path` - file path to persist to, defaults to
      `config :vagus, :core_versions_path`.
    * `:now` - zero-arity clock returning monotonic milliseconds, defaults
      to `System.monotonic_time(:millisecond)`. Tests inject a controllable
      clock to exercise the 24h cache without sleeping.
    * `:fetch` - zero-arity function performing the actual upstream fetch,
      returning `{:ok, String.t()} | {:error, term()}`. Defaults to a Finch
      GET through the `Vagus.Core.Finch` pool with a 10s receive timeout.
      Tests inject a stub so `latest/1` never makes a real HTTP call.
  """

  use GenServer

  require Logger

  @default_finch Vagus.Core.Finch
  @stable_url "https://version.home-assistant.io/stable.json"
  @fetch_receive_timeout 10_000
  @cache_ttl_ms 24 * 60 * 60 * 1_000
  @default_machine_key "default"

  @doc """
  Starts the store.

  See the moduledoc for `:name`/`:path`/`:now`/`:fetch` options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns the persisted installed version, or `nil` if none is known yet."
  @spec installed(GenServer.server()) :: String.t() | nil
  def installed(server \\ __MODULE__) do
    GenServer.call(server, :installed)
  end

  @doc "Sets (and persists) the installed version, always overwriting any prior value."
  @spec set_installed(String.t(), GenServer.server()) :: :ok
  def set_installed(version, server \\ __MODULE__) when is_binary(version) do
    GenServer.call(server, {:set_installed, version})
  end

  @doc """
  Sets the installed version only if none is currently persisted — used by
  boot adoption to seed from the running container's image tag without
  clobbering a value this store already has.
  """
  @spec seed(String.t(), GenServer.server()) :: :ok
  def seed(version, server \\ __MODULE__) when is_binary(version) do
    GenServer.call(server, {:seed, version})
  end

  @doc """
  Returns the latest upstream HA Core version, using a 24h in-memory cache.
  `nil` if never successfully fetched (fresh start + offline, or an
  unrecognized upstream response shape).
  """
  @spec latest(GenServer.server()) :: String.t() | nil
  def latest(server \\ __MODULE__) do
    GenServer.call(server, :latest)
  end

  @doc "`true` iff both an installed and a latest version are known and they differ."
  @spec update_available?(GenServer.server()) :: boolean()
  def update_available?(server \\ __MODULE__) do
    GenServer.call(server, :update_available?)
  end

  ## GenServer callbacks

  @impl GenServer
  def init(opts) do
    path = Keyword.get(opts, :path, versions_path())

    state = %{
      path: path,
      installed: read_persisted_version(path),
      now: Keyword.get(opts, :now, &default_now/0),
      fetch: Keyword.get(opts, :fetch, &default_fetch/0),
      # `nil` (never fetched) or `%{value: String.t() | nil, fetched_at: integer()}`.
      latest_cache: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:installed, _from, state) do
    {:reply, state.installed, state}
  end

  def handle_call({:set_installed, version}, _from, state) do
    persist(state.path, version)
    {:reply, :ok, %{state | installed: version}}
  end

  def handle_call({:seed, _version}, _from, %{installed: installed} = state)
      when is_binary(installed) do
    {:reply, :ok, state}
  end

  def handle_call({:seed, version}, _from, state) do
    persist(state.path, version)
    {:reply, :ok, %{state | installed: version}}
  end

  def handle_call(:latest, _from, state) do
    {value, new_state} = resolve_latest(state)
    {:reply, value, new_state}
  end

  def handle_call(:update_available?, _from, state) do
    {latest_value, new_state} = resolve_latest(state)

    result =
      is_binary(state.installed) and is_binary(latest_value) and latest_value != state.installed

    {:reply, result, new_state}
  end

  ## Internals — latest/cache

  defp resolve_latest(state) do
    now_ms = state.now.()

    case state.latest_cache do
      %{value: value, fetched_at: fetched_at} when now_ms - fetched_at < @cache_ttl_ms ->
        {value, state}

      _stale_or_absent ->
        do_fetch(state, now_ms)
    end
  end

  defp do_fetch(state, now_ms) do
    case state.fetch.() do
      {:ok, version} ->
        {version, %{state | latest_cache: %{value: version, fetched_at: now_ms}}}

      {:error, reason} ->
        Logger.debug("Vagus.Core.Versions: latest fetch failed (#{inspect(reason)})")
        {cached_value_or_nil(state.latest_cache), state}
    end
  end

  defp cached_value_or_nil(%{value: value}), do: value
  defp cached_value_or_nil(nil), do: nil

  defp default_now, do: System.monotonic_time(:millisecond)

  defp default_fetch do
    request = Finch.build(:get, @stable_url)

    case Finch.request(request, @default_finch, receive_timeout: @fetch_receive_timeout) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        parse_stable_json(body)

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_stable_json(body) do
    case Jason.decode(body) do
      {:ok, %{"homeassistant" => homeassistant}} -> extract_version(homeassistant)
      {:ok, _other} -> {:error, :missing_homeassistant_field}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  # Map keyed by machine (the real shape, confirmed live — see moduledoc):
  # v1 runs the generic image, so take the "default" key.
  defp extract_version(%{@default_machine_key => version}) when is_binary(version) do
    {:ok, version}
  end

  defp extract_version(map) when is_map(map), do: {:error, :no_default_version}

  # Defensive: accept a plain string too, in case upstream ever serves this
  # field unkeyed.
  defp extract_version(version) when is_binary(version), do: {:ok, version}

  defp extract_version(_other), do: {:error, :unexpected_homeassistant_shape}

  ## Internals — persistence

  # `path` is the compile/config-time versions-store path, never request
  # input — no user-controlled traversal is possible.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_persisted_version(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"version" => version}} when is_binary(version) <- Jason.decode(contents) do
      version
    else
      _not_found_or_invalid -> nil
    end
  end

  # `path` is the compile/config-time versions-store path, not request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp persist(path, version) do
    :ok = File.mkdir_p(Path.dirname(path))

    case File.write(path, Jason.encode!(%{"version" => version})) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Vagus.Core.Versions: failed to persist #{path} (#{inspect(reason)}) — " <>
            "installed version change was not written to disk"
        )
    end
  end

  defp versions_path do
    Application.get_env(:vagus, :core_versions_path) ||
      raise "config :vagus, :core_versions_path is not set (expected from config/host.exs or config/target.exs)"
  end
end
