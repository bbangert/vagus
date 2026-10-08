defmodule Vagus.App.PrepareTest do
  # Not async: the start this is compared with writes to the application's
  # own state of installed apps.
  use ExUnit.Case, async: false

  alias Vagus.Addon.{Devices, Manager}
  alias Vagus.App.{Facts, Prepare}
  alias Vagus.App.Spec.Schema
  alias Vagus.Test.AppManifests

  @moduletag :capture_log

  defmodule Halting do
    @moduledoc "A backend of the old kind that lets a start get as far as its create, and no further."
    def stop(_id, _opts), do: :ok
    def remove(_id, _opts \\ []), do: :ok
    def create(_spec), do: {:error, :far_enough}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "vagus-prepare-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{old: Path.join(root, "old"), new: Path.join(root, "new")}
  end

  # Every directory and file beneath `root`: its path, its mode, its bytes.
  defp tree(root) do
    for path <- Enum.sort(Path.wildcard(Path.join(root, "**"), match_dot: true)) do
      stat = File.stat!(path)

      {Path.relative_to(path, root), stat.type, Integer.to_string(stat.mode, 8),
       if(stat.type == :regular, do: File.read!(path))}
    end
  end

  defp spec(config, facts, fields) do
    port = if Schema.dynamic_ingress?(config), do: %{ingress_port: 62_000}, else: %{}

    {:ok, spec} =
      Schema.validate(Schema.from_manifest(config, facts, Map.merge(port, fields)), facts)

    spec
  end

  defp prepare(config, root, fields \\ %{}) do
    facts = Facts.read(data_root: root)
    Prepare.run(spec(config, facts, fields), facts, network: fn -> :ok end)
  end

  # The start this replaces, stopped at its create: a bridged app's fails
  # one step earlier, at a network no engine is there to make.
  defp old_start(config, root, user_options) do
    Manager.start(config,
      backend: Halting,
      data_root: root,
      user_options: user_options,
      socket: Path.join(root, "no-engine.sock")
    )
  end

  describe "against the start it replaces" do
    for config <- AppManifests.containers() do
      @config config
      test "#{config.slug}: the same directories, the same options.json, byte for byte", ctx do
        config = unquote(Macro.escape(@config))
        assert {:error, _stopped_short} = old_start(config, ctx.old, %{})
        new = prepare(config, ctx.new)

        assert tree(ctx.new) == tree(ctx.old)
        assert tree(ctx.new) != []

        case new do
          {:ok, %{device_cgroup_rules: rules}} ->
            assert rules == Manager.build_spec(config, data_root: ctx.old).device_cgroup_rules
            path = Prepare.options_path(config.slug, Facts.read(data_root: ctx.new))
            assert {:ok, %File.Stat{type: :regular}} = File.stat(path)

          # Where the old start refuses, before or after it wrote anything,
          # this one does, having written the same.
          {:error, {:invalid, {reason, _message}}} ->
            assert {:error, {^reason, _}} = old_start(config, ctx.old, %{})
        end
      end
    end

    test "the user's options over the manifest's, as the old start writes them", ctx do
      config = AppManifests.get("core_mosquitto")

      options = %{
        "require_certificate" => true,
        "logins" => [%{"username" => "u", "password" => "p"}]
      }

      assert {:error, _stopped_short} = old_start(config, ctx.old, options)
      assert {:ok, _prepared} = prepare(config, ctx.new, %{options: options})
      assert tree(ctx.new) == tree(ctx.old)

      written = File.read!(Prepare.options_path(config.slug, Facts.read(data_root: ctx.new)))
      assert Jason.decode!(written) == options
    end

    test "an app that is not protected gets the rules the old start gives it", ctx do
      config = AppManifests.get("full_and_devices")
      facts = Facts.read(data_root: ctx.new)

      {:ok, %{device_cgroup_rules: rules}} =
        Prepare.run(spec(config, facts, %{settings: %{protected: false}}), facts,
          network: fn -> :ok end
        )

      assert rules == Devices.cgroup_rules(config, false)
      assert rules != Devices.cgroup_rules(config, true)
    end
  end

  describe "run/3" do
    test "is the same done twice", ctx do
      config = AppManifests.get("core_samba")
      assert {:ok, first} = prepare(config, ctx.new)
      before = tree(ctx.new)
      assert {:ok, ^first} = prepare(config, ctx.new)
      assert tree(ctx.new) == before
    end

    test "asks for the app network of a bridged app, and of no other", ctx do
      test = self()
      network = fn -> send(test, :network) && :ok end
      facts = Facts.read(data_root: ctx.new)
      run = &Prepare.run(spec(AppManifests.get(&1), facts, %{}), facts, network: network)

      assert {:ok, _} = run.("only_host_uts")
      assert_received :network
      assert {:ok, _} = run.("core_samba")
      refute_received :network
      assert {:ok, _} = run.("core_mqtt")
      refute_received :network
    end

    test "a native app gets its options.json too", ctx do
      facts = Facts.read(data_root: ctx.new)

      assert {:ok, %{device_cgroup_rules: []}} =
               Prepare.run(spec(AppManifests.native(), facts, %{}), facts)

      assert File.read!(Path.join([ctx.new, "addons", "data", "core_mqtt", "options.json"])) =~
               "{"
    end

    test "a network that cannot be made is the engine's failure, in the engine's shape", ctx do
      facts = Facts.read(data_root: ctx.new)
      spec = spec(AppManifests.get("only_host_uts"), facts, %{})

      assert Prepare.run(spec, facts, network: fn -> {:error, :enoent} end) ==
               {:error, Vagus.Runtime.Docker.failure(:enoent)}
    end

    test "what trying again cannot change is refused as invalid: the DSP, and options", ctx do
      facts = Facts.read(data_root: ctx.new)
      dsp = spec(AppManifests.get("local_dsp"), facts, %{})
      run = &Prepare.run(dsp, facts, [network: fn -> :ok end] ++ &1)

      assert {:error, {:invalid, {:dsp_unsupported, _}}} = run.(dsp_state: fn -> :unsupported end)

      assert {:error, {:invalid, {:dsp_not_configured, _}}} =
               run.(dsp_state: fn -> :not_configured end)

      assert {:error, {:invalid, {:dsp_devices_unavailable, message}}} =
               run.(
                 dsp_state: fn -> :configured end,
                 devices: [required_dsp_nodes: ["/dev/none0"]]
               )

      assert message =~ "/dev/none0"

      assert {:ok, _} =
               run.(
                 dsp_state: fn -> :configured end,
                 devices: [required_dsp_nodes: ["/dev/null"]]
               )

      # A manifest whose schema does not admit what is stored.
      plain = spec(AppManifests.get("only_host_uts"), facts, %{})
      stale = put_in(plain.config.schema, %{"must" => "str"})

      assert {:error, {:invalid, {:invalid_options, _}}} =
               Prepare.run(stale, facts, network: fn -> :ok end)
    end

    test "a directory that cannot be made says which", ctx do
      File.mkdir_p!(ctx.new)
      File.write!(Path.join(ctx.new, "addons"), "in the way")

      assert {:error, {:mkdir, path, _reason}} =
               prepare(AppManifests.get("only_host_uts"), ctx.new)

      assert path =~ "addons/data/only_host_uts"
    end
  end

  describe "an app's data" do
    test "is there once prepared, and gone once removed", ctx do
      facts = Facts.read(data_root: ctx.new)
      refute Prepare.data?("only_host_uts", facts)
      assert {:ok, _} = prepare(AppManifests.get("only_host_uts"), ctx.new)
      assert Prepare.data?("only_host_uts", facts)
      File.write!(Path.join(Prepare.data_dir("only_host_uts", facts), "state.db"), "x")

      assert Prepare.remove_data("only_host_uts", facts) == :ok
      refute Prepare.data?("only_host_uts", facts)
      assert Prepare.remove_data("only_host_uts", facts) == :ok
    end

    test "a slug that names anything but a directory of its own removes nothing", ctx do
      facts = Facts.read(data_root: ctx.new)
      File.mkdir_p!(Path.join([ctx.new, "addons", "data"]))

      for slug <- ["..", ".", "a/b", "../../etc"] do
        assert {:error, {:invalid, {:slug, ^slug}}} = Prepare.remove_data(slug, facts)
      end

      assert File.dir?(Path.join([ctx.new, "addons", "data"]))
    end
  end
end
