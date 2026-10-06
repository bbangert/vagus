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

  ## Restarts

  Every entry is checkpointed to `Vagus.RunState` (`opts[:path]`) and read
  back in `init/1`, so a running provider's service stays published, and its
  credentials keep authenticating, across a crash here. The checkpoint lives
  one application run: the directory is wiped at app start and sits on tmpfs,
  so neither an app restart nor a reboot can revive a provider that is gone.

  Only the default-named instance checkpoints unless `:path` is given, so a
  privately-named one stays memory-only.

  A service's config carries its password, so `format_status/1` keeps the
  configs out of crash reports.
  """

  use GenServer

  require Logger

  alias Vagus.RunState

  @known_services ~w(mqtt)

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
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
  @spec delete(String.t(), String.t(), GenServer.server(), timeout()) ::
          :ok | {:error, :not_provider}
  def delete(service, slug, server \\ __MODULE__, timeout \\ 5_000) do
    GenServer.call(server, {:delete, service, slug}, timeout)
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
  @spec delete_by_slug(String.t(), GenServer.server(), timeout()) :: {:ok, [String.t()]}
  def delete_by_slug(slug, server \\ __MODULE__, timeout \\ 5_000) do
    GenServer.call(server, {:delete_by_slug, slug}, timeout)
  end

  ## GenServer

  @impl GenServer
  def init(opts) do
    path = Keyword.get_lazy(opts, :path, fn -> default_path(opts[:name]) end)
    {:ok, %{entries: load(path), path: path}}
  end

  defp default_path(__MODULE__), do: RunState.path(:services)
  defp default_path(_name), do: nil

  defp load(path) do
    entries = RunState.load(path, %{})

    if is_map(entries) and not is_struct(entries) and Enum.all?(entries, &entry?/1) do
      entries
    else
      Logger.warning("run state #{path} unusable: :wrong_shape")
      %{}
    end
  end

  # An entry of another shape would crash every call that reads it, and be
  # loaded again after each restart.
  defp entry?({service, %{data: data, slug: slug}})
       when is_binary(service) and is_map(data) and is_binary(slug),
       do: true

  defp entry?(_other), do: false

  defp put_entries(state, entries) do
    RunState.save(state.path, entries)
    %{state | entries: entries}
  end

  @impl GenServer
  def format_status(status) do
    Map.new(status, fn
      {:state, %{entries: entries} = state} ->
        {:state, %{state | entries: Map.new(entries, fn {service, e} -> {service, e.slug} end)}}

      {:message, {:set, service, _data, slug}} ->
        {:message, {:set, service, :redacted, slug}}

      other ->
        other
    end)
  end

  @impl GenServer
  def handle_call({:set, service, data, slug}, _from, %{entries: entries} = state) do
    case Map.get(entries, service) do
      nil ->
        {:reply, :ok, put_entries(state, Map.put(entries, service, %{data: data, slug: slug}))}

      _already ->
        {:reply, {:error, :already_provided}, state}
    end
  end

  def handle_call({:get, service}, _from, state) do
    case Map.get(state.entries, service) do
      nil -> {:reply, :error, state}
      %{data: data, slug: slug} -> {:reply, {:ok, Map.put(data, "addon", slug)}, state}
    end
  end

  def handle_call({:delete, service, slug}, _from, %{entries: entries} = state) do
    case Map.get(entries, service) do
      nil -> {:reply, :ok, state}
      %{slug: ^slug} -> {:reply, :ok, put_entries(state, Map.delete(entries, service))}
      _other -> {:reply, {:error, :not_provider}, state}
    end
  end

  def handle_call({:delete_by_slug, slug}, _from, state) do
    {owned, rest} = Enum.split_with(state.entries, fn {_service, %{slug: s}} -> s == slug end)
    freed = Enum.map(owned, fn {service, _} -> service end)
    # A save can fail and drop the checkpoint, so not for a no-op.
    state = if owned == [], do: state, else: put_entries(state, Map.new(rest))
    {:reply, {:ok, freed}, state}
  end

  def handle_call(:list, _from, %{entries: entries} = state) do
    services =
      Enum.map(@known_services, fn service ->
        providers = for %{slug: slug} <- List.wrap(Map.get(entries, service)), do: slug
        %{slug: service, available: Map.has_key?(entries, service), providers: providers}
      end)

    {:reply, services, state}
  end
end
