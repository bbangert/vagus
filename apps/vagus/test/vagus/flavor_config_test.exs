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

    assert orchestrator, "config/target.exs no longer has its Orchestrator line; update this test"

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

  test "agent-dev-board enables the SSH key handout and wires its login hook" do
    System.put_env("VAGUS_FLAVOR", "agent-dev-board")
    config = Config.Reader.read!(@flavor_exs)

    assert config[:vagus][:ssh_handout][:enabled] == true

    assert config[:nerves_ssh][:daemon_option_overrides][:connectfun] ==
             {Vagus.SSHAccess.Handout, :on_login, 3}
  end

  test "an unset VAGUS_FLAVOR leaves the SSH key handout off" do
    System.delete_env("VAGUS_FLAVOR")
    config = Config.Reader.read!(@flavor_exs)

    refute Keyword.has_key?(config[:vagus], :ssh_handout)
    refute Keyword.has_key?(config, :nerves_ssh)
  end

  # target.exs sets `config :nerves_ssh, authorized_keys:` before importing
  # flavor.exs; the override is a sibling key, so both must survive.
  test "the handout's nerves_ssh override keeps target.exs's authorized_keys" do
    System.put_env("VAGUS_FLAVOR", "agent-dev-board")
    target = Path.join(System.tmp_dir!(), "flavor_ssh_#{System.unique_integer([:positive])}")
    File.mkdir_p!(target)
    on_exit(fn -> File.rm_rf(target) end)

    File.write!(Path.join(target, "target.exs"), """
    import Config
    config :nerves_ssh, authorized_keys: ["ssh-ed25519 AAAA operator"]
    import_config #{inspect(@flavor_exs)}
    """)

    nerves_ssh = Config.Reader.read!(Path.join(target, "target.exs"))[:nerves_ssh]

    assert nerves_ssh[:authorized_keys] == ["ssh-ed25519 AAAA operator"]

    assert nerves_ssh[:daemon_option_overrides][:connectfun] ==
             {Vagus.SSHAccess.Handout, :on_login, 3}
  end

  describe "target.exs authorized_keys" do
    setup do
      prev = System.get_env("NERVES_AUTHORIZED_KEYS")

      on_exit(fn ->
        if prev,
          do: System.put_env("NERVES_AUTHORIZED_KEYS", prev),
          else: System.delete_env("NERVES_AUTHORIZED_KEYS")
      end)

      # Only the block itself: the whole file needs a board's environment.
      dir = Path.join(System.tmp_dir!(), "authorized_keys_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      lines = @target_exs |> File.read!() |> String.split("\n")

      assert "authorized_keys =" in lines and "  authorized_keys: authorized_keys" in lines,
             "config/target.exs's authorized_keys block moved or was reformatted; update this test"

      {_, from} = Enum.split_while(lines, &(&1 != "authorized_keys ="))
      {block, [last | _]} = Enum.split_while(from, &(&1 != "  authorized_keys: authorized_keys"))

      exs = Path.join(dir, "keys.exs")
      File.write!(exs, Enum.join(["import Config" | block] ++ [last], "\n"))
      {:ok, exs: exs, dir: dir}
    end

    test "an empty NERVES_AUTHORIZED_KEYS bakes no keys and does not raise", %{exs: exs} do
      System.put_env("NERVES_AUTHORIZED_KEYS", "")
      assert Config.Reader.read!(exs)[:nerves_ssh][:authorized_keys] == []

      System.put_env("NERVES_AUTHORIZED_KEYS", "ssh-ed25519 AAAA a\nssh-ed25519 BBBB b\n")

      assert Config.Reader.read!(exs)[:nerves_ssh][:authorized_keys] ==
               ["ssh-ed25519 AAAA a", "ssh-ed25519 BBBB b"]
    end

    # `System.user_home!/0` is fixed at VM start, so a fake home needs a
    # fresh VM. Resolved first: a mise shim breaks under a fake HOME.
    defp read_in_home(exs, home) do
      elixir = System.find_executable("elixir")

      System.cmd(
        elixir,
        ["-e", "IO.inspect(Config.Reader.read!(#{inspect(exs)})[:nerves_ssh][:authorized_keys])"],
        env: [{"HOME", home}, {"NERVES_AUTHORIZED_KEYS", nil}],
        stderr_to_stdout: true
      )
    end

    test "an unset NERVES_AUTHORIZED_KEYS with no ~/.ssh keys fails the build",
         %{exs: exs, dir: dir} do
      home = Path.join(dir, "home")
      File.mkdir_p!(home)

      {out, status} = read_in_home(exs, home)

      assert status != 0
      assert out =~ "No SSH public keys found in ~/.ssh"
    end

    test "an unset NERVES_AUTHORIZED_KEYS bakes the ~/.ssh keys", %{exs: exs, dir: dir} do
      home = Path.join(dir, "home")
      File.mkdir_p!(Path.join(home, ".ssh"))
      File.write!(Path.join(home, ".ssh/id_ed25519.pub"), "ssh-ed25519 AAAA home\n")

      assert {out, 0} = read_in_home(exs, home)
      assert out == inspect(["ssh-ed25519 AAAA home\n"]) <> "\n"
    end
  end

  test "an unknown VAGUS_FLAVOR fails the build instead of falling back" do
    System.put_env("VAGUS_FLAVOR", "bogus")
    assert_raise Mix.Error, ~r/Unknown VAGUS_FLAVOR "bogus"/, &read_vagus/0
  end
end
