defmodule Vagus.Core.TokenStore do
  @moduledoc """
  Persists the fields Home Assistant Core posts to `core/options`
  (`docs/contract-2026.7.md` §22), most importantly the Supervisor-user
  refresh token Core hands over during entry setup (§5) — everything
  downstream that needs to talk back to Core (`Vagus.Core.Client`'s access
  -token exchange, `Vagus.Core.EventPusher`'s WS auth) reads it from here
  rather than from the request path directly.

  File-backed JSON (target: `/data/vagus/core_token.json`, host:
  `.dev/core_token.json`, test: an isolated tmp path — same
  `config :vagus, :core_token_path` pattern `Vagus.API.Token` uses for its
  own file), read once at `init/1` so a value posted before an emulator
  restart is still there afterwards.

  Only the fields Core's `HomeAssistantOptions` model actually declares
  (§22: `boot`, `image`, `port`, `ssl`, `watchdog`, `refresh_token`,
  `audio_input`, `audio_output`, `backups_exclude_database`,
  `duplicate_log_file`) are accepted from `put_options/2` — anything else
  is silently dropped, mirroring the real Supervisor's tolerance of unknown
  wire keys (§6) rather than rejecting the whole call.

  Subscribers (`subscribe/1`) get a `{:token_store, :refresh_token_available}`
  message the moment a refresh token first lands or changes value — this is
  how `Vagus.Core.EventPusher` knows it's safe to start connecting instead
  of polling. A subscriber that already missed the notification (e.g. it
  starts up after the token landed) is expected to also call
  `get_refresh_token/1` once at its own `init/1`, since this store does not
  replay history to new subscribers.
  """

  use GenServer

  require Logger

  @accepted_fields ~w(
    boot image port ssl watchdog refresh_token audio_input audio_output
    backups_exclude_database duplicate_log_file
  )

  @typedoc "The subset of POST core/options fields this store persists."
  @type options :: %{optional(String.t()) => term()}

  @doc "Field names accepted from POST core/options (contract §22)."
  @spec accepted_fields() :: [String.t()]
  def accepted_fields, do: @accepted_fields

  @doc """
  Starts the store.

  Options:

    * `:name` - GenServer name, defaults to `__MODULE__`.
    * `:path` - file path to persist to, defaults to
      `config :vagus, :core_token_path`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns the persisted refresh token, or `nil` if none has been posted yet."
  @spec get_refresh_token(GenServer.server()) :: String.t() | nil
  def get_refresh_token(server \\ __MODULE__) do
    GenServer.call(server, :get_refresh_token)
  end

  @doc """
  Merges `fields` (a string-keyed map, e.g. straight off `conn.body_params`)
  into the persisted options — only keys in `accepted_fields/0` are kept,
  everything else is ignored. Always succeeds, even with an empty map
  (an options-only call with no `refresh_token` is valid, §22).

  Persists to disk before returning. Notifies subscribers only when the
  resulting `refresh_token` is a non-nil value that differs from what was
  persisted before this call (idempotent re-puts of the same token are a
  no-op for notification purposes).
  """
  @spec put_options(options(), GenServer.server()) :: :ok
  def put_options(fields, server \\ __MODULE__) when is_map(fields) do
    GenServer.call(server, {:put_options, fields})
  end

  @doc """
  Registers the calling process to receive
  `{:token_store, :refresh_token_available}` the next time a refresh token
  first lands or changes.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  ## GenServer callbacks

  @impl GenServer
  def init(opts) do
    path = Keyword.get(opts, :path, token_path())
    options = read_persisted(path)
    {:ok, %{path: path, options: options, subscribers: MapSet.new()}}
  end

  @impl GenServer
  def handle_call(:get_refresh_token, _from, state) do
    {:reply, Map.get(state.options, "refresh_token"), state}
  end

  def handle_call({:put_options, fields}, _from, state) do
    accepted = Map.take(fields, @accepted_fields)
    old_refresh_token = Map.get(state.options, "refresh_token")
    new_options = Map.merge(state.options, accepted)
    new_refresh_token = Map.get(new_options, "refresh_token")

    persist(state.path, new_options)

    if is_binary(new_refresh_token) and new_refresh_token != old_refresh_token do
      notify_subscribers(state.subscribers)
    end

    {:reply, :ok, %{state | options: new_options}}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  defp notify_subscribers(subscribers) do
    Enum.each(subscribers, &send(&1, {:token_store, :refresh_token_available}))
  end

  # `path` is the compile/config-time token-store path, never request input —
  # no user-controlled traversal is possible.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_persisted(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{} = decoded} <- Jason.decode(contents) do
      decoded
    else
      _not_found_or_invalid -> %{}
    end
  end

  # `path` is the compile/config-time token-store path, not request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp persist(path, options) do
    :ok = File.mkdir_p(Path.dirname(path))

    case File.write(path, Jason.encode!(options)) do
      :ok ->
        chmod_admin_only(path)

      {:error, reason} ->
        Logger.error(
          "Vagus.Core.TokenStore: failed to persist #{path} (#{inspect(reason)}) — " <>
            "refresh token change was not written to disk"
        )
    end
  end

  # This file holds Core's admin-grade refresh token — restrict it to the
  # owning user. A chmod failure doesn't invalidate the write that already
  # landed, so it's logged rather than raised.
  # sobelow_skip ["Traversal.FileModule"]
  defp chmod_admin_only(path) do
    case File.chmod(path, 0o600) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Vagus.Core.TokenStore: failed to chmod #{path} to 0600 (#{inspect(reason)})"
        )
    end
  end

  defp token_path do
    Application.get_env(:vagus, :core_token_path) ||
      raise "config :vagus, :core_token_path is not set (expected from config/host.exs or config/target.exs)"
  end
end
