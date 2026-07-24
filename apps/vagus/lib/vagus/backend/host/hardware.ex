defmodule Vagus.Backend.Host.Hardware do
  @moduledoc """
  Hardware enumeration for `GET /hardware/info` — upstream
  `supervisor/api/hardware.py` (`device_struct/1` per udev device). The
  frontend's Settings → Hardware → "All hardware" dialog lists these.

  Upstream enumerates via pyudev (a live udev database). Nerves has no
  udev daemon, but the same ground truth is in sysfs: every entry under
  `/sys/class/<subsystem>/<name>` is a device the kernel exports, its
  canonical sysfs path is the symlink target, and its `uevent` file
  carries the udev-property subset the kernel itself provides (including
  `DEVNAME` for nodes that exist under `/dev`). That's what this module
  reports — honest, kernel-sourced, no invented fields.

  Per-device wire shape (upstream `device_struct/1`): `name`, `sysfs`,
  `dev_path` (nil when the device has no /dev node), `subsystem`,
  `by_id` (always nil — /dev/disk/by-id symlink farms are udev-created
  and don't exist on Nerves), `attributes` (the uevent key/values),
  `children` (always [] — upstream nests child sysfs paths; flat here,
  every device is already its own top-level entry).

  `drives` is `[]` for v1: upstream sources it from UDisks2 over D-Bus,
  which Vagus doesn't run. The SD card still appears as `block`
  subsystem devices in `devices`.
  """

  @doc """
  Builds the `/hardware/info` data map.

  Options (injectable for tests): `:sys_class` (default `"/sys/class"`),
  `:dev_root` (default `"/dev"`).
  """
  @spec info(keyword()) :: map()
  def info(opts \\ []) do
    sys_class = Keyword.get(opts, :sys_class, "/sys/class")
    dev_root = Keyword.get(opts, :dev_root, "/dev")

    %{devices: devices(sys_class, dev_root), drives: []}
  end

  defp devices(sys_class, dev_root) do
    for subsystem <- ls(sys_class),
        name <- ls(Path.join(sys_class, subsystem)) do
      entry = Path.join([sys_class, subsystem, name])
      sysfs = canonical_sysfs(entry)
      attributes = read_uevent(sysfs)

      %{
        name: name,
        sysfs: sysfs,
        dev_path: dev_path(attributes, name, dev_root),
        subsystem: subsystem,
        by_id: nil,
        attributes: attributes,
        children: []
      }
    end
    |> Enum.sort_by(&{&1.subsystem, &1.name})
  end

  defp ls(path) do
    case File.ls(path) do
      {:ok, entries} -> Enum.sort(entries)
      {:error, _reason} -> []
    end
  end

  # /sys/class entries are symlinks into /sys/devices — resolve to the
  # canonical path like udev's device.sys_path. A non-symlink (or
  # unreadable) entry keeps its literal path.
  defp canonical_sysfs(entry) do
    case File.read_link(entry) do
      {:ok, target} -> Path.expand(target, Path.dirname(entry))
      {:error, _reason} -> entry
    end
  end

  # The kernel's own udev-property subset. DEVNAME here is what makes
  # dev_path honest for nested nodes (e.g. "input/event0").
  #
  # `sysfs` is built from /sys/class directory enumeration + symlink
  # resolution — never request input — so no user-controlled traversal
  # is possible.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_uevent(sysfs) do
    case File.read(Path.join(sysfs, "uevent")) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case String.split(line, "=", parts: 2) do
            [key, value] -> [{key, value}]
            _other -> []
          end
        end)
        |> Map.new()

      {:error, _reason} ->
        %{}
    end
  end

  defp dev_path(%{"DEVNAME" => devname}, _name, dev_root),
    do: Path.join(dev_root, devname)

  defp dev_path(_attributes, name, dev_root) do
    path = Path.join(dev_root, name)
    if File.exists?(path), do: path, else: nil
  end
end
