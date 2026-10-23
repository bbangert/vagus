import Config

# Build-time firmware flavor (`Vagus.Flavor`), from `VAGUS_FLAVOR`. Imported
# last by config/target.exs so its overrides win, and by config/host.exs so a
# host compile with the variable set still checks the parse; on host the
# overridden keys are inert. A typo must fail the build: silently falling
# back to the stock image would ship Home Assistant to an agent board.
flavor =
  case System.get_env("VAGUS_FLAVOR") do
    value when value in [nil, ""] ->
      :default

    "agent-dev-board" ->
      :agent_dev_board

    other ->
      Mix.raise("""
      Unknown VAGUS_FLAVOR #{inspect(other)}. Accepted values: unset or empty
      (the default Home Assistant image) or "agent-dev-board".
      """)
  end

config :vagus, :flavor, flavor

# The agent-dev-board never runs Core: no watchdog to probe it and no
# first-boot install of it. `:first_boot_provision` stays on so /data still
# expands.
if flavor == :agent_dev_board do
  config :vagus, core_watchdog: false, provision_core: false
end
