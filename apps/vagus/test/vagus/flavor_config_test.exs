defmodule Vagus.FlavorConfigTest do
  # Mutates the process-global VAGUS_FLAVOR env.
  use ExUnit.Case, async: false

  @flavor_exs Path.expand("../../../../config/flavor.exs", __DIR__)

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

  test "an unknown VAGUS_FLAVOR fails the build instead of falling back" do
    System.put_env("VAGUS_FLAVOR", "bogus")
    assert_raise Mix.Error, ~r/Unknown VAGUS_FLAVOR "bogus"/, &read_vagus/0
  end
end
