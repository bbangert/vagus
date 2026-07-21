defmodule Vagus.Auth do
  @moduledoc """
  Add-on `/auth` backend (`docs/contract-2026.7-m4-addendum.md` §A3.3) — lets a
  provider add-on (e.g. Mosquitto, via its in-container NGINX) validate an
  external client's Home Assistant username/password.

  `check_login/4` consults a local success cache first, then, on a miss,
  forwards `{username, password, addon}` to Core `POST api/hassio_auth`
  (authenticated as the Supervisor via `Vagus.Core.Client`); a `200` means the
  credentials are valid and the pair is remembered.

  The cache is keyed by `sha256("username:password")`. The real Supervisor
  additionally 19-round-rehashes with a per-process salt, but that detail is
  purely internal — the cache never crosses any wire — so a plain sha256 key is
  equivalent for interop while still never holding a plaintext password.
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

  defp cache_key(username, password) do
    :crypto.hash(:sha256, "#{username}:#{password}")
  end

  defp cached?(key, server), do: GenServer.call(server, {:cached?, key})
  defp remember(key, server), do: GenServer.call(server, {:remember, key})

  # POST core api/hassio_auth {username,password,addon}; 200 ⇒ valid. Any
  # non-200, transport error, or "Core not connected yet"
  # (`{:error, :no_refresh_token}`) is a rejection.
  defp forward(username, password, addon_slug, core_client) do
    body =
      Jason.encode!(%{"username" => username, "password" => password, "addon" => addon_slug})

    case core_client.request(:post, "/api/hassio_auth",
           headers: [{"content-type", "application/json"}],
           body: body
         ) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  ## GenServer

  @impl GenServer
  def init(_opts), do: {:ok, MapSet.new()}

  @impl GenServer
  def handle_call({:cached?, key}, _from, cache) do
    {:reply, MapSet.member?(cache, key), cache}
  end

  def handle_call({:remember, key}, _from, cache) do
    {:reply, :ok, MapSet.put(cache, key)}
  end

  def handle_call(:reset, _from, _cache) do
    {:reply, :ok, MapSet.new()}
  end
end
