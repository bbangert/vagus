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
  Vagus doesn't model yet are honest defaults (no ingress, not privileged, etc.).
  Core's hassio discovery only reads `.name`, but the whole payload must parse.
  """

  alias Vagus.Addon.Config

  @doc """
  Builds the info map for `config` in lifecycle `state` (`:started`/`:stopped`)
  with its effective `options`.
  """
  @spec render(Config.t(), :started | :stopped, map()) :: map()
  def render(%Config{} = config, state, options) when is_map(options) do
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
      "update_available" => false,
      "url" => nil,
      "version_latest" => config.version,
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
      "webui" => config.webui,
      "ingress_entry" => nil,
      "ingress_url" => nil,
      "ingress_port" => nil,
      "ingress_panel" => nil,
      "audio_input" => nil,
      "audio_output" => nil,
      "auto_update" => false,
      "ip_address" => "0.0.0.0",
      "watchdog" => config.watchdog != nil,
      "devices" => [],
      "system_managed" => false,
      "system_managed_config_entry" => nil
    }
  end
end
