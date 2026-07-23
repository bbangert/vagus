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

  ## The fetch never blocks the server loop

  A cache-miss/stale fetch is a Finch HTTP request with a 10s
  `receive_timeout`, but every caller reaches this GenServer via
  `GenServer.call/2`'s default 5s timeout. Running the fetch inline inside
  `handle_call/3` would let a slow/dead network wedge the *whole* server
  for up to 10s: `installed/1`, `set_installed/2`, `seed/2`, and any other
  in-flight `latest/1`/`update_available?/1` caller would all queue behind
  one unrelated HTTP request, and the original caller would itself time
  out at 5s while the server kept blocking.

  So `handle_call(:latest, ...)` / `handle_call(:update_available?, ...)`
  only ever reply synchronously from a *fresh* cache. On a stale/absent
  cache they queue the caller's `from` (tagged with which reply shape it
  wants) in `state.pending` and return `{:noreply, state}` — the mailbox
  stays open for `installed/1` etc. in the meantime. The actual fetch runs
  in a `spawn_monitor/1`-ed one-shot process (not a linked `Task`, so a
  crash there can never take this GenServer down with it); the server
  learns the outcome via an ordinary message plus a `:DOWN` for the crash
  case, updates the cache exactly like the old inline path did, and then
  `GenServer.reply/2`s every queued waiter — `update_available?` waiters
  are computed from the *current* `state.installed` at reply time, not
  whatever it was when they were queued. At most one fetch runs at a time:
  a caller arriving while one is already in flight just joins the queue
  instead of starting a second request. A crash (`:DOWN` with no prior
  result message) falls back to the stale-cache-or-nil value for every
  queued waiter, same as a `{:error, _}` from `fetch.()`.

  `installed/1`, `set_installed/2`, and `seed/2` never touch `pending` or
  `in_flight` — they always reply immediately regardless of what `latest`
  is doing.

  ## Options (all injectable)

    * `:name` - GenServer name, defaults to `__MODULE__`.
    * `:path` - file path to persist to, defaults to
      `config :vagus, :core_versions_path`.
    * `:now` - zero-arity clock returning monotonic milliseconds, defaults
      to `System.monotonic_time(:millisecond)`. Tests inject a controllable
      clock to exercise the 24h cache without sleeping.
    * `:fetch` - zero-arity function performing the actual upstream fetch,
      returning `{:ok, String.t()} | {:error, term()}`. Runs inside the
      spawned fetch process, not the GenServer itself (see "The fetch
      never blocks the server loop" above). Defaults to a Finch GET
      through the `Vagus.Core.Finch` pool with a 10s receive timeout.
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
      latest_cache: nil,
      # Callers queued behind an in-flight fetch: `{GenServer.from(), :latest | :update_available?}`.
      pending: [],
      # `nil` or `%{pid: pid(), correlation_ref: reference(), monitor_ref: reference()}`
      # for the one fetch process allowed to run at a time.
      in_flight: nil
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

  def handle_call(:latest, from, state) do
    case fresh_cache_value(state) do
      {:fresh, value} -> {:reply, value, state}
      :stale -> {:noreply, enqueue_and_maybe_fetch(state, from, :latest)}
    end
  end

  def handle_call(:update_available?, from, state) do
    case fresh_cache_value(state) do
      {:fresh, value} -> {:reply, update_available_result(state.installed, value), state}
      :stale -> {:noreply, enqueue_and_maybe_fetch(state, from, :update_available?)}
    end
  end

  @impl GenServer
  def handle_info(
        {:versions_fetch_result, ref, result},
        %{in_flight: %{correlation_ref: ref, monitor_ref: monitor_ref}} = state
      ) do
    Process.demonitor(monitor_ref, [:flush])
    state = apply_fetch_result(state, result)
    reply_waiters(state)
    {:noreply, %{state | pending: [], in_flight: nil}}
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, _pid, _reason},
        %{in_flight: %{monitor_ref: monitor_ref}} = state
      ) do
    reply_waiters(state)
    {:noreply, %{state | pending: [], in_flight: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("Vagus.Core.Versions: unexpected message #{inspect(msg)}")
    {:noreply, state}
  end

  ## Internals — latest/cache

  defp fresh_cache_value(state) do
    now_ms = state.now.()

    case state.latest_cache do
      %{value: value, fetched_at: fetched_at} when now_ms - fetched_at < @cache_ttl_ms ->
        {:fresh, value}

      _stale_or_absent ->
        :stale
    end
  end

  defp enqueue_and_maybe_fetch(state, from, kind) do
    state = %{state | pending: [{from, kind} | state.pending]}
    if state.in_flight, do: state, else: start_fetch(state)
  end

  defp start_fetch(state) do
    correlation_ref = make_ref()
    parent = self()
    fetch = state.fetch

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(parent, {:versions_fetch_result, correlation_ref, fetch.()})
      end)

    %{
      state
      | in_flight: %{pid: pid, correlation_ref: correlation_ref, monitor_ref: monitor_ref}
    }
  end

  # Same shape rule the router applies to user-supplied versions
  # (`validate_core_update_version/1`): the fetched value ends up in
  # `Container.image/1` and persisted state via `update(nil)`, so an
  # upstream-served value gets the same scrutiny as request input —
  # an invalid tag is treated exactly like a fetch failure (stale cache
  # or nil), never cached.
  @version_tag_re ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @version_max_len 128

  defp apply_fetch_result(state, {:ok, version}) do
    if valid_version_tag?(version) do
      %{state | latest_cache: %{value: version, fetched_at: state.now.()}}
    else
      Logger.warning(
        "Vagus.Core.Versions: upstream served a non-tag-shaped version " <>
          "(#{inspect(String.slice(version, 0, 64))}) — ignoring"
      )

      state
    end
  end

  defp apply_fetch_result(state, {:error, reason}) do
    Logger.debug("Vagus.Core.Versions: latest fetch failed (#{inspect(reason)})")
    state
  end

  defp valid_version_tag?(version) do
    byte_size(version) <= @version_max_len and Regex.match?(@version_tag_re, version)
  end

  defp reply_waiters(state) do
    latest_value = cached_value_or_nil(state.latest_cache)

    Enum.each(state.pending, fn
      {from, :latest} ->
        GenServer.reply(from, latest_value)

      {from, :update_available?} ->
        GenServer.reply(from, update_available_result(state.installed, latest_value))
    end)
  end

  defp update_available_result(installed, latest_value) do
    is_binary(installed) and is_binary(latest_value) and latest_value != installed
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
