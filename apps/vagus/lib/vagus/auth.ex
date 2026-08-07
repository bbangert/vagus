defmodule Vagus.Auth do
  @moduledoc """
  Add-on `/auth` backend (`docs/contract-2026.7-m4-addendum.md` §A3.3) — lets a
  provider add-on (e.g. Mosquitto, via its in-container NGINX) validate an
  external client's Home Assistant username/password.

  `check_login/4` consults a local success cache first, then, on a miss,
  forwards `{username, password, addon}` to Core `POST api/hassio_auth`
  (authenticated as the Supervisor via `Vagus.Core.Client`); a `200` means the
  credentials are valid and the pair is remembered.

  The cache is keyed by `sha256(term_to_binary({username, password}))`
  (unambiguous — a `"user:pass"` join would collide across field boundaries)
  and entries expire after `@ttl_seconds` so a rotated password stops working.
  The real Supervisor additionally 19-round-rehashes with a per-process salt,
  but that detail is purely internal — the cache never crosses any wire — so a
  plain sha256 key is equivalent for interop while never holding a plaintext
  password.
  """

  use GenServer

  @doc "Starts the credential cache."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns `true` if `username`/`password` are valid for `addon_slug`.

  Options (mainly for tests):

    * `:server` - the cache GenServer, defaults to `__MODULE__`.
    * `:core_client` - a module exporting `request/3` like `Vagus.Core.Client`,
      defaults to `config :vagus, :core_client` (itself `Vagus.Core.Client`).
  """
  @spec check_login(String.t(), String.t(), String.t(), keyword()) :: boolean()
  def check_login(username, password, addon_slug, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    core_client = Keyword.get(opts, :core_client, default_core_client())
    key = cache_key(username, password)

    cond do
      cached?(key, server) ->
        true

      forward(username, password, addon_slug, core_client) ->
        remember(key, server)
        true

      true ->
        false
    end
  end

  @doc "Clears the credential cache (`DELETE /auth/cache`)."
  @spec reset_cache(GenServer.server()) :: :ok
  def reset_cache(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  ## Internals

  defp default_core_client do
    Application.get_env(:vagus, :core_client, Vagus.Core.Client)
  end

  # Hash the pair unambiguously: a `"#{u}:#{p}"` join is non-injective
  # (`{"a:b","c"}` and `{"a","b:c"}` collide), which would let a cached login
  # authenticate a *different* username/password split without re-checking Core.
  defp cache_key(username, password) do
    :crypto.hash(:sha256, :erlang.term_to_binary({username, password}))
  end

  defp cached?(key, server), do: GenServer.call(server, {:cached?, key})
  defp remember(key, server), do: GenServer.call(server, {:remember, key})

  # POST core api/hassio_auth {username,password,addon}; 200 ⇒ valid. Any
  # non-200, transport error, or "Core not connected yet"
  # (`{:error, :no_refresh_token}`) is a rejection.
  #
  # Prefer Core's Supervisor unix socket when configured: `api/hassio_auth`'s
  # `_check_access` requires the request to originate from the SUPERVISOR IP or
  # that socket, and the host-networked emulator can't present a `172.30.32.2`
  # source over TCP — the socket is the channel that authenticates us as the
  # Supervisor user (see `Vagus.Core.ApiSocket`). With no socket configured
  # (host tests), fall back to the injectable TCP client.
  defp forward(username, password, addon_slug, core_client) do
    body = %{"username" => username, "password" => password, "addon" => addon_slug}

    # One resolution, threaded into the POST — `Vagus.Core.Transport`'s
    # single-resolution discipline. Resolving a second time inside `post/3`
    # would let a socket that vanishes in between (a Core recreate) turn an
    # auth request into a connect against a `nil` path.
    case Vagus.Core.ApiSocket.path() do
      nil ->
        forward_tcp(body, core_client)

      socket ->
        match?({:ok, 200}, Vagus.Core.ApiSocket.post("/api/hassio_auth", body, socket: socket))
    end
  end

  defp forward_tcp(body, core_client) do
    case core_client.request(:post, "/api/hassio_auth",
           headers: [{"content-type", "application/json"}],
           body: Jason.encode!(body)
         ) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  ## GenServer

  # Cached logins expire so a rotated/revoked HA password stops authenticating
  # without a manual `DELETE /auth/cache`.
  @ttl_seconds 300

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  # Prune the entry on read if it has expired (returns false, drops it).
  @impl GenServer
  def handle_call({:cached?, key}, _from, cache) do
    case Map.get(cache, key) do
      nil ->
        {:reply, false, cache}

      inserted ->
        if now() - inserted < @ttl_seconds,
          do: {:reply, true, cache},
          else: {:reply, false, Map.delete(cache, key)}
    end
  end

  def handle_call({:remember, key}, _from, cache) do
    {:reply, :ok, Map.put(cache, key, now())}
  end

  def handle_call(:reset, _from, _cache) do
    {:reply, :ok, %{}}
  end

  defp now, do: System.monotonic_time(:second)
end
