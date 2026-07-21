defmodule Vagus.Ingress do
  @moduledoc """
  Ingress session store + per-add-on dynamic port allocator
  (`docs/contract-2026.7-m4b-ingress-watchdog.md` §B1, §B3.2) — the
  in-memory counterpart of the real Supervisor's `Ingress` class
  (`supervisor/ingress.py`).

  ## Sessions (§B1)

  `POST /ingress/session` mints a 128-hex-char token
  (`secrets.token_hex(64)`, §B1.1) valid for 15 minutes.
  `POST /ingress/validate_session` (§B1.2) is a **sliding-window renewal**,
  not a fixed-TTL check: every successful validate — including the ones the
  real proxy issues on *every single proxied request* — pushes the expiry
  another 15 minutes out from *now*. A session only expires after 15
  minutes of complete idleness, not 15 minutes after creation.

  Deliberate deviations from upstream, both intentional for M4b:

    * **No disk persistence.** Real Supervisor persists `session`/
      `session_data`/`ports` to `ingress.json` so sessions and dynamic port
      assignments survive a Supervisor restart. This module is pure
      in-memory state — an emulator restart drops every open ingress
      session (the panel iframe would need reloading) and, more subtly,
      *would* re-roll dynamic ports too if `Vagus.Addon.State` weren't
      already the durable side of that: dynamic ports are persisted via
      `State.put_setting/4` (§B3.2 below), so *those* do survive a restart
      even though the session store doesn't. Acceptable for M4b; sessions
      dying on emulator restart is a minor, self-healing UX blip (the
      frontend just re-requests a session), unlike a port reassignment
      which would break bashio's cached `ingress_port` inside a running
      add-on container.
    * **Lazy pruning, no timer.** Upstream purges expired sessions on
      `Ingress.load()`/`reload()`, which runs at Supervisor startup and
      every `RUN_RELOAD_INGRESS` tick (930s). This module instead prunes
      expired sessions inline on every `create_session/1` and
      `validate_session/2` call — equivalent for correctness (an expired
      session is never observably valid either way) and needs no
      background timer process.

  ## Dynamic ports (§B3.2)

  `dynamic_port/2` resolves an add-on's `ingress_port: 0` config to a real
  port in `62_000..65_500`. Once allocated it is persisted forever (via
  `Vagus.Addon.State.put_setting/4`) and never re-rolled for that slug,
  matching upstream's "assign once, keep until uninstall" behavior — this
  module doesn't handle the uninstall-time `del_dynamic_port` release
  itself; that's `Vagus.Addon.State`'s entry lifecycle (deleting the slug's
  entry entirely drops its `ingress_port` along with it).

  A candidate port is rejected if it collides with another add-on's already
  -assigned port (scanned from `State.list/1`) or if something is actually
  listening on it at the docker gateway IP (`port_probe`, a real
  `:gen_tcp.connect/3` probe by default) — mirroring upstream's
  `check_port(sys_docker.network.gateway, port)` call.

  ## Token → slug resolution (§B2.2 step 2)

  `resolve_token/2` scans `State.list/1` for the add-on whose
  `ingress_token` matches, on every call — **deliberately not cached**.
  Upstream rebuilds a `dict[ingress_token → slug]` once per
  `Ingress.load()`/`reload()` tick; this emulator's `State.list/1` is small
  (a handful of installed add-ons at most) and a scan is cheap enough that
  keeping a second, cacheable copy in sync across install/uninstall would
  be pure risk (a stale entry pointing at an uninstalled slug) for no
  measurable benefit.

  ## Injectable opts

  `:state` — the `Vagus.Addon.State` server to resolve slugs/tokens/ports
  against (default `Vagus.Addon.State`).

  `:clock` — zero-arity fn returning "now" in milliseconds (default
  `System.monotonic_time(:millisecond)`), so tests can drive session
  expiry without sleeping.

  `:port_probe` — arity-2 fn `(ip, port) -> :listening | :free` (default: a
  real TCP connect probe against `ip:port` with a ~500ms timeout; a
  successful connect means something is already listening there).

  `:gateway_ip` — the docker bridge gateway IP the port probe targets
  (default `Vagus.Network.anchors().gateway`).

  `:rand` — arity-2 fn `(min, max) -> integer` for candidate port
  selection (default a uniform `min..max` picker).
  """

  use GenServer

  alias Vagus.Addon.State
  alias Vagus.Network

  @session_ttl_ms 15 * 60 * 1000
  @port_min 62_000
  @port_max 65_500
  @max_port_tries 100

  @type token :: String.t()

  @doc "Starts the ingress store. `opts[:name]` defaults to `__MODULE__`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Creates a new ingress session, valid for 15 minutes from now. Returns
  `{:ok, token}` where `token` is 128 lowercase hex characters
  (§B1.1, `secrets.token_hex(64)`).
  """
  @spec create_session(GenServer.server()) :: {:ok, token()}
  def create_session(server \\ __MODULE__) do
    GenServer.call(server, :create_session)
  end

  @doc """
  Validates `token` and, on success, **slides** its expiry another 15
  minutes out from now (§B1.2) — call this on every proxied request, not
  just once, to keep a session alive for as long as the panel is in active
  use. `:error` for an unknown or already-expired token (expired tokens are
  purged as a side effect of this call).
  """
  @spec validate_session(token(), GenServer.server()) :: :ok | :error
  def validate_session(token, server \\ __MODULE__) when is_binary(token) do
    GenServer.call(server, {:validate_session, token})
  end

  @doc """
  Resolves a per-add-on `ingress_token` (distinct from a session token) to
  its slug — only add-ons whose config declares `ingress: true` resolve;
  everything else (unknown token, or a token belonging to a non-ingress
  add-on) is `:error`.
  """
  @spec resolve_token(String.t(), GenServer.server()) :: {:ok, String.t()} | :error
  def resolve_token(ingress_token, server \\ __MODULE__) when is_binary(ingress_token) do
    GenServer.call(server, {:resolve_token, ingress_token})
  end

  @doc """
  Resolves `slug`'s dynamic ingress port (§B3.2), allocating and persisting
  one on first call. `{:error, :not_found}` for an untracked slug,
  `{:error, :no_free_port}` if 100 candidates in a row all collide.
  """
  @spec dynamic_port(String.t(), GenServer.server()) ::
          {:ok, pos_integer()} | {:error, :not_found | :no_free_port}
  def dynamic_port(slug, server \\ __MODULE__) when is_binary(slug) do
    GenServer.call(server, {:dynamic_port, slug})
  end

  @doc "Number of currently-live (unexpired) sessions — tests/inspection only."
  @spec session_count(GenServer.server()) :: non_neg_integer()
  def session_count(server \\ __MODULE__) do
    GenServer.call(server, :session_count)
  end

  ## GenServer

  @impl GenServer
  def init(opts) do
    state = %{
      sessions: %{},
      state_server: Keyword.get(opts, :state, State),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      port_probe: Keyword.get(opts, :port_probe, &default_port_probe/2),
      gateway_ip: Keyword.get(opts, :gateway_ip, Network.anchors().gateway),
      rand: Keyword.get(opts, :rand, &default_rand/2)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:create_session, _from, state) do
    now = state.clock.()
    sessions = prune_expired(state.sessions, now)
    token = generate_session_token()
    sessions = Map.put(sessions, token, now + @session_ttl_ms)
    {:reply, {:ok, token}, %{state | sessions: sessions}}
  end

  def handle_call({:validate_session, token}, _from, state) do
    now = state.clock.()
    sessions = prune_expired(state.sessions, now)

    case Map.fetch(sessions, token) do
      {:ok, expiry} when expiry > now ->
        sessions = Map.put(sessions, token, now + @session_ttl_ms)
        {:reply, :ok, %{state | sessions: sessions}}

      _expired_or_absent ->
        {:reply, :error, %{state | sessions: sessions}}
    end
  end

  def handle_call({:resolve_token, ingress_token}, _from, state) do
    result =
      state.state_server
      |> State.list()
      |> Enum.find(fn entry ->
        entry.config.ingress and entry.ingress_token == ingress_token
      end)

    reply =
      case result do
        %{config: %{slug: slug}} -> {:ok, slug}
        nil -> :error
      end

    {:reply, reply, state}
  end

  def handle_call({:dynamic_port, slug}, _from, state) do
    case State.get(slug, state.state_server) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %{ingress_port: port}} when is_integer(port) ->
        {:reply, {:ok, port}, state}

      {:ok, _entry} ->
        other_ports = other_assigned_ports(state.state_server)

        case allocate_port(state, other_ports, @max_port_tries) do
          {:ok, port} ->
            :ok = State.put_setting(slug, :ingress_port, port, state.state_server)
            {:reply, {:ok, port}, state}

          {:error, :no_free_port} = error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call(:session_count, _from, state) do
    now = state.clock.()
    sessions = prune_expired(state.sessions, now)
    {:reply, map_size(sessions), %{state | sessions: sessions}}
  end

  ## Internals

  defp prune_expired(sessions, now) do
    Map.filter(sessions, fn {_token, expiry} -> expiry > now end)
  end

  defp generate_session_token do
    :crypto.strong_rand_bytes(64) |> Base.encode16(case: :lower)
  end

  defp other_assigned_ports(state_server) do
    state_server
    |> State.list()
    |> Enum.flat_map(fn
      %{ingress_port: port} when is_integer(port) -> [port]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp allocate_port(_state, _other_ports, 0), do: {:error, :no_free_port}

  defp allocate_port(state, other_ports, tries_left) do
    candidate = state.rand.(@port_min, @port_max)

    if MapSet.member?(other_ports, candidate) or
         state.port_probe.(state.gateway_ip, candidate) == :listening do
      allocate_port(state, other_ports, tries_left - 1)
    else
      {:ok, candidate}
    end
  end

  # Real Supervisor's `check_port`: attempt a TCP connect, success means
  # something is already listening there. Short timeout — this runs
  # synchronously inline in a GenServer call, on the loopback-ish docker
  # gateway, so a hung/filtered port must not stall port allocation for
  # long.
  defp default_port_probe(ip, port) do
    ip_charlist = ip |> to_string() |> String.to_charlist()

    case :gen_tcp.connect(ip_charlist, port, [:binary, active: false], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :listening

      {:error, _reason} ->
        :free
    end
  end

  defp default_rand(min, max), do: min + :rand.uniform(max - min + 1) - 1
end
