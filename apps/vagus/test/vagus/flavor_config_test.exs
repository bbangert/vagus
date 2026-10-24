defmodule Vagus.FlavorConfigTest do
  # Mutates the process-global VAGUS_FLAVOR env.
  use ExUnit.Case, async: false

  @flavor_exs Path.expand("../../../../config/flavor.exs", __DIR__)
  @target_exs Path.expand("../../../../config/target.exs", __DIR__)

  setup do
    prev = System.get_env("VAGUS_FLAVOR")

    on_exit(fn ->
      if prev, do: System.put_env("VAGUS_FLAVOR", prev), else: System.delete_env("VAGUS_FLAVOR")
    end)
  end

  defp read_vagus, do: Config.Reader.read!(@flavor_exs)[:vagus]

  test "an unset VAGUS_FLAVOR configures the :default flavor" do
    System.delete_env("VAGUS_FLAVOR")
    assert read_vagus()[:flavor] == :default
  end

  test "an empty VAGUS_FLAVOR configures the :default flavor" do
    System.put_env("VAGUS_FLAVOR", "")
    assert read_vagus()[:flavor] == :default
  end

  test "agent-dev-board configures the flavor and turns off the Core watchdog and provisioning" do
    System.put_env("VAGUS_FLAVOR", "agent-dev-board")
    vagus = read_vagus()

    assert vagus[:flavor] == :agent_dev_board
    assert vagus[:core_watchdog] == false
    assert vagus[:provision_core] == false
  end

  test "an unset VAGUS_FLAVOR names no orchestrator app and leaves the default apps alone" do
    System.delete_env("VAGUS_FLAVOR")
    vagus = read_vagus()

    refute Keyword.has_key?(vagus, :orchestrator_app)
    refute Keyword.has_key?(vagus, :memory_app)
    refute Keyword.has_key?(vagus, :protected_apps)
    refute Keyword.has_key?(vagus, :native_addon_slugs)
    refute Keyword.has_key?(vagus, Vagus.App.Orchestrator)
  end

  # config/target.exs imports flavor.exs last; the Orchestrator's keyword list
  # deep-merges, so the flavor's list must replace the target's and keep `boot`.
  test "agent-dev-board adds its memory and orchestrator apps to target.exs's default apps" do
    System.put_env("VAGUS_FLAVOR", "agent-dev-board")
    target = Path.join(System.tmp_dir!(), "flavor_merge_#{System.unique_integer([:positive])}")
    File.mkdir_p!(target)
    on_exit(fn -> File.rm_rf(target) end)

    # target.exs's own line, as the whole file needs a board's environment.
    orchestrator =
      @target_exs
      |> File.read!()
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "config :vagus, Vagus.App.Orchestrator,"))

    File.write!(Path.join(target, "target.exs"), """
    import Config
    #{orchestrator}
    import_config #{inspect(@flavor_exs)}
    """)

    vagus = Config.Reader.read!(Path.join(target, "target.exs"))[:vagus]

    assert vagus[:orchestrator_app] == "agent_orchestrator"
    assert vagus[:memory_app] == "agent_memory"
    assert vagus[:protected_apps] == ["agent_orchestrator", "agent_memory", "vagus_memory"]
    assert vagus[:native_addon_slugs] == ["core_mqtt", "vagus_memory"]

    # The DB and its server ahead of the orchestrator that uses them.
    assert Enum.sort(vagus[Vagus.App.Orchestrator]) ==
             Enum.sort(
               boot: true,
               default_apps: ["core_mqtt", "agent_memory", "vagus_memory", "agent_orchestrator"]
             )
  end

  test "an unknown VAGUS_FLAVOR fails the build instead of falling back" do
    System.put_env("VAGUS_FLAVOR", "bogus")
    assert_raise Mix.Error, ~r/Unknown VAGUS_FLAVOR "bogus"/, &read_vagus/0
  end
end
