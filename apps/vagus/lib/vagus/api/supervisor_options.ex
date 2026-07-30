defmodule Vagus.API.SupervisorOptions do
  @moduledoc """
  Persists the fields `POST supervisor/options` posts that this emulator
  actually has somewhere to put: `timezone`, `country`, `diagnostics`
  (audit E5). `Vagus.API.Router` validates the full upstream vocabulary —
  `channel`, `addons_repositories`, `wait_boot`, `debug`, `debug_block`,
  `logging`, `auto_update`, `detect_blocking_io` are all type/enum-checked
  too — but only these three ever reach `put/2`; the rest are
  "validate shape, then ignore" (same standing rule
  `Vagus.Backend.Network.WireConfig`'s moduledoc documents for its own
  unsupported fields) because Vagus has no channel/debug/wait_boot
  machinery for them to drive.

  File-backed JSON (target: `/data/vagus/supervisor_options.json`, host:
  `.dev/supervisor_options.json`, test: an isolated tmp path — same
  `config :vagus, :supervisor_options_path` / injectable-`:path` pattern
  `Vagus.Core.TokenStore` uses for `:core_token_path`), read once at
  `init/1` so a value posted before an emulator restart is still there
  afterwards.

  `Vagus.API.Router`'s `GET /supervisor/info` and `GET /info` read this
  store's fields back live instead of `Vagus.API.StaticData`'s permanent
  nulls (audit D5/D1) — Core pushes `{timezone, country}` unconditionally
  at hassio entry setup and on every core-config update, and `{diagnostics}`
  whenever the user toggles diagnostics sharing; before this store existed
  every one of those posts was silently discarded.
  """

  use GenServer

  require Logger

  @persisted_fields ~w(timezone country diagnostics)

  @typedoc "The subset of POST supervisor/options fields this store persists."
  @type options :: %{optional(String.t()) => term()}

  @doc """
  Starts the store.

  Options:

    * `:name` - GenServer name, defaults to `__MODULE__`.
    * `:path` - file path to persist to, defaults to
      `config :vagus, :supervisor_options_path`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns the persisted `timezone`, or `nil` if never posted."
  @spec timezone(GenServer.server()) :: String.t() | nil
  def timezone(server \\ __MODULE__) do
    GenServer.call(server, :timezone)
  end

  @doc """
  Returns all three persisted fields at once (atom-keyed, `nil` for any
  never posted) — the shape `Vagus.API.Router` merges straight over
  `Vagus.API.StaticData.supervisor_info/0`.
  """
  @spec get(GenServer.server()) :: %{
          timezone: String.t() | nil,
          country: String.t() | nil,
          diagnostics: boolean() | nil
        }
  def get(server \\ __MODULE__) do
    GenServer.call(server, :get)
  end

  @doc """
  Merges `fields` (string-keyed, e.g. `%{"timezone" => "UTC"}`) into the
  persisted set — only `#{inspect(@persisted_fields)}` are ever kept, same
  "unknown/unhandled keys are silently dropped here" contract
  `Vagus.Core.TokenStore.put_options/2` follows (the caller,
  `Vagus.API.Router`, has already validated shape/type before this is
  called, but this store does not trust that alone). Always succeeds.
  """
  @spec put(options(), GenServer.server()) :: :ok
  def put(fields, server \\ __MODULE__) when is_map(fields) do
    GenServer.call(server, {:put, fields})
  end

  ## GenServer callbacks

  @impl GenServer
  def init(opts) do
    path = Keyword.get(opts, :path, options_path())
    options = read_persisted(path)
    {:ok, %{path: path, options: options}}
  end

  @impl GenServer
  def handle_call(:timezone, _from, state) do
    {:reply, Map.get(state.options, "timezone"), state}
  end

  def handle_call(:get, _from, state) do
    reply = %{
      timezone: Map.get(state.options, "timezone"),
      country: Map.get(state.options, "country"),
      diagnostics: Map.get(state.options, "diagnostics")
    }

    {:reply, reply, state}
  end

  def handle_call({:put, fields}, _from, state) do
    accepted = Map.take(fields, @persisted_fields)
    new_options = Map.merge(state.options, accepted)
    persist(state.path, new_options)
    {:reply, :ok, %{state | options: new_options}}
  end

  # `path` is the compile/config-time options-store path, never request
  # input — no user-controlled traversal is possible.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_persisted(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{} = decoded} <- Jason.decode(contents) do
      decode_options(decoded)
    else
      _not_found_or_invalid -> %{}
    end
  end

  # Mirrors `Vagus.Addon.State`'s decode discipline (`decode_entry`/
  # `decode_bool_setting` etc., state.ex) — a hand-edited or partially
  # written `supervisor_options.json` is not trusted verbatim. Before this,
  # a wrongly-typed field (e.g. `"diagnostics": "yes"`) reached
  # `handle_call(:get, ...)` unchanged and would raise wherever the caller
  # assumes the declared type — `GET /info`, Core's main poll
  # (security-phase6.md W2). A type mismatch is dropped (logged, not
  # persisted-through) rather than trusted; a missing key stays absent, same
  # as today.
  defp decode_options(decoded) do
    %{}
    |> put_decoded("timezone", decode_string(decoded, "timezone"))
    |> put_decoded("country", decode_string(decoded, "country"))
    |> put_decoded("diagnostics", decode_boolean(decoded, "diagnostics"))
  end

  defp put_decoded(map, _key, nil), do: map
  defp put_decoded(map, key, value), do: Map.put(map, key, value)

  defp decode_string(decoded, key) do
    case Map.get(decoded, key) do
      nil -> nil
      value when is_binary(value) -> value
      other -> log_dropped(key, other)
    end
  end

  defp decode_boolean(decoded, key) do
    case Map.get(decoded, key) do
      nil -> nil
      value when is_boolean(value) -> value
      other -> log_dropped(key, other)
    end
  end

  # `inspect/1` is bounded (`limit: 20`, same default `Logger` config uses
  # elsewhere in this file) and this only ever reaches the log, never a
  # response — no phase-5 `safe_inspect` concern (that rule is about HTTP
  # error bodies, not server-side logs of on-disk state).
  defp log_dropped(key, value) do
    Logger.warning(
      "Vagus.API.SupervisorOptions: dropping #{inspect(key)} " <>
        "(unexpected type #{inspect(value, limit: 20)}) from the persisted file"
    )

    nil
  end

  # `path` is the compile/config-time options-store path, not request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp persist(path, options) do
    :ok = File.mkdir_p(Path.dirname(path))

    case File.write(path, Jason.encode!(options)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Vagus.API.SupervisorOptions: failed to persist #{path} (#{inspect(reason)}) — " <>
            "options change was not written to disk"
        )
    end
  end

  defp options_path do
    Application.get_env(:vagus, :supervisor_options_path) ||
      raise "config :vagus, :supervisor_options_path is not set " <>
              "(expected from config/host.exs or config/target.exs)"
  end
end
