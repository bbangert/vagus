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

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end

if Mix.env() == :test do
  import_config "test.exs"
end
