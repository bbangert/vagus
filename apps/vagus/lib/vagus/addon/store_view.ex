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

  `available`/`homeassistant` (audit G1) are computed by
  `Vagus.Addon.Availability` / read off `config` — both were previously
  hardcoded (`true`/`nil`), so an unavailable store add-on showed an
  enabled Install button. `machine` is NOT emitted here: it's only on
  `InstalledAddonComplete`
  (`aiohasupervisor`'s `AddonInfoStoreBaseFields` doesn't carry it), which
  is why `Vagus.Addon.Info` is the one that reports it.
  """

  alias Vagus.Addon.{Availability, Config}

  @doc """
  The `StoreAddon` summary for `GET /store/addons` (and the `GET /store` list).

  `installed?` is whether the add-on is currently installed locally — a
  required `StoreAddon`/`StoreAddonComplete` field (found live in P5:
  Core 2026.7.2's aiohasupervisor raises `MissingField` without it, killing
  the whole hassio coordinator refresh).

  `installed_version` is the version of the *locally installed* copy, or
  `nil` when it isn't installed (or the caller has no state context). It is
  what makes `update_available` real: the store entry's own `config.version`
  is the latest, and these two differing is the entire signal the frontend
  uses to offer an update.
  """
  @spec summary(
          String.t(),
          %{config: Config.t(), repository: String.t()},
          boolean(),
          nil | String.t()
        ) :: map()
  def summary(
        store_slug,
        %{config: config, repository: repo} = entry,
        installed?,
        installed_version \\ nil
      ) do
    base_fields(store_slug, config, repo, installed?, installed_version, assets(entry))
  end

  @doc """
  The `Repository` wire shape for `GET /store`'s `repositories` list.

  Built-in "virtual" repositories (M5, e.g. `%{slug: "core", builtin: :mqtt}`)
  carry no `:url` — mirror real Supervisor's `core`/`local` repos, whose `url`
  is null while `source` stays a non-null string (aiohasupervisor's `Repository`
  model requires it). Reading `repo.url` directly would `KeyError` on a built-in
  repo → `GET /store` 500 → the hassio config entry fails setup.

  `source` prefers an explicit `:source` on the repo map — a runtime-added
  repository (`Vagus.Addon.Store.RepositorySpec`) carries the original
  `url#branch` string the user posted, which `url` alone would lose — then
  falls back to `url`, then the slug, for the config-declared repos that
  carry neither.
  """
  @spec repository(map()) :: map()
  def repository(repo) do
    url = Map.get(repo, :url)

    %{
      slug: repo.slug,
      name: Map.get(repo, :name, repo.slug),
      source: Map.get(repo, :source) || url || repo.slug,
      url: url,
      maintainer: Map.get(repo, :maintainer, "")
    }
  end

  @doc """
  The `StoreAddonComplete` detail for `GET /store/addons/{slug}`. See
  `summary/4` for `installed_version`.
  """
  @spec detail(
          String.t(),
          %{config: Config.t(), repository: String.t()},
          boolean(),
          nil | String.t(),
          nil | String.t()
        ) :: map()
  def detail(
        store_slug,
        %{config: config, repository: repo} = entry,
        installed?,
        installed_version \\ nil,
        long_description \\ nil
      ) do
    base_fields(store_slug, config, repo, installed?, installed_version, assets(entry))
    |> Map.merge(%{
      "apparmor" => if(config.apparmor, do: "default", else: "disable"),
      "auth_api" => config.auth_api,
      "docker_api" => config.docker_api,
      "full_access" => config.full_access,
      "homeassistant_api" => config.homeassistant_api,
      "host_network" => config.host_network,
      "host_pid" => config.host_pid,
      "ingress" => config.ingress,
      # The add-on's README.md, rendered as markdown under the install card —
      # the entire body of the store page. `nil` when the repository ships no
      # README, or when the entry is detached (no store source to read one
      # from), matching upstream's `long_description()`.
      "long_description" => long_description,
      "rating" => 5,
      "signed" => false,
      "hassio_api" => config.hassio_api,
      "hassio_role" => config.hassio_role,
      "detached" => false
    })
  end

  # The catalog entry's asset presence flags (`Vagus.Addon.Store`'s
  # `retain_assets/3`). Absent for an entry built before assets existed, and
  # for hand-built entries in tests — `%{}` renders every flag false, which is
  # the honest answer when nothing is known to be retained.
  defp assets(entry), do: Map.get(entry, :assets) || %{}

  # AddonInfoBaseFields + AddonInfoStoreBaseFields + installed, shared by
  # both shapes.
  #
  # `icon`/`logo`/`changelog`/`documentation` are **not** decoration: the
  # frontend requests an asset only when the payload says it exists
  # (`addon.icon ? "/api/hassio/addons/<slug>/icon" : undefined` in
  # `supervisor-apps-repository.ts` and `ha-config-apps-installed.ts`; the
  # changelog and documentation links in `supervisor-app-info.ts` gate the
  # same way). Hardcoding them false is what made P2-A's asset routes
  # unreachable from the UI even though they served correct bytes.
  defp base_fields(store_slug, config, repo, installed?, installed_version, assets) do
    %{
      "advanced" => config.advanced,
      "available" => Availability.available?(config),
      "installed" => installed?,
      "build" => config.image == nil,
      "changelog" => Map.get(assets, :changelog, false),
      "description" => config.description,
      "homeassistant" => config.homeassistant,
      "icon" => Map.get(assets, :icon, false),
      "logo" => Map.get(assets, :logo, false),
      "name" => config.name,
      "repository" => repo,
      "slug" => store_slug,
      "stage" => config.stage,
      # The store entry's version IS the latest; `version` is what is running
      # locally, which is only the same thing when nothing has moved on.
      "update_available" => Vagus.Version.update_available?(installed_version, config.version),
      "url" => config.url,
      "version_latest" => config.version,
      # `nil` when the add-on isn't installed — upstream sends
      # `installed.version if installed else None`, and the frontend's add-on
      # page switches its entire layout on this one field: falsy renders the
      # Install button and the store view, truthy renders the current-version
      # line, state chip, controls card and uninstall menu. Defaulting it to
      # the store's version made every uninstalled add-on's page claim to be
      # installed.
      "version" => installed_version,
      "arch" => config.arch,
      "documentation" => Map.get(assets, :documentation, false)
    }
  end
end
