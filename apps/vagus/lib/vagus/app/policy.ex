defmodule Vagus.App.Policy do
  @moduledoc """
  Upstream Supervisor's boot, service and discovery rules, as pure functions:
  the orchestrator, the app process and the router apply the results.
  """

  alias Vagus.Addon.Config

  @type message :: %{uuid: String.t(), addon: String.t(), service: String.t(), config: map()}
  @type caller :: :supervisor | {:addon, map()} | term()

  # `GET /services` lists these whether or not anything provides them.
  @known_services ~w(mqtt)

  @doc """
  What boot does with one app. Only one recorded `:started` is touched: a
  running one is left alone, since starting it again would recreate its
  container; a stopped one starts when its effective boot is `auto`, and is
  otherwise recorded `:stopped` so its state stops claiming it runs.
  """
  @spec boot(map(), boolean()) :: :start | :demote | :none
  def boot(%{state: :started} = entry, false = _running?) do
    if Config.effective_boot(entry.config, entry[:boot]) == "auto", do: :start, else: :demote
  end

  def boot(_entry, _running?), do: :none

  @doc """
  Upstream compares discovery messages by `(app, service)` only, so a repeat
  post never mints a second uuid: Core would see a second config flow rather
  than an update. `:new` takes `fresh_uuid`; `:existing` (same config) means
  Core already has the record and must not be told again; `:updated` keeps
  the uuid and replaces the config.
  """
  @spec discover([message()], String.t(), String.t(), map(), String.t()) ::
          {:new | :existing | :updated, message()}
  def discover(existing, slug, service, config, fresh_uuid) do
    case Enum.find(existing, &(&1.addon == slug and &1.service == service)) do
      nil -> {:new, %{uuid: fresh_uuid, addon: slug, service: service, config: config}}
      %{config: ^config} = message -> {:existing, message}
      message -> {:updated, %{message | config: config}}
    end
  end

  @doc "Only an app whose config gives it the `provide` role may publish or withdraw a service."
  @spec may_provide?(caller(), String.t()) :: boolean()
  def may_provide?({:addon, %{services_role: roles}}, service),
    do: Map.get(roles, service) == "provide"

  def may_provide?(_caller, _service), do: false

  @doc "Core always; an app when it declares any role (`provide`, `want`, `need`) for it."
  @spec may_read_service?(caller(), String.t()) :: boolean()
  def may_read_service?(:supervisor, _service), do: true

  def may_read_service?({:addon, %{services_role: roles}}, service),
    do: Map.has_key?(roles, service)

  def may_read_service?(_caller, _service), do: false

  @doc "The `GET /services` list, from the `{service, provider_slug}` pairs provided now."
  @spec services_view([{String.t(), String.t()}]) :: [map()]
  def services_view(provided) do
    Enum.map(@known_services, fn service ->
      providers = for {^service, slug} <- provided, do: slug
      %{slug: service, available: providers != [], providers: providers}
    end)
  end
end
