defmodule Vagus.Addon.StoreView do
  @moduledoc """
  Renders `Vagus.Addon.Store` catalog entries into the store wire shapes
  aiohasupervisor parses: `StoreAddon` (the `GET /store/addons` list items) and
  `StoreAddonComplete` (`GET /store/addons/{slug}`), per
  `home-assistant-libs/python-supervisor-client` `models/addons.py`.

  `StoreAddon` = `AddonInfoBaseFields` + `AddonInfoStoreBaseFields`;
  `StoreAddonComplete` adds `AddonInfoStoreExtFields` (wire keys
  `hassio_api`/`hassio_role`, not the model's `supervisor_*` aliases) +
  `detached`. A store add-on isn't installed, so there's no state/options/
  hostname/network here (that's `InstalledAddonComplete`, see `Vagus.Addon.Info`).
  """

  alias Vagus.Addon.Config

  @doc "The `StoreAddon` summary for `GET /store/addons` (and the `GET /store` list)."
  @spec summary(String.t(), %{config: Config.t(), repository: String.t()}) :: map()
  def summary(store_slug, %{config: config, repository: repo}) do
    base_fields(store_slug, config, repo)
  end

  @doc "The `StoreAddonComplete` detail for `GET /store/addons/{slug}`."
  @spec detail(String.t(), %{config: Config.t(), repository: String.t()}) :: map()
  def detail(store_slug, %{config: config, repository: repo}) do
    base_fields(store_slug, config, repo)
    |> Map.merge(%{
      "apparmor" => if(config.apparmor, do: "default", else: "disable"),
      "auth_api" => config.auth_api,
      "docker_api" => config.docker_api,
      "full_access" => config.full_access,
      "homeassistant_api" => config.homeassistant_api,
      "host_network" => config.host_network,
      "host_pid" => config.host_pid,
      "ingress" => config.ingress,
      "long_description" => nil,
      "rating" => 5,
      "signed" => false,
      "hassio_api" => config.hassio_api,
      "hassio_role" => config.hassio_role,
      "detached" => false
    })
  end

  # AddonInfoBaseFields + AddonInfoStoreBaseFields, shared by both shapes.
  defp base_fields(store_slug, config, repo) do
    %{
      "advanced" => false,
      "available" => true,
      "build" => config.image == nil,
      "description" => config.description,
      "homeassistant" => nil,
      "icon" => false,
      "logo" => false,
      "name" => config.name,
      "repository" => repo,
      "slug" => store_slug,
      "stage" => "stable",
      "update_available" => false,
      "url" => nil,
      "version_latest" => config.version,
      "version" => config.version,
      "arch" => config.arch,
      "documentation" => false
    }
  end
end
