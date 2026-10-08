# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

# Customize non-Elixir parts of the firmware. See
# https://nerves.hexdocs.pm/advanced-configuration.html for details.
#
# Nerves builds run from apps/vagus_platform (see that app's mix.exs for the
# umbrella config_path/build_path/deps_path/lockfile wiring), but this config
# file is shared across the whole umbrella and can be loaded regardless of
# which directory `mix` was invoked from. Anchoring the overlay path to
# `__DIR__` (this file's own location, not the current working directory)
# keeps it correct either way.

config :nerves, :firmware,
  rootfs_overlay: Path.expand("../apps/vagus_platform/rootfs_overlay", __DIR__)

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1784525674"

# How `Vagus.Addon.Store` retains repository assets (icon/logo/changelog/
# documentation): `:auto | :memory | :disk`. `:auto` decides at boot from
# `MemTotal` — under 1 GiB goes to disk. Set here rather than per target so
# detection is the default everywhere; a target file below can pin a mode if
# a board is ever misjudged. See `Vagus.Addon.Store.AssetMode`.
config :vagus, :store_asset_mode, :auto

# The `Vagus.Resource.Controller` modules that `Vagus.Resource.Supervisor`
# runs, one runtime each. The resource store's kinds follow from this list.
# An entry is a module, or `{module, options}` for that runtime alone.
#
# This list is not how apps are switched over: the App controller needs the
# context `Vagus.App.wiring/1` builds, and that function's result is what
# the resource supervisor is started with. See `Vagus.App` for why it must
# not run beside `Vagus.Addon.Manager` and the watchdogs.
config :vagus, :controllers, []

# How many steps one controller's runtime has in flight at once. A step
# starts with an observation, usually an engine call, and a start looks at
# every resource of the kind.
config :vagus, :max_in_flight_steps, 4

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end

if Mix.env() == :test do
  import_config "test.exs"
end
