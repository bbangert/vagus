defmodule Vagus.Devices do
  @moduledoc """
  The board's pluggable hardware, read from sysfs: each USB device with the
  `/dev` nodes, network interfaces and Bluetooth controllers its drivers
  created, plus the header buses (`i2c-*`, `spidev*`, `gpiochip*`) wired to
  the SoC itself.

  It exists for callers that hand hardware to a container, the
  agent-dev-board orchestrator first: after a re-plug the tty number may have
  changed, so they find the cable by something that did not
  (`find/2`) and turn what they found into `podman --device` arguments
  (`devices_args/1`) or a `--device-cgroup-rule` (`major_minor/2`).

  ## Identity

  Two ids, because a re-plug keeps one and a port move keeps the other:

    * `id` — `"usb:<bus>-<port path>"`, the kernel's own name for the device
      (`1-1.2`: bus 1, root port 1, hub port 2). It names the physical port,
      so the same cable re-plugged into the same port gets it back, and so
      does a different cable plugged there.
    * `serial` — the device's own iSerial, which follows the cable to any
      port. Not every device has one, and cheap clones share them, which is
      why `find/2` reports an ambiguity instead of picking.

  Hubs are skipped: nothing in a container wants one, and every node behind a
  hub belongs to the device on the hub's port.

  ## Ownership

  A node belongs to the USB device whose canonical sysfs path is the longest
  prefix of the node's own: `/sys/class/tty/ttyUSB0` resolves to
  `.../1-1/1-1.2/1-1.2:1.0/ttyUSB0/tty/ttyUSB0`, which is under both `1-1`
  and `1-1.2`, and the cable is the deeper one.

  Options, here and on every function: `:sysfs_root` (default `"/sys"`) and
  `:dev_root` (default `"/dev"`), with `config :vagus, Vagus.Devices` as the
  defaults beneath them so a test can point the HTTP route at a fixture tree.
  """

  alias Vagus.Sysfs

  @type node_class :: :tty | :hidraw | :usb | :i2c | :spi | :gpio
  @type dev_node :: %{
          path: String.t(),
          major: non_neg_integer(),
          minor: non_neg_integer(),
          class: node_class()
        }
  @type device :: %{
          id: String.t(),
          kind: :usb | :sys,
          vid: String.t() | nil,
          pid: String.t() | nil,
          vid_pid: String.t() | nil,
          serial: String.t() | nil,
          manufacturer: String.t() | nil,
          product: String.t() | nil,
          busnum: non_neg_integer() | nil,
          devnum: non_neg_integer() | nil,
          sysfs: String.t(),
          nodes: [dev_node()],
          ifaces: [String.t()],
          hci: [String.t()]
        }

  # Sources of `/dev` nodes, by where sysfs lists them. gpiochips come from
  # the bus, not `/sys/class/gpio`: that directory is the legacy sysfs GPIO
  # interface, named by global base number (`gpiochip512`), with no `dev`
  # file — not the character device in `/dev`.
  @node_sources [
    {["class", "tty"], :tty},
    {["class", "hidraw"], :hidraw},
    {["class", "i2c-dev"], :i2c},
    {["class", "spidev"], :spi},
    {["bus", "gpio", "devices"], :gpio}
  ]

  # The header buses reported on their own when no USB device owns them.
  @sys_classes [:i2c, :spi, :gpio]

  # `<bus>-<port>[.<port>…]`. Leaves out root hubs (`usb1`) and interfaces
  # (`1-1.2:1.0`), which share the directory.
  @usb_device_name ~r/^\d+-\d+(?:\.\d+)*$/

  @hub_class "09"

  @spec list(keyword()) :: [device()]
  def list(opts \\ []) do
    {root, dev_root} = roots(opts)
    usb = usb_devices(root)
    nodes = node_entries(root, dev_root)
    {owned, unowned} = Enum.split_with(nodes, &owner(&1.sysfs, usb))

    by_owner = Enum.group_by(owned, &owner(&1.sysfs, usb), & &1.node)
    ifaces = owned_names(root, ["class", "net"], usb, &(&1 != "lo"))
    hci = owned_names(root, ["class", "bluetooth"], usb, &String.match?(&1, ~r/^hci\d+$/))

    usb_list =
      for dev <- usb do
        bus_nodes = bus_node(dev, dev_root)

        dev.device
        |> Map.put(:nodes, bus_nodes ++ Map.get(by_owner, dev.id, []))
        |> Map.put(:ifaces, Map.get(ifaces, dev.id, []))
        |> Map.put(:hci, Map.get(hci, dev.id, []))
      end

    sys_list =
      for %{node: %{class: class}} = entry <- unowned, class in @sys_classes do
        sys_device(entry)
      end

    Enum.sort_by(usb_list, & &1.id) ++ Enum.sort_by(sys_list, & &1.id)
  end

  @doc """
  Finds one device by its `id`, by one of its `/dev` node paths, by serial,
  or by `"vid:pid"` (hex, any case) — tried in that order, the first key that
  matches anything deciding. Two matches on that key is `{:ambiguous, ids}`:
  guessing between two identical cables is how the wrong board gets flashed.
  """
  @spec find(String.t(), keyword()) ::
          {:ok, device()} | {:error, :not_found | {:ambiguous, [String.t()]}}
  def find(key, opts \\ []) when is_binary(key) do
    devices = list(opts)
    vid_pid = String.downcase(key)

    [
      &(&1.id == key),
      fn device -> Enum.any?(device.nodes, &(&1.path == key)) end,
      &(&1.serial == key),
      &(&1.vid_pid == vid_pid)
    ]
    |> Enum.find_value({:error, :not_found}, fn match? ->
      case Enum.filter(devices, match?) do
        [] -> nil
        [device] -> {:ok, device}
        many -> {:error, {:ambiguous, Enum.map(many, & &1.id)}}
      end
    end)
  end

  @doc "`podman --device` arguments passing every node of `device`."
  @spec devices_args(device()) :: [String.t()]
  def devices_args(%{nodes: nodes}), do: Enum.flat_map(nodes, &["--device", &1.path])

  @doc """
  The `major:minor` of a `/dev` node. Nodes of listed devices answer from the
  inventory; anything else (a `/dev/video0`, a UART) is looked up across
  `/sys/class` by its uevent `DEVNAME`.
  """
  @spec major_minor(String.t(), keyword()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, :not_found}
  def major_minor(path, opts \\ []) when is_binary(path) do
    listed =
      opts
      |> list()
      |> Enum.flat_map(& &1.nodes)
      |> Enum.find_value(fn node -> node.path == path && {node.major, node.minor} end)

    case listed || class_major_minor(path, opts) do
      nil -> {:error, :not_found}
      found -> {:ok, found}
    end
  end

  @doc """
  The stable id for the USB device the kernel named `name`, or `nil` for a
  root hub or an interface. Its sysfs entry is not needed, so it still
  answers for a device already unplugged.
  """
  @spec usb_id(String.t()) :: String.t() | nil
  def usb_id(name) do
    if Regex.match?(@usb_device_name, name), do: "usb:" <> name
  end

  defp roots(opts) do
    opts = Keyword.merge(Application.get_env(:vagus, __MODULE__, []), opts)
    {Keyword.get(opts, :sysfs_root, "/sys"), Keyword.get(opts, :dev_root, "/dev")}
  end

  defp usb_devices(root) do
    dir = Path.join([root, "bus", "usb", "devices"])

    for name <- Sysfs.ls(dir),
        id = usb_id(name),
        sysfs = Sysfs.canonical(Path.join(dir, name)),
        Sysfs.attr(sysfs, "bDeviceClass") != @hub_class do
      %{id: id, sysfs: sysfs, device: usb_device(id, sysfs)}
    end
  end

  defp usb_device(id, sysfs) do
    vid = sysfs |> Sysfs.attr("idVendor") |> downcase()
    pid = sysfs |> Sysfs.attr("idProduct") |> downcase()

    %{
      id: id,
      kind: :usb,
      vid: vid,
      pid: pid,
      vid_pid: vid && pid && vid <> ":" <> pid,
      serial: Sysfs.attr(sysfs, "serial"),
      manufacturer: Sysfs.attr(sysfs, "manufacturer"),
      product: Sysfs.attr(sysfs, "product"),
      busnum: sysfs |> Sysfs.attr("busnum") |> to_integer(),
      devnum: sysfs |> Sysfs.attr("devnum") |> to_integer(),
      sysfs: sysfs
    }
  end

  # libusb opens the device through this node, which is what a flashing tool
  # in a container needs; usbfs names it by zero-padded bus and device number.
  defp bus_node(%{device: %{busnum: bus, devnum: dev}, sysfs: sysfs}, dev_root)
       when is_integer(bus) and is_integer(dev) do
    case dev_numbers(sysfs) do
      {major, minor} ->
        path = Path.join([dev_root, "bus", "usb", pad3(bus), pad3(dev)])
        [%{path: path, major: major, minor: minor, class: :usb}]

      nil ->
        []
    end
  end

  defp bus_node(_dev, _dev_root), do: []

  defp sys_device(%{name: name, node: node, sysfs: sysfs}) do
    %{
      id: "sys:" <> name,
      kind: :sys,
      vid: nil,
      pid: nil,
      vid_pid: nil,
      serial: nil,
      manufacturer: nil,
      product: nil,
      busnum: nil,
      devnum: nil,
      sysfs: sysfs,
      nodes: [node],
      ifaces: [],
      hci: []
    }
  end

  # Only entries with a `dev` file: anything else has no `/dev` node to pass.
  defp node_entries(root, dev_root) do
    for {dir, class} <- @node_sources,
        base = Path.join([root | dir]),
        name <- Sysfs.ls(base),
        sysfs = Sysfs.canonical(Path.join(base, name)),
        {major, minor} <- [dev_numbers(sysfs)] do
      path = Path.join(dev_root, Map.get(Sysfs.uevent(sysfs), "DEVNAME", name))
      %{name: name, sysfs: sysfs, node: %{path: path, major: major, minor: minor, class: class}}
    end
  end

  defp owned_names(root, dir, usb, keep?) do
    base = Path.join([root | dir])

    for name <- Sysfs.ls(base),
        keep?.(name),
        id = owner(Sysfs.canonical(Path.join(base, name)), usb),
        reduce: %{} do
      acc -> Map.update(acc, id, [name], &(&1 ++ [name]))
    end
  end

  defp owner(sysfs, usb) do
    usb
    |> Enum.filter(&String.starts_with?(sysfs, &1.sysfs <> "/"))
    |> Enum.max_by(&byte_size(&1.sysfs), fn -> nil end)
    |> case do
      nil -> nil
      %{id: id} -> id
    end
  end

  defp class_major_minor(path, opts) do
    {root, dev_root} = roots(opts)
    class = Path.join(root, "class")

    Enum.find_value(Sysfs.ls(class), fn subsystem ->
      Enum.find_value(Sysfs.ls(Path.join(class, subsystem)), fn name ->
        sysfs = Sysfs.canonical(Path.join([class, subsystem, name]))
        devname = Map.get(Sysfs.uevent(sysfs), "DEVNAME", name)
        Path.join(dev_root, devname) == path && dev_numbers(sysfs)
      end)
    end)
  end

  defp dev_numbers(sysfs) do
    with value when is_binary(value) <- Sysfs.attr(sysfs, "dev"),
         [major, minor] <- String.split(value, ":"),
         {major, ""} <- Integer.parse(major),
         {minor, ""} <- Integer.parse(minor) do
      {major, minor}
    else
      _other -> nil
    end
  end

  defp to_integer(nil), do: nil

  defp to_integer(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp downcase(nil), do: nil
  defp downcase(value), do: String.downcase(value)

  defp pad3(n), do: n |> Integer.to_string() |> String.pad_leading(3, "0")
end
