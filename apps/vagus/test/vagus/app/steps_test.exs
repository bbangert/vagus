defmodule Vagus.App.StepsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vagus.Addon.Config
  alias Vagus.App.Steps

  alias Vagus.App.StepsTest.{
    DockerSpy,
    FakeBackend,
    PanelSpy,
    RaisingBackend,
    RefusingBackend
  }

  # No CI machine has a Hexagon DSP, and `dsp: true` refuses a start whose
  # required nodes do not resolve, so a start testing anything else aims the
  # check at char devices every Linux host has.
  @host_dsp_nodes ["/dev/null", "/dev/zero"]

  defp mosquitto_config do
    {:ok, c} = Config.parse(mosquitto_raw())
    c
  end

  defp mosquitto_raw do
    %{
      "name" => "Mosquitto broker",
      "version" => "7.1.0",
      "slug" => "core_mosquitto",
      "description" => "MQTT broker",
      "arch" => ["aarch64", "amd64"],
      "image" => "homeassistant/{arch}-addon-mosquitto",
      "init" => false,
      "startup" => "system",
      "auth_api" => true,
      "services" => ["mqtt:provide"],
      "discovery" => ["mqtt"],
      "ports" => %{"1883/tcp" => 1883, "8883/tcp" => 8883},
      "map" => ["ssl", "share"]
    }
  end

  # Only the `map:`-derived binds; /data and /dev are always there.
  defp map_mounts(map) do
    {:ok, config} = Config.parse(%{mosquitto_raw() | "map" => map})
    spec = Steps.build_spec(config, access_token: "t", arch: "amd64", data_root: "/data")

    spec.mounts
    |> Enum.reject(&(&1.target in ["/data", "/dev"]))
    |> Enum.map(&Map.take(&1, [:source, :target, :read_only, :propagation]))
  end

  describe "build_spec/2 (hermetic)" do
    setup do
      spec =
        Steps.build_spec(mosquitto_config(),
          access_token: "tok123",
          arch: "amd64",
          data_root: "/data"
        )

      %{spec: spec}
    end

    test "identity: name, hostname, arch-resolved image", %{spec: s} do
      assert s.name == "addon_core_mosquitto"
      assert s.hostname == "core-mosquitto"
      assert s.image == "homeassistant/amd64-addon-mosquitto:7.1.0"
      assert s.platform == "linux/amd64"
    end

    test "env carries TZ + both supervisor token names", %{spec: s} do
      assert s.env["SUPERVISOR_TOKEN"] == "tok123"
      assert s.env["HASSIO_TOKEN"] == "tok123"
      assert s.env["TZ"] == "UTC"
    end

    test "hassio-bridge attach with injected hosts + CoreDNS resolver (P1-T3)", %{spec: s} do
      # `supervisor`/`hassio` -> the bridge anchor is half of the add-on
      # contract; the other half is that `http://supervisor/` means port 80 on
      # it. The Supervisor-API listener vacated 80 for Core, so that port is
      # now `Vagus.Network.Nat`'s DNAT — this mapping is what add-ons resolve
      # to reach it, and it must stay the anchor and stay portless (a
      # `host:port` value here is not even valid for `ExtraHosts`).
      assert s.network == :hassio
      assert s.extra_hosts == %{"supervisor" => "172.30.32.2", "hassio" => "172.30.32.2"}
      assert s.dns == ["172.30.32.3"]
      assert s.dns_search == ["local.hass.io"]
      assert s.dns_options == ["timeout:10"]
    end

    test "init from config, /dev/shm tmpfs, ports passthrough", %{spec: s} do
      assert s.init == false
      assert s.tmpfs == %{"/dev/shm" => ""}
      assert s.ports == %{"1883/tcp" => 1883, "8883/tcp" => 8883}
    end

    test "mounts: /data always + map-derived /ssl,/share with data-root sources", %{spec: s} do
      data = Enum.find(s.mounts, &(&1.target == "/data"))
      assert data.source == "/data/addons/data/core_mosquitto"
      assert data.read_only == false

      ssl = Enum.find(s.mounts, &(&1.target == "/ssl"))
      assert ssl.source == "/data/ssl"

      share = Enum.find(s.mounts, &(&1.target == "/share"))
      assert share.source == "/data/share"
      assert share.propagation == "rslave"
    end

    test "mounts: app_config is the renamed addon_config — same /config bind" do
      expected = %{
        source: "/data/addon_configs/core_mosquitto",
        target: "/config",
        read_only: false,
        propagation: nil
      }

      assert map_mounts(["app_config:rw"]) == [expected]
      assert map_mounts(["addon_config:rw"]) == [expected]
    end

    # Upstream mounts the renamed keys at renamed targets (`docker/const.py`
    # PATH_ALL_APP_CONFIGS / PATH_LOCAL_APPS); the legacy keys keep theirs.
    test "mounts: all_app_configs and local_apps bind the legacy sources at the new targets" do
      assert map_mounts(["all_app_configs"]) == [
               %{
                 source: "/data/addon_configs",
                 target: "/app_configs",
                 read_only: true,
                 propagation: nil
               }
             ]

      assert map_mounts(["all_addon_configs"]) == [
               %{
                 source: "/data/addon_configs",
                 target: "/addon_configs",
                 read_only: true,
                 propagation: nil
               }
             ]

      assert map_mounts(["local_apps:rw"]) == [
               %{
                 source: "/data/addons/local",
                 target: "/local_apps",
                 read_only: false,
                 propagation: nil
               }
             ]
    end

    test "mounts: a legacy key is ignored when its app counterpart is also declared" do
      assert [%{target: "/config", read_only: false}] =
               map_mounts(["addon_config", "app_config:rw"])

      assert [%{target: "/app_configs"}] = map_mounts(["all_addon_configs", "all_app_configs"])
    end

    test "mounts: an unknown map type still warns and is skipped" do
      log = capture_log([level: :warning], fn -> assert map_mounts(["bogus_config"]) == [] end)
      assert log =~ "unknown map type 'bogus_config'"
    end

    test "mounts: every add-on gets the host /dev read-only (MOUNT_DEV parity)", %{spec: s} do
      dev = Enum.find(s.mounts, &(&1.target == "/dev"))

      assert dev.source == "/dev"
      # Not a preference: `Vagus.Addon.Devices`' cgroup rule is what grants
      # access, and the container-fingerprint gate pins this against a real
      # HAOS capture whose /dev is ro.
      assert dev.read_only == true
      assert dev.system == true

      # Unconditional — mosquitto declares no `devices:` and gets the bind
      # anyway. Safe for the nodes it is meant to cover: every block device is
      # denied by default, so `Vagus.Addon.Devices`' rule is what grants them.
      # NOT a blanket "the bind grants nothing" — moby's default allowlist
      # already permits `c 5:1` and `c 136:*`, and those are reachable by
      # devnum with or without this mount (docs/divergences.md).
      assert s.device_cgroup_rules == []

      # Upstream's MOUNT_DEV sets this; measured on-device it changes nothing
      # about isolation, so it is carried for parity rather than protection.
      assert dev.read_only_non_recursive == true

      # The /dev/shm tmpfs stacks over the bind rather than being swallowed by
      # it, the same duplicate-target pair the real Supervisor produces.
      assert Map.has_key?(s.tmpfs, "/dev/shm")
    end

    test "mounts: no /dev/console mask — masking a path does not revoke a devnum", %{spec: s} do
      # A `/dev/null` bind over `/dev/console` was tried and removed: verified
      # on-device, an add-on just runs `mknod c 5 1` and reads/writes the host
      # console through its own node. `CAP_MKNOD` is in the default set and the
      # cgroup allows `c 5:1` with the `m` bit, so the mount was never the
      # enforcement point. Pinned so the theatre does not come back.
      refute Enum.any?(s.mounts, &(&1.target == "/dev/console"))
    end

    test "mounts: host_dbus add-on gets /run/dbus read-only; default does not", %{spec: s} do
      # default (mosquitto fixture has no host_dbus)
      refute Enum.any?(s.mounts, &(&1.target == "/run/dbus"))

      {:ok, dbus_cfg} =
        Config.parse(%{
          "name" => "N",
          "version" => "1",
          "slug" => "dbus_addon",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "x/y",
          "host_dbus" => true
        })

      dbus_spec = Steps.build_spec(dbus_cfg, access_token: "t", arch: "amd64")
      dbus = Enum.find(dbus_spec.mounts, &(&1.target == "/run/dbus"))
      assert dbus.source == "/run/dbus"
      assert dbus.read_only == true
      assert dbus.propagation == nil
      # `system: true` = ensure_mount_sources must NOT mkdir this source; a
      # missing /run/dbus (BlueZ-less firmware) fails container create loudly
      # instead of binding a silently empty dir.
      assert dbus.system == true
      # the dbus mount is additive — the standard /data mount is still there
      assert Enum.any?(dbus_spec.mounts, &(&1.target == "/data"))
    end

    test "host_network add-on: NetworkMode host, no ports/hostname", %{} do
      {:ok, hostcfg} =
        Config.parse(%{
          "name" => "N",
          "version" => "1",
          "slug" => "hostnet",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "x/y",
          "host_network" => true,
          "ports" => %{"9/tcp" => 9}
        })

      s = Steps.build_spec(hostcfg, access_token: "t", arch: "amd64")
      assert s.network == :host
      assert s.hostname == nil
      assert s.ports == %{}
    end

    test "device_cgroup_rules: declared devices resolve; none declared stays empty", %{spec: s} do
      assert s.device_cgroup_rules == []

      dev_spec = Steps.build_spec(device_config(devices: ["/dev/null"]), arch: "amd64")
      assert dev_spec.device_cgroup_rules == ["c 1:3 rwm"]
    end

    test "device_cgroup_rules: full_access is gated on protection, like pid_mode" do
      cfg = device_config(full_access: true, host_pid: true)

      protected = Steps.build_spec(cfg, arch: "amd64")
      assert protected.device_cgroup_rules == []
      assert protected.pid_mode == nil

      # `protected: false` is the same switch that makes `host_pid` reachable —
      # both gates are `build_spec/2`'s, and until Phase 4 no caller flips it.
      unprotected = Steps.build_spec(cfg, arch: "amd64", protected: false)
      assert unprotected.device_cgroup_rules == ["b *:* rwm", "c *:* rwm"]
      assert unprotected.pid_mode == "host"
    end

    test "dsp: false declares neither dsp mount", %{spec: s} do
      refute Enum.any?(s.mounts, &(&1.target in ["/usr/lib/dsp", "/usr/lib/rfsa/adsp"]))
    end

    test "dsp: true declares both binds, read-only and system-owned" do
      dsp_root = configure_dsp_root()
      spec = Steps.build_spec(device_config(dsp: true), arch: "amd64")

      # The shells the system image ships. Measured as independently required
      # from the skel — without them the fastrpc session never opens.
      assert shells = Enum.find(spec.mounts, &(&1.target == "/usr/lib/dsp"))
      assert shells.source == "/usr/lib/dsp"
      assert shells.read_only == true
      assert shells.system == true

      # The operator's skel, at the one entry on `libcdsprpc`'s built-in search
      # list the system image never populates — so the two binds cannot collide.
      assert skel = Enum.find(spec.mounts, &(&1.target == "/usr/lib/rfsa/adsp"))
      assert skel.source == dsp_root
      assert skel.read_only == true

      # `system: true` is the whole failure model: it stops
      # `ensure_mount_sources/1` creating the store, so an add-on whose operator
      # never uploaded a skel fails container-create instead of binding an empty
      # dir and hitting a QNN device-creation failure at start (or, for a
      # wrapper with its own CPU fallback, running silently on the CPU).
      assert skel.system == true
    end

    # Pinned against the config rather than the literal: the store bind and
    # `Vagus.DSP`'s own reads must name one directory, and a `:dsp_root` change
    # that desynced them would otherwise pass every other assertion here.
    test "the store bind's source is exactly Vagus.DSP.root/0" do
      configure_dsp_root()
      spec = Steps.build_spec(device_config(dsp: true), arch: "amd64")

      assert %{source: source} = Enum.find(spec.mounts, &(&1.target == "/usr/lib/rfsa/adsp"))
      assert source == Vagus.DSP.root()
    end

    # rpi3_64 sets no `:dsp_root` — `nil` is that target's "no DSP here".
    test "with :dsp_root unset, dsp: true declares only the shells bind" do
      put_dsp_root(nil)
      spec = Steps.build_spec(device_config(dsp: true), arch: "amd64")

      assert Enum.any?(spec.mounts, &(&1.target == "/usr/lib/dsp"))
      refute Enum.any?(spec.mounts, &(&1.target == "/usr/lib/rfsa/adsp"))

      # A mount with a nil source binds nothing and reads as a bug at the
      # engine, not here.
      refute Enum.any?(spec.mounts, &is_nil(&1.source))
    end

    test "dsp: true still resolves the declared devices:" do
      # Membership, not equality: on a board with fastrpc nodes the spec also
      # carries their rules, and this test has no seam to inject through.
      spec = Steps.build_spec(device_config(dsp: true, devices: ["/dev/null"]), arch: "amd64")

      assert "c 1:3 rwm" in spec.device_cgroup_rules
    end

    # The flag must not disturb the mount every add-on already gets.
    test "dsp: true leaves the unconditional /dev bind alone" do
      spec = Steps.build_spec(device_config(dsp: true), arch: "amd64")

      assert dev = Enum.find(spec.mounts, &(&1.target == "/dev"))
      assert dev.read_only == true
      assert dev.system == true
    end
  end

  # `:dsp_root` is set per board (`config/dragon_q6a.exs`), so it is genuinely
  # present when this suite runs on-board — snapshot and restore rather than
  # leaving a tmp path, or `nil`, behind for everything after.
  defp put_dsp_root(value) do
    previous = Application.fetch_env(:vagus, :dsp_root)

    on_exit(fn ->
      case previous do
        {:ok, root} -> Application.put_env(:vagus, :dsp_root, root)
        :error -> Application.delete_env(:vagus, :dsp_root)
      end
    end)

    case value do
      nil -> Application.delete_env(:vagus, :dsp_root)
      root -> Application.put_env(:vagus, :dsp_root, root)
    end

    value
  end

  # A path this test owns, so every assertion about it holds on any host —
  # the lesson of the `/usr/lib/dsp` absence assertion that failed on a q6a.
  # Not created: whether it exists is the thing under test.
  defp configure_dsp_root do
    put_dsp_root(
      Path.join(System.tmp_dir!(), "vagus-mgr-dsp-#{System.unique_integer([:positive])}")
    )
  end

  defp cfg_dsp(slug) do
    {:ok, cfg} =
      Config.parse(%{
        "name" => "Dsp",
        "version" => "1",
        "slug" => slug,
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "x/y",
        "host_network" => true,
        "dsp" => true
      })

    cfg
  end

  defp device_config(extra) do
    raw =
      Map.merge(
        %{
          "name" => "N",
          "version" => "1",
          "slug" => "device_addon",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "x/y"
        },
        Map.new(extra, fn {k, v} -> {to_string(k), v} end)
      )

    {:ok, cfg} = Config.parse(raw)
    cfg
  end

  defp test_config(extra \\ %{}) do
    {:ok, config} =
      %{
        "name" => "Test",
        "version" => "3",
        "slug" => "test_app",
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "homeassistant/{arch}-addon-test",
        "map" => ["share"],
        "host_network" => true,
        "options" => %{"greeting" => "hi"},
        "schema" => %{"greeting" => "str"}
      }
      |> Map.merge(extra)
      |> Config.parse()

    config
  end

  defp input(context, extra \\ %{}) do
    Map.merge(
      %{
        slug: "test_app",
        config: test_config(),
        backend: FakeBackend,
        data_root: context.data_root,
        token: "tok",
        user_options: %{},
        ports: %{},
        protected: true
      },
      extra
    )
  end

  setup context do
    :persistent_term.put({FakeBackend, :pid}, self())

    on_exit(fn ->
      for key <- [:state, :stop],
          do: :persistent_term.erase({FakeBackend, key})
    end)

    data_root = Path.join(context[:tmp_dir] || System.tmp_dir!(), "data")
    %{data_root: data_root}
  end

  defp options_path(dr, slug \\ "test_app"),
    do: Path.join([dr, "addons", "data", slug, "options.json"])

  describe "start" do
    @describetag :tmp_dir

    test "writes options.json, removes a stale container, creates + starts with the token", ctx do
      assert {:ok, %{container_id: "fake-id", ip: nil, healthcheck: false}} =
               Steps.run(:start, input(ctx))

      assert Jason.decode!(File.read!(options_path(ctx.data_root))) == %{"greeting" => "hi"}

      # A reboot leaves the previous `addon_<slug>` behind and create would 409.
      assert_received {:stop, "addon_test_app"}
      assert_received {:remove, "addon_test_app"}
      assert_received {:create, spec}
      assert spec.env["SUPERVISOR_TOKEN"] == "tok"
      assert Enum.any?(spec.mounts, &(&1.target == "/share"))
      assert_received {:start, "fake-id"}
    end

    test "the user's options are merged over the defaults", ctx do
      assert {:ok, _} = Steps.run(:start, input(ctx, %{user_options: %{"greeting" => "yo"}}))
      assert Jason.decode!(File.read!(options_path(ctx.data_root))) == %{"greeting" => "yo"}
    end

    test "invalid options fail before any create", ctx do
      bad = test_config(%{"schema" => %{"port" => "port"}, "options" => %{"port" => 70_000}})
      assert {:error, {:invalid_options, _}} = Steps.run(:start, input(ctx, %{config: bad}))
      refute_received {:create, _}
    end

    test "a failed engine start removes the created container", ctx do
      :persistent_term.put({FakeBackend, :start}, {:error, :boom})
      on_exit(fn -> :persistent_term.erase({FakeBackend, :start}) end)

      assert {:error, {:start_failed, :boom}} = Steps.run(:start, input(ctx))
      assert_received {:remove, "fake-id"}
    end

    test "protection reaches the spec, and a non-boolean reads as protected", ctx do
      priv = test_config(%{"full_access" => true, "host_pid" => true})

      assert {:ok, _} = Steps.run(:start, input(ctx, %{config: priv, protected: false}))
      assert_received {:create, unprotected}
      assert unprotected.device_cgroup_rules == ["b *:* rwm", "c *:* rwm"]
      assert unprotected.pid_mode == "host"

      for protected <- [true, "false", nil] do
        assert {:ok, _} = Steps.run(:start, input(ctx, %{config: priv, protected: protected}))
        assert_received {:create, spec}
        assert spec.device_cgroup_rules == []
        assert spec.pid_mode == nil
      end
    end

    test "port overrides reach a bridged app's spec", ctx do
      bridged = test_config(%{"host_network" => false, "ports" => %{"80/tcp" => 8080}})
      ports = %{"80/tcp" => 9090}

      assert {:ok, %{ip: nil}} = Steps.run(:start, input(ctx, %{config: bridged, ports: ports}))
      assert_received {:create, spec}
      assert spec.ports == %{"80/tcp" => 9090}
      assert spec.platform == "linux/amd64" or is_binary(spec.platform)
    end

    test "a native app answers on the supervisor anchor", ctx do
      native = %{test_config(%{"slug" => "core_mqtt", "backend" => "native"}) | image: nil}

      assert {:ok, %{container_id: "fake-id", ip: ip, pid: nil}} =
               Steps.run(:start, input(ctx, %{slug: "core_mqtt", config: native}))

      assert ip == Vagus.Network.supervisor_ip()
    end

    test "a dsp: true start creates its data dir but never mkdir_p's /usr/lib/dsp", ctx do
      dsp_existed? = File.exists?("/usr/lib/dsp")
      dsp_root = configure_dsp_root()
      File.mkdir_p!(dsp_root)
      File.write!(Path.join(dsp_root, "libQnnHtpV68Skel.so"), "")
      on_exit(fn -> File.rm_rf!(dsp_root) end)

      cfg = cfg_dsp("dsp_app")

      assert {:ok, _} =
               Steps.run(
                 :start,
                 input(ctx, %{slug: "dsp_app", config: cfg, required_dsp_nodes: @host_dsp_nodes})
               )

      assert File.dir?(Path.join([ctx.data_root, "addons", "data", "dsp_app"]))
      assert File.exists?("/usr/lib/dsp") == dsp_existed?
      assert File.ls!(dsp_root) == ["libQnnHtpV68Skel.so"]
    end

    test "a dsp: true start with nothing stored fails naming the panel", ctx do
      dsp_root = configure_dsp_root()

      assert {:error, {:dsp_not_configured, message}} =
               Steps.run(:start, input(ctx, %{slug: "dsp_none", config: cfg_dsp("dsp_none")}))

      assert message =~ "Vagus admin panel"
      refute File.exists?(dsp_root)
    end

    test "a dsp: true start whose required node is missing fails naming it", ctx do
      dsp_root = configure_dsp_root()
      File.mkdir_p!(dsp_root)
      File.write!(Path.join(dsp_root, "libQnnHtpV68Skel.so"), "")
      on_exit(fn -> File.rm_rf!(dsp_root) end)
      nodes = ["/dev/null", "/dev/vagus-no-such-dsp-node"]

      assert {:error, {:dsp_devices_unavailable, message}} =
               Steps.run(
                 :start,
                 input(ctx, %{config: cfg_dsp("dsp_nonode"), required_dsp_nodes: nodes})
               )

      assert message =~ "/dev/vagus-no-such-dsp-node"
      refute message =~ "/dev/null"
      refute_received {:create, _spec}
    end

    test "a dsp: false start ignores the same missing node", ctx do
      nodes = ["/dev/vagus-no-such-dsp-node"]
      assert {:ok, _} = Steps.run(:start, input(ctx, %{required_dsp_nodes: nodes}))
      assert_received {:create, _spec}
    end

    test "a dsp: true start on a board with no DSP says so", ctx do
      put_dsp_root(nil)
      nodes = ["/dev/vagus-no-such-dsp-node"]

      assert {:error, {:dsp_unsupported, message}} =
               Steps.run(
                 :start,
                 input(ctx, %{config: cfg_dsp("dsp_nodsp"), required_dsp_nodes: nodes})
               )

      assert message =~ "no Hexagon DSP"
    end
  end

  describe "options.json is never written through the app's own entries" do
    @describetag :tmp_dir

    test "a symlinked options.json is replaced, and its target is not written", ctx do
      target = Path.join(ctx.tmp_dir, "outside.json")
      File.write!(target, "precious")
      File.mkdir_p!(Path.dirname(options_path(ctx.data_root)))
      File.ln_s!(target, options_path(ctx.data_root))

      assert {:ok, _} = Steps.run(:start, input(ctx))

      assert File.read!(target) == "precious"
      assert {:ok, %File.Stat{type: :regular}} = File.lstat(options_path(ctx.data_root))
      assert Jason.decode!(File.read!(options_path(ctx.data_root))) == %{"greeting" => "hi"}
    end

    test "a dangling symlink is replaced without creating its target", ctx do
      target = Path.join(ctx.tmp_dir, "created-by-vagus.json")
      File.mkdir_p!(Path.dirname(options_path(ctx.data_root)))
      File.ln_s!(target, options_path(ctx.data_root))

      assert {:ok, _} = Steps.run(:start, input(ctx))
      refute File.exists?(target)
      assert {:ok, %File.Stat{type: :regular}} = File.lstat(options_path(ctx.data_root))
    end

    test "a directory in its place fails the start and leaves no temp file", ctx do
      File.mkdir_p!(options_path(ctx.data_root))

      assert {:error, {:write_options, _}} = Steps.run(:start, input(ctx))
      refute_received {:create, _}
      dir = Path.dirname(options_path(ctx.data_root))
      assert File.ls!(dir) == ["options.json"]
    end

    test "a data dir it cannot write fails the start with the reason, leaving nothing", ctx do
      dir = Path.dirname(options_path(ctx.data_root))
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o555)
      on_exit(fn -> File.chmod!(dir, 0o755) end)

      assert {:error, {:write_options, :eacces}} = Steps.run(:start, input(ctx))
      refute_received {:create, _}
      assert File.ls!(dir) == []
    end
  end

  describe "stop, halt_stop, pull" do
    @describetag :tmp_dir

    test "stop stops and removes, and says whether it was running", ctx do
      assert {:ok, %{was_running: true}} = Steps.run(:stop, input(ctx))
      assert_received {:stop, "addon_test_app"}
      assert_received {:remove, "addon_test_app"}

      :persistent_term.put({FakeBackend, :state}, {:ok, :stopped})
      assert {:ok, %{was_running: false}} = Steps.run(:stop, input(ctx))
    end

    test "halt_stop stops by name with the shutdown timeout and removes nothing", ctx do
      assert {:ok, :stopped} = Steps.run(:halt_stop, input(ctx))
      assert_received {:stop, "addon_test_app", opts}
      assert opts[:timeout] == 30
      refute_received {:remove, _}
    end

    # A restore swaps the data dir next: only a container that is gone or
    # stopped is safe, and a stop the engine failed may have left it writing.
    test "a strict stop fails on an engine error, and passes an absent or stopped container",
         ctx do
      strict = Map.put(input(ctx), :strict, true)

      for ok <- [:ok, {:error, {:http, 404}}] do
        :persistent_term.put({FakeBackend, :stop}, fn -> ok end)
        assert {:ok, %{was_running: true}} = Steps.run(:stop, strict)
        assert_received {:remove, "addon_test_app"}
      end

      for failure <- [{:http, 500}, :econnrefused] do
        :persistent_term.put({FakeBackend, :stop}, fn -> {:error, failure} end)

        log = capture_log(fn -> assert {:error, ^failure} = Steps.run(:stop, strict) end)
        assert log =~ "stop addon_test_app failed"
        refute_received {:remove, _id}

        capture_log(fn -> assert {:ok, _fact} = Steps.run(:stop, input(ctx)) end)
        assert_received {:remove, "addon_test_app"}
      end
    end

    test "pull pulls the arch-resolved image", ctx do
      assert {:ok, image} = Steps.run(:pull, Map.put(input(ctx), :arch, "amd64"))
      assert image == "homeassistant/amd64-addon-test:3"
      assert_received {:pull, %{image: ^image}}
    end
  end

  describe "port" do
    setup do
      directory = :"steps_dir_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: directory})
      %{directory: directory}
    end

    defp sequence(ports) do
      Process.put(:ports, ports)

      fn ->
        [port | rest] = Process.get(:ports)
        Process.put(:ports, rest)
        port
      end
    end

    test "skips a port another app holds and one something listens on", %{directory: dir} do
      {:ok, _} = Registry.register(dir, {:ingress_port, 62_001}, nil)
      probe = fn _ip, port -> if port == 62_002, do: :listening, else: :free end

      assert {:ok, 62_003} =
               Steps.run(:port, %{
                 config: test_config(),
                 directory: dir,
                 port_probe: probe,
                 rand: sequence([62_001, 62_002, 62_003])
               })
    end

    test "gives up when nothing is free", %{directory: dir} do
      assert {:error, :no_free_port} =
               Steps.run(:port, %{
                 config: test_config(),
                 directory: dir,
                 port_probe: fn _ip, _port -> :listening end
               })
    end
  end

  describe "exec_hook and snapshot" do
    @describetag :tmp_dir

    test "exec_hook runs the command in the app's container", ctx do
      assert {:ok, :ok} =
               Steps.run(:exec_hook, input(ctx, %{cmd: "dump-db", docker: DockerSpy}))

      assert_received {:exec, "addon_test_app", "dump-db"}

      assert {:error, {:exec, 3}} =
               Steps.run(:exec_hook, input(ctx, %{cmd: "fail 3", docker: DockerSpy}))

      assert {:error, {:exec_create_failed, 409, _}} =
               Steps.run(:exec_hook, input(ctx, %{cmd: "status 409", docker: DockerSpy}))
    end

    test "exec_hook with no container skips the hook", ctx do
      log =
        capture_log(fn ->
          assert {:ok, :skipped} =
                   Steps.run(:exec_hook, input(ctx, %{cmd: "status 404", docker: DockerSpy}))
        end)

      assert log =~ "no container addon_test_app; backup hook skipped"
    end

    test "snapshot writes <slug>.tar.gz of the data dir into the staging dir", ctx do
      data_dir = Path.join([ctx.data_root, "addons", "data", "test_app"])
      File.mkdir_p!(Path.join(data_dir, "sub"))
      File.write!(Path.join(data_dir, "db.sqlite"), "rows")
      File.write!(Path.join([data_dir, "sub", "x"]), "y")
      staging = Path.join(ctx.tmp_dir, "staging")

      assert {:ok, path} =
               Steps.run(
                 :snapshot,
                 input(ctx, %{
                   staging_dir: staging,
                   user_options: %{"greeting" => "yo"},
                   state: "started"
                 })
               )

      assert path == Path.join(staging, "test_app.tar.gz")
      {:ok, entries} = :erl_tar.extract(String.to_charlist(path), [:memory, :compressed])
      entries = Map.new(entries, fn {name, bin} -> {to_string(name), bin} end)

      assert Map.keys(entries) |> Enum.sort() ==
               ["./addon.json", "./data/db.sqlite", "./data/sub/x"]

      assert entries["./data/db.sqlite"] == "rows"

      assert %{"state" => "started", "user" => %{"options" => %{"greeting" => "yo"}}} =
               Jason.decode!(entries["./addon.json"])
    end

    defp members(path) do
      {:ok, entries} = :erl_tar.extract(String.to_charlist(path), [:memory, :compressed])
      Map.new(entries, fn {name, bin} -> {to_string(name), bin} end)
    end

    defp snapshot_input(ctx, extra) do
      input(ctx, Map.merge(%{staging_dir: Path.join(ctx.tmp_dir, "staging")}, extra))
    end

    test "addon.json's system block carries the restore-required keys", ctx do
      assert {:ok, path} = Steps.run(:snapshot, snapshot_input(ctx, %{}))
      system = Jason.decode!(members(path)["./addon.json"])["system"]

      assert %{"slug" => "test_app", "repository" => "core", "arch" => [_ | _]} = system
      assert Map.has_key?(system, "name") and Map.has_key?(system, "version")
    end
  end

  describe "swap_data" do
    @describetag :tmp_dir

    defp swap_dirs(ctx) do
      data_dir = Path.join([ctx.data_root, "addons", "data", "test_app"])
      staging = Path.join([ctx.data_root, "addons", "data", ".restore-test_app-1"])
      File.mkdir_p!(data_dir)
      File.write!(Path.join(data_dir, "db"), "old")
      File.mkdir_p!(staging)
      File.write!(Path.join(staging, "db"), "new")
      {data_dir, staging}
    end

    defp siblings(data_dir), do: data_dir |> Path.dirname() |> File.ls!() |> Enum.sort()

    test "the staged data replaces the data dir", ctx do
      {data_dir, staging} = swap_dirs(ctx)

      assert {:ok, ^data_dir} = Steps.run(:swap_data, input(ctx, %{staging_dir: staging}))
      assert File.ls!(data_dir) == ["db"]
      assert File.read!(Path.join(data_dir, "db")) == "new"
      assert siblings(data_dir) == ["test_app"]
    end

    test "a staging path that is not this app's restore sibling is refused untouched", ctx do
      {data_dir, staging} = swap_dirs(ctx)
      elsewhere = Path.join(ctx.tmp_dir, ".restore-test_app-1")
      File.mkdir_p!(elsewhere)
      other_app = Path.join(Path.dirname(data_dir), ".restore-other_app-1")
      File.mkdir_p!(other_app)

      for bad <- [elsewhere, other_app, staging <> "x", staging <> "/../test_app"] do
        assert {:error, :bad_staging} = Steps.run(:swap_data, input(ctx, %{staging_dir: bad}))
      end

      assert File.read!(Path.join(data_dir, "db")) == "old"
      assert File.dir?(elsewhere) and File.dir?(other_app) and File.dir?(staging)
    end

    test "an app with no data dir yet gets the staged one", ctx do
      {data_dir, staging} = swap_dirs(ctx)
      File.rm_rf!(data_dir)

      assert {:ok, ^data_dir} = Steps.run(:swap_data, input(ctx, %{staging_dir: staging}))
      assert File.read!(Path.join(data_dir, "db")) == "new"
    end

    # Upstream's wipe-then-extract has no rollback either; the caller retries.
    test "a rename that fails is the step's error, with the data dir already gone", ctx do
      {data_dir, staging} = swap_dirs(ctx)
      File.rm_rf!(staging)

      assert {:error, :enoent} = Steps.run(:swap_data, input(ctx, %{staging_dir: staging}))
      assert siblings(data_dir) == []
    end

    # A name too long for the filesystem fails for root too, unlike a mode.
    test "a data dir it cannot remove is the step's error; the path is only logged", ctx do
      File.mkdir_p!(ctx.data_root)
      root = Path.join(ctx.data_root, String.duplicate("x", 300))
      parent = Path.join([root, "addons", "data"])
      data_dir = Path.join(parent, "test_app")

      input =
        input(ctx, %{data_root: root, staging_dir: Path.join(parent, ".restore-test_app-1")})

      log =
        capture_log(fn ->
          assert {:error, {:remove_data_dir, :enametoolong}} = Steps.run(:swap_data, input)
        end)

      assert log =~ data_dir
    end
  end

  describe "set_options" do
    defp schema_config(schema) do
      {:ok, config} =
        Config.parse(%{
          "name" => "Test",
          "version" => "1",
          "slug" => "test_app",
          "description" => "d",
          "arch" => ["amd64"],
          "options" => %{"greet" => "hi"},
          "schema" => schema
        })

      config
    end

    test "options the config in hand accepts are returned raw" do
      config = schema_config(%{"greet" => "str"})
      raw = %{"greet" => "hello", "extra" => 1}

      assert {:ok, ^raw} =
               Steps.run(:set_options, %{config: config, options: raw, job: nil, stage: nil})
    end

    test "options the config in hand rejects keep the current ones, with a warning" do
      config = schema_config(%{"greet" => "int"})

      log =
        capture_log(fn ->
          assert {:ok, nil} =
                   Steps.run(:set_options, %{
                     config: config,
                     options: %{"greet" => "hello"},
                     job: nil,
                     stage: nil
                   })
        end)

      assert log =~ "test_app's backed-up options do not validate"
      assert log =~ "keeping the current options"
    end

    # An app without a schema accepts any map, but a tar's options are its own.
    test "options that are not a map keep the current ones, schema or not" do
      for schema <- [%{"greet" => "str"}, false] do
        input = %{config: schema_config(schema), options: ["x"], job: nil, stage: nil}
        capture_log(fn -> assert {:ok, nil} = Steps.run(:set_options, input) end)
      end
    end
  end

  describe "reclaim_image" do
    test "removes the superseded image only when the ref changed" do
      old = test_config()
      new = test_config(%{"version" => "4"})
      input = %{config: new, old: old, backend: FakeBackend, arch: "amd64"}

      assert {:ok, :ok} = Steps.run(:reclaim_image, input)
      assert_received {:remove_image, "homeassistant/amd64-addon-test:3"}

      assert {:ok, :ok} = Steps.run(:reclaim_image, %{input | old: new})
      refute_received {:remove_image, _}
    end

    test "a refused or raising removal never fails the op" do
      input = %{config: test_config(%{"version" => "4"}), old: test_config(), arch: "amd64"}

      capture_log(fn ->
        assert {:ok, :ok} = Steps.run(:reclaim_image, Map.put(input, :backend, RefusingBackend))
        assert {:ok, :ok} = Steps.run(:reclaim_image, Map.put(input, :backend, RaisingBackend))
      end)
    end
  end

  describe "remove_app" do
    @describetag :tmp_dir

    test "removes the data dir and pushes the panel DELETE for an ingress app", ctx do
      :persistent_term.put({PanelSpy, :pid}, self())
      data_dir = Path.join([ctx.data_root, "addons", "data", "test_app"])
      File.mkdir_p!(data_dir)
      ingress = test_config(%{"ingress" => true})

      assert {:ok, :ok} = Steps.run(:remove_app, input(ctx, %{config: ingress, panels: PanelSpy}))
      refute File.exists?(data_dir)
      assert_received {:panel_push, "test_app", [method: :delete]}
    end

    test "a non-ingress app pushes no panel", ctx do
      :persistent_term.put({PanelSpy, :pid}, self())
      assert {:ok, :ok} = Steps.run(:remove_app, input(ctx, %{panels: PanelSpy}))
      refute_received {:panel_push, _, _}
    end

    # A name too long for the filesystem fails for root too, unlike a mode.
    # Its parent must exist: lookup stops at a missing one with `:enoent`,
    # which `rm_rf` takes as already removed.
    test "a data dir it cannot remove is the step's error; the path is only logged", ctx do
      File.mkdir_p!(ctx.data_root)
      root = Path.join(ctx.data_root, String.duplicate("x", 300))
      data_dir = Path.join([root, "addons", "data", "test_app"])

      log =
        capture_log(fn ->
          assert {:error, {:remove_data_dir, :enametoolong}} =
                   Steps.run(:remove_app, input(ctx, %{data_root: root}))
        end)

      assert log =~ data_dir
    end

    test "refuses to rm_rf outside the data dir for an unsafe slug", ctx do
      for slug <- ["../evil", ".."] do
        hostile = %{test_config() | slug: slug}
        sentinel = Path.join([ctx.data_root, "addons", "keep.txt"])
        File.mkdir_p!(Path.dirname(sentinel))
        File.write!(sentinel, "keep me")

        capture_log(fn ->
          assert {:error, {:invalid_slug, ^slug}} =
                   Steps.run(:remove_app, input(ctx, %{config: hostile}))
        end)

        assert File.exists?(sentinel)
      end
    end
  end

  describe "native?/1" do
    test "only an allowlisted slug runs in-BEAM" do
      assert Steps.native?(%{test_config(%{"slug" => "core_mqtt"}) | backend: :native})
      refute Steps.native?(%{test_config() | backend: :native})
      refute Steps.native?(test_config(%{"slug" => "core_mqtt"}))
      refute Steps.native?(nil)
    end
  end

  defmodule FakeBackend do
    @moduledoc false
    @behaviour Vagus.Addon.Backend

    defp notify(msg), do: send(:persistent_term.get({__MODULE__, :pid}), msg)

    @impl true
    def pull(spec), do: notify({:pull, spec}) && :ok

    @impl true
    def create(spec) do
      notify({:create, spec})
      {:ok, "fake-id"}
    end

    @impl true
    def start(id) do
      notify({:start, id})
      :persistent_term.get({__MODULE__, :start}, :ok)
    end

    @impl true
    def stop(id, opts \\ []) do
      notify({:stop, id})
      notify({:stop, id, opts})
      :persistent_term.get({__MODULE__, :stop}, fn -> :ok end).()
    end

    @impl true
    def remove(id, _opts \\ []), do: notify({:remove, id}) && :ok

    @impl true
    def remove_image(image, _opts \\ []), do: notify({:remove_image, image}) && :ok

    @impl true
    def state(_id), do: :persistent_term.get({__MODULE__, :state}, {:ok, :running})
  end

  defmodule RefusingBackend do
    @moduledoc false
    def remove_image(_image, _opts), do: {:error, :in_use}
  end

  defmodule RaisingBackend do
    @moduledoc false
    def remove_image(_image, _opts), do: raise("no images here")
  end

  defmodule DockerSpy do
    @moduledoc false
    def exec(_id, "fail " <> code, _opts), do: {:error, {:exec, String.to_integer(code)}}

    def exec(_id, "status " <> status, _opts),
      do: {:error, {:exec_create_failed, String.to_integer(status), "refused"}}

    def exec(id, cmd, _opts), do: send(self(), {:exec, id, cmd}) && :ok
  end

  defmodule PanelSpy do
    @moduledoc false
    def update_hass_panel(slug, opts) do
      send(:persistent_term.get({__MODULE__, :pid}), {:panel_push, slug, opts})
      :ok
    end
  end
end
