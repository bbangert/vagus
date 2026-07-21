defmodule Vagus.Addon.Registry do
  @moduledoc """
  Maps a running add-on's per-start Supervisor token to its identity + API
  grants, so the emulator can resolve who is calling the add-on-facing
  endpoints (`/services`, `/discovery`, `/auth`) and what they're allowed to do
  (`docs/contract-2026.7-m4-addendum.md` §A3 — the Supervisor's `REQUEST_FROM`
  + grant checks).

  `Vagus.Addon.Manager.start/2` registers the token it generates; `Vagus.API.Auth`
  looks it up on each request whose bearer/`X-Supervisor-Token` isn't the
  supervisor token itself.

  Identity: `%{slug, services_role: %{service => role}, auth_api: bool,
  discovery: [service]}` — derived from the add-on's `config.yaml`
  (`services`/`auth_api`/`discovery`).
  """

  use GenServer

  @type role :: String.t()
  @type identity :: %{
          slug: String.t(),
          services_role: %{optional(String.t()) => role()},
          auth_api: boolean(),
          discovery: [String.t()]
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Registers `token` → `identity` (idempotent; replaces any prior token for the slug)."
  @spec register(String.t(), identity(), GenServer.server()) :: :ok
  def register(token, identity, server \\ __MODULE__) do
    GenServer.call(server, {:register, token, identity})
  end

  @doc "Removes an add-on's registration by slug (e.g. on stop/uninstall)."
  @spec unregister_slug(String.t(), GenServer.server()) :: :ok
  def unregister_slug(slug, server \\ __MODULE__) do
    GenServer.call(server, {:unregister_slug, slug})
  end

  @doc "Resolves a token to its add-on identity, `:error` if unknown."
  @spec identity_for_token(String.t(), GenServer.server()) :: {:ok, identity()} | :error
  def identity_for_token(token, server \\ __MODULE__) do
    GenServer.call(server, {:lookup, token})
  end

  @doc """
  Builds an add-on identity from a `Vagus.Addon.Config` (`services` like
  `"mqtt:provide"` → `%{"mqtt" => "provide"}`).
  """
  @spec identity_from_config(Vagus.Addon.Config.t()) :: identity()
  def identity_from_config(config) do
    services_role =
      Map.new(config.services, fn s ->
        [service, role] = String.split(s, ":", parts: 2)
        {service, role}
      end)

    %{
      slug: config.slug,
      services_role: services_role,
      auth_api: config.auth_api,
      discovery: config.discovery
    }
  end

  ## GenServer

  @impl GenServer
  def init(_opts), do: {:ok, %{by_token: %{}, token_by_slug: %{}}}

  @impl GenServer
  def handle_call({:register, token, %{slug: slug} = identity}, _from, state) do
    # Drop any previous token for this slug so a restart's fresh token replaces it.
    by_token =
      case Map.get(state.token_by_slug, slug) do
        nil -> state.by_token
        old -> Map.delete(state.by_token, old)
      end

    {:reply, :ok,
     %{
       state
       | by_token: Map.put(by_token, token, identity),
         token_by_slug: Map.put(state.token_by_slug, slug, token)
     }}
  end

  def handle_call({:unregister_slug, slug}, _from, state) do
    case Map.pop(state.token_by_slug, slug) do
      {nil, _} ->
        {:reply, :ok, state}

      {token, token_by_slug} ->
        {:reply, :ok,
         %{state | by_token: Map.delete(state.by_token, token), token_by_slug: token_by_slug}}
    end
  end

  def handle_call({:lookup, token}, _from, state) do
    {:reply, Map.fetch(state.by_token, token), state}
  end
end
