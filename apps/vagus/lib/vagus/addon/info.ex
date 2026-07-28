defmodule Vagus.Addon.Info do
  @moduledoc """
  Renders an add-on's `GET /addons/{slug}/info` payload
  (`docs/contract-2026.7-m4-addendum.md` §A1; `supervisor/api/apps.py`
  `info_data`) in the exact shape aiohasupervisor's `InstalledAddonComplete`
  model parses (`home-assistant-libs/python-supervisor-client`,
  `models/addons.py`).

  Every field the model declares (all are required — no mashumaro defaults) is
  emitted, with the wire key names (`hassio_api`/`hassio_role`, not the model's
  `supervisor_*` aliases) and the enum string values the model accepts. Fields
  Vagus doesn't model yet are honest defaults (not privileged, etc.). The
  ingress fields (`ingress_entry`/`ingress_url`/`ingress_port`/`ingress_panel`)
  and `watchdog` are real (`docs/contract-2026.7-m4b-ingress-watchdog.md`
  §B3.4, §B8) — see `render/4`'s `settings` param. `webui` is rendered from
  `config.webui` via `Vagus.Addon.ProbeURL.webui_url/3` (§B7.2) — a `[HOST]`
  literal survives into the rendered value on purpose, see that call site.
  Core's hassio discovery only reads `.name`, but the whole payload must
  parse.
  """

  alias Vagus.Addon.Config

  @doc """
  Builds the info map for `config` in lifecycle `state` (`:started`/`:stopped`)
  with its effective `options`, plus the per-install `settings` carried by a
  `Vagus.Addon.State` entry (`docs/contract-2026.7-m4b-ingress-watchdog.md`
  §B3.4, §B8) — everything in that entry except `config`/`state`/
  `user_options`, i.e. `Map.take(entry, [:ingress_token, :ingress_port,
  :ingress_panel, :watchdog])`. All keys are optional (default `%{}`, so
  callers that don't yet have a State entry — e.g. hermetic unit tests — get
  the honest "not resolved yet" rendering below) with atom keys:

    * `:ingress_token` — the stable per-install token; without it `ingress_entry`/
      `ingress_url` render `nil` even for an `ingress: true` config, since real
      Supervisor can't build those URLs before the token is assigned either.
    * `:ingress_port` — the resolved dynamic port (§B3.2), once
      `Vagus.Ingress.dynamic_port/2` has allocated one.
    * `:ingress_panel` — the persisted sidebar-panel toggle (§B4.4).
    * `:watchdog` — the persisted watchdog enable/disable (§B8).
    * `:version_latest` — the version the store currently advertises for this
      add-on, which drives `version_latest` and `update_available`. Omitted
      (or `nil`) means "not resolved": either the caller has no store context,
      or the add-on is **detached** — installed, but its repository no longer
      lists it. Both render as `version_latest == version` and
      `update_available == false`, matching upstream, which cannot offer an
      update it has no store entry for.

  `version` always comes from `config`, which for an installed add-on is the
  config captured at install time — `Vagus.Addon.State` never refreshes a
  stored config from the store catalog, so it is the installed version by
  construction. See `addon_state_test.exs`'s "start/stop never moves the
  installed version" for the invariant that keeps that true.
  """
  @spec render(Config.t(), :started | :stopped, map(), map()) :: map()
  def render(%Config{} = config, state, options, settings \\ %{})
      when is_map(options) and is_map(settings) do
    latest = Map.get(settings, :version_latest)

    %{
      # AddonInfoBaseFields
      "advanced" => false,
      "available" => true,
      "build" => false,
      "description" => config.description,
      "homeassistant" => nil,
      "icon" => false,
      "logo" => false,
      "name" => config.name,
      "repository" => "core",
      "slug" => config.slug,
      "stage" => "stable",
      "update_available" => Vagus.Version.update_available?(config.version, latest),
      "url" => nil,
      "version_latest" => latest || config.version,
      "version" => config.version,
      # AddonInfoStoreBaseFields
      "arch" => config.arch,
      "documentation" => false,
      # AddonInfoStoreExtFields
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
      # AddonInfoStoreExtInstalledBaseFields
      "detached" => false,
      # InstalledAddon
      "state" => to_string(state),
      # InstalledAddonComplete
      "hostname" => String.replace(config.slug, "_", "-"),
      "dns" => [],
      "protected" => true,
      "boot" => config.boot,
      "boot_config" => "auto",
      "options" => options,
      "schema" => nil,
      "machine" => [],
      "network" => config.ports,
      "network_description" => nil,
      "host_ipc" => config.host_ipc,
      "host_uts" => config.host_uts,
      "host_dbus" => config.host_dbus,
      "privileged" => config.privileged,
      "changelog" => false,
      "stdin" => false,
      "gpio" => false,
      "usb" => false,
      "uart" => false,
      "kernel_modules" => false,
      "devicetree" => false,
      "udev" => false,
      "video" => false,
      "audio" => false,
      "startup" => config.startup,
      "services" => config.services,
      "discovery" => config.discovery,
      "translations" => %{},
      # §B7.2 fact 8: `[HOST]` is deliberately left as the literal string
      # "[HOST]" here — it's the frontend/browser, not this server, that
      # knows what hostname to substitute; do not resolve it server-side.
      # `nil` template (no `webui:` configured) or one that doesn't match the
      # webui grammar both render `nil` via `ProbeURL.webui_url/3`.
      "webui" => Vagus.Addon.ProbeURL.webui_url(config.webui, config, options),
      "ingress_entry" => ingress_entry(config, settings),
      "ingress_url" => ingress_url(config, settings),
      "ingress_port" => resolved_ingress_port(config, settings),
      "ingress_panel" => ingress_panel(config, settings),
      "audio_input" => nil,
      "audio_output" => nil,
      "auto_update" => false,
      "ip_address" => "0.0.0.0",
      "watchdog" => Map.get(settings, :watchdog) || false,
      "devices" => [],
      "system_managed" => false,
      "system_managed_config_entry" => nil
    }
  end

  # §B3.4: `/api/hassio_ingress/{ingress_token}` — no trailing content. `nil`
  # for a non-ingress add-on, or an ingress one whose token isn't known yet
  # (settings not supplied — see `render/4`'s doc).
  defp ingress_entry(%Config{ingress: true}, %{ingress_token: token}) when is_binary(token) do
    "/api/hassio_ingress/#{token}"
  end

  defp ingress_entry(_config, _settings), do: nil

  # §B3.4: `/api/hassio_ingress/{ingress_token}/{ingress_entry?}` — Core uses
  # this + `ingress_entry` to build the sidebar iframe `src`.
  defp ingress_url(%Config{ingress: true} = config, %{ingress_token: token})
       when is_binary(token) do
    "/api/hassio_ingress/#{token}/#{config.ingress_entry || ""}"
  end

  defp ingress_url(_config, _settings), do: nil

  # §B3.2: reading `ingress_port` while still unresolved (dynamic, not yet
  # allocated) raises upstream rather than serving `0` — we render `nil`
  # instead of raising (the resolved dynamic port, once allocated, lives in
  # `settings[:ingress_port]`; a static `config.ingress_port` is served
  # as-is unless it's the literal `0` sentinel meaning "not yet resolved").
  defp resolved_ingress_port(%Config{ingress: true} = config, settings) do
    case Map.get(settings, :ingress_port) do
      port when is_integer(port) -> port
      _ when config.ingress_port != 0 -> config.ingress_port
      _ -> nil
    end
  end

  defp resolved_ingress_port(_config, _settings), do: nil

  # aiohasupervisor's `ingress_panel` field is a required bool (not nullable)
  # — emit `false`, not `nil`, for a non-ingress add-on.
  defp ingress_panel(%Config{ingress: true}, settings),
    do: Map.get(settings, :ingress_panel) || false

  defp ingress_panel(_config, _settings), do: false
end
