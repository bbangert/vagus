defmodule Vagus.Core.Users do
  @moduledoc """
  Answers "is this Core user an administrator?" (gating Supervisor-owned
  panels) and "what is this Core user called?" (the ingress identity
  headers) from one cached fetch.

  Core exposes its user records **only** over the WebSocket API — the
  `config/auth/list` command (`homeassistant/components/config/auth.py`),
  itself `@websocket_api.require_admin`. There is no REST equivalent
  anywhere in Core and no single-user lookup, so the whole list is fetched
  and filtered here, over `Vagus.Core.EventPusher`'s existing authenticated
  socket. Vagus's Core token belongs to the Supervisor system user, which
  Core creates in the admin group, so it satisfies `require_admin`.

  The derived `user_id => %{admin?, username, name}` map is cached for 30
  seconds so a panel that asks repeatedly doesn't hammer Core. Only
  successful fetches are cached; an error never displaces a good answer nor
  poisons the next call. A cached map is authoritative for ids it doesn't
  contain too — the fetch returns *every* user, so an absent id is a known
  non-admin with no known names, not a cache miss.

  Swappable by consumers via `Application.get_env(:vagus, :core_users,
  Vagus.Core.Users)` — a drop-in need only export what its consumer calls
  (`admin?/1` for `Vagus.API.AdminPanel`, `names/2` for
  `Vagus.API.IngressProxy`, which passes its own short `:timeout`).
  """

  use GenServer

  alias Vagus.Core.EventPusher

  @ttl_ms 30_000
  @command_timeout 5_000
  @list_command %{"type" => "config/auth/list"}

  # `config/auth/list` user dicts carry no `is_admin` key. Core derives it
  # (homeassistant/auth/models.py:89-94) as
  #
  #     is_owner or (is_active and GROUP_ID_ADMIN in group_ids)
  #
  # where GROUP_ID_ADMIN is "system-admin" (homeassistant/auth/const.py:9).
  # Note the asymmetry: an owner is an admin even while inactive, whereas a
  # group member is not.
  @admin_group_id "system-admin"

  # What a successful fetch says about an id it doesn't contain: known, and
  # known to be nothing. Never an error — see the moduledoc.
  @absent_user %{admin?: false, username: nil, name: nil}

  @doc """
  Starts the admin-status cache.

  Options:

    * `:name` - GenServer name, defaults to `__MODULE__`.
    * `:ttl_ms` - how long a fetched user list stays fresh, defaults to
      `#{@ttl_ms}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns `{:ok, true}` if the Core user `user_id` is an administrator.

  A successful fetch in which `user_id` does not appear is a definitive
  `{:ok, false}` — only transport/protocol failures yield `{:error, reason}`
  (including the case where the WS manager isn't running at all, which is
  `{:error, :not_started}`).

  Options (mainly for tests):

    * `:server` - the cache GenServer, defaults to `__MODULE__`. A missing
      or dead server degrades to "no caching", never an error.
    * `:command_fun` - a 2-arity `(payload, opts)` function like
      `Vagus.Core.EventPusher.command/2`, defaults to
      `config :vagus, :core_users_command_fun`.
    * `:timeout` - milliseconds to wait for Core, defaults to
      `#{@command_timeout}`.
  """
  @spec admin?(String.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def admin?(user_id, opts \\ []) when is_binary(user_id) do
    case lookup(user_id, opts) do
      {:ok, user} -> {:ok, user.admin?}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns `{:ok, %{username: ..., name: ...}}` — Core's login name and
  display name for `user_id`, either of which is `nil` when Core has none
  (both are nullable there) or when `user_id` is absent from the list.

  Takes the same options as `admin?/2`, and shares its cached fetch: asking
  for both costs one Core round-trip, not two.
  """
  @spec names(String.t(), keyword()) ::
          {:ok, %{username: String.t() | nil, name: String.t() | nil}} | {:error, term()}
  def names(user_id, opts \\ []) when is_binary(user_id) do
    case lookup(user_id, opts) do
      {:ok, user} -> {:ok, Map.take(user, [:username, :name])}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Drops the cached user list, forcing the next `admin?/2` to re-fetch."
  @spec invalidate(GenServer.server()) :: :ok
  def invalidate(server \\ __MODULE__) do
    call(server, :invalidate, :ok)
  end

  ## Internals

  defp lookup(user_id, opts) do
    server = Keyword.get(opts, :server, __MODULE__)

    case cached(server) do
      {:ok, users} -> {:ok, Map.get(users, user_id, @absent_user)}
      :miss -> fetch(user_id, server, opts)
    end
  end

  defp fetch(user_id, server, opts) do
    command_fun = Keyword.get(opts, :command_fun, default_command_fun())
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    case command_fun.(@list_command, timeout: timeout) do
      {:ok, users} when is_list(users) ->
        users = derive(users)
        call(server, {:put, users}, :ok)
        {:ok, Map.get(users, user_id, @absent_user)}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_result, other}}
    end
  end

  defp derive(users) do
    for user <- users,
        is_map(user),
        id = Map.get(user, "id"),
        is_binary(id),
        into: %{},
        do:
          {id,
           %{
             admin?: admin_user?(user),
             username: name_field(user, "username"),
             name: name_field(user, "name")
           }}
  end

  # Both fields are nullable in Core, and a consumer that only forwards them
  # (`Vagus.API.IngressProxy`'s identity headers) must be able to tell
  # "Core has no name for this user" from a real one: an empty or
  # non-string value is indistinguishable from absent downstream, so it
  # reads as absent here.
  defp name_field(user, key) do
    case Map.get(user, key) do
      value when is_binary(value) and value != "" -> value
      _absent_null_or_malformed -> nil
    end
  end

  # `group_ids` must be a real list to be consulted at all: a malformed
  # scalar (`"system-admin"`) would otherwise read as membership. Any other
  # shape means "not in the admin group", never admin — the owner branch is
  # independent of it, matching Core (an owner is admin regardless).
  defp admin_user?(user) do
    group_ids = Map.get(user, "group_ids")

    Map.get(user, "is_owner") == true or
      (Map.get(user, "is_active") == true and is_list(group_ids) and
         @admin_group_id in group_ids)
  end

  defp cached(server), do: call(server, :fetch, :miss)

  defp default_command_fun do
    Application.get_env(:vagus, :core_users_command_fun, &EventPusher.command/2)
  end

  # The cache is an optimisation, never a dependency: if its process isn't
  # there, every lookup is simply a fresh fetch.
  defp call(server, message, on_missing) do
    GenServer.call(server, message)
  catch
    :exit, _reason -> on_missing
  end

  ## GenServer callbacks

  @impl GenServer
  def init(opts) do
    {:ok, %{users: nil, expires_at: 0, ttl_ms: Keyword.get(opts, :ttl_ms, @ttl_ms)}}
  end

  @impl GenServer
  def handle_call(:fetch, _from, state) do
    if not is_nil(state.users) and now_ms() < state.expires_at do
      {:reply, {:ok, state.users}, state}
    else
      {:reply, :miss, state}
    end
  end

  def handle_call({:put, users}, _from, state) do
    {:reply, :ok, %{state | users: users, expires_at: now_ms() + state.ttl_ms}}
  end

  def handle_call(:invalidate, _from, state) do
    {:reply, :ok, %{state | users: nil, expires_at: 0}}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
