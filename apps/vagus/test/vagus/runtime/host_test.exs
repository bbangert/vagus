defmodule Vagus.Runtime.HostTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.Runtime.Host
  alias Vagus.Runtime.Podman.Cmd
  alias Vagus.Test.FakePodman

  @gib_kb 1024 * 1024

  setup do
    root = Path.join(System.tmp_dir!(), "vagus-host-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, name: :"host_#{System.unique_integer([:positive])}"}
  end

  defp mountinfo(root, lines) do
    path = Path.join(root, "mountinfo-#{System.unique_integer([:positive])}")
    File.write!(path, lines)
    path
  end

  defp meminfo(root, kb) do
    path = Path.join(root, "meminfo-#{kb}")
    File.write!(path, "MemTotal:       #{kb} kB\nMemFree:        1000 kB\n")
    path
  end

  # Every step reports to the test, so their order is the mailbox's.
  defp host_opts(ctx, extra \\ []) do
    test = self()

    [
      name: ctx.name,
      graphroot: Path.join(ctx.root, "storage"),
      run_dir: Path.join(ctx.root, "run/vagus/podman"),
      meminfo: meminfo(ctx.root, 1 * @gib_kb),
      profile_override: Path.join(ctx.root, "podman-profile"),
      socket_dir: Path.join(ctx.root, "run/supervisor"),
      resolv_conf: Path.join(ctx.root, "resolv.conf"),
      log_dir: Path.join(ctx.root, "run/vagus/logs"),
      mountinfo: mountinfo(ctx.root, ""),
      name_servers: fn -> [{192, 168, 2, 1}] end,
      run: fn bin, args ->
        send(test, {:step, {bin, args}})
        {"", 0}
      end,
      probe: fn _opts ->
        send(test, {:step, :probe})
        :ok
      end,
      shutting_down?: fn -> false end,
      # A tree with no balena in it: no migration.
      migration: migration_paths(ctx.root)
    ]
    |> Keyword.merge(extra)
  end

  defp migration_paths(root) do
    [
      legacy_root: Path.join(root, "root/balena-engine"),
      marker: Path.join(root, "root/vagus/engine-migrated"),
      config_dir: Path.join(root, "root/vagus/core/config"),
      mountinfo: Path.join(root, "no-mounts")
    ]
  end

  defp start_host(ctx, extra \\ []) do
    start_supervised!({Host, host_opts(ctx, extra)})
    await_ready(ctx.name)
  end

  # The first answer other than :preparing, or :ok when `until_ok`.
  defp await_ready(name, until_ok \\ false) do
    Enum.find_value(1..1_000, fn _ ->
      case Host.ready(name) do
        {:error, :preparing} -> Process.sleep(10) && nil
        :ok -> :ok
        _other when until_ok -> Process.sleep(10) && nil
        other -> other
      end
    end) || flunk("Host #{name} never answered")
  end

  # Neither the machine's meminfo nor its override file.
  defp profile_opts(root, extra),
    do: [profile_override: Path.join(root, "no-override")] ++ extra

  describe "preparation" do
    test "runs its steps in order, then is ready", ctx do
      assert start_host(ctx) == :ok
      assert_receive {:step, {"mount", ["--make-rshared", "/"]}}, 5_000
      assert_receive {:step, :probe}, 5_000

      for dir <- ["run/supervisor", "run/vagus/logs"] do
        assert File.stat!(Path.join(ctx.root, dir)).mode |> Bitwise.band(0o777) == 0o700
      end

      assert File.read!(Path.join(ctx.root, "resolv.conf")) == "nameserver 192.168.2.1\n"
      assert File.dir?(Path.join(ctx.root, "storage/tmp"))
    end

    test "the probe runs last: every file is in place when podman first runs", ctx do
      test = self()
      run_dir = Path.join(ctx.root, "run/vagus/podman")

      probe = fn _opts ->
        send(
          test,
          {:at_probe, File.exists?(Path.join(run_dir, "containers.conf")),
           File.dir?(Path.join(ctx.root, "storage/tmp")),
           File.exists?(Path.join(ctx.root, "resolv.conf"))}
        )

        :ok
      end

      start_host(ctx, probe: probe)
      assert_receive {:at_probe, true, true, true}, 5_000
    end

    test "is :preparing until the probe answers", ctx do
      test = self()

      probe = fn _opts ->
        send(test, {:probing, self()})
        receive do: (:go -> :ok)
      end

      start_supervised!({Host, host_opts(ctx, probe: probe)})
      assert_receive {:probing, prober}, 5_000
      assert Host.ready(ctx.name) == {:error, :preparing}
      # The probe runs off the Host, which keeps granting permits meanwhile.
      assert {:ok, _} = Host.checkout(ctx.name, :ops, 5_000)
      send(prober, :go)
      assert await_ready(ctx.name) == :ok
    end

    test "a failed probe is {:prep_failed, reason} and is retried", ctx do
      test = self()
      {:ok, agent} = Agent.start_link(fn -> [{:error, :unavailable}, :ok] end)

      probe = fn _opts ->
        send(test, :probed)
        Agent.get_and_update(agent, fn [r | rest] -> {r, rest ++ [r]} end)
      end

      start_supervised!({Host, host_opts(ctx, probe: probe, prep_retry_ms: 50)})
      assert_receive :probed, 5_000
      assert_receive :probed, 5_000
      assert await_ready(ctx.name, true) == :ok
    end

    test "the default probe is podman info through the runner", ctx do
      fake = FakePodman.start([])
      opts = host_opts(ctx, podman_bin: fake.bin) |> Keyword.delete(:probe)
      start_supervised!({Host, opts})
      assert await_ready(ctx.name) == :ok
      assert [["info", "--format", "{{.Version.Version}}"]] = FakePodman.verbs(fake)
    end

    test "a missing podman is {:prep_failed, :unavailable}", ctx do
      opts = host_opts(ctx, podman_bin: "/nonexistent/podman") |> Keyword.delete(:probe)
      start_supervised!({Host, opts})
      assert await_ready(ctx.name) == {:error, {:prep_failed, :unavailable}}
    end

    test "no Host is :unavailable" do
      assert Host.ready(:no_such_host) == {:error, :unavailable}
    end
  end

  describe "the logs' tmpfs" do
    @opts "mode=0700,nosuid,nodev,noexec"

    test "is mounted once at the log dir, 16 MiB on frugal", ctx do
      start_host(ctx)
      dir = Path.join(ctx.root, "run/vagus/logs")
      args = ["-t", "tmpfs", "-o", "size=16777216," <> @opts, "tmpfs", dir]
      assert_receive {:step, {"mount", ^args}}, 5_000
      refute_received {:step, {"mount", ["-t" | _]}}
    end

    test "is 64 MiB on fast", ctx do
      start_host(ctx, meminfo: meminfo(ctx.root, 8 * @gib_kb))
      dir = Path.join(ctx.root, "run/vagus/logs")
      args = ["-t", "tmpfs", "-o", "size=67108864," <> @opts, "tmpfs", dir]
      assert_receive {:step, {"mount", ^args}}, 5_000
    end

    # A Vagus restart in the same boot: the mount is already in mountinfo
    # (a space in the path is written there as \040).
    test "is not mounted again over itself", ctx do
      dir = Path.join(ctx.root, "run/vagus/log s")

      mountinfo =
        mountinfo(ctx.root, """
        22 1 0:21 / /run rw,nosuid,nodev,noexec - tmpfs tmpfs rw,size=48000k,mode=755
        95 22 0:52 / #{String.replace(dir, " ", "\\040")} rw,nosuid,nodev,noexec - tmpfs tmpfs rw,size=16384k,mode=700
        """)

      start_host(ctx, log_dir: dir, mountinfo: mountinfo)
      assert_receive {:step, {"mount", ["--make-rshared", "/"]}}, 5_000
      refute_received {:step, {"mount", ["-t", "tmpfs" | _]}}
    end

    # Each of these keeps the plain directory and says why.
    defp refuses_to_mount(ctx, extra) do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert start_host(ctx, extra) == :ok
          assert_receive {:step, {"mount", ["--make-rshared", "/"]}}, 5_000
          refute_received {:step, {"mount", ["-t" | _]}}
        end)

      assert log =~ "logs stay on /run"
      log
    end

    test "not when mountinfo cannot be read", ctx do
      log = refuses_to_mount(ctx, mountinfo: Path.join(ctx.root, "no-mountinfo"))
      assert log =~ "mountinfo unreadable"
    end

    test "not over another filesystem mounted there", ctx do
      dir = Path.join(ctx.root, "run/vagus/logs")

      info =
        mountinfo(ctx.root, """
        95 22 0:52 / #{dir} rw,relatime - ext4 /dev/mmcblk0p7 rw
        """)

      assert refuses_to_mount(ctx, mountinfo: info) =~ "ext4 is mounted there"
    end

    test "not over a directory that already holds logs", ctx do
      dir = Path.join(ctx.root, "run/vagus/logs")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "addon_local_x.log"), "live lines")
      assert refuses_to_mount(ctx, []) =~ "already holds logs"
      assert File.read!(Path.join(dir, "addon_local_x.log")) == "live lines"
    end

    test "a failed mount leaves the plain directory and a ready Host", ctx do
      test = self()

      run = fn bin, args ->
        send(test, {:step, {bin, args}})
        if match?(["-t" | _], args), do: {"mount: permission denied", 32}, else: {"", 0}
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert start_host(ctx, run: run) == :ok
        end)

      assert log =~ "logs stay on /run"
      assert File.dir?(Path.join(ctx.root, "run/vagus/logs"))
    end
  end

  describe "the profile" do
    test "below 2 GiB is frugal, from 2 GiB fast", ctx do
      assert Host.pick_profile(
               profile_opts(ctx.root, meminfo: meminfo(ctx.root, 2 * @gib_kb - 1))
             ) ==
               :frugal

      assert Host.pick_profile(profile_opts(ctx.root, meminfo: meminfo(ctx.root, 2 * @gib_kb))) ==
               :fast
    end

    test "the override file wins either way", ctx do
      override = Path.join(ctx.root, "podman-profile")

      File.write!(override, "fast\n")

      assert Host.pick_profile(meminfo: meminfo(ctx.root, @gib_kb), profile_override: override) ==
               :fast

      File.write!(override, "frugal")

      assert Host.pick_profile(
               meminfo: meminfo(ctx.root, 8 * @gib_kb),
               profile_override: override
             ) ==
               :frugal

      File.write!(override, "turbo")

      assert Host.pick_profile(
               meminfo: meminfo(ctx.root, 8 * @gib_kb),
               profile_override: override
             ) ==
               :fast
    end

    test "an unreadable meminfo is frugal", ctx do
      assert Host.pick_profile(profile_opts(ctx.root, meminfo: Path.join(ctx.root, "nope"))) ==
               :frugal
    end

    test "frugal: drop-in, Go limits and permits", ctx do
      start_host(ctx)
      conf = Path.join(ctx.root, "run/vagus/podman/containers.conf")

      assert File.read!(conf) == """
             [engine]
             events_logger = "file"
             events_logfile_max_size = 4194304
             image_parallel_copies = 1
             image_copy_tmp_dir = "#{Path.join(ctx.root, "storage/tmp")}"
             """

      assert Host.profile(ctx.name) == :frugal

      assert Host.env(ctx.name) == [
               {"GOMAXPROCS", "1"},
               {"GOMEMLIMIT", "32MiB"},
               {"GOGC", "10"},
               {"CONTAINERS_CONF_OVERRIDE", conf}
             ]

      assert permits(ctx.name, :ops) == 2

      assert Host.log_config(ctx.name) ==
               %{dir: Path.join(ctx.root, "run/vagus/logs"), max_bytes: 2_097_152}
    end

    test "fast: drop-in spooling on tmpfs, no Go limits, four ops permits", ctx do
      start_host(ctx, meminfo: meminfo(ctx.root, 8 * @gib_kb))
      conf = Path.join(ctx.root, "run/vagus/podman/containers.conf")

      assert File.read!(conf) == """
             [engine]
             events_logger = "file"
             events_logfile_max_size = 4194304
             image_copy_tmp_dir = "#{Path.join(ctx.root, "run/vagus/podman/spool")}"
             """

      assert File.dir?(Path.join(ctx.root, "run/vagus/podman/spool"))
      assert Host.env(ctx.name) == [{"CONTAINERS_CONF_OVERRIDE", conf}]
      assert permits(ctx.name, :ops) == 4
      assert Host.log_config(ctx.name).max_bytes == 8_388_608
    end

    test "the env reaches every podman the runner spawns", ctx do
      start_host(ctx)
      fake = FakePodman.start([], log_env: ["GOMAXPROCS", "CONTAINERS_CONF_OVERRIDE"])
      {:ok, _} = Cmd.run(["info"], timeout_ms: 5_000, podman_bin: fake.bin, host: ctx.name)
      conf = Path.join(ctx.root, "run/vagus/podman/containers.conf")
      assert [["GOMAXPROCS=1", "CONTAINERS_CONF_OVERRIDE=" <> ^conf]] = FakePodman.envs(fake)
    end
  end

  describe "the spool" do
    test "is emptied on the first start of a boot only", ctx do
      spool = Path.join(ctx.root, "storage/tmp")
      File.mkdir_p!(Path.join(spool, "leaked-pull"))
      File.write!(Path.join(spool, "layer"), "x")

      start_host(ctx)
      assert File.ls!(spool) == []

      stop_supervised!(ctx.name)
      File.write!(Path.join(spool, "live-pull"), "x")
      start_host(ctx)
      assert File.ls!(spool) == ["live-pull"]
    end
  end

  describe "clear_spool/1 after a failed pull" do
    setup ctx do
      start_host(ctx, spool_quiet_ms: 60_000)
      %{spool: Path.join(ctx.root, "storage/tmp")}
    end

    # Every path under `path`, itself included, an hour old.
    defp age(path) do
      {_, 0} =
        System.cmd("find", [
          path,
          "-exec",
          "touch",
          "-h",
          "-d",
          "@#{System.os_time(:second) - 3_600}",
          "{}",
          "+"
        ])

      :ok
    end

    defp tree(spool, entry, files) do
      for file <- files do
        path = Path.join([spool, entry, file])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "x")
      end

      Path.join(spool, entry)
    end

    test "keeps an entry just written", %{spool: spool} = ctx do
      tree(spool, "live", ["layer"])
      Host.clear_spool(ctx.name)
      assert File.ls!(spool) == ["live"]
    end

    test "removes an entry with nothing written inside for the quiet period",
         %{spool: spool} = ctx do
      spool |> tree("leaked", ["a/b/layer", "c"]) |> age()
      Host.clear_spool(ctx.name)
      assert File.ls!(spool) == []
    end

    test "keeps an entry with one recent file deep inside", %{spool: spool} = ctx do
      entry = tree(spool, "pulling", ["a/b/old", "c"])
      age(entry)
      File.write!(Path.join(entry, "a/b/new"), "x")
      Host.clear_spool(ctx.name)
      assert File.ls!(spool) == ["pulling"]
    end

    test "does not follow a symlink, for its age or its removal", %{spool: spool} = ctx do
      outside = Path.join(ctx.root, "outside")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "recent"), "x")
      entry = tree(spool, "linky", ["old"])
      File.ln_s!(outside, Path.join(entry, "link"))
      age(entry)

      Host.clear_spool(ctx.name)
      assert File.ls!(spool) == []
      assert File.read!(Path.join(outside, "recent")) == "x"
    end
  end

  # Takes every free permit of `class` with try-style zero waits.
  defp permits(host, class) do
    Stream.repeatedly(fn -> Host.checkout(host, class, 0) end)
    |> Enum.take_while(&match?({:ok, _}, &1))
    |> length()
  end

  defp await_waiters(host, class, n) do
    Enum.find(1..1_000, fn _ ->
      :queue.len(:sys.get_state(host).waiting[class]) == n or (Process.sleep(5) && false)
    end) || flunk("no #{n} #{class} waiter(s) queued")
  end

  describe "permits" do
    test "a full class makes the next caller wait, and :busy when its wait runs out", ctx do
      start_host(ctx)
      for _ <- 1..2, do: {:ok, _} = Host.checkout(ctx.name, :ops, 0)
      assert Host.checkout(ctx.name, :ops, 50) == {:error, :busy}
    end

    test "a waiter gets the permit a holder checks in", ctx do
      start_host(ctx)
      {:ok, p1} = Host.checkout(ctx.name, :ops, 0)
      {:ok, _p2} = Host.checkout(ctx.name, :ops, 0)
      waiter = Task.async(fn -> Host.checkout(ctx.name, :ops, 10_000) end)
      await_waiters(ctx.name, :ops, 1)
      Host.checkin(p1)
      assert {:ok, _} = Task.await(waiter, 10_000)
    end

    test "classes are separate: a held pull does not hold up ops or shutdown", ctx do
      start_host(ctx)
      {:ok, _} = Host.checkout(ctx.name, :pull, 0)
      assert Host.checkout(ctx.name, :pull, 0) == {:error, :busy}
      assert {:ok, _} = Host.checkout(ctx.name, :ops, 0)
      assert {:ok, _} = Host.checkout(ctx.name, :shutdown, 0)
      assert Host.checkout(ctx.name, :shutdown, 0) == {:error, :busy}
    end

    test "a holder that dies frees its permit", ctx do
      start_host(ctx, permits: %{pull: 1, ops: 1, shutdown: 1})
      test = self()

      holder =
        spawn(fn ->
          send(test, Host.checkout(ctx.name, :ops, 0))
          Process.sleep(:infinity)
        end)

      assert_receive {:ok, _}, 5_000
      assert Host.checkout(ctx.name, :ops, 0) == {:error, :busy}
      Process.exit(holder, :kill)
      assert {:ok, _} = Host.checkout(ctx.name, :ops, 1_000)
    end

    test "a caller whose wait ran out is never handed the permit later", ctx do
      start_host(ctx, permits: %{pull: 1, ops: 1, shutdown: 1})
      {:ok, held} = Host.checkout(ctx.name, :ops, 0)
      assert Host.checkout(ctx.name, :ops, 20) == {:error, :busy}
      Host.checkin(held)
      assert {:ok, _} = Host.checkout(ctx.name, :ops, 0)
    end

    test "with_permit checks the permit in after the fun, even when it raises", ctx do
      start_host(ctx, permits: %{pull: 1, ops: 1, shutdown: 1})
      assert Host.with_permit(ctx.name, :ops, 0, fn -> :done end) == :done

      assert_raise RuntimeError, fn ->
        Host.with_permit(ctx.name, :ops, 0, fn -> raise "boom" end)
      end

      assert {:ok, _} = Host.checkout(ctx.name, :ops, 0)
    end

    test "new pulls are refused once a shutdown is in flight; other classes are not", ctx do
      flag = :atomics.new(1, [])
      start_host(ctx, shutting_down?: fn -> :atomics.get(flag, 1) == 1 end)
      :atomics.put(flag, 1, 1)
      assert Host.checkout(ctx.name, :pull, 0) == {:error, :shutting_down}
      assert {:ok, _} = Host.checkout(ctx.name, :ops, 0)
      assert {:ok, _} = Host.checkout(ctx.name, :shutdown, 0)
    end

    test "a queued pull is refused once a shutdown has begun", ctx do
      flag = :atomics.new(1, [])
      start_host(ctx, shutting_down?: fn -> :atomics.get(flag, 1) == 1 end)
      {:ok, held} = Host.checkout(ctx.name, :pull, 0)
      waiter = Task.async(fn -> Host.checkout(ctx.name, :pull, 10_000) end)
      await_waiters(ctx.name, :pull, 1)
      :atomics.put(flag, 1, 1)
      Host.checkin(held)
      assert Task.await(waiter, 10_000) == {:error, :shutting_down}
    end

    test "a late grant never lingers in the mailbox of a caller that gave up", ctx do
      start_host(ctx, permits: %{pull: 1, ops: 1, shutdown: 1})
      {:ok, held} = Host.checkout(ctx.name, :ops, 0)
      assert Host.checkout(ctx.name, :ops, 20) == {:error, :busy}
      Host.checkin(held)
      _ = :sys.get_state(ctx.name)
      refute_received {Host, _, _}
    end

    test "a waiter whose Host dies is :unavailable at once, not at its deadline", ctx do
      start_host(ctx, permits: %{pull: 1, ops: 1, shutdown: 1})
      {:ok, _held} = Host.checkout(ctx.name, :ops, 0)
      waiter = Task.async(fn -> Host.checkout(ctx.name, :ops, 60_000) end)
      await_waiters(ctx.name, :ops, 1)

      old = Process.whereis(ctx.name)
      Process.exit(old, :kill)
      assert Task.await(waiter, 5_000) == {:error, :unavailable}

      # The test supervisor restarts it; the new Host serves new requests.
      assert Enum.find(1..1_000, fn _ ->
               (Process.whereis(ctx.name) || old) != old or (Process.sleep(5) && false)
             end)

      assert {:ok, _} = Host.checkout(ctx.name, :ops, 5_000)
    end

    test "an unknown class is :badarg and the Host lives on", ctx do
      start_host(ctx)
      pid = Process.whereis(ctx.name)
      assert Host.checkout(ctx.name, :bogus, 0) == {:error, :badarg}
      send(pid, :stray)
      assert {:ok, _} = Host.checkout(ctx.name, :ops, 0)
      assert Process.whereis(ctx.name) == pid
    end

    test "no Host is :unavailable" do
      assert Host.checkout(:no_such_host, :ops, 0) == {:error, :unavailable}
    end
  end

  describe "the balena migration" do
    @core "ghcr.io/home-assistant/home-assistant:2026.7.3"

    setup ctx do
      legacy = Path.join(ctx.root, "root/balena-engine")
      File.mkdir_p!(Path.join(legacy, "volumes/vagus-core-config/_data"))
      File.write!(Path.join(ctx.root, "no-mounts"), "")
      %{legacy: legacy, legacy_config: Path.join(legacy, "volumes/vagus-core-config/_data")}
    end

    defp df(free_mib) do
      fn _path ->
        {"Filesystem 1K-blocks Used Available Use% Mounted on\n" <>
           "/dev/root 99999999 1 #{free_mib * 1024} 1% /root\n", 0}
      end
    end

    # Every condition holds and the images fit unless `extra` says otherwise.
    defp migration(ctx, extra) do
      migration_paths(ctx.root) ++
        Keyword.merge(
          [
            validated?: fn -> true end,
            wanted_images: fn -> {:ok, [@core]} end,
            image_present?: fn _ -> true end,
            core_healthy?: fn -> true end,
            df: df(10_000)
          ],
          extra
        )
    end

    # Holds the check task's first call until the test sends :go.
    defp held_images(test) do
      fn ->
        unless Process.get(:released) do
          send(test, {:checking, self()})
          receive do: (:go -> Process.put(:released, true))
        end

        {:ok, [@core]}
      end
    end

    defp pull_waiter(ctx, opts) do
      test = self()

      Task.async(fn ->
        result = Host.checkout(ctx.name, :pull, 30_000, opts)
        send(test, {:granted, opts[:as], result})
        receive do: (:release -> with({:ok, p} <- result, do: Host.checkin(p)))
      end)
    end

    test "only the first preparation of a boot moves Core's config", ctx do
      valid = :atomics.new(1, [])
      validated? = fn -> :atomics.get(valid, 1) == 1 end

      opts = [
        migration: migration(ctx, validated?: validated?, image_present?: fn _ -> false end)
      ]

      start_host(ctx, opts)
      assert File.dir?(ctx.legacy_config)

      # Validated later in the same boot, then the Host restarts.
      :atomics.put(valid, 1, 1)
      stop_supervised!(ctx.name)
      start_host(ctx, opts)
      assert File.dir?(ctx.legacy_config)

      # The next boot starts with an empty /run.
      stop_supervised!(ctx.name)
      File.rm_rf!(Path.join(ctx.root, "run"))
      start_host(ctx, opts)
      refute File.exists?(ctx.legacy_config)
      assert File.dir?(Path.join(ctx.root, "root/vagus/core/config"))
    end

    test "pulls wait for the space check, then Core's goes first", ctx do
      start_host(ctx, migration: migration(ctx, wanted_images: held_images(self())))
      assert_receive {:checking, check}, 5_000

      app = pull_waiter(ctx, as: :app)
      await_waiters(ctx.name, :pull, 1)
      core = pull_waiter(ctx, as: :core, priority: true)
      await_waiters(ctx.name, :pull, 2)
      refute_received {:granted, _, _}

      send(check, :go)
      assert_receive {:granted, :core, {:ok, _}}, 5_000
      refute_received {:granted, :app, _}

      send(core.pid, :release)
      assert_receive {:granted, :app, {:ok, _}}, 5_000
      send(app.pid, :release)
      Enum.each([app, core], &Task.await/1)
    end

    test "with no room, queued and new pulls are refused; other classes go on", ctx do
      start_host(ctx,
        migration:
          migration(ctx,
            wanted_images: held_images(self()),
            image_present?: fn _ -> false end,
            df: df(10)
          )
      )

      assert_receive {:checking, check}, 5_000
      waiter = pull_waiter(ctx, as: :app)
      await_waiters(ctx.name, :pull, 1)

      capture_log(fn ->
        send(check, :go)
        assert_receive {:granted, :app, {:error, :no_space}}, 5_000
      end)

      assert Host.checkout(ctx.name, :pull, 0) == {:error, :no_space}
      assert {:ok, _} = Host.checkout(ctx.name, :ops, 0)
      send(waiter.pid, :release)
      Task.await(waiter)
    end

    test "a space check that keeps failing lets pulls go after three tries", ctx do
      test = self()

      df = fn _ ->
        send(test, :df)
        {"", 1}
      end

      capture_log(fn ->
        start_host(ctx,
          prep_retry_ms: 1,
          migration: migration(ctx, df: df, image_present?: fn _ -> false end)
        )

        for _ <- 1..3, do: assert_receive(:df, 5_000)
        assert {:ok, _} = Host.checkout(ctx.name, :pull, 5_000)
      end)
    end

    test "checks again on its timer until every condition holds, then deletes and stops",
         ctx do
      test = self()
      healthy = :atomics.new(1, [])

      core_healthy? = fn ->
        send(test, :health_checked)
        :atomics.get(healthy, 1) == 1
      end

      start_host(ctx,
        migration_check_ms: 1,
        migration: migration(ctx, core_healthy?: core_healthy?)
      )

      for _ <- 1..2, do: assert_receive(:health_checked, 5_000)
      assert File.dir?(ctx.legacy)

      :atomics.put(healthy, 1, 1)
      assert_receive :health_checked, 5_000
      _ = :sys.get_state(ctx.name)

      Enum.find(1..1_000, fn _ ->
        :sys.get_state(ctx.name).migration == nil or (Process.sleep(5) && false)
      end) || flunk("the migration never completed")

      refute File.exists?(ctx.legacy)
      assert File.exists?(Path.join(ctx.root, "root/vagus/engine-migrated"))
      flush_health_checks()
      _ = :sys.get_state(ctx.name)
      refute_received :health_checked
    end

    test "a board without balena runs no check and holds no pull", ctx do
      File.rm_rf!(ctx.legacy)

      start_host(ctx,
        migration_check_ms: 1,
        migration: migration(ctx, wanted_images: held_images(self()))
      )

      assert {:ok, _} = Host.checkout(ctx.name, :pull, 0)
      refute_received {:checking, _}
      assert File.dir?(Path.join(ctx.root, "root/vagus/core/config"))
    end

    defp flush_health_checks do
      receive do
        :health_checked -> flush_health_checks()
      after
        0 -> :ok
      end
    end
  end
end
