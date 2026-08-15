defmodule Vagus.Addon.SystemDiskTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.Addon.SystemDisk

  # A fake sysfs: `<sysfs>/<name>/dev` holds "major:minor", and a partition
  # additionally has a `partition` file. Partitions live *inside* their disk's
  # directory, which is what makes `Path.join(part_dir, "..")` the disk — the
  # same shape the real /sys/class/block symlinks resolve to.
  defp fake_sysfs(ctx) do
    root = Path.join(System.tmp_dir!(), "vagus-sysfs-#{System.unique_integer([:positive])}")
    disk = Path.join(root, "mmcblk0")
    File.mkdir_p!(disk)
    File.write!(Path.join(disk, "dev"), "179:0\n")

    for {name, devnum} <- [{"mmcblk0p1", "179:1"}, {"mmcblk0p2", "179:2"}, {"mmcblk0p5", "179:5"}] do
      part = Path.join(disk, name)
      File.mkdir_p!(part)
      File.write!(Path.join(part, "dev"), devnum <> "\n")
      File.write!(Path.join(part, "partition"), "1\n")
      # /sys/class/block/<part> is a flat symlink into the tree; mirror that
      # so lookups by basename find the partition dir.
      File.ln_s!(part, Path.join(root, name))
    end

    on_exit(fn -> File.rm_rf(root) end)
    Map.put(ctx, :sysfs, root)
  end

  defp mounts(lines) do
    path = Path.join(System.tmp_dir!(), "vagus-mounts-#{System.unique_integer([:positive])}")
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "devnums/1" do
    setup :fake_sysfs

    test "a mounted system partition blocks itself, its disk, and its siblings", %{sysfs: sysfs} do
      # Only p5 is mounted. The whole medium still goes — on a Nerves
      # appliance every partition of the boot device is system storage.
      path =
        mounts([
          "/dev/mmcblk0p5 /root ext4 rw,relatime 0 0",
          "proc /proc proc rw,nosuid 0 0"
        ])

      devnums = SystemDisk.devnums(mounts_path: path, sysfs_block: sysfs)

      assert SystemDisk.blocked?(devnums, 179, 5), "the mounted partition itself"
      assert SystemDisk.blocked?(devnums, 179, 0), "the whole disk it sits on"
      assert SystemDisk.blocked?(devnums, 179, 1), "a sibling partition"
      assert SystemDisk.blocked?(devnums, 179, 2), "another sibling"
    end

    test "an unrelated disk is not blocked", %{sysfs: sysfs} do
      path = mounts(["/dev/mmcblk0p5 /root ext4 rw 0 0"])
      devnums = SystemDisk.devnums(mounts_path: path, sysfs_block: sysfs)

      # 8:0 is a different major entirely — a USB disk stays grantable, which
      # is the whole point of not simply refusing every block device.
      refute SystemDisk.blocked?(devnums, 8, 0)
    end

    test "pseudo-filesystems in the device column are ignored", %{sysfs: sysfs} do
      # `overlay`, `tmpfs` and `none` all appear in the device column and name
      # no block device; stat-ing them would either fail or hit a stray file.
      path =
        mounts([
          "overlay / overlay rw 0 0",
          "tmpfs /run tmpfs rw 0 0",
          "none /data tmpfs rw 0 0"
        ])

      assert SystemDisk.devnums(mounts_path: path, sysfs_block: sysfs) == MapSet.new()
    end

    test "a non-system mountpoint contributes nothing", %{sysfs: sysfs} do
      path = mounts(["/dev/mmcblk0p5 /mnt/usb ext4 rw 0 0"])

      assert SystemDisk.devnums(mounts_path: path, sysfs_block: sysfs) == MapSet.new()
    end

    test "a system mount sysfs cannot map collapses the whole answer to :unknown", %{sysfs: sysfs} do
      # The dangerous case: returning the partial set here would turn a
      # resolver failure into an allow decision for the very disk that failed
      # to resolve.
      path =
        mounts([
          "/dev/mmcblk0p5 /root ext4 rw 0 0",
          "/dev/mysteryblk /boot ext4 rw 0 0"
        ])

      log =
        capture_log(fn ->
          assert SystemDisk.devnums(mounts_path: path, sysfs_block: sysfs) == :unknown
        end)

      assert log =~ "sysfs has no entry"
      assert log =~ "refusing all block devices"
    end

    test "a malformed dev file collapses to :unknown", %{sysfs: sysfs} do
      File.write!(Path.join([sysfs, "mmcblk0", "mmcblk0p1", "dev"]), "not-a-devnum\n")
      path = mounts(["/dev/mmcblk0p5 /root ext4 rw 0 0"])

      log =
        capture_log(fn ->
          assert SystemDisk.devnums(mounts_path: path, sysfs_block: sysfs) == :unknown
        end)

      assert log =~ "cannot read a devnum"
    end

    test "an unreadable mount table is :unknown, and :unknown blocks everything" do
      log =
        capture_log(fn ->
          assert SystemDisk.devnums(mounts_path: "/nonexistent/mounts") == :unknown
        end)

      assert log =~ "cannot read"

      # Fail-closed: not knowing which disk is the system's must never resolve
      # to handing it out.
      assert SystemDisk.blocked?(:unknown, 179, 0)
      assert SystemDisk.blocked?(:unknown, 8, 0)
    end
  end

  describe "the real host" do
    test "reading the actual mount table does not crash and blocks nothing spurious" do
      # Non-hermetic on purpose but assertion-free about *which* devices: the
      # value is proving the parser survives a real /proc/mounts (overlay
      # roots, bind mounts, cgroup2) rather than only the fixture's shape.
      assert match?(%MapSet{}, SystemDisk.devnums()) or SystemDisk.devnums() == :unknown
    end
  end
end
