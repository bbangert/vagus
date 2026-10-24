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

# The agent-dev-board never runs Core. `:first_boot_provision` stays on so
# /data still expands. The memory DB and its native server are listed before
# the orchestrator that uses them. The Orchestrator's keyword list
# deep-merges, so `default_apps` replaces config/target.exs's list and keeps
# its `boot`.
if flavor == :agent_dev_board do
  config :vagus, core_watchdog: false, provision_core: false
  config :vagus, :orchestrator_app, "agent_orchestrator"
  config :vagus, :memory_app, "agent_memory"
  config :vagus, :protected_apps, ["agent_orchestrator", "agent_memory", "vagus_memory"]
  config :vagus, :native_addon_slugs, ["core_mqtt", "vagus_memory"]

  config :vagus, Vagus.App.Orchestrator,
    default_apps: ["core_mqtt", "agent_memory", "vagus_memory", "agent_orchestrator"]
end
