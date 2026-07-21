defmodule Vagus.Services do
  @moduledoc """
  The Supervisor services registry (`docs/contract-2026.7-m4-addendum.md`
  §A3.1) — currently the MQTT service a provider add-on (e.g. Mosquitto)
  publishes via `POST /services/mqtt`, which Core/other add-ons read via
  `GET /services/mqtt`.

  Holds one config map per service plus the provider slug. `get/1` returns the
  stored fields with the provider under the legacy `"addon"` key (the V1 wire
  shape Core's `aiohasupervisor` reads). `delete_by_slug/2` purges every
  service a given add-on provides (called from `Vagus.Addon.Manager.uninstall/2`
  so a removed add-on's stale provider entries don't linger).
  """

  use GenServer

  @known_services ~w(mqtt)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Stores `data` for `service`, provided by `slug`. Errors if already provided."
  @spec set(String.t(), map(), String.t(), GenServer.server()) ::
          :ok | {:error, :already_provided}
  def set(service, data, slug, server \\ __MODULE__) do
    GenServer.call(server, {:set, service, data, slug})
  end

  @doc "Returns the stored config + `\"addon\" => provider_slug`, or `:error` if not provided."
  @spec get(String.t(), GenServer.server()) :: {:ok, map()} | :error
  def get(service, server \\ __MODULE__) do
    GenServer.call(server, {:get, service})
  end

  @doc "Clears `service` (only the provider may). Returns `:ok` even if absent."
  @spec delete(String.t(), String.t(), GenServer.server()) :: :ok | {:error, :not_provider}
  def delete(service, slug, server \\ __MODULE__) do
    GenServer.call(server, {:delete, service, slug})
  end

  @doc "Lists known services with availability + providers (`GET /services`)."
  @spec list(GenServer.server()) :: [map()]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @doc """
  Clears every service provided by `slug` (e.g. on add-on stop/uninstall).
  Mirrors `Vagus.Discovery.delete_by_slug/2`. Returns the freed service names.
  """
  @spec delete_by_slug(String.t(), GenServer.server()) :: {:ok, [String.t()]}
  def delete_by_slug(slug, server \\ __MODULE__) do
    GenServer.call(server, {:delete_by_slug, slug})
  end

  ## GenServer

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:set, service, data, slug}, _from, state) do
    case Map.get(state, service) do
      nil -> {:reply, :ok, Map.put(state, service, %{data: data, slug: slug})}
      _already -> {:reply, {:error, :already_provided}, state}
    end
  end

  def handle_call({:get, service}, _from, state) do
    case Map.get(state, service) do
      nil -> {:reply, :error, state}
      %{data: data, slug: slug} -> {:reply, {:ok, Map.put(data, "addon", slug)}, state}
    end
  end

  def handle_call({:delete, service, slug}, _from, state) do
    case Map.get(state, service) do
      nil -> {:reply, :ok, state}
      %{slug: ^slug} -> {:reply, :ok, Map.delete(state, service)}
      _other -> {:reply, {:error, :not_provider}, state}
    end
  end

  def handle_call({:delete_by_slug, slug}, _from, state) do
    {owned, rest} = Enum.split_with(state, fn {_service, %{slug: s}} -> s == slug end)
    freed = Enum.map(owned, fn {service, _} -> service end)
    {:reply, {:ok, freed}, Map.new(rest)}
  end

  def handle_call(:list, _from, state) do
    services =
      Enum.map(@known_services, fn service ->
        providers = for %{slug: slug} <- List.wrap(Map.get(state, service)), do: slug
        %{slug: service, available: Map.has_key?(state, service), providers: providers}
      end)

    {:reply, services, state}
  end
end
