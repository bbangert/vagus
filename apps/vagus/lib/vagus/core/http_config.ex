defmodule Vagus.Core.HttpConfig do
  @moduledoc """
  Core's live HTTP parameters — the `{port, ssl, server_host}` Core reports
  about *itself*, pulled over the Supervisor↔Core unix socket and cached
  here so `GET core/info` (`Vagus.API.StaticData.core_info/0`) can report
  the port Core actually listens on instead of a hardcoded `8123`.

  ## The endpoint (Core 2026.8, supervisor PR #6590)

  `GET /api/core/http_config` is served **only** on
  `SUPERVISOR_CORE_API_SOCKET` (`http/server.py`) — Core refuses it on its
  TCP listener — and answers, as observed against a live
  `home-assistant:2026.8.0`,

      {"port": 8123, "ssl": false, "ssl_peer_certificate": false,
       "server_host": ["0.0.0.0", "::"]}

  Only `port`, `ssl` and `server_host` are kept: those are the facts Vagus
  reports outward or (in a later phase of the core-socket-port80 plan) has
  to reason about when Core moves to port 80. `ssl_peer_certificate` is
  Core's own client-cert setting and means nothing to us.

  ## `server_host` is a *list*

  Core's `server_host` is every address its listener is bound to — a real
  2026.8 wildcard bind reports `["0.0.0.0", "::"]`, two addresses, and a
  configured single host reports a one-element list. Upstream's own config
  schema also still permits the pre-list scalar form, so a bare string is
  accepted and normalized to a one-element list rather than rejected. The
  cache therefore always holds `[String.t()]` (never a bare string) or
  `nil` — "Core has not told us", the same thing the defaults mean. Keeping
  the whole list rather than collapsing to the first entry is deliberate:
  the question Phase B has to answer is whether Core *wildcard*-binds (and
  so collides with our own `:80` listener), which the first element alone
  cannot answer.

  Because the endpoint is socket-only, there is nothing to pull on the TCP
  fallback (host dev, `:core_base_url`): `refresh/1` returns
  `{:skipped, :no_socket}` without issuing a request at all, and `get/1`
  keeps serving `defaults/0` — `port: 8123, ssl: false, server_host: nil`,
  byte-for-byte what `core/info` reported before this cache existed, and
  Core's own `_DEFAULT_CONFIG_LEGACY_PORT` bind-failure fallback. The
  defaults are deliberately NOT derived from `:core_base_url`: that URL is
  where *we* dial Core in dev, not something Core told us about itself.

  ## When it refreshes

  `Vagus.Core.Lifecycle` calls `refresh/1` at every point it establishes
  that Core is up: after a passing health gate (start / restart / rebuild /
  update) and on the already-running no-op `start/1` — the latter is the
  Vagus-restarted-while-Core-kept-running case (`Vagus.Core.Boot` calls
  `start/1` unconditionally), which has no health gate to hang off. Core's
  port can change across its own restarts, so this is a re-pull on every
  such transition, never a pull-once.

  A failed pull (Core healthy but the endpoint erroring, a socket that
  exists with nothing listening, garbage in the body) logs a warning and
  leaves the previous cache — including the defaults — in place. Nothing
  here ever raises into the lifecycle/health path it is called from.

  ## Core is not fully trusted with this device's memory

  The response is **streamed** (`Finch.stream_while/5`) and abandoned past
  64KB — a real answer is under 200 bytes — rather than buffered whole: a
  compromised or broken Core answering this endpoint with a multi-GB body
  would otherwise OOM a 512MB device. For the same reason `server_host` is
  only accepted up to 32 entries, since the accepted list is cached
  indefinitely. An over-long body is an ordinary `{:error, _}` pull that
  keeps the previous cache; an over-long `server_host` falls back to the
  default the same way any other unreadable shape does.

  Decode failures are logged as a *shape* (`{:invalid_json, {:position,
  n}}`), never as the offending body: `%Jason.DecodeError{}` carries the
  data it choked on, and `inspect/1` would spill up to 4KB of Core-controlled
  bytes into the fixed-size ring buffer that is a device's only forensic
  record.

  ## Why a process, and why the pull does not run inside it

  The cache is written by whoever drives Core's lifecycle (a router request
  worker, `Vagus.Core.Boot`, the watchdog's action task) and read by
  whichever Bandit worker is serving `core/info` — different processes,
  mutable state, so it needs an owner. No existing process fits:
  `Vagus.Core.Versions` owns the persisted *version* file (with its own
  fetch-queue machinery), `Vagus.Core.TokenStore` owns the fields
  `POST core/options` *requests* (as opposed to what Core actually serves),
  `Vagus.Core.Health`/`Vagus.Core.Lifecycle` are plain modules with no
  state at all, and the watchdog only runs on target.

  The HTTP request itself runs in the **caller's** process (`refresh/1` is
  a plain function that pulls, then hands the result over), so this
  GenServer never blocks on IO: a hung Core can't wedge `core/info` behind
  a 5s request the way an inline `handle_call/3` fetch would.

  `get/1` answers `defaults/0` if the server is down (mid-restart of the
  `:rest_for_one` Core subtree) rather than exiting — this is a cache with
  a meaningful default on a read path that must not 500 because it blinked.

  ## Options

    * `:name` - GenServer name, defaults to `#{inspect(__MODULE__)}`.
    * `:config` - the initial cached value, defaults to `defaults/0`.

  `refresh/1` additionally takes `:server` (which cache to write, default
  `#{inspect(__MODULE__)}`), `:transport` (a resolved `Vagus.Core.Transport.t()`,
  default `Vagus.Core.Transport.current/1`) and `:finch` (the pool, default
  `Vagus.Core.Finch`).
  """

  use GenServer

  require Logger

  alias Vagus.Core.Transport

  @typedoc "Core's reported HTTP parameters."
  @type t :: %{port: pos_integer(), ssl: boolean(), server_host: [String.t()] | nil}

  @endpoint "/api/core/http_config"
  @defaults %{port: 8123, ssl: false, server_host: nil}
  @default_finch Vagus.Core.Finch
  @receive_timeout 5_000
  @max_port 65_535
  @max_body 65_536
  @max_server_hosts 32

  ## Public API

  @doc "Starts the cache. See the moduledoc for `:name`/`:config`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  What Core reports when it has never been asked (no socket, or no
  successful pull yet) — see the moduledoc.
  """
  @spec defaults() :: t()
  def defaults, do: @defaults

  @doc """
  The cached HTTP config, or `defaults/0` if nothing has been pulled yet
  (or the cache process is momentarily down).
  """
  @spec get(GenServer.server()) :: t()
  def get(server \\ __MODULE__) do
    GenServer.call(server, :get)
  catch
    # See the moduledoc: a blinking cache must not turn `core/info` into a 500.
    :exit, _reason -> @defaults
  end

  @doc """
  Pulls `GET #{@endpoint}` over the socket and caches the result.

  `:ok` when the cache was updated, `{:skipped, :no_socket}` when there is
  no socket to ask (TCP fallback — the endpoint does not exist there), and
  `{:error, reason}` when the pull or the handover failed, in which case
  the previously cached value stays.

  See the moduledoc for `:server`/`:transport`/`:finch`.
  """
  @spec refresh(keyword()) :: :ok | {:skipped, :no_socket} | {:error, term()}
  def refresh(opts \\ []) do
    case pull(opts) do
      {:ok, config} ->
        store(config, opts)

      {:skipped, :no_socket} = skipped ->
        Logger.debug(
          "Vagus.Core.HttpConfig: no Supervisor↔Core socket — keeping #{inspect(@defaults)}"
        )

        skipped

      {:error, reason} ->
        Logger.warning(
          "Vagus.Core.HttpConfig: #{@endpoint} pull failed (#{inspect(reason)}) — " <>
            "keeping the previously cached config"
        )

        {:error, reason}
    end
  end

  ## GenServer callbacks

  @impl GenServer
  def init(opts) do
    {:ok, %{config: Keyword.get(opts, :config, @defaults)}}
  end

  @impl GenServer
  def handle_call(:get, _from, state) do
    {:reply, state.config, state}
  end

  def handle_call({:put, config}, _from, state) do
    {:reply, :ok, %{state | config: config}}
  end

  ## Internals

  defp pull(opts) do
    case Keyword.get(opts, :transport) || Transport.current() do
      {:socket, _path} = transport -> fetch(transport, opts)
      {:tcp, _base_url} -> {:skipped, :no_socket}
    end
  end

  defp fetch(transport, opts) do
    request = Transport.build(transport, :get, @endpoint)
    acc = %{status: nil, body: [], size: 0}

    stream =
      Finch.stream_while(request, finch(opts), acc, &collect/2, receive_timeout: @receive_timeout)

    case stream do
      {:ok, %{size: size}} when size > @max_body -> {:error, :response_too_large}
      {:ok, %{status: 200, body: body}} -> body |> IO.iodata_to_binary() |> decode()
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason, _acc} -> {:error, reason}
    end
  rescue
    # `Finch.stream_while/5` raises (rather than returning an error) when its
    # pool isn't running — reachable in the window where the `:rest_for_one`
    # Core subtree is restarting around an in-flight lifecycle op. That must
    # not take the caller's health path down with it.
    e in ArgumentError -> {:error, {:finch_unavailable, Exception.message(e)}}
  end

  # Streamed rather than buffered, and abandoned the moment Core has sent
  # more than a sane answer could be — see the moduledoc. `:halt` leaves the
  # over-limit size in the accumulator, which is what `fetch/2` matches on.
  defp collect({:status, status}, acc), do: {:cont, %{acc | status: status}}

  defp collect({:data, chunk}, acc) do
    acc = %{acc | body: [acc.body, chunk], size: acc.size + byte_size(chunk)}

    if acc.size > @max_body, do: {:halt, acc}, else: {:cont, acc}
  end

  defp collect(_headers_or_trailers, acc), do: {:cont, acc}

  defp store(config, opts) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:put, config})
  catch
    :exit, reason ->
      Logger.warning(
        "Vagus.Core.HttpConfig: cache unavailable (#{inspect(reason)}) — " <>
          "#{inspect(config)} was pulled but not stored"
      )

      {:error, {:cache_unavailable, reason}}
  end

  # `port` is the one field that must be there and be sane — it is what the
  # rest of the system reports outward. `ssl`/`server_host` fall back to the
  # defaults rather than rejecting the whole response, the same tolerance
  # `Vagus.Core.TokenStore` applies to unknown/absent wire fields.
  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{"port" => port} = decoded}
      when is_integer(port) and port > 0 and port <= @max_port ->
        {:ok, %{port: port, ssl: ssl(decoded), server_host: server_host(decoded)}}

      {:ok, _other} ->
        {:error, :invalid_response}

      {:error, reason} ->
        {:error, {:invalid_json, json_error_shape(reason)}}
    end
  end

  # The position, never the data — see the moduledoc: `refresh/1` inspects
  # this reason straight into RingLogger, and a `%Jason.DecodeError{}` would
  # carry up to 4KB of Core's body along with it.
  defp json_error_shape(%Jason.DecodeError{position: position}), do: {:position, position}

  defp ssl(%{"ssl" => ssl}) when is_boolean(ssl), do: ssl
  defp ssl(_decoded), do: @defaults.ssl

  # See the moduledoc: a real Core answers with a list of bound addresses;
  # the scalar form upstream's schema still allows is normalized into one.
  defp server_host(%{"server_host" => host}) when is_binary(host), do: [host]

  # The cap is memory hygiene, not protocol: the accepted list is held in
  # GenServer state indefinitely, and no real bind list is anywhere near 32
  # addresses (see the moduledoc).
  defp server_host(%{"server_host" => hosts})
       when is_list(hosts) and length(hosts) <= @max_server_hosts do
    if Enum.all?(hosts, &is_binary/1), do: hosts, else: @defaults.server_host
  end

  defp server_host(_decoded), do: @defaults.server_host

  defp finch(opts), do: Keyword.get(opts, :finch, @default_finch)
end
