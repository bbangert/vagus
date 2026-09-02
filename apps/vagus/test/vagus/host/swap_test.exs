defmodule Vagus.Host.SwapTest do
  @moduledoc """
  `ProvisionerTest`-style: sysfs/procfs/mount-table fixtures under `tmp_dir`
  plus a scripted `:cmd` fake, so no real zram device, swap or `/data` is
  ever touched. `async: false` because several tests assert on captured log
  output (`ExUnit.CaptureLog` is process-global under async).
  """
  use ExUnit.Case, async: false

  import Bitwise
  import ExUnit.CaptureLog

  alias Vagus.Host.Swap

  @mib 1024 * 1024
  @gib 1024 * 1024 * 1024

  # A Pi-3-shaped MemTotal: 970644 kB is what a "1 GB" board actually
  # reports once the kernel and gpu_mem have taken their cut.
  @pi_kb 970_644
  @pi_bytes 970_644 * 1024

  setup do
    prev = Application.get_env(:vagus, :host_swap)
    Application.put_env(:vagus, :host_swap, true)
    on_exit(fn -> restore_env(:host_swap, prev) end)
    :ok
  end

  # Lays out every file `Vagus.Host.Swap` reads or writes under `tmp_dir`
  # and returns the opts (minus `:cmd`) that point the GenServer at them.
  defp fixture(tmp_dir, opts) do
    disk = Keyword.get(opts, :disk, "mmcblk0")
    mem_kb = Keyword.get(opts, :mem_kb, @pi_kb)
    comp = Keyword.get(opts, :comp_algorithm, "lzo lzo-rle [lz4] zstd")
    swaps = Keyword.get(opts, :swaps, "Filename\t\t\t\tType\t\tSize\tUsed\tPriority\n")
    mount_device = Keyword.get(opts, :mount_device, "/dev/#{disk}p5")
    mountpoint = Keyword.get(opts, :mountpoint, "/root")
    mounts = Keyword.get(opts, :mounts, [{mount_device, mountpoint}])

    zram_dir = Path.join([tmp_dir, "sys", "block", "zram0"])
    zswap_dir = Path.join([tmp_dir, "sys", "module", "zswap", "parameters"])
    vm_dir = Path.join([tmp_dir, "proc", "sys", "vm"])
    proc_dir = Path.join(tmp_dir, "proc")

    if Keyword.get(opts, :zram_dir?, true), do: File.mkdir_p!(zram_dir)
    File.mkdir_p!(zswap_dir)
    File.mkdir_p!(vm_dir)

    if Keyword.get(opts, :zram_dir?, true) do
      File.write!(Path.join(zram_dir, "comp_algorithm"), comp)
      File.write!(Path.join(zram_dir, "disksize"), "0")
    end

    File.write!(Path.join(zswap_dir, "enabled"), "N")
    File.write!(Path.join(vm_dir, "swappiness"), "60")
    File.write!(Path.join(vm_dir, "page-cluster"), "3")
    File.write!(Path.join(proc_dir, "swaps"), swaps)
    File.write!(Path.join(proc_dir, "meminfo"), "MemTotal:       #{mem_kb} kB\nMemFree: 1 kB\n")

    File.write!(
      Path.join(proc_dir, "mounts"),
      """
      /dev/#{disk}p2 / ext4 rw,relatime 0 0
      /dev/#{disk}p1 /boot vfat rw,relatime 0 0
      """ <>
        Enum.map_join(mounts, fn {device, mp} -> "#{device} #{mp} ext4 rw,relatime 0 0\n" end)
    )

    rootdisk = Path.join(tmp_dir, "rootdisk0")
    File.ln_s!(disk, rootdisk)

    [
      rootdisk: rootdisk,
      sysfs_root: Path.join(tmp_dir, "sys"),
      procsys_root: Path.join([tmp_dir, "proc", "sys"]),
      mounts_path: Path.join(proc_dir, "mounts"),
      swaps_path: Path.join(proc_dir, "swaps"),
      meminfo_path: Path.join(proc_dir, "meminfo"),
      swapfile_path: Path.join(tmp_dir, "swapfile"),
      zswap_param_dir: zswap_dir,
      name: nil
    ]
  end

  # Reports every invocation to `parent` and answers from `responses`, a
  # keyword-ish list of `{bin, {output, status}}` consumed in order per
  # binary (so `swapon` can fail once and succeed on the retry). Anything
  # unscripted succeeds.
  defp scripted_cmd(parent, responses \\ []) do
    # An ETS table rather than an Agent: the fn runs inside the GenServer,
    # so the queue has to live outside both processes.
    table = :ets.new(:swap_cmd_script, [:public, :set])
    :ets.insert(table, {:queue, responses})

    fn bin, args ->
      send(parent, {:cmd, bin, args})
      [{:queue, queue}] = :ets.lookup(table, :queue)

      case Enum.split_while(queue, fn {b, _r} -> b != bin end) do
        {before, [{^bin, response} | rest]} ->
          :ets.insert(table, {:queue, before ++ rest})
          response

        {_before, []} ->
          {"", 0}
      end
    end
  end

  defp start_swap(opts) do
    pid = start_supervised!({Swap, opts})
    # `handle_continue` runs before any other message, so a state read is a
    # completion barrier for the whole flow.
    {pid, :sys.get_state(pid).result}
  end

  defp read!(path), do: File.read!(path)

  defp collect_cmds(acc \\ []) do
    receive do
      {:cmd, bin, args} -> collect_cmds([{bin, args} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:vagus, key)
  defp restore_env(key, value), do: Application.put_env(:vagus, key, value)

  # --- gate + validation ----------------------------------------------------

  test "disabled config -> :ignore, no process registered" do
    prev = Application.get_env(:vagus, :host_swap)
    Application.put_env(:vagus, :host_swap, false)
    on_exit(fn -> restore_env(:host_swap, prev) end)

    assert :ignore = Swap.start_link([])
    assert Process.whereis(Swap) == nil
  end

  @tag :tmp_dir
  test "swapfile_path not named \"swapfile\" -> {:failed, _}, nothing read or run", %{
    tmp_dir: tmp_dir
  } do
    parent = self()

    opts =
      tmp_dir
      |> fixture(disk: "sda", mount_device: "/dev/sda5")
      |> Keyword.put(:swapfile_path, Path.join(tmp_dir, "etc-shadow"))

    log =
      capture_log(fn ->
        assert {pid, {:failed, reason}} = start_swap([{:cmd, scripted_cmd(parent)} | opts])
        assert reason =~ "must be named swapfile"
        assert Process.alive?(pid)
      end)

    assert log =~ "etc-shadow"
    assert collect_cmds() == []
  end

  # --- already-active short circuit ----------------------------------------

  @tag :tmp_dir
  test "swap already active -> :already_active, no commands at all", %{tmp_dir: tmp_dir} do
    parent = self()

    opts =
      fixture(tmp_dir,
        swaps: "Filename\tType\tSize\tUsed\tPriority\n/dev/zram0\tpartition\t1\t0\t100\n"
      )

    log =
      capture_log(fn ->
        assert {_pid, :already_active} = start_swap([{:cmd, scripted_cmd(parent)} | opts])
      end)

    assert log =~ "already active"
    assert log =~ "/dev/zram0"
    assert collect_cmds() == []
  end

  @tag :tmp_dir
  test "unreadable /proc/swaps -> skipped, never reaches mkswap", %{tmp_dir: tmp_dir} do
    parent = self()
    opts = fixture(tmp_dir, disk: "mmcblk0")
    File.rm!(opts[:swaps_path])

    capture_log(fn ->
      assert {_pid, {:skipped, reason}} = start_swap([{:cmd, scripted_cmd(parent)} | opts])
      assert reason =~ "can't read"
      assert reason =~ "swaps"
    end)

    assert collect_cmds() == []
  end

  # --- zram ----------------------------------------------------------------

  @tag :tmp_dir
  test "mmcblk root -> zram at half of RAM, lz4, swappiness 150, page-cluster 0", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    opts = fixture(tmp_dir, disk: "mmcblk0")
    enabled = Path.join(opts[:zswap_param_dir], "enabled")
    # Seeded on, unlike the fixture's default "N", so the read at mkswap
    # time can only come back "N" if the write actually ran first.
    File.write!(enabled, "Y")
    scripted = scripted_cmd(parent)

    # Reading the parameter from inside `mkswap` dates the zswap write: it
    # must be off before the device is ever mkswap'd.
    cmd = fn
      "mkswap", args ->
        send(parent, {:zswap_at_mkswap, read!(enabled)})
        scripted.("mkswap", args)

      bin, args ->
        scripted.(bin, args)
    end

    log =
      capture_log(fn ->
        assert {_pid, {:zram, 473}} = start_swap([{:cmd, cmd} | opts])
      end)

    assert_received {:zswap_at_mkswap, "N"}

    zram_dir = Path.join([tmp_dir, "sys", "block", "zram0"])
    assert read!(Path.join(zram_dir, "comp_algorithm")) == "lz4"
    assert read!(Path.join(zram_dir, "disksize")) == to_string(div(@pi_bytes, 2))

    assert collect_cmds() == [
             {"mkswap", ["/dev/zram0"]},
             {"swapon", ["-p", "100", "/dev/zram0"]}
           ]

    assert read!(Path.join([tmp_dir, "proc", "sys", "vm", "swappiness"])) == "150"
    assert read!(Path.join([tmp_dir, "proc", "sys", "vm", "page-cluster"])) == "0"
    assert read!(enabled) == "N"
    assert log =~ "zram 473 MiB active, swappiness 150"
  end

  @tag :tmp_dir
  test "zram without lz4 -> comp_algorithm untouched, warning, setup continues", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    opts = fixture(tmp_dir, disk: "mmcblk0", comp_algorithm: "lzo [lzo-rle]")

    log =
      capture_log(fn ->
        assert {_pid, {:zram, 473}} = start_swap([{:cmd, scripted_cmd(parent)} | opts])
      end)

    assert read!(Path.join([tmp_dir, "sys", "block", "zram0", "comp_algorithm"])) ==
             "lzo [lzo-rle]"

    assert log =~ "no lz4"
    assert collect_cmds() == [{"mkswap", ["/dev/zram0"]}, {"swapon", ["-p", "100", "/dev/zram0"]}]
  end

  @tag :tmp_dir
  test "no zram0 sysfs dir -> skipped, no commands", %{tmp_dir: tmp_dir} do
    parent = self()
    opts = fixture(tmp_dir, disk: "mmcblk0", zram_dir?: false)

    capture_log(fn ->
      assert {_pid, {:skipped, reason}} = start_swap([{:cmd, scripted_cmd(parent)} | opts])
      assert reason =~ "zram0"
    end)

    assert collect_cmds() == []
  end

  @tag :tmp_dir
  test "mkswap fails on the zram path -> {:failed, _}, warning, process alive", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    opts = fixture(tmp_dir, disk: "mmcblk0")
    cmd = scripted_cmd(parent, [{"mkswap", {"mkswap: :enoent", 127}}])

    log =
      capture_log(fn ->
        assert {pid, {:failed, reason}} = start_swap([{:cmd, cmd} | opts])
        assert reason =~ "127"
        assert Process.alive?(pid)
      end)

    assert log =~ "mkswap: :enoent"
    # swapon must not run after a failed mkswap.
    assert collect_cmds() == [{"mkswap", ["/dev/zram0"]}]
    assert read!(Path.join([tmp_dir, "proc", "sys", "vm", "swappiness"])) == "60"
  end

  @tag :tmp_dir
  test "zram disksize write fails -> {:failed, _}, no commands, lz4 still selected", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    opts = fixture(tmp_dir, disk: "mmcblk0")
    zram_dir = Path.join([tmp_dir, "sys", "block", "zram0"])
    # A directory where the kernel would put an attribute: `File.write` fails
    # with :eisdir, which is the shape of a write to a real read-only sysfs.
    File.rm!(Path.join(zram_dir, "disksize"))
    File.mkdir!(Path.join(zram_dir, "disksize"))

    log =
      capture_log(fn ->
        assert {pid, {:failed, reason}} = start_swap([{:cmd, scripted_cmd(parent)} | opts])
        assert reason =~ "can't set zram disksize"
        assert Process.alive?(pid)
      end)

    assert log =~ "leaving zram0 alone until reboot"
    assert collect_cmds() == []
    # comp_algorithm precedes disksize — the kernel only accepts it while the
    # device is uninitialised — so it is written even on this path.
    assert read!(Path.join(zram_dir, "comp_algorithm")) == "lz4"
  end

  @tag :tmp_dir
  test "unreadable comp_algorithm -> warning, zram still initialised", %{tmp_dir: tmp_dir} do
    parent = self()
    opts = fixture(tmp_dir, disk: "mmcblk0")
    zram_dir = Path.join([tmp_dir, "sys", "block", "zram0"])
    File.rm!(Path.join(zram_dir, "comp_algorithm"))

    log =
      capture_log(fn ->
        assert {_pid, {:zram, 473}} = start_swap([{:cmd, scripted_cmd(parent)} | opts])
      end)

    assert log =~ "can't read"
    assert log =~ "comp_algorithm"
    assert read!(Path.join(zram_dir, "disksize")) == to_string(div(@pi_bytes, 2))

    assert collect_cmds() == [
             {"mkswap", ["/dev/zram0"]},
             {"swapon", ["-p", "100", "/dev/zram0"]}
           ]
  end

  # --- swapfile ------------------------------------------------------------

  @tag :tmp_dir
  test "sda root, 1 GB RAM -> swapfile clamped up to 1 GiB, mkswap retry, swappiness 10", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5")
    enabled = Path.join(opts[:zswap_param_dir], "enabled")
    scripted = scripted_cmd(parent, [{"swapon", {"swapon: read swap header failed", 255}}])

    # Reading the parameter from inside `dd` dates the zswap write: the
    # swapfile must not exist before zswap is on.
    cmd = fn
      "dd", args ->
        send(parent, {:zswap_at_dd, read!(enabled)})
        scripted.("dd", args)

      bin, args ->
        scripted.(bin, args)
    end

    log =
      capture_log(fn ->
        assert {_pid, {:swapfile, 1024}} =
                 start_swap([{:cmd, cmd}, {:df, fn _mp -> {:ok, 8 * @gib} end} | opts])
      end)

    assert_received {:zswap_at_dd, "Y"}
    swapfile = opts[:swapfile_path]

    assert collect_cmds() == [
             {"dd", ["if=/dev/zero", "of=#{swapfile}.tmp", "bs=4k", "count=262144"]},
             {"swapon", [swapfile]},
             {"mkswap", [swapfile]},
             {"swapon", [swapfile]}
           ]

    # Only the completed file is renamed into place, at 0600.
    assert (File.stat!(swapfile).mode &&& 0o777) == 0o600
    refute File.exists?(swapfile <> ".tmp")

    assert read!(Path.join(opts[:zswap_param_dir], "enabled")) == "Y"
    assert read!(Path.join([tmp_dir, "proc", "sys", "vm", "swappiness"])) == "10"
    # page-cluster is a zram-only knob.
    assert read!(Path.join([tmp_dir, "proc", "sys", "vm", "page-cluster"])) == "3"
    assert log =~ "swapfile 1024 MiB active, swappiness 10"
  end

  @tag :tmp_dir
  test "nvme root, 16 GiB RAM -> swapfile clamped down to 4 GiB", %{tmp_dir: tmp_dir} do
    parent = self()

    opts =
      fixture(tmp_dir,
        disk: "nvme0n1",
        mount_device: "/dev/nvme0n1p5",
        mem_kb: div(16 * @gib, 1024)
      )

    capture_log(fn ->
      assert {_pid, {:swapfile, 4096}} =
               start_swap([
                 {:cmd, scripted_cmd(parent)},
                 {:df, fn _mp -> {:ok, 64 * @gib} end} | opts
               ])
    end)

    swapfile = opts[:swapfile_path]

    tmp = swapfile <> ".tmp"

    assert [{"dd", ["if=/dev/zero", "of=" <> ^tmp, "bs=4k", "count=1048576"]} | _rest] =
             collect_cmds()
  end

  @tag :tmp_dir
  test "nvme root, 12 GiB RAM -> swapfile is 33% of RAM rounded to 4 KiB", %{tmp_dir: tmp_dir} do
    parent = self()
    mem = 12 * @gib
    expected_size = div(div(mem * 33, 100), 4096) * 4096

    opts =
      fixture(tmp_dir, disk: "nvme0n1", mount_device: "/dev/nvme0n1p5", mem_kb: div(mem, 1024))

    capture_log(fn ->
      assert {_pid, {:swapfile, mib}} =
               start_swap([
                 {:cmd, scripted_cmd(parent)},
                 {:df, fn _mp -> {:ok, 64 * @gib} end} | opts
               ])

      assert mib == div(expected_size, @mib)
    end)

    tmp = opts[:swapfile_path] <> ".tmp"
    count = "count=#{div(expected_size, 4096)}"

    assert [{"dd", ["if=/dev/zero", "of=" <> ^tmp, "bs=4k", ^count]} | _rest] =
             collect_cmds()
  end

  @tag :tmp_dir
  test "existing swapfile within slack -> reused at 0600, no dd, no df", %{tmp_dir: tmp_dir} do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5")
    # 8 MiB under the 1 GiB target, inside the 32 MiB slack.
    stub_size(opts[:swapfile_path], @gib - 8 * @mib)
    File.chmod!(opts[:swapfile_path], 0o644)

    df = fn _mp ->
      send(parent, :df_called)
      :error
    end

    log =
      capture_log(fn ->
        assert {_pid, {:swapfile, 1024}} =
                 start_swap([{:cmd, scripted_cmd(parent)}, {:df, df} | opts])
      end)

    assert collect_cmds() == [{"swapon", [opts[:swapfile_path]]}]
    assert log =~ "reusing existing swapfile"
    # The mode is tightened before the file the module didn't create is
    # handed to swapon.
    assert (File.stat!(opts[:swapfile_path]).mode &&& 0o777) == 0o600
    # Nothing is written, so free space is never consulted.
    refute_received :df_called
  end

  @tag :tmp_dir
  test "existing swapfile of the wrong size -> removed and recreated", %{tmp_dir: tmp_dir} do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5")
    stub_size(opts[:swapfile_path], 128 * @mib)

    capture_log(fn ->
      assert {_pid, {:swapfile, 1024}} =
               start_swap([
                 {:cmd, scripted_cmd(parent)},
                 {:df, fn _mp -> {:ok, 8 * @gib} end} | opts
               ])
    end)

    swapfile = opts[:swapfile_path]
    tmp = swapfile <> ".tmp"
    cmds = collect_cmds()

    assert [{"dd", ["if=/dev/zero", "of=" <> ^tmp, "bs=4k", "count=262144"]} | _rest] = cmds
    # The stale file is gone: the dd fake writes nothing, so what's on disk
    # is the empty file `touch_swapfile/1` created.
    assert File.stat!(swapfile).size == 0
  end

  @tag :tmp_dir
  test "dd fails -> {:failed, _} and neither the swapfile nor its tmp is left behind", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5")
    cmd = scripted_cmd(parent, [{"dd", {"dd: No space left on device", 1}}])

    log =
      capture_log(fn ->
        assert {_pid, {:failed, reason}} =
                 start_swap([{:cmd, cmd}, {:df, fn _mp -> {:ok, 8 * @gib} end} | opts])

        assert reason =~ "dd exited 1"
        refute reason =~ "could not remove"
      end)

    swapfile = opts[:swapfile_path]

    # Nothing is formatted or swapon'd after a failed dd.
    assert collect_cmds() == [
             {"dd", ["if=/dev/zero", "of=#{swapfile}.tmp", "bs=4k", "count=262144"]}
           ]

    refute File.exists?(swapfile)
    refute File.exists?(swapfile <> ".tmp")
    assert log =~ "No space left"
  end

  @tag :tmp_dir
  test "a leftover .tmp is removed, not extended, before dd runs", %{tmp_dir: tmp_dir} do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5")
    tmp = opts[:swapfile_path] <> ".tmp"
    # What a killed dd leaves: near the target size, so it would pass the
    # reuse slack if it ever reached the real path.
    stub_size(tmp, @gib - 8 * @mib)

    log =
      capture_log(fn ->
        assert {_pid, {:swapfile, 1024}} =
                 start_swap([
                   {:cmd, scripted_cmd(parent)},
                   {:df, fn _mp -> {:ok, 8 * @gib} end} | opts
                 ])
      end)

    assert log =~ "removing leftover"

    assert [{"dd", ["if=/dev/zero", "of=" <> ^tmp, "bs=4k", "count=262144"]} | _rest] =
             collect_cmds()

    # The dd fake writes nothing, so a zero-length file at the real path
    # proves the leftover was replaced rather than renamed into place.
    assert File.stat!(opts[:swapfile_path]).size == 0
    refute File.exists?(tmp)
  end

  @tag :tmp_dir
  test "dd fails and its tmp can't be removed -> the error names the leftover", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    dir = Path.join(tmp_dir, "readonly")
    File.mkdir!(dir)
    # Clearing the directory's write bit is the only way to make `File.rm`
    # fail without a real filesystem, and root ignores it.
    on_exit(fn -> File.chmod(dir, 0o700) end)

    opts =
      tmp_dir
      |> fixture(disk: "sda", mount_device: "/dev/sda5")
      |> Keyword.put(:swapfile_path, Path.join(dir, "swapfile"))

    cmd = fn
      "dd", args ->
        send(parent, {:cmd, "dd", args})
        File.chmod!(dir, 0o500)
        {"dd: No space left on device", 1}

      bin, args ->
        send(parent, {:cmd, bin, args})
        {"", 0}
    end

    log =
      capture_log(fn ->
        assert {_pid, {:failed, reason}} =
                 start_swap([{:cmd, cmd}, {:df, fn _mp -> {:ok, 8 * @gib} end} | opts])

        assert reason =~ "dd exited 1"

        if root?() do
          refute reason =~ "could not remove"
        else
          assert reason =~ "could not remove"
          assert reason =~ "swapfile.tmp"
        end
      end)

    assert log =~ "No space left"
  end

  @tag :tmp_dir
  test "swapon fails twice -> one mkswap, two swapons, {:failed, _}", %{tmp_dir: tmp_dir} do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5")

    cmd =
      scripted_cmd(parent, [
        {"swapon", {"swapon: nope", 255}},
        {"swapon", {"swapon: still nope", 255}}
      ])

    log =
      capture_log(fn ->
        assert {pid, {:failed, reason}} =
                 start_swap([{:cmd, cmd}, {:df, fn _mp -> {:ok, 8 * @gib} end} | opts])

        assert reason =~ "255"
        assert Process.alive?(pid)
      end)

    swapfile = opts[:swapfile_path]

    assert collect_cmds() == [
             {"dd", ["if=/dev/zero", "of=#{swapfile}.tmp", "bs=4k", "count=262144"]},
             {"swapon", [swapfile]},
             {"mkswap", [swapfile]},
             {"swapon", [swapfile]}
           ]

    assert log =~ "still nope"
    assert read!(Path.join([tmp_dir, "proc", "sys", "vm", "swappiness"])) == "60"
  end

  @tag :tmp_dir
  test "/root on a different disk than rootdisk -> skipped, no swapfile", %{tmp_dir: tmp_dir} do
    parent = self()
    opts = fixture(tmp_dir, disk: "nvme0n1", mount_device: "/dev/nvme1n1p5")

    capture_log(fn ->
      assert {_pid, {:skipped, reason}} =
               start_swap([
                 {:cmd, scripted_cmd(parent)},
                 {:df, fn _mp -> {:ok, 8 * @gib} end} | opts
               ])

      assert reason =~ "nvme1n1"
      assert reason =~ "nvme0n1"
    end)

    assert collect_cmds() == []
    refute File.exists?(opts[:swapfile_path])
    # zswap precedes the disk-identity check: a kernel knob with nothing to
    # compress until some swap device exists.
    assert read!(Path.join(opts[:zswap_param_dir], "enabled")) == "Y"
    assert read!(Path.join([tmp_dir, "proc", "sys", "vm", "swappiness"])) == "60"
  end

  @tag :tmp_dir
  test "/data instead of /root in the mount table -> swapfile path still proceeds", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5", mountpoint: "/data")

    capture_log(fn ->
      assert {_pid, {:swapfile, 1024}} =
               start_swap([
                 {:cmd, scripted_cmd(parent)},
                 {:df, fn "/data" -> {:ok, 8 * @gib} end} | opts
               ])
    end)
  end

  @tag :tmp_dir
  test "/data and /root both mounted -> /data decides where the swapfile would go", %{
    tmp_dir: tmp_dir
  } do
    parent = self()

    opts =
      fixture(tmp_dir, disk: "sda", mounts: [{"/dev/sda5", "/root"}, {"/dev/nvme0n1p1", "/data"}])

    capture_log(fn ->
      assert {_pid, {:skipped, reason}} =
               start_swap([
                 {:cmd, scripted_cmd(parent)},
                 {:df, fn _mp -> {:ok, 8 * @gib} end} | opts
               ])

      # `/root` is on the root disk and would have proceeded — only the
      # `/data` entry can produce this skip.
      assert reason =~ "/data is on nvme0n1"
      assert reason =~ "not on the root disk sda"
    end)

    assert collect_cmds() == []
    refute File.exists?(opts[:swapfile_path])
  end

  @tag :tmp_dir
  test "no zswap parameters -> swapfile path skipped before any disk is touched", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5")
    File.rm!(Path.join(opts[:zswap_param_dir], "enabled"))

    capture_log(fn ->
      assert {_pid, {:skipped, reason}} =
               start_swap([
                 {:cmd, scripted_cmd(parent)},
                 {:df, fn _mp -> {:ok, 8 * @gib} end} | opts
               ])

      assert reason =~ "zswap"
    end)

    assert collect_cmds() == []
    refute File.exists?(opts[:swapfile_path])
    refute File.exists?(opts[:swapfile_path] <> ".tmp")
  end

  @tag :tmp_dir
  test "zswap enabled can't be written -> {:failed, _}, no commands, no swapfile", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5")
    enabled = Path.join(opts[:zswap_param_dir], "enabled")
    # A directory where the kernel would put the parameter: `File.write`
    # fails with :eisdir, the shape of a sysfs write the kernel refuses.
    File.rm!(enabled)
    File.mkdir!(enabled)

    log =
      capture_log(fn ->
        assert {_pid, {:failed, reason}} =
                 start_swap([
                   {:cmd, scripted_cmd(parent)},
                   {:df, fn _mp -> {:ok, 8 * @gib} end} | opts
                 ])

        assert reason =~ "can't enable zswap"
      end)

    assert log =~ ":eisdir"
    assert collect_cmds() == []
    refute File.exists?(opts[:swapfile_path])
  end

  @tag :tmp_dir
  test "not enough free space -> skipped, error logged, nothing written", %{tmp_dir: tmp_dir} do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5")

    log =
      capture_log(fn ->
        assert {_pid, {:skipped, reason}} =
                 start_swap([
                   {:cmd, scripted_cmd(parent)},
                   {:df, fn _mp -> {:ok, 100 * @mib} end} | opts
                 ])

        assert reason =~ "free space"
      end)

    assert log =~ "not enough free space"
    assert log =~ "have 100 MiB"
    assert collect_cmds() == []
    refute File.exists?(opts[:swapfile_path])
  end

  @tag :tmp_dir
  test "free space without the headroom -> skipped, headroom named in the log", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5")

    log =
      capture_log(fn ->
        assert {_pid, {:skipped, reason}} =
                 start_swap([
                   {:cmd, scripted_cmd(parent)},
                   {:df, fn _mp -> {:ok, @gib + 100 * @mib} end} | opts
                 ])

        assert reason =~ "free space"
      end)

    assert log =~ "need 1024 MiB + 512 MiB headroom, have 1124 MiB"
    assert collect_cmds() == []
    refute File.exists?(opts[:swapfile_path])
  end

  @tag :tmp_dir
  test "df can't measure the create path -> skipped, no dd", %{tmp_dir: tmp_dir} do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5")

    capture_log(fn ->
      assert {_pid, {:skipped, reason}} =
               start_swap([{:cmd, scripted_cmd(parent)}, {:df, fn _mp -> :error end} | opts])

      assert reason =~ "can't measure free space"
    end)

    assert collect_cmds() == []
    refute File.exists?(opts[:swapfile_path])
  end

  @tag :tmp_dir
  test "unreadable /proc/mounts -> skipped, no swapfile", %{tmp_dir: tmp_dir} do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5")
    File.rm!(opts[:mounts_path])

    capture_log(fn ->
      assert {_pid, {:skipped, reason}} =
               start_swap([
                 {:cmd, scripted_cmd(parent)},
                 {:df, fn _mp -> {:ok, 8 * @gib} end} | opts
               ])

      assert reason =~ "can't read"
      assert reason =~ "mounts"
    end)

    assert collect_cmds() == []
    refute File.exists?(opts[:swapfile_path])
  end

  @tag :tmp_dir
  test "rm of a stale swapfile fails -> {:failed, _}, nothing formatted", %{tmp_dir: tmp_dir} do
    parent = self()
    dir = Path.join(tmp_dir, "locked")
    File.mkdir!(dir)
    swapfile = Path.join(dir, "swapfile")
    stub_size(swapfile, 128 * @mib)

    opts =
      tmp_dir
      |> fixture(disk: "sda", mount_device: "/dev/sda5")
      |> Keyword.put(:swapfile_path, swapfile)

    # Clearing the directory's write bit is the only way to make `File.rm`
    # fail without a real filesystem, and root ignores it — so under root
    # there is no failure to observe and only the fixture holds.
    File.chmod!(dir, 0o500)
    on_exit(fn -> File.chmod(dir, 0o700) end)

    if root?() do
      assert File.stat!(swapfile).size == 128 * @mib
    else
      log =
        capture_log(fn ->
          assert {_pid, {:failed, reason}} =
                   start_swap([
                     {:cmd, scripted_cmd(parent)},
                     {:df, fn _mp -> {:ok, 8 * @gib} end} | opts
                   ])

          assert reason =~ "can't remove stale swapfile"
        end)

      assert log =~ ":eacces"
      assert collect_cmds() == []
      assert File.stat!(swapfile).size == 128 * @mib
    end
  end

  @tag :tmp_dir
  test "swapfile path is a directory -> skipped, nothing touched, directory survives", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5")
    File.mkdir_p!(opts[:swapfile_path])

    capture_log(fn ->
      assert {_pid, {:skipped, reason}} =
               start_swap([
                 {:cmd, scripted_cmd(parent)},
                 {:df, fn _mp -> {:ok, 8 * @gib} end} | opts
               ])

      assert reason =~ "not a regular file"
    end)

    assert collect_cmds() == []
    assert File.dir?(opts[:swapfile_path])
  end

  # --- retry after a free-space skip ---------------------------------------

  @tag :tmp_dir
  test "free-space skip -> one retry, which succeeds once /data has grown", %{tmp_dir: tmp_dir} do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5")
    table = df_table(100 * @mib)

    log =
      capture_log(fn ->
        assert {pid, {:skipped, reason}} =
                 start_swap([
                   {:cmd, scripted_cmd(parent)},
                   {:df, table_df(table)},
                   {:retry_after, 60_000} | opts
                 ])

        assert reason =~ "free space"
        assert collect_cmds() == []

        # What `resize2fs` does to `/data` a moment after we measured it.
        :ets.insert(table, {:free, 8 * @gib})
        send(pid, :retry)
        assert :sys.get_state(pid).result == {:swapfile, 1024}
      end)

    assert log =~ "retrying in 60 s"
    tmp = opts[:swapfile_path] <> ".tmp"

    assert [{"dd", ["if=/dev/zero", "of=" <> ^tmp, "bs=4k", "count=262144"]}] =
             Enum.filter(collect_cmds(), fn {bin, _args} -> bin == "dd" end)
  end

  @tag :tmp_dir
  test "still no free space on the retry -> no dd, and a further :retry is a no-op", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5")
    table = df_table(100 * @mib)

    capture_log(fn ->
      assert {pid, {:skipped, _reason}} =
               start_swap([
                 {:cmd, scripted_cmd(parent)},
                 {:df, table_df(table)},
                 {:retry_after, 60_000} | opts
               ])

      send(pid, :retry)
      assert {:skipped, _reason} = :sys.get_state(pid).result
      assert df_calls(table) == 2

      # The budget is one retry: a third message runs nothing at all.
      send(pid, :retry)
      assert {:skipped, _reason} = :sys.get_state(pid).result
      assert df_calls(table) == 2
    end)

    assert collect_cmds() == []
    refute File.exists?(opts[:swapfile_path])
  end

  @tag :tmp_dir
  test "a skip that is not about free space schedules nothing", %{tmp_dir: tmp_dir} do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5")
    table = df_table(0)

    df = fn _mountpoint ->
      :ets.update_counter(table, :calls, 1)
      :error
    end

    capture_log(fn ->
      assert {pid, {:skipped, reason}} =
               start_swap([{:cmd, scripted_cmd(parent)}, {:df, df}, {:retry_after, 10} | opts])

      assert reason =~ "can't measure free space"
      # Ten times the retry delay: a scheduled retry would have fired.
      Process.sleep(100)
      assert :sys.get_state(pid).result == {:skipped, reason}
      assert df_calls(table) == 1
    end)

    assert collect_cmds() == []
  end

  @tag :tmp_dir
  test "an unexpected message is ignored, not a crash", %{tmp_dir: tmp_dir} do
    parent = self()
    opts = fixture(tmp_dir, disk: "mmcblk0")

    capture_log(fn ->
      assert {pid, {:zram, 473}} = start_swap([{:cmd, scripted_cmd(parent)} | opts])

      send(pid, {:tcp_closed, :nothing_we_own})
      assert :sys.get_state(pid).result == {:zram, 473}
      assert Process.alive?(pid)
    end)
  end

  # --- classification + crash isolation ------------------------------------

  @tag :tmp_dir
  test "unrecognised root disk -> skipped, no commands", %{tmp_dir: tmp_dir} do
    parent = self()
    opts = fixture(tmp_dir, disk: "loop0")

    capture_log(fn ->
      assert {_pid, {:skipped, reason}} = start_swap([{:cmd, scripted_cmd(parent)} | opts])
      assert reason =~ "loop0"
    end)

    assert collect_cmds() == []
  end

  @tag :tmp_dir
  test "unreadable meminfo -> skipped", %{tmp_dir: tmp_dir} do
    parent = self()
    opts = fixture(tmp_dir, disk: "mmcblk0")
    File.rm!(opts[:meminfo_path])

    capture_log(fn ->
      assert {_pid, {:skipped, reason}} = start_swap([{:cmd, scripted_cmd(parent)} | opts])
      assert reason =~ "MemTotal"
    end)

    assert collect_cmds() == []
  end

  @tag :tmp_dir
  test "a raising seam -> {:error, :crashed}, logged, process alive and answering", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5")

    log =
      capture_log(fn ->
        assert {pid, {:error, :crashed}} =
                 start_swap([
                   {:cmd, scripted_cmd(parent)},
                   {:df, fn _mp -> raise "boom" end} | opts
                 ])

        assert Process.alive?(pid)
        # A second read proves it isn't crash-looping behind our back.
        assert :sys.get_state(pid).result == {:error, :crashed}
      end)

    assert log =~ "boom"
    assert log =~ "crashed"
  end

  # --- default df parsing ---------------------------------------------------

  @tag :tmp_dir
  test "default df seam parses busybox `df -Pk` output", %{tmp_dir: tmp_dir} do
    parent = self()
    opts = fixture(tmp_dir, disk: "sda", mount_device: "/dev/sda5")

    df_output = """
    Filesystem         1024-blocks      Used Available Capacity Mounted on
    /dev/sda5             30000000    100000   8000000       2% /root
    """

    cmd = fn
      "df", args ->
        send(parent, {:cmd, "df", args})
        {df_output, 0}

      bin, args ->
        send(parent, {:cmd, bin, args})
        {"", 0}
    end

    capture_log(fn ->
      assert {_pid, {:swapfile, 1024}} = start_swap([{:cmd, cmd} | opts])
    end)

    assert {"df", ["-Pk", "/root"]} in collect_cmds()
  end

  # A `df` seam answering from ETS, so a test can grow the filesystem between
  # the first run and the retry, and count how often it was consulted.
  defp df_table(free) do
    table = :ets.new(:swap_df, [:public, :set])
    :ets.insert(table, [{:free, free}, {:calls, 0}])
    table
  end

  defp table_df(table) do
    fn _mountpoint ->
      :ets.update_counter(table, :calls, 1)
      {:ok, :ets.lookup_element(table, :free, 2)}
    end
  end

  defp df_calls(table), do: :ets.lookup_element(table, :calls, 2)

  defp root? do
    {uid, 0} = System.cmd("id", ["-u"])
    String.trim(uid) == "0"
  end

  # Grows `path` to `size` without writing `size` bytes — the tests care
  # about `File.stat/1`'s view of an existing swapfile, not its contents.
  defp stub_size(path, size) do
    File.open!(path, [:write], fn io ->
      :file.position(io, size - 1)
      IO.binwrite(io, <<0>>)
    end)
  end
end
