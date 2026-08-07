defmodule Vagus.Core.Users do
  @moduledoc """
  Answers "is this Core user an administrator?", for gating
  Supervisor-owned panels.

  Core exposes its user records **only** over the WebSocket API — the
  `config/auth/list` command (`homeassistant/components/config/auth.py`),
  itself `@websocket_api.require_admin`. There is no REST equivalent
  anywhere in Core and no single-user lookup, so the whole list is fetched
  and filtered here, over `Vagus.Core.EventPusher`'s existing authenticated
  socket. Vagus's Core token belongs to the Supervisor system user, which
  Core creates in the admin group, so it satisfies `require_admin`.

  The derived `user_id => admin?` map is cached for 30 seconds so a panel
  that asks repeatedly doesn't hammer Core. Only successful fetches
  are cached; an error never displaces a good answer nor poisons the next
  call. A cached map is authoritative for ids it doesn't contain too — the
  fetch returns *every* user, so an absent id is a known non-admin, not a
  cache miss.

  Swappable by consumers via `Application.get_env(:vagus, :core_users,
  Vagus.Core.Users)` — any module exporting `admin?/1` is a drop-in.
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
    server = Keyword.get(opts, :server, __MODULE__)

    case cached(server) do
      {:ok, admins} -> {:ok, Map.get(admins, user_id, false)}
      :miss -> fetch(user_id, server, opts)
    end
  end

  @doc "Drops the cached user list, forcing the next `admin?/2` to re-fetch."
  @spec invalidate(GenServer.server()) :: :ok
  def invalidate(server \\ __MODULE__) do
    call(server, :invalidate, :ok)
  end

  ## Internals

  defp fetch(user_id, server, opts) do
    command_fun = Keyword.get(opts, :command_fun, default_command_fun())
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    case command_fun.(@list_command, timeout: timeout) do
      {:ok, users} when is_list(users) ->
        admins = derive(users)
        call(server, {:put, admins}, :ok)
        {:ok, Map.get(admins, user_id, false)}

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
        do: {id, admin_user?(user)}
  end

  defp admin_user?(user) do
    Map.get(user, "is_owner") == true or
      (Map.get(user, "is_active") == true and
         @admin_group_id in List.wrap(Map.get(user, "group_ids")))
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
    {:ok, %{admins: nil, expires_at: 0, ttl_ms: Keyword.get(opts, :ttl_ms, @ttl_ms)}}
  end

  @impl GenServer
  def handle_call(:fetch, _from, state) do
    if not is_nil(state.admins) and now_ms() < state.expires_at do
      {:reply, {:ok, state.admins}, state}
    else
      {:reply, :miss, state}
    end
  end

  def handle_call({:put, admins}, _from, state) do
    {:reply, :ok, %{state | admins: admins, expires_at: now_ms() + state.ttl_ms}}
  end

  def handle_call(:invalidate, _from, state) do
    {:reply, :ok, %{state | admins: nil, expires_at: 0}}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
