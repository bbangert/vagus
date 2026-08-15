defmodule Vagus.Addon.SystemDisk do
  @moduledoc """
  Which block devices an add-on may never be granted — the storage the system
  itself runs from.

  Upstream refuses these in `hardware/policy.py`'s `allowed_for_access/1`,
  which `docker/app.py` consults *before* emitting each cgroup rule
  (`"App %s tried to access blocked device %s!"`, then `continue`). Its test is
  `disk.is_used_by_system/1`: a block partition whose udev `ID_FS_LABEL` starts
  with `hassos`, or a whole disk owning such a partition.

  **The label is not portable and the mechanism here diverges.** Nerves runs no
  udev, so there is no `ID_FS_LABEL` to read, and Vagus's partitions are not
  labelled `hassos*` anyway. This asks the kernel a question it can always
  answer instead: which block device numbers currently back the system's own
  mounts (`#{inspect(~w(/ /boot /root /data))}`), plus — via sysfs — the whole
  disk each one sits on and every other partition of that disk.

  That is **stricter than upstream**, deliberately. Upstream blocks only the
  partitions carrying its own label, leaving a co-resident unlabelled partition
  grantable; on a Nerves appliance every partition of the boot medium is
  system storage, so the whole device is refused. A relabelled or unmounted
  partition of the boot disk is still refused here, where upstream would hand
  it over.

  Fail-closed: if the mount table cannot be read, every block device is treated
  as system storage. An unreadable `/proc/mounts` means the answer is unknown,
  and "unknown" must not resolve to "grant the disk". Character devices are
  never affected — upstream's check is block-only, and so is this.
  """

  require Logger

  @mounts_path "/proc/mounts"
  @sysfs_block "/sys/class/block"

  # `/root` is here because Nerves mounts the application partition there with
  # `/data` as a symlink to it on older systems — `Vagus.Backend.OS.Nerves`
  # carries the same pair for the same reason.
  @system_mountpoints ~w(/ /boot /root /data)

  @typedoc "`{major, minor}` pairs that must never appear in a `b` rule."
  @type devnums :: MapSet.t({non_neg_integer(), non_neg_integer()})

  @doc """
  The blocked `{major, minor}` set, or `:unknown` when the mount table is
  unreadable (callers must treat that as "block every block device").

  `:mounts_path` and `:sysfs_block` are injectable so this is testable against
  a fixture rather than the host's real storage.
  """
  # `mounts_path` is the `/proc/mounts` constant or a test-injected fixture,
  # never request input — an add-on's `devices:` strings reach `File.stat` in
  # `Vagus.Addon.Devices`, never this read.
  # sobelow_skip ["Traversal.FileModule"]
  @spec devnums(keyword()) :: devnums() | :unknown
  def devnums(opts \\ []) do
    mounts_path = Keyword.get(opts, :mounts_path, @mounts_path)
    sysfs = Keyword.get(opts, :sysfs_block, @sysfs_block)

    case File.read(mounts_path) do
      {:ok, contents} ->
        contents |> system_mount_devices() |> Enum.reduce(MapSet.new(), &add_disk(&1, &2, sysfs))

      {:error, reason} ->
        Logger.error("Vagus.Addon.SystemDisk: cannot read #{mounts_path} (#{inspect(reason)})")
        :unknown
    end
  end

  @doc "Whether `devnums/1`'s answer forbids granting `{major, minor}`."
  @spec blocked?(devnums() | :unknown, non_neg_integer(), non_neg_integer()) :: boolean()
  def blocked?(:unknown, _major, _minor), do: true
  def blocked?(devnums, major, minor), do: MapSet.member?(devnums, {major, minor})

  # `/proc/mounts` is fstab(5)-shaped: "<device> <mountpoint> <fstype> ...".
  # Only `/dev/...` entries can name a block device — `overlay`, `tmpfs` and
  # `none` occupy the same column and never do.
  defp system_mount_devices(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line) do
        ["/dev/" <> _ = device, mountpoint | _rest] when mountpoint in @system_mountpoints ->
          [resolve_link(device)]

        _other ->
          []
      end
    end)
    |> Enum.uniq()
  end

  # `/dev/disk/by-uuid/…` and Nerves's `/dev/rootdisk0p*` are symlink aliases;
  # sysfs only knows the real name, so take one hop the way
  # `Vagus.Provisioner` does for the same reason.
  defp resolve_link(device) do
    case File.read_link(device) do
      {:ok, target} -> Path.basename(target)
      {:error, _reason} -> Path.basename(device)
    end
  end

  # sysfs, not `stat` on the `/dev` node: the mount is proof the kernel knows
  # this block device, but its `/dev` entry may be absent (Nerves prunes
  # unused nodes, and a container's `/dev` is not the host's). Stat-ing would
  # fail **open** there — resolve nothing, block nothing, grant the disk.
  #
  # One mounted device contributes its own devnum, its parent disk's, and every
  # sibling partition's — see the moduledoc on why the whole disk goes.
  defp add_disk(name, acc, sysfs) do
    part_dir = Path.join(sysfs, name)

    if File.dir?(part_dir) do
      acc
      |> put_dev_file(Path.join(part_dir, "dev"))
      |> union_disk_family(part_dir)
    else
      Logger.warning(
        "Vagus.Addon.SystemDisk: #{name} mounts a system path but sysfs has no entry"
      )

      acc
    end
  end

  # `/sys/class/block/<part>` symlinks into the device tree, so `..` is the
  # disk's own directory — that is what makes the parent reachable without
  # parsing partition names (`mmcblk0p5` vs `sda5` vs `nvme0n1p5` differ).
  defp union_disk_family(acc, part_dir) do
    if File.exists?(Path.join(part_dir, "partition")) do
      disk_dir = Path.join(part_dir, "..")

      acc
      |> put_dev_file(Path.join(disk_dir, "dev"))
      |> union_partitions(disk_dir)
    else
      # Already a whole disk: still take its partitions.
      union_partitions(acc, part_dir)
    end
  end

  defp union_partitions(acc, disk_dir) do
    case File.ls(disk_dir) do
      {:ok, entries} -> Enum.reduce(entries, acc, &add_partition(Path.join(disk_dir, &1), &2))
      {:error, _reason} -> acc
    end
  end

  defp add_partition(child, acc) do
    if File.exists?(Path.join(child, "partition")),
      do: put_dev_file(acc, Path.join(child, "dev")),
      else: acc
  end

  # sysfs `dev` files hold "major:minor\n" — the kernel's own statement of the
  # pair, independent of the stat(2) path used elsewhere.
  #
  # `path` is built from the sysfs root and directory entries the kernel
  # published there, not from anything an add-on supplies.
  # sobelow_skip ["Traversal.FileModule"]
  defp put_dev_file(acc, path) do
    with {:ok, contents} <- File.read(path),
         [major, minor] <- String.split(String.trim(contents), ":"),
         {major, ""} <- Integer.parse(major),
         {minor, ""} <- Integer.parse(minor) do
      MapSet.put(acc, {major, minor})
    else
      _other -> acc
    end
  end
end
