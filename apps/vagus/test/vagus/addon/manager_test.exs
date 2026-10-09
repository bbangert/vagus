defmodule Vagus.Addon.ManagerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vagus.Addon.{Config, Manager, State}
  alias Vagus.API.AdminPanel

  # No CI machine has a Hexagon DSP, and `dsp: true` now refuses a start whose
  # required nodes do not resolve — so a start that is testing anything else
  # aims the check at char devices every Linux host has.
  @host_dsp_nodes ["/dev/null", "/dev/zero"]

  defp mosquitto_config do
    {:ok, c} =
      Config.parse(%{
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
      })

    c
  end

  describe "build_spec/2 (hermetic)" do
    setup do
      spec =
        Manager.build_spec(mosquitto_config(),
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

      dbus_spec = Manager.build_spec(dbus_cfg, access_token: "t", arch: "amd64")
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

      s = Manager.build_spec(hostcfg, access_token: "t", arch: "amd64")
      assert s.network == :host
      assert s.hostname == nil
      assert s.ports == %{}
    end

    test "device_cgroup_rules: declared devices resolve; none declared stays empty", %{spec: s} do
      assert s.device_cgroup_rules == []

      dev_spec = Manager.build_spec(device_config(devices: ["/dev/null"]), arch: "amd64")
      assert dev_spec.device_cgroup_rules == ["c 1:3 rwm"]
    end

    test "device_cgroup_rules: full_access is gated on protection, like pid_mode" do
      cfg = device_config(full_access: true, host_pid: true)

      protected = Manager.build_spec(cfg, arch: "amd64")
      assert protected.device_cgroup_rules == []
      assert protected.pid_mode == nil

      # `protected: false` is the same switch that makes `host_pid` reachable —
      # both gates are `build_spec/2`'s, and until Phase 4 no caller flips it.
      unprotected = Manager.build_spec(cfg, arch: "amd64", protected: false)
      assert unprotected.device_cgroup_rules == ["b *:* rwm", "c *:* rwm"]
      assert unprotected.pid_mode == "host"
    end

    test "dsp: false declares neither dsp mount", %{spec: s} do
      refute Enum.any?(s.mounts, &(&1.target in ["/usr/lib/dsp", "/usr/lib/rfsa/adsp"]))
    end

    test "dsp: true declares both binds, read-only and system-owned" do
      dsp_root = configure_dsp_root()
      spec = Manager.build_spec(device_config(dsp: true), arch: "amd64")

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
      spec = Manager.build_spec(device_config(dsp: true), arch: "amd64")

      assert %{source: source} = Enum.find(spec.mounts, &(&1.target == "/usr/lib/rfsa/adsp"))
      assert source == Vagus.DSP.root()
    end

    # rpi3_64 sets no `:dsp_root` — `nil` is that target's "no DSP here".
    test "with :dsp_root unset, dsp: true declares only the shells bind" do
      put_dsp_root(nil)
      spec = Manager.build_spec(device_config(dsp: true), arch: "amd64")

      assert Enum.any?(spec.mounts, &(&1.target == "/usr/lib/dsp"))
      refute Enum.any?(spec.mounts, &(&1.target == "/usr/lib/rfsa/adsp"))

      # A mount with a nil source binds nothing and reads as a bug at the
      # engine, not here.
      refute Enum.any?(spec.mounts, &is_nil(&1.source))
    end

    test "dsp: true still resolves the declared devices:" do
      # Membership, not equality: on a board with fastrpc nodes the spec also
      # carries their rules, and this test has no seam to inject through.
      spec = Manager.build_spec(device_config(dsp: true, devices: ["/dev/null"]), arch: "amd64")

      assert "c 1:3 rwm" in spec.device_cgroup_rules
    end

    # The flag must not disturb the mount every add-on already gets.
    test "dsp: true leaves the unconditional /dev bind alone" do
      spec = Manager.build_spec(device_config(dsp: true), arch: "amd64")

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

  describe "install + start orchestration (fake backend)" do
    # Real bind-mount execution can't be exercised in this docker-outside-of-
    # docker devcontainer (host daemon can't resolve devcontainer paths); that
    # is covered by the on-device Gate-1 run. Here an injected fake backend
    # verifies the orchestration + the spec the manager builds, deterministically
    # and without a daemon.
    setup do
      :persistent_term.put({__MODULE__.FakeBackend, :pid}, self())
      data_root = Path.join(System.tmp_dir!(), "vagus-mgr-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(data_root) end)

      {:ok, config} =
        Config.parse(%{
          "name" => "Test",
          "version" => "3",
          "slug" => "test_addon",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "homeassistant/{arch}-addon-test",
          "map" => ["share"],
          "host_network" => true,
          "options" => %{"greeting" => "hi"},
          "schema" => %{"greeting" => "str"}
        })

      %{config: config, data_root: data_root}
    end

    test "install pulls via the backend", %{config: config, data_root: dr} do
      assert :ok = Manager.install(config, backend: __MODULE__.FakeBackend, data_root: dr)
      assert_received {:pull, %{image: "homeassistant/amd64-addon-test:3"}}
    end

    # `Vagus.API.Router`'s install handler overwrites the parsed config's slug
    # with the one from the URL, so `Config.parse/1`'s reserved-slug rejection
    # cannot cover installs — this is the choke point that does.
    test "install refuses a slug Vagus reserves for itself, without pulling", %{
      config: config,
      data_root: dr
    } do
      reserved = %{config | slug: AdminPanel.slug()}

      assert {:error, {:reserved_slug, "vagus"}} =
               Manager.install(reserved, backend: __MODULE__.FakeBackend, data_root: dr)

      refute_received {:pull, _spec}
    end

    test "start writes options.json, creates + starts, returns id + 112-char token",
         %{config: config, data_root: dr} do
      assert {:ok, %{id: "fake-id", access_token: token}} =
               Manager.start(config, backend: __MODULE__.FakeBackend, data_root: dr)

      assert byte_size(token) == 112

      # options validated (against schema) + written to the /data source dir
      opts_path = Path.join([dr, "addons", "data", "test_addon", "options.json"])
      assert File.exists?(opts_path)
      assert Jason.decode!(File.read!(opts_path)) == %{"greeting" => "hi"}

      # the backend received a fully-built spec with the token + mounts
      assert_received {:create, spec}
      assert spec.name == "addon_test_addon"
      assert spec.env["SUPERVISOR_TOKEN"] == token
      assert Enum.any?(spec.mounts, &(&1.target == "/data"))
      assert Enum.any?(spec.mounts, &(&1.target == "/share"))
      assert_received {:start, "fake-id"}
    end

    test "start removes a stale same-name container before create (reboot orphan)",
         %{config: config, data_root: dr} do
      # After a device reboot the previous session's `addon_<slug>` container
      # survives while in-memory state does not; `create` would 409 on the
      # fixed name. Supervisor's `DockerInterface.run` stops+removes first.
      assert {:ok, _} = Manager.start(config, backend: __MODULE__.FakeBackend, data_root: dr)

      assert_received {:stop, "addon_test_addon"}
      assert_received {:remove, "addon_test_addon"}
      assert_received {:create, _spec}
    end

    test "invalid options (schema mismatch) fail start before any create",
         %{data_root: dr} do
      {:ok, bad} =
        Config.parse(%{
          "name" => "B",
          "version" => "1",
          "slug" => "bad",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "x/y",
          "host_network" => true,
          "schema" => %{"port" => "port"},
          "options" => %{"port" => 70_000}
        })

      assert {:error, {:invalid_options, _}} =
               Manager.start(bad, backend: __MODULE__.FakeBackend, data_root: dr)

      refute_received {:create, _}
    end

    # The plumbing that makes protection mode real: without it `build_spec/2`
    # defaults `protected: true` forever and `POST /addons/{slug}/security` is
    # a setting nothing reads.
    test "start reads the stored `protected` and it reaches the spec", %{data_root: dr} do
      {:ok, cfg} =
        Config.parse(%{
          "name" => "Priv",
          "version" => "1",
          "slug" => "priv_addon",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "x/y",
          "host_network" => true,
          "full_access" => true,
          "host_pid" => true
        })

      :ok = State.put(cfg, :stopped)
      on_exit(fn -> State.delete("priv_addon") end)

      assert {:ok, _} = Manager.start(cfg, backend: __MODULE__.FakeBackend, data_root: dr)
      assert_received {:create, protected_spec}
      assert protected_spec.device_cgroup_rules == []
      assert protected_spec.pid_mode == nil

      :ok = State.put_setting("priv_addon", :protected, false)

      assert {:ok, _} = Manager.start(cfg, backend: __MODULE__.FakeBackend, data_root: dr)
      assert_received {:create, unprotected_spec}
      assert unprotected_spec.device_cgroup_rules == ["b *:* rwm", "c *:* rwm"]
      assert unprotected_spec.pid_mode == "host"
    end

    # `Update`/`DefaultProvider`/the install path all reach `do_start/2` with a
    # bare `Config` and no `:protected` opt — an explicit one must still win,
    # or the resolution would have to move a level up and those callers would
    # silently run protected.
    test "an explicit :protected opt wins over the stored value", %{data_root: dr} do
      {:ok, cfg} =
        Config.parse(%{
          "name" => "Priv2",
          "version" => "1",
          "slug" => "priv_addon_2",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "x/y",
          "host_network" => true,
          "full_access" => true
        })

      :ok = State.put(cfg, :stopped)
      :ok = State.put_setting("priv_addon_2", :protected, false)
      on_exit(fn -> State.delete("priv_addon_2") end)

      assert {:ok, _} =
               Manager.start(cfg,
                 backend: __MODULE__.FakeBackend,
                 data_root: dr,
                 protected: true
               )

      assert_received {:create, spec}
      assert spec.device_cgroup_rules == []
    end

    # `ensure_mount_sources/1` mkdir_p's every non-`system:` bind source, and
    # the `/data` assertion below is the control proving it ran at all — without
    # it, "the dsp dir wasn't created" would pass just as well if the whole
    # function had been skipped.
    #
    # Asserted as "the start did not CHANGE /usr/lib/dsp", not "/usr/lib/dsp
    # does not exist": this suite also runs on-board (phase 7 runs it with
    # `--include block_device`), and a dragon_q6a target ships that directory —
    # so an absence assertion would fail on the exact hardware the flag exists
    # for. The trade is honest rather than free: where the directory already
    # exists the `mkdir_p` would be a no-op and this degrades to a tautology.
    # It bites on every host that lacks it, which is dev and CI — and the spec
    # -level `system: true` assertion above is the one that holds everywhere.
    test "a dsp: true start creates its data dir but never mkdir_p's /usr/lib/dsp", %{
      data_root: dr
    } do
      dsp_existed? = File.exists?("/usr/lib/dsp")
      dsp_root = configure_dsp_root()
      File.mkdir_p!(dsp_root)
      File.write!(Path.join(dsp_root, "libQnnHtpV68Skel.so"), "")
      on_exit(fn -> File.rm_rf!(dsp_root) end)

      on_exit(fn -> State.delete("dsp_addon") end)

      assert {:ok, _} =
               Manager.start(cfg_dsp("dsp_addon"),
                 backend: __MODULE__.FakeBackend,
                 data_root: dr,
                 required_dsp_nodes: @host_dsp_nodes
               )

      assert File.dir?(Path.join([dr, "addons", "data", "dsp_addon"]))
      assert File.exists?("/usr/lib/dsp") == dsp_existed?

      # Nothing was written into the store either — the operator's file is the
      # only thing that belongs there.
      assert File.ls!(dsp_root) == ["libQnnHtpV68Skel.so"]
    end

    # The `system: true` half of the failure model, asserted where it is not a
    # tautology: the store path is one this test owns and deliberately did not
    # create, so "still absent" means `ensure_mount_sources/1` genuinely skipped
    # it. The `/data` dir is the control proving that function ran at all.
    test "a dsp: true start with nothing stored fails naming the panel", %{data_root: dr} do
      dsp_root = configure_dsp_root()
      refute File.exists?(dsp_root)
      on_exit(fn -> State.delete("dsp_unstored") end)

      assert {:error, {:dsp_not_configured, message}} =
               Manager.start(cfg_dsp("dsp_unstored"),
                 backend: __MODULE__.FakeBackend,
                 data_root: dr
               )

      assert message =~ "Vagus admin panel"

      assert File.dir?(Path.join([dr, "addons", "data", "dsp_unstored"]))
      refute File.exists?(dsp_root)
    end

    # The mount and the skel are both in place, so this isolates the device
    # nodes: without a cgroup rule for them the container starts and dies at
    # `ERROR 0x68` inside the add-on, which reads to an operator as the add-on
    # being broken rather than the board being wrong.
    test "a dsp: true start whose required node is missing fails naming it", %{data_root: dr} do
      dsp_root = configure_dsp_root()
      File.mkdir_p!(dsp_root)
      File.write!(Path.join(dsp_root, "libQnnHtpV68Skel.so"), "")
      on_exit(fn -> File.rm_rf!(dsp_root) end)
      on_exit(fn -> State.delete("dsp_nonode") end)

      assert {:error, {:dsp_devices_unavailable, message}} =
               Manager.start(cfg_dsp("dsp_nonode"),
                 backend: __MODULE__.FakeBackend,
                 data_root: dr,
                 required_dsp_nodes: ["/dev/null", "/dev/vagus-no-such-dsp-node"]
               )

      assert message =~ "/dev/vagus-no-such-dsp-node"
      # Only the unresolvable one is named — the sentence has to point at what
      # is actually absent.
      refute message =~ "/dev/null"
      refute_received {:create, _spec}
    end

    # The check is `dsp: true`'s alone: an add-on that never asked for the DSP
    # cannot be failed by a node it has no interest in.
    test "a dsp: false start ignores the same missing node", %{config: config, data_root: dr} do
      assert {:ok, _} =
               Manager.start(config,
                 backend: __MODULE__.FakeBackend,
                 data_root: dr,
                 required_dsp_nodes: ["/dev/vagus-no-such-dsp-node"]
               )

      assert_received {:create, _spec}
    end

    # Distinct from the above on purpose: nothing an operator uploads fixes a
    # board with no DSP, so the sentence must not send them to the panel. The
    # node list is deliberately unresolvable here too: a board with no DSP has
    # no fastrpc nodes either, and naming one would be a true answer to the
    # wrong question.
    test "a dsp: true start on a board with no DSP says so instead", %{data_root: dr} do
      put_dsp_root(nil)
      on_exit(fn -> State.delete("dsp_nodsp") end)

      assert {:error, {:dsp_unsupported, message}} =
               Manager.start(cfg_dsp("dsp_nodsp"),
                 backend: __MODULE__.FakeBackend,
                 data_root: dr,
                 required_dsp_nodes: ["/dev/vagus-no-such-dsp-node"]
               )

      assert message =~ "no Hexagon DSP"
    end

    # `Devices.cgroup_rules/3` guards on `is_boolean`, so a non-boolean reaching
    # it crashes the start outright. `put_setting/4` type-checks no key's value,
    # so the read end fails closed instead — the same rule
    # `State.decode_protected/1` applies to a corrupt file on disk.
    test "a non-boolean stored `protected` reads as protected, it does not crash the start", %{
      data_root: dr
    } do
      {:ok, cfg} =
        Config.parse(%{
          "name" => "Priv3",
          "version" => "1",
          "slug" => "priv_addon_3",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "x/y",
          "host_network" => true,
          "full_access" => true
        })

      :ok = State.put(cfg, :stopped)
      :ok = State.put_setting("priv_addon_3", :protected, "false")
      on_exit(fn -> State.delete("priv_addon_3") end)

      assert {:ok, _} = Manager.start(cfg, backend: __MODULE__.FakeBackend, data_root: dr)
      assert_received {:create, spec}
      assert spec.device_cgroup_rules == []
    end
  end

  describe "ingress dynamic port allocation (IW-P2-T2, §B3.2)" do
    setup do
      :persistent_term.put({__MODULE__.FakeBackend, :pid}, self())

      data_root =
        Path.join(System.tmp_dir!(), "vagus-mgr-ingress-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(data_root) end)

      {:ok, config} =
        Config.parse(%{
          "name" => "ESPHome",
          "version" => "1",
          "slug" => "ingress_addon",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "homeassistant/{arch}-addon-esphome",
          "host_network" => true,
          "ingress" => true,
          "ingress_port" => 0
        })

      on_exit(fn -> Vagus.Addon.State.delete("ingress_addon") end)

      %{config: config, data_root: data_root}
    end

    test "ingress_port: 0 add-on allocates + persists a dynamic port before create",
         %{config: config, data_root: dr} do
      # Mirrors the real install flow: `POST /addons/{slug}/install` calls
      # `State.put(config, :stopped)` right after `Manager.install/2` — the
      # State entry (and its ingress_token) must already exist before
      # `start/2` can allocate + persist a dynamic port against it.
      :ok = Vagus.Addon.State.put(config, :stopped)

      name = :"ingress_#{System.unique_integer([:positive])}"
      start_supervised!({Vagus.Ingress, name: name})

      assert {:ok, _} =
               Manager.start(config,
                 backend: __MODULE__.FakeBackend,
                 data_root: dr,
                 ingress_server: name
               )

      assert_received {:create, _spec}

      assert {:ok, %{ingress_port: port}} = Vagus.Addon.State.get("ingress_addon")
      assert is_integer(port) and port in 62_000..65_500
    end

    test "allocation failure (untracked slug, :not_found) fails the start before any create",
         %{config: config, data_root: dr} do
      name = :"ingress_#{System.unique_integer([:positive])}"
      start_supervised!({Vagus.Ingress, name: name})

      # No `State.put/2` here — the slug is untracked, so `dynamic_port/2`
      # has nowhere to persist an allocation.
      assert {:error, {:ingress_port, :not_found}} =
               Manager.start(config,
                 backend: __MODULE__.FakeBackend,
                 data_root: dr,
                 ingress_server: name
               )

      refute_received {:create, _}
    end

    test "ingress server not running: allocation is skipped silently (host unit tests)",
         %{config: config, data_root: dr} do
      :ok = Vagus.Addon.State.put(config, :stopped)

      assert {:ok, _} =
               Manager.start(config,
                 backend: __MODULE__.FakeBackend,
                 data_root: dr,
                 ingress_server: :no_such_ingress_process
               )

      assert_received {:create, _spec}
    end

    test "a non-ingress add-on never touches the ingress server", %{data_root: dr} do
      {:ok, plain} =
        Config.parse(%{
          "name" => "Plain",
          "version" => "1",
          "slug" => "plain_addon",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "homeassistant/{arch}-addon-plain",
          "host_network" => true
        })

      on_exit(fn -> Vagus.Addon.State.delete("plain_addon") end)

      assert {:ok, _} =
               Manager.start(plain,
                 backend: __MODULE__.FakeBackend,
                 data_root: dr,
                 ingress_server: :no_such_ingress_process
               )

      assert_received {:create, _spec}
    end
  end

  describe "stop/2, start_slug/2, restart/2, uninstall/2 (fake backend + real State/Registry/DNS)" do
    setup do
      :persistent_term.put({__MODULE__.FakeBackend, :pid}, self())

      data_root =
        Path.join(System.tmp_dir!(), "vagus-mgr-lifecycle-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(data_root) end)

      {:ok, config} =
        Config.parse(%{
          "name" => "Test",
          "version" => "3",
          "slug" => "life_addon",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "homeassistant/{arch}-addon-test",
          "host_network" => true
        })

      on_exit(fn ->
        Vagus.Addon.State.delete("life_addon")
        Vagus.Addon.Registry.unregister_slug("life_addon")
        if Process.whereis(Vagus.DNS), do: Vagus.DNS.unregister("life-addon")
      end)

      %{config: config, data_root: data_root}
    end

    test "stop on an unknown slug is :not_found" do
      assert {:error, :not_found} = Manager.stop("no-such-#{System.unique_integer([:positive])}")
    end

    test "stop: backend stop+remove called, State -> :stopped, registry/DNS deregistered",
         %{config: config, data_root: dr} do
      assert {:ok, _} = Manager.start(config, backend: __MODULE__.FakeBackend, data_root: dr)
      assert {:ok, %{state: :started}} = Vagus.Addon.State.get("life_addon")

      assert :ok = Manager.stop("life_addon", backend: __MODULE__.FakeBackend)
      assert_received {:stop, "addon_life_addon"}
      assert_received {:remove, "addon_life_addon"}

      assert {:ok, %{state: :stopped}} = Vagus.Addon.State.get("life_addon")
      assert :error = Vagus.Addon.Registry.identity_for_token("does-not-matter")
    end

    test "start_slug on an unknown slug is :not_found" do
      assert {:error, :not_found} =
               Manager.start_slug("no-such-#{System.unique_integer([:positive])}")
    end

    test "restart round-trip: new token, options.json rewritten", %{config: config, data_root: dr} do
      assert {:ok, %{access_token: token1}} =
               Manager.start(config, backend: __MODULE__.FakeBackend, data_root: dr)

      assert {:ok, %{access_token: token2}} =
               Manager.restart("life_addon", backend: __MODULE__.FakeBackend, data_root: dr)

      assert token1 != token2
      assert_received {:stop, "addon_life_addon"}
      assert_received {:remove, "addon_life_addon"}
      assert_received {:create, _spec}

      opts_path = Path.join([dr, "addons", "data", "life_addon", "options.json"])
      assert File.exists?(opts_path)
    end

    test "restart on an unknown slug is :not_found" do
      assert {:error, :not_found} =
               Manager.restart("no-such-#{System.unique_integer([:positive])}")
    end

    test "uninstall on an unknown slug is :not_found" do
      assert {:error, :not_found} =
               Manager.uninstall("no-such-#{System.unique_integer([:positive])}")
    end

    test "uninstall purges State + the data dir", %{
      config: config,
      data_root: dr
    } do
      assert {:ok, _} = Manager.start(config, backend: __MODULE__.FakeBackend, data_root: dr)
      data_dir = Path.join([dr, "addons", "data", "life_addon"])
      assert File.dir?(data_dir)

      assert :ok = Manager.uninstall("life_addon", backend: __MODULE__.FakeBackend, data_root: dr)

      refute File.exists?(data_dir)
      assert :error = Vagus.Addon.State.get("life_addon")
    end

    test "uninstall refuses to rm_rf outside the data dir for a slug that fails the safety check",
         %{data_root: dr} do
      hostile = %Config{
        name: "Hostile",
        version: "1",
        slug: "../evil",
        description: "d",
        arch: ["amd64"],
        image: "x/y"
      }

      :ok = Vagus.Addon.State.put(hostile, :stopped)
      on_exit(fn -> Vagus.Addon.State.delete("../evil") end)

      # `<data_root>/addons/data/../evil` resolves to `<data_root>/addons/evil`
      # — this is exactly what an unguarded rm_rf would delete.
      escape_dir = Path.join(dr, "addons/evil")
      File.mkdir_p!(escape_dir)
      sentinel = Path.join(escape_dir, "sentinel.txt")
      File.write!(sentinel, "keep me")

      assert {:error, _reason} =
               Manager.uninstall("../evil", backend: __MODULE__.FakeBackend, data_root: dr)

      assert File.exists?(sentinel)
    end

    # W3: `Config`'s own slug charset permits a bare `..` (and `.`) as a
    # token — the shared `Config.valid_slug?/1` guard must reject those
    # explicitly, not just rely on the charset (which the old lowercase-only
    # regex here happened to reject only because it also excluded `.`).
    test "uninstall refuses to rm_rf outside the data dir for the bare slug \"..\"",
         %{data_root: dr} do
      hostile = %Config{
        name: "Hostile",
        version: "1",
        slug: "..",
        description: "d",
        arch: ["amd64"],
        image: "x/y"
      }

      :ok = Vagus.Addon.State.put(hostile, :stopped)
      on_exit(fn -> Vagus.Addon.State.delete("..") end)

      # `<data_root>/addons/data/..` resolves to `<data_root>/addons` itself
      # — this is exactly what an unguarded rm_rf would delete.
      addons_dir = Path.join(dr, "addons")
      File.mkdir_p!(addons_dir)
      sentinel = Path.join(addons_dir, "sentinel.txt")
      File.write!(sentinel, "keep me")

      assert {:error, _reason} =
               Manager.uninstall("..", backend: __MODULE__.FakeBackend, data_root: dr)

      assert File.exists?(sentinel)
    end
  end

  describe "ingress panel push on lifecycle transitions (IW-P2-T3, §B4.4)" do
    # `Vagus.Ingress.Panels.update_hass_panel/2` is best-effort by design
    # (fire-and-forget `Task.start/1`, warning-not-raise on failure — see
    # that module's tests for the push semantics themselves). What matters
    # here is *which* lifecycle ops push at all: only uninstall does.
    #
    # start/stop deliberately don't, and that is load-bearing rather than an
    # optimisation: the P2-A device gate caught Core answering a push for an
    # already-registered panel with 500 + `ValueError: Overwriting panel` and
    # an ERROR traceback, because HA's `_register_panel` omits `update=True`.
    # Upstream pushes only on options-change, uninstall, and
    # restore-when-the-flag-moved. See `maybe_push_panel/2`'s comment.
    setup do
      :persistent_term.put({__MODULE__.FakeBackend, :pid}, self())

      data_root =
        Path.join(System.tmp_dir!(), "vagus-mgr-panel-push-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(data_root) end)

      {:ok, config} =
        Config.parse(%{
          "name" => "ESPHome",
          "version" => "1",
          "slug" => "panel_push_addon",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "homeassistant/{arch}-addon-esphome",
          "host_network" => true,
          "ingress" => true
        })

      on_exit(fn ->
        Vagus.Addon.State.delete("panel_push_addon")
        Vagus.Addon.Registry.unregister_slug("panel_push_addon")
      end)

      %{config: config, data_root: data_root}
    end

    test "start, stop, and uninstall of an ingress add-on all succeed without crashing",
         %{config: config, data_root: dr} do
      assert {:ok, _} = Manager.start(config, backend: __MODULE__.FakeBackend, data_root: dr)
      assert :ok = Manager.stop("panel_push_addon", backend: __MODULE__.FakeBackend)

      assert {:ok, _} =
               Manager.start_slug("panel_push_addon",
                 backend: __MODULE__.FakeBackend,
                 data_root: dr
               )

      assert :ok =
               Manager.uninstall("panel_push_addon",
                 backend: __MODULE__.FakeBackend,
                 data_root: dr
               )
    end

    test "only uninstall pushes: start, stop and start_slug leave Core's panel list alone",
         %{config: config, data_root: dr} do
      opts = [backend: __MODULE__.FakeBackend, data_root: dr, panels: __MODULE__.PanelSpy]
      :persistent_term.put({__MODULE__.PanelSpy, :pid}, self())

      assert {:ok, _} = Manager.start(config, opts)
      assert :ok = Manager.stop("panel_push_addon", opts)
      assert {:ok, _} = Manager.start_slug("panel_push_addon", opts)

      refute_received {:panel_push, _}

      assert :ok = Manager.uninstall("panel_push_addon", opts)
      assert_received {:panel_push, "panel_push_addon"}
    end

    test "a non-ingress add-on doesn't push even on uninstall", %{data_root: dr} do
      {:ok, plain} =
        Config.parse(%{
          "name" => "Plain",
          "version" => "1",
          "slug" => "panel_push_plain",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "homeassistant/{arch}-addon-plain",
          "host_network" => true
        })

      on_exit(fn -> Vagus.Addon.State.delete("panel_push_plain") end)

      opts = [backend: __MODULE__.FakeBackend, data_root: dr, panels: __MODULE__.PanelSpy]
      :persistent_term.put({__MODULE__.PanelSpy, :pid}, self())

      assert {:ok, _} = Manager.start(plain, opts)
      assert :ok = Manager.uninstall("panel_push_plain", opts)

      refute_received {:panel_push, _}
    end
  end

  describe "W6 — record-:stopped-before-container-touch + per-slug serialization" do
    setup do
      slug = "w6_addon_#{System.unique_integer([:positive])}"
      :persistent_term.put({__MODULE__.OrderingBackend, :pid}, self())

      data_root =
        Path.join(System.tmp_dir!(), "vagus-mgr-w6-#{System.unique_integer([:positive])}")

      on_exit(fn ->
        File.rm_rf(data_root)
        Vagus.Addon.State.delete(slug)
        Vagus.Addon.Registry.unregister_slug(slug)
      end)

      {:ok, config} =
        Config.parse(%{
          "name" => "Test",
          "version" => "1",
          "slug" => slug,
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "homeassistant/{arch}-addon-test",
          "host_network" => true
        })

      %{config: config, slug: slug, data_root: data_root}
    end

    test "stop/2 records State :stopped before the container is touched", %{
      config: config,
      slug: slug,
      data_root: dr
    } do
      assert {:ok, _} = Manager.start(config, backend: __MODULE__.OrderingBackend, data_root: dr)

      assert :ok = Manager.stop(slug, backend: __MODULE__.OrderingBackend)

      assert_received {:stop_saw_state, {:ok, %{state: :stopped}}}
    end

    test "uninstall/2 records State :stopped before the container is touched", %{
      config: config,
      slug: slug,
      data_root: dr
    } do
      assert {:ok, _} = Manager.start(config, backend: __MODULE__.OrderingBackend, data_root: dr)

      assert :ok = Manager.uninstall(slug, backend: __MODULE__.OrderingBackend, data_root: dr)

      assert_received {:stop_saw_state, {:ok, %{state: :stopped}}}
    end

    test "concurrent restart/2 and stop/2 for the same slug never interleave", %{
      config: config,
      slug: slug,
      data_root: dr
    } do
      log = :ets.new(:w6_serial_log, [:public, :ordered_set])
      :persistent_term.put({__MODULE__.SlowBackend, :log}, log)

      assert {:ok, _} = Manager.start(config, backend: __MODULE__.SlowBackend, data_root: dr)

      # Only the two concurrent ops below matter for the interleaving
      # assertion — the setup start above also logs (untagged) `stop`/
      # `create` entries via `remove_stale_container/2`'s stale-container
      # cleanup, which would otherwise show up as a spurious third chunk.
      :ets.delete_all_objects(log)

      restart_task =
        Task.async(fn ->
          Process.put(:w6_log_tag, :restart)
          Manager.restart(slug, backend: __MODULE__.SlowBackend, data_root: dr)
        end)

      # Give the restart task a moment to acquire the slug lock and enter
      # its stop's sleep, so the concurrent stop below deterministically
      # queues behind it instead of racing to go first — either order is
      # fine for what's being proven (no interleaving), this just keeps the
      # test from being a coin flip about which op logs first.
      Process.sleep(5)

      stop_task =
        Task.async(fn ->
          Process.put(:w6_log_tag, :stop)
          Manager.stop(slug, backend: __MODULE__.SlowBackend)
        end)

      Task.await(restart_task, 5_000)
      Task.await(stop_task, 5_000)

      tags =
        log
        |> :ets.tab2list()
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {_seq, {tag, _event, _id}} -> tag end)

      :ets.delete(log)

      # Serialized: one op's entries are entirely contiguous before the
      # other's — chunk_by collapses consecutive same-tag runs, so any
      # interleaving (tag alternating more than once) would produce more
      # than 2 chunks.
      assert tags |> Enum.chunk_by(& &1) |> length() == 2
    end
  end

  describe "registration with the application's Registry and a default-named DNS" do
    # Wide enough that bringing the server back always lands inside it; a
    # start that finds its server returns at once.
    @slack_retry {2_000, 5}
    @tiny_retry {2, 1}
    # Outlasts any hold a test keeps on a stubbed call.
    @held_call_timeout 60_000

    setup do
      :persistent_term.put({__MODULE__.OrderingBackend, :pid}, self())
      slug = "registration_#{System.unique_integer([:positive])}"

      data_root =
        Path.join(
          System.tmp_dir!(),
          "vagus-mgr-registration-#{System.unique_integer([:positive])}"
        )

      # Native, so its DNS record needs no Docker inspect.
      {:ok, config} =
        Config.parse(%{
          "name" => "Test",
          "version" => "1",
          "slug" => slug,
          "description" => "d",
          "arch" => ["amd64"],
          "backend" => "native"
        })

      on_exit(fn ->
        File.rm_rf(data_root)
        State.delete(slug)
        Vagus.Addon.Registry.unregister_slug(slug)
      end)

      %{
        config: config,
        slug: slug,
        id: "addon_#{slug}",
        host: String.replace(slug, "_", "-"),
        opts: [backend: __MODULE__.OrderingBackend, data_root: data_root]
      }
    end

    # Holds `name` like the real server: reports each call to the test, then
    # replies with `handler`'s `{:reply, term}`, stays silent on `:noreply`,
    # or goes down mid-call when `handler` exits.
    defp stub_server(name, handler) do
      test = self()
      pid = spawn(fn -> stub_loop(test, name, handler) end)
      Process.register(pid, name)
      on_exit(fn -> kill(pid) end)
      pid
    end

    defp stub_loop(test, name, handler) do
      receive do
        {:"$gen_call", from, request} ->
          send(test, {:stub_call, name, request})

          case handler.(request) do
            {:reply, reply} -> GenServer.reply(from, reply)
            :noreply -> :ok
          end

          stub_loop(test, name, handler)

        {:sync, from} ->
          send(from, {:synced, self()})
          stub_loop(test, name, handler)
      end
    end

    # The stub takes its mailbox in order, so once it answers, every call
    # sent to it before this one has been reported to the test.
    defp sync(stub) do
      send(stub, {:sync, self()})
      assert_receive {:synced, ^stub}, 5_000
    end

    # Holds `name` like a server that goes down with `reason` on every call
    # and is restarted. The successor has the name before the caller sees the
    # exit, so each of the caller's attempts reaches a stub. Cleaned up by
    # `bring_registry_up/0`, so only for the Registry's name.
    defp dying_server(name, reason) do
      test = self()
      Process.register(spawn(fn -> dying_loop(test, name, reason) end), name)
    end

    defp dying_loop(test, name, reason) do
      receive do
        {:"$gen_call", _from, request} ->
          send(test, {:stub_call, name, request})
          Process.unregister(name)
          Process.register(spawn(fn -> dying_loop(test, name, reason) end), name)
          exit(reason)
      end
    end

    defp stub_calls(name) do
      for {:stub_call, ^name, request} <- drain(), do: elem(request, 0)
    end

    # A dead process has released its name by the time its monitor fires.
    defp await_down(pid) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    end

    defp kill(pid) do
      Process.exit(pid, :kill)
      await_down(pid)
    end

    # terminate + restart, never a kill: a kill counts toward
    # `Vagus.Supervisor`'s restart intensity, and exceeding it stops the app.
    defp take_registry_down, do: take_down(Vagus.Addon.Registry)
    defp bring_registry_up, do: bring_up(Vagus.Addon.Registry)
    defp cycle_registry, do: cycle(Vagus.Addon.Registry)

    defp take_down(child) do
      :ok = Supervisor.terminate_child(Vagus.Supervisor, child)
      on_exit(fn -> bring_up(child) end)
    end

    defp bring_up(child) do
      case Supervisor.restart_child(Vagus.Supervisor, child) do
        {:ok, _pid} ->
          :ok

        {:error, :running} ->
          :ok

        {:error, {:already_started, stub}} ->
          kill(stub)
          bring_up(child)
      end
    end

    defp cycle(child) do
      :ok = Supervisor.terminate_child(Vagus.Supervisor, child)
      bring_up(child)
    end

    # The default-named DNS checkpoints, so a file from an earlier test would
    # hand its records to the one started here.
    defp enable_dns do
      prev = Application.get_env(:vagus, :dns_enabled)
      Application.put_env(:vagus, :dns_enabled, true)
      File.rm(Vagus.RunState.path(:dns))

      on_exit(fn ->
        Application.put_env(:vagus, :dns_enabled, prev)
        File.rm(Vagus.RunState.path(:dns))
      end)
    end

    defp start_dns do
      {:ok, sock} = :gen_udp.open(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(sock)
      :gen_udp.close(sock)

      start_supervised!(
        {Vagus.DNS, name: Vagus.DNS, ip: {127, 0, 0, 1}, port: port, upstream: nil}
      )
    end

    # The Watchdog only restarts an add-on whose `watchdog` setting is on.
    defp watch(config) do
      :ok = State.put(config, :stopped)
      :ok = State.put_setting(config.slug, :watchdog, true)
    end

    defp start_watchdog(watchdog_opts \\ []) do
      :persistent_term.put({__MODULE__.WatchdogSpy, :pid}, self())

      start_supervised!(
        {Vagus.Addon.Watchdog,
         [name: nil, manager: __MODULE__.WatchdogSpy, running_check: fn _slug -> false end]
         |> Keyword.merge(watchdog_opts)}
      )
    end

    defp die_event(id) do
      {:docker_event,
       %{action: "die", name: id, id: "id", exit_code: 137, time_nano: 0, attributes: %{}}}
    end

    defp drain(acc \\ []) do
      receive do
        message -> drain([message | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    # A start first stops and removes any stale same-name container, so only
    # the backend calls after the create belong to the start's own cleanup.
    defp split_at_create(messages) do
      {_stale, [{:create, spec} | after_create]} =
        Enum.split_while(messages, &(not match?({:create, _spec}, &1)))

      {spec, after_create}
    end

    test "start/2 waits out a Registry that is briefly absent", %{
      config: c,
      slug: slug,
      opts: opts
    } do
      take_registry_down()
      stub = stub_server(Vagus.Addon.Registry, fn _request -> exit(:shutdown) end)

      start = Task.async(fn -> Manager.start(c, [register_retry: @slack_retry] ++ opts) end)

      assert_receive {:stub_call, Vagus.Addon.Registry, {:register, token, _identity}}, 5_000
      await_down(stub)
      bring_registry_up()

      assert {:ok, %{access_token: ^token}} = Task.await(start, 60_000)
      assert {:ok, %{slug: ^slug}} = Vagus.Addon.Registry.identity_for_token(token)
    end

    test "start/2 gives up on an absent Registry: the add-on is stopped and the token stays out of the log",
         %{config: c, slug: slug, id: id, opts: opts} do
      :ok = State.put(c, :stopped)
      take_registry_down()

      {result, log} =
        with_log(fn ->
          Manager.start(c, [register_retry: @tiny_retry, deregister_retry: @tiny_retry] ++ opts)
        end)

      assert {:error, {:registration_failed, :registry}} = result

      {spec, after_create} = split_at_create(drain())
      assert [{:stop_saw_state, {:ok, %{state: :stopped}}}, {:remove, ^id}] = after_create
      assert {:ok, %{state: :stopped}} = State.get(slug)

      # The exit reason of a failed call carries the call's arguments.
      assert log =~ "Registry register for #{slug} failed: noproc"
      assert log =~ "Registry unregister for #{slug} failed (noproc)"
      refute log =~ spec.env["SUPERVISOR_TOKEN"]
    end

    # A failed registration is no verdict on whether the add-on should run:
    # `:stopped` would end the Watchdog's retries and survive a reboot.
    test "a failed registration leaves an add-on that was :started as :started", %{
      config: c,
      slug: slug,
      id: id,
      opts: opts
    } do
      :ok = State.put(c, :started)
      # Enabled with no server: the Registry takes the token, then DNS fails.
      enable_dns()

      {result, _log} = with_log(fn -> Manager.start(c, [register_retry: @tiny_retry] ++ opts) end)

      assert {:error, {:registration_failed, :dns}} = result

      {spec, after_create} = split_at_create(drain())
      assert [{:stop_saw_state, {:ok, %{state: :stopped}}}, {:remove, ^id}] = after_create
      assert {:ok, %{state: :started}} = State.get(slug)
      assert :error = Vagus.Addon.Registry.identity_for_token(spec.env["SUPERVISOR_TOKEN"])
    end

    test "the Watchdog's next attempt follows a failed registration, and succeeds", %{
      config: c,
      slug: slug,
      id: id,
      opts: opts
    } do
      test = self()
      watch(c)
      :ok = State.put(c, :started)
      take_registry_down()

      :persistent_term.put(
        {__MODULE__.RetryingManager, :opts},
        [register_retry: @tiny_retry] ++ opts
      )

      # Parks the sequence between attempts until the Registry is back.
      park = fn ms ->
        send(test, {:backoff, self(), ms})

        receive do
          :resume -> :ok
        end
      end

      with_log(fn ->
        watchdog =
          start_watchdog(manager: __MODULE__.RetryingManager, sleep: park, backoff_base_ms: 1)

        send(watchdog, die_event(id))

        assert_receive {:watchdog_started, ^slug, {:error, {:registration_failed, :registry}}},
                       5_000

        assert_receive {:backoff, sequence, 1}, 5_000
        assert {:ok, %{state: :started}} = State.get(slug)
        bring_registry_up()
        send(sequence, :resume)

        assert_receive {:watchdog_started, ^slug, {:ok, %{access_token: token}}}, 5_000
        assert {:ok, %{slug: ^slug}} = Vagus.Addon.Registry.identity_for_token(token)
        assert {:ok, %{state: :started}} = State.get(slug)
      end)
    end

    # A call that crashes its server would otherwise spend one of
    # `Vagus.Supervisor`'s restarts per attempt.
    test "a call that crashes the Registry is retried once, not for the whole budget", %{
      config: c,
      opts: opts
    } do
      take_registry_down()
      dying_server(Vagus.Addon.Registry, :boom)

      {result, log} = with_log(fn -> Manager.start(c, [register_retry: {50, 1}] ++ opts) end)

      assert {:error, {:registration_failed, :registry}} = result
      assert log =~ "failed: server_down"

      assert stub_calls(Vagus.Addon.Registry) ==
               [:register, :register, :unregister_slug, :unregister_slug]
    end

    # The failed server has had the register budget already, and all of it is
    # spent under the slug lock.
    test "a start that gives up deregisters on the register budget", %{config: c, opts: opts} do
      take_registry_down()
      dying_server(Vagus.Addon.Registry, :shutdown)

      {result, _log} =
        with_log(fn ->
          Manager.start(c, [register_retry: {3, 1}, deregister_retry: {7, 1}] ++ opts)
        end)

      assert {:error, {:registration_failed, :registry}} = result

      assert stub_calls(Vagus.Addon.Registry) ==
               List.duplicate(:register, 3) ++ List.duplicate(:unregister_slug, 3)
    end

    test "an add-on whose registration is still in flight is :started, so its die is acted on", %{
      config: c,
      slug: slug,
      id: id,
      opts: opts
    } do
      watch(c)
      take_registry_down()

      stub =
        stub_server(Vagus.Addon.Registry, fn {:register, _token, _identity} ->
          receive do
            :release -> {:reply, :ok}
          end
        end)

      start =
        Task.async(fn ->
          Manager.start(c, [registration_call_timeout: @held_call_timeout] ++ opts)
        end)

      assert_receive {:stub_call, Vagus.Addon.Registry, {:register, token, _identity}}, 5_000

      assert {:ok, %{state: :started}} = State.get(slug)
      send(start_watchdog(), die_event(id))
      assert_receive {:watchdog_start_slug, ^slug}, 5_000

      send(stub, :release)
      assert {:ok, %{access_token: ^token}} = Task.await(start, @held_call_timeout)
    end

    test "start/2 waits out a DNS that is briefly absent", %{
      config: c,
      slug: slug,
      host: host,
      opts: opts
    } do
      enable_dns()
      stub = stub_server(Vagus.DNS, fn _request -> exit(:shutdown) end)

      start = Task.async(fn -> Manager.start(c, [register_retry: @slack_retry] ++ opts) end)

      assert_receive {:stub_call, Vagus.DNS, {:register, ^host, _ip}}, 5_000
      await_down(stub)
      start_dns()

      assert {:ok, %{access_token: token}} = Task.await(start, 60_000)
      assert {:ok, {172, 30, 32, 2}} = Vagus.DNS.resolve(host, Vagus.DNS)
      assert {:ok, %{slug: ^slug}} = Vagus.Addon.Registry.identity_for_token(token)
    end

    test "start/2 gives up on an absent DNS and revokes the token it had registered", %{
      config: c,
      slug: slug,
      id: id,
      host: host,
      opts: opts
    } do
      enable_dns()

      stub =
        stub_server(Vagus.DNS, fn _request ->
          receive do
            :go_down -> exit(:shutdown)
          end
        end)

      start =
        Task.async(fn ->
          with_log(fn ->
            Manager.start(
              c,
              [
                register_retry: @tiny_retry,
                deregister_retry: @tiny_retry,
                registration_call_timeout: @held_call_timeout
              ] ++ opts
            )
          end)
        end)

      assert_receive {:create, spec}, 5_000
      assert_receive {:stub_call, Vagus.DNS, {:register, ^host, _ip}}, 5_000
      token = spec.env["SUPERVISOR_TOKEN"]
      assert {:ok, %{slug: ^slug}} = Vagus.Addon.Registry.identity_for_token(token)
      _stale_container_calls = drain()

      send(stub, :go_down)
      {result, log} = Task.await(start, @held_call_timeout)

      assert {:error, {:registration_failed, :dns}} = result
      assert [{:stop_saw_state, {:ok, %{state: :stopped}}}, {:remove, ^id}] = drain()
      assert {:ok, %{state: :stopped}} = State.get(slug)
      assert :error = Vagus.Addon.Registry.identity_for_token(token)
      assert log =~ "DNS register for #{slug} failed: noproc"
      refute log =~ token
    end

    # Each retry of a call that timed out would hold the slug lock for
    # another full call timeout.
    @tag :capture_log
    test "a registration call that times out is not retried", %{config: c, opts: opts} do
      take_registry_down()
      stub = stub_server(Vagus.Addon.Registry, fn _request -> :noreply end)

      result =
        Manager.start(c, [registration_call_timeout: 100, register_retry: {5, 1}] ++ opts)

      assert {:error, {:registration_failed, :registry}} = result

      sync(stub)
      assert stub_calls(Vagus.Addon.Registry) == [:register, :unregister_slug]
    end

    test "stop/2 waits out a Registry that is briefly absent, and the token stays revoked", %{
      config: c,
      slug: slug,
      opts: opts
    } do
      assert {:ok, %{access_token: token}} = Manager.start(c, opts)
      assert {:ok, %{slug: ^slug}} = Vagus.Addon.Registry.identity_for_token(token)

      take_registry_down()
      stub = stub_server(Vagus.Addon.Registry, fn _request -> exit(:shutdown) end)

      stop = Task.async(fn -> Manager.stop(slug, [deregister_retry: @slack_retry] ++ opts) end)

      assert_receive {:stub_call, Vagus.Addon.Registry, {:unregister_slug, ^slug}}, 5_000
      await_down(stub)
      # Comes back holding the token: its checkpoint predates the unregister.
      bring_registry_up()

      assert :ok = Task.await(stop, 60_000)
      assert :error = Vagus.Addon.Registry.identity_for_token(token)

      cycle_registry()
      assert :error = Vagus.Addon.Registry.identity_for_token(token)
    end

    test "stop/2 still succeeds when the Registry stays absent, and logs the token left valid",
         %{config: c, slug: slug, opts: opts} do
      assert {:ok, %{access_token: token}} = Manager.start(c, opts)
      take_registry_down()

      {result, log} =
        with_log(fn -> Manager.stop(slug, [deregister_retry: @tiny_retry] ++ opts) end)

      assert result == :ok
      assert {:ok, %{state: :stopped}} = State.get(slug)
      assert log =~ "[error] Vagus.Addon.Manager: Registry unregister for #{slug} failed (noproc)"
      refute log =~ token
    end

    test "uninstall/2 waits out a Registry that is briefly absent, and the token is revoked", %{
      config: c,
      slug: slug,
      opts: opts
    } do
      assert {:ok, %{access_token: token}} = Manager.start(c, opts)

      take_registry_down()
      stub = stub_server(Vagus.Addon.Registry, fn _request -> exit(:shutdown) end)

      uninstall =
        Task.async(fn -> Manager.uninstall(slug, [deregister_retry: @slack_retry] ++ opts) end)

      assert_receive {:stub_call, Vagus.Addon.Registry, {:unregister_slug, ^slug}}, 5_000
      await_down(stub)
      bring_registry_up()

      assert :ok = Task.await(uninstall, 60_000)
      assert :error = Vagus.Addon.Registry.identity_for_token(token)
      assert :error = State.get(slug)
    end

    test "uninstall/2 deregisters on its caller's retry budget", %{
      config: c,
      slug: slug,
      opts: opts
    } do
      assert {:ok, _started} = Manager.start(c, opts)

      take_registry_down()
      dying_server(Vagus.Addon.Registry, :shutdown)
      _start_calls = drain()

      {result, _log} =
        with_log(fn -> Manager.uninstall(slug, [deregister_retry: {3, 1}] ++ opts) end)

      assert result == :ok
      assert stub_calls(Vagus.Addon.Registry) == List.duplicate(:unregister_slug, 3)
    end
  end

  defmodule OrderingBackend do
    @moduledoc false
    @behaviour Vagus.Addon.Backend

    @impl true

    def remove_image(_image, _opts \\ []), do: :ok

    defp notify(msg),
      do: send(:persistent_term.get({Vagus.Addon.ManagerTest.OrderingBackend, :pid}), msg)

    @impl true
    def pull(_spec), do: :ok

    @impl true
    def create(spec) do
      notify({:create, spec})
      {:ok, "fake-id"}
    end

    @impl true
    def start(_id), do: :ok

    @impl true
    def stop(id, _opts \\ []) do
      slug = String.replace_prefix(id, "addon_", "")
      notify({:stop_saw_state, Vagus.Addon.State.get(slug)})
      :ok
    end

    @impl true
    def remove(id, _opts \\ []) do
      notify({:remove, id})
      :ok
    end

    @impl true
    def state(_id), do: {:ok, :running}
  end

  defmodule SlowBackend do
    @moduledoc false
    @behaviour Vagus.Addon.Backend

    @impl true

    def remove_image(_image, _opts \\ []), do: :ok

    defp log(entry) do
      table = :persistent_term.get({Vagus.Addon.ManagerTest.SlowBackend, :log})
      tag = Process.get(:w6_log_tag, :unknown)

      :ets.insert(
        table,
        {System.unique_integer([:monotonic]), {tag, elem(entry, 0), elem(entry, 1)}}
      )
    end

    @impl true
    def pull(_spec), do: :ok

    @impl true
    def create(spec) do
      log({:create, spec.name})
      {:ok, "fake-id"}
    end

    @impl true
    def start(_id), do: :ok

    @impl true
    def stop(id, _opts \\ []) do
      log({:stop_start, id})
      Process.sleep(30)
      log({:stop_end, id})
      :ok
    end

    @impl true
    def remove(_id, _opts \\ []), do: :ok

    @impl true
    def state(_id), do: {:ok, :running}
  end

  defmodule FakeBackend do
    @behaviour Vagus.Addon.Backend

    @impl true

    def remove_image(_image, _opts \\ []), do: :ok

    defp notify(msg),
      do: send(:persistent_term.get({Vagus.Addon.ManagerTest.FakeBackend, :pid}), msg)

    @impl true
    def pull(spec), do: notify({:pull, spec}) && :ok

    @impl true
    def create(spec) do
      notify({:create, spec})
      {:ok, "fake-id"}
    end

    @impl true
    def start(id), do: notify({:start, id}) && :ok

    @impl true
    def stop(id, _opts \\ []), do: notify({:stop, id}) && :ok

    @impl true
    def remove(id, _opts \\ []), do: notify({:remove, id}) && :ok

    @impl true
    def state(_id), do: {:ok, :running}
  end

  defmodule WatchdogSpy do
    @moduledoc false
    def start_slug(slug, _opts) do
      send(:persistent_term.get({__MODULE__, :pid}), {:watchdog_start_slug, slug})
      {:ok, %{}}
    end
  end

  # The Watchdog calls `start_slug(slug, [])`; this is the real Manager with
  # the test's backend and retry budget, reporting each attempt's result.
  defmodule RetryingManager do
    @moduledoc false
    def start_slug(slug, _opts) do
      result = Vagus.Addon.Manager.start_slug(slug, :persistent_term.get({__MODULE__, :opts}))

      send(
        :persistent_term.get({Vagus.Addon.ManagerTest.WatchdogSpy, :pid}),
        {:watchdog_started, slug, result}
      )

      result
    end
  end

  # Stands in for `Vagus.Ingress.Panels` via `Manager`'s `:panels` opt — the
  # same module-seam style as `:backend`. The real module's push semantics
  # (POST vs DELETE, unreachable-Core tolerance) are covered in
  # `Vagus.Ingress.PanelsTest`; all this needs to report is *whether* a
  # lifecycle op reached it at all.
  defmodule PanelSpy do
    @moduledoc false
    def update_hass_panel(slug) do
      send(:persistent_term.get({__MODULE__, :pid}), {:panel_push, slug})
      :ok
    end
  end
end
