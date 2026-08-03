defmodule Vagus.ProvisionerTest do
  @moduledoc """
  Issue #40 first-boot provisioning — `BootTest`-style: injected `:cmd`/
  `:reboot`/`:ping`/`:connection`/`:installed`/`:update`/`:start`/
  `:await_healthy` fns, no real disk/engine/Core needed. `async: false`
  because several tests assert on captured log output (`ExUnit.CaptureLog`
  is process-global under async).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vagus.Provisioner

  setup do
    # `Provisioner.start_link/1` reads `config :vagus, :first_boot_provision`
    # at call time (`:ignore` unless truthy) — `config/test.exs` never
    # enables it, so every test but the explicit "disabled" one below needs
    # it flipped on for the injected seams to ever run.
    prev = Application.get_env(:vagus, :first_boot_provision)
    Application.put_env(:vagus, :first_boot_provision, true)
    on_exit(fn -> restore_env(:first_boot_provision, prev) end)
    :ok
  end

  # Builds `<tmp>/sys/block/<disk>/...` sysfs fixtures plus a
  # `<tmp>/rootdisk0` symlink pointing at `disk` (basename resolution means
  # the link target doesn't need to exist as a real device node).
  defp sysfs_fixture(tmp_dir, disk, part_dir_name, logical_block_size, disk_sectors, opts) do
    part_start = Keyword.fetch!(opts, :start)
    part_size = Keyword.fetch!(opts, :size)

    disk_dir = Path.join([tmp_dir, "sys", "block", disk])
    part_dir = Path.join(disk_dir, part_dir_name)
    queue_dir = Path.join(disk_dir, "queue")

    File.mkdir_p!(part_dir)
    File.mkdir_p!(queue_dir)

    File.write!(Path.join(queue_dir, "logical_block_size"), to_string(logical_block_size))
    File.write!(Path.join(disk_dir, "size"), to_string(disk_sectors))
    File.write!(Path.join(part_dir, "start"), to_string(part_start))
    File.write!(Path.join(part_dir, "size"), to_string(part_size))

    rootdisk = Path.join(tmp_dir, "rootdisk0")
    File.ln_s!(disk, rootdisk)

    %{rootdisk: rootdisk, sysfs_root: Path.join(tmp_dir, "sys")}
  end

  # No-op fwup/reboot/resize2fs `:cmd` fake that reports every invocation to
  # `parent` — used by expand-step tests that don't care about the exact
  # `cmd` args beyond observing whether fwup ran.
  defp reporting_cmd(parent) do
    fn bin, args ->
      send(parent, {:cmd, bin, args})
      {"", 0}
    end
  end

  # `:provision_core`-side seams that never get called — used by
  # expand-only tests where the tail is intentionally kept quiet with
  # `installed` returning a version.
  defp quiet_provision_seams(parent) do
    [
      installed: fn ->
        send(parent, :installed_checked)
        "2026.7.3"
      end,
      ping: fn ->
        send(parent, :ping_called)
        {:error, :should_not_be_called}
      end,
      connection: fn ->
        send(parent, :connection_called)
        :disconnected
      end
    ]
  end

  test "disabled config -> :ignore, no process registered" do
    prev = Application.get_env(:vagus, :first_boot_provision)
    Application.put_env(:vagus, :first_boot_provision, false)
    on_exit(fn -> restore_env(:first_boot_provision, prev) end)

    assert :ignore = Provisioner.start_link([])
    assert Process.whereis(Provisioner) == nil
  end

  @tag :tmp_dir
  test "4Kn disk -> fwup never invoked, resize2fs still attempted, step 2 reached", %{
    tmp_dir: tmp_dir
  } do
    parent = self()

    fixture =
      sysfs_fixture(tmp_dir, "nvme0n1", "nvme0n1p5", 4096, 128_000_000,
        start: 1_000_000,
        size: 1_000_000
      )

    log =
      capture_log(fn ->
        start_supervised!(
          {Provisioner,
           [
             rootdisk: fixture.rootdisk,
             sysfs_root: fixture.sysfs_root,
             ops_fw: "/usr/share/fwup/ops.fw",
             cmd: reporting_cmd(parent),
             reboot: fn -> send(parent, :reboot_called) end
           ] ++ quiet_provision_seams(parent) ++ [name: nil]}
        )

        assert_receive {:cmd, "resize2fs", [p5]}, 1_000
        assert p5 == fixture.rootdisk <> "p5"
        assert_receive :installed_checked, 1_000
        refute_received {:cmd, "fwup", _}
        refute_received :reboot_called
      end)

    assert log =~ "512-LBA-only"
  end

  @tag :tmp_dir
  test "no-tail disk -> fwup not invoked, proceeds to step 2, resize2fs attempted", %{
    tmp_dir: tmp_dir
  } do
    parent = self()

    fixture =
      sysfs_fixture(tmp_dir, "nvme0n1", "nvme0n1p5", 512, 2_004_096,
        start: 1_000_000,
        size: 1_000_000
      )

    capture_log(fn ->
      start_supervised!(
        {Provisioner,
         [
           rootdisk: fixture.rootdisk,
           sysfs_root: fixture.sysfs_root,
           ops_fw: "/usr/share/fwup/ops.fw",
           cmd: reporting_cmd(parent),
           reboot: fn -> send(parent, :reboot_called) end
         ] ++ quiet_provision_seams(parent) ++ [name: nil]}
      )

      assert_receive {:cmd, "resize2fs", _}, 1_000
      assert_receive :installed_checked, 1_000
      refute_received {:cmd, "fwup", _}
      refute_received :reboot_called
    end)
  end

  @tag :tmp_dir
  test "expand fires: 512 LBA + >1 GiB tail -> exact fwup args, reboot called, step 2 skipped", %{
    tmp_dir: tmp_dir
  } do
    parent = self()

    fixture =
      sysfs_fixture(tmp_dir, "nvme0n1", "nvme0n1p5", 512, 128_000_000,
        start: 1_000_000,
        size: 1_000_000
      )

    ops_fw = "/usr/share/fwup/ops.fw"

    log =
      capture_log(fn ->
        start_supervised!(
          {Provisioner,
           [
             rootdisk: fixture.rootdisk,
             sysfs_root: fixture.sysfs_root,
             ops_fw: ops_fw,
             cmd: reporting_cmd(parent),
             reboot: fn -> send(parent, :reboot_called) end
           ] ++ quiet_provision_seams(parent) ++ [name: nil]}
        )

        assert_receive {:cmd, "resize2fs", _}, 1_000
        assert_receive {:cmd, "fwup", args}, 1_000
        assert args == ["-t", "expand-data", "-d", fixture.rootdisk, ops_fw]
        assert_receive :reboot_called, 1_000
        refute_received :installed_checked
      end)

    assert log =~ "rebooting to complete the expansion"
  end

  @tag :tmp_dir
  test "fwup nonzero exit -> reboot NOT called, proceeds to step 2, error logged", %{
    tmp_dir: tmp_dir
  } do
    parent = self()

    fixture =
      sysfs_fixture(tmp_dir, "nvme0n1", "nvme0n1p5", 512, 128_000_000,
        start: 1_000_000,
        size: 1_000_000
      )

    cmd = fn
      "fwup", _args ->
        send(parent, {:cmd, "fwup", :failed})
        {"boom", 1}

      bin, args ->
        send(parent, {:cmd, bin, args})
        {"", 0}
    end

    log =
      capture_log(fn ->
        start_supervised!(
          {Provisioner,
           [
             rootdisk: fixture.rootdisk,
             sysfs_root: fixture.sysfs_root,
             ops_fw: "/usr/share/fwup/ops.fw",
             cmd: cmd,
             reboot: fn -> send(parent, :reboot_called) end
           ] ++ quiet_provision_seams(parent) ++ [name: nil]}
        )

        assert_receive {:cmd, "fwup", :failed}, 1_000
        assert_receive :installed_checked, 1_000
        refute_received :reboot_called
      end)

    assert log =~ "boom"
  end

  @tag :tmp_dir
  test "partition naming: sda/sda5 (no p) -> expand still fires", %{tmp_dir: tmp_dir} do
    parent = self()

    fixture =
      sysfs_fixture(tmp_dir, "sda", "sda5", 512, 128_000_000, start: 1_000_000, size: 1_000_000)

    ops_fw = "/usr/share/fwup/ops.fw"

    capture_log(fn ->
      start_supervised!(
        {Provisioner,
         [
           rootdisk: fixture.rootdisk,
           sysfs_root: fixture.sysfs_root,
           ops_fw: ops_fw,
           cmd: reporting_cmd(parent),
           reboot: fn -> send(parent, :reboot_called) end
         ] ++ quiet_provision_seams(parent) ++ [name: nil]}
      )

      assert_receive {:cmd, "fwup", args}, 1_000
      assert args == ["-t", "expand-data", "-d", fixture.rootdisk, ops_fw]
      assert_receive :reboot_called, 1_000
    end)
  end

  test "already installed -> full no-op, ping/connection never called, logged" do
    parent = self()

    log =
      capture_log(fn ->
        start_supervised!(
          {Provisioner,
           steps: [:provision_core],
           installed: fn -> "2026.7.3" end,
           ping: fn ->
             send(parent, :ping_called)
             :ok
           end,
           connection: fn ->
             send(parent, :connection_called)
             :internet
           end,
           name: nil}
        )

        Process.sleep(20)
        refute_received :ping_called
        refute_received :connection_called
      end)

    assert log =~ "already installed"
  end

  test "happy path: engine retries, net retries, update -> start -> await_healthy in order" do
    parent = self()
    ping_counter = :counters.new(1, [])
    conn_counter = :counters.new(1, [])

    ping = fn ->
      n = :counters.get(ping_counter, 1)
      :counters.add(ping_counter, 1, 1)
      if n < 3, do: {:error, :not_ready}, else: :ok
    end

    connection = fn ->
      n = :counters.get(conn_counter, 1)
      :counters.add(conn_counter, 1, 1)
      if n < 2, do: :disconnected, else: :internet
    end

    update = fn ->
      send(parent, :update_called)
      {:ok, "2026.7.3"}
    end

    start = fn ->
      send(parent, :start_called)
      :ok
    end

    await_healthy = fn ->
      send(parent, :health_called)
      :healthy
    end

    log =
      capture_log(fn ->
        start_supervised!(
          {Provisioner,
           steps: [:provision_core],
           installed: fn -> nil end,
           ping: ping,
           connection: connection,
           update: update,
           start: start,
           await_healthy: await_healthy,
           engine_interval: 1,
           net_interval: 1,
           name: nil}
        )

        assert_receive :update_called, 1_000
        assert_receive :start_called, 1_000
        assert_receive :health_called, 1_000
        Process.sleep(20)
      end)

    assert log =~ "provisioning complete"
  end

  test "pull error backoff: fails twice then succeeds -> exactly 3 update calls" do
    parent = self()
    counter = :counters.new(1, [])

    update = fn ->
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      send(parent, {:update_called, n})

      if n < 2 do
        {:error, {:pull, :nope}}
      else
        {:ok, "2026.7.3"}
      end
    end

    start = fn ->
      send(parent, :start_called)
      :ok
    end

    log =
      capture_log(fn ->
        start_supervised!(
          {Provisioner,
           steps: [:provision_core],
           installed: fn -> nil end,
           ping: fn -> :ok end,
           connection: fn -> :internet end,
           update: update,
           start: start,
           await_healthy: fn -> :healthy end,
           retry_base: 1,
           retry_cap: 4,
           name: nil}
        )

        assert_receive {:update_called, 0}, 1_000
        assert_receive {:update_called, 1}, 1_000
        assert_receive {:update_called, 2}, 1_000
        assert_receive :start_called, 1_000
        refute_received {:update_called, 3}
      end)

    assert log =~ "retrying"
  end

  test ":version_installed -> treated as done, start never called" do
    parent = self()

    start = fn ->
      send(parent, :start_called)
      :ok
    end

    log =
      capture_log(fn ->
        start_supervised!(
          {Provisioner,
           steps: [:provision_core],
           installed: fn -> nil end,
           ping: fn -> :ok end,
           connection: fn -> :internet end,
           update: fn -> {:error, :version_installed} end,
           start: start,
           name: nil}
        )

        Process.sleep(20)
        refute_received :start_called
      end)

    assert log =~ "already done"
  end

  test "start error -> warning logged, process alive, await_healthy not called" do
    parent = self()

    await_healthy = fn ->
      send(parent, :health_called)
      :healthy
    end

    log =
      capture_log(fn ->
        pid =
          start_supervised!(
            {Provisioner,
             steps: [:provision_core],
             installed: fn -> nil end,
             ping: fn -> :ok end,
             connection: fn -> :internet end,
             update: fn -> {:ok, "2026.7.3"} end,
             start: fn -> {:error, :boom} end,
             await_healthy: await_healthy,
             name: nil}
          )

        Process.sleep(20)
        refute_received :health_called
        assert Process.alive?(pid)
      end)

    assert log =~ "boom"
  end

  test "init never blocks: never-succeeding ping + installed nil -> start_supervised returns promptly" do
    pid =
      start_supervised!(
        {Provisioner,
         steps: [:provision_core],
         installed: fn -> nil end,
         ping: fn -> {:error, :never} end,
         engine_interval: 60_000,
         name: nil}
      )

    assert Process.alive?(pid)
  end

  defp restore_env(key, nil), do: Application.delete_env(:vagus, key)
  defp restore_env(key, value), do: Application.put_env(:vagus, key, value)
end
