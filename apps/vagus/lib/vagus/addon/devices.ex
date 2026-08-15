defmodule Vagus.Addon.Devices do
  @moduledoc """
  Resolves an add-on's `devices:` list (and `full_access:`) into the
  `HostConfig.DeviceCgroupRules` the engine wants (§A1.4).

  Upstream builds these from pyudev (`hardware/policy.py`'s `get_cgroups_rule`,
  reading the udev DB's `MAJOR`/`MINOR` properties and a `UdevSubsystem`
  char/block split). Nerves runs no udev daemon, so vagus reads the kernel's own
  answer with `stat(2)` instead: the S_IFMT bits of `mode` classify char vs
  block, and `minor_device` carries `st_rdev`. Different mechanism, identical
  output — which is what matters, since the probe-parity gate compares emitted
  container config, not how it was computed.

  Two `File.Stat` traps this module exists to not fall into:

    * `type: :device` is returned for character **and** block nodes, so it
      cannot classify. Only the S_IFMT bits can.
    * `minor_device` is documented as "only valid for character devices on
      Unix". That is a doc wart — it is `st_rdev` for every node type. The
      `:block_device` test pins it.

  **Resolution happens once, at container create.** Two consequences, and the
  second is the one with teeth:

    * A node that appears later gets no rule until the add-on restarts.
      Upstream is the same (its policy comes from the udev DB at create time),
      so this is parity rather than a gap.
    * A rule is a *device number*, not a path. If a dynamically-allocated major
      is reassigned to another driver while the container runs (module reload,
      USB re-enumeration), the rule keeps granting that number and the live
      `/dev` bind keeps exposing it — so the add-on silently gains a device
      class it never declared. Also parity, and not fixable without
      restart-on-hotplug.
  """

  import Bitwise
  require Logger

  alias Vagus.Addon.Config

  @s_ifmt 0o170000
  @s_ifchr 0o20000
  @s_ifblk 0o60000

  # `full_access`'s blanket grant — every block and every char device, i.e. the
  # whole disk included. Upstream has the same hammer and gates it the same way.
  @blanket ["b *:* rwm", "c *:* rwm"]

  @doc """
  The rules for `config`, given whether the add-on is still protected.

  `full_access: true` contributes the blanket pair only once protection is off;
  while protected it contributes nothing, and only the `devices:` entries
  resolve.

  Every rule is full `rwm`: upstream does no per-device permission filtering,
  and the `devices:` value format carries no permission field to filter on.

  A declared path that is missing, unstattable, or not a device node is skipped
  with a warning rather than failing the start (a missing node is a
  board/firmware fact, not a config error — and it matches how an unknown
  `map:` type is handled). Skipping is **also the security boundary**: only
  char/block S_IFMT bits ever emit a rule, so `devices: ["/etc/shadow"]`
  produces no rule at all rather than one granting something.
  """
  @spec cgroup_rules(Config.t(), boolean()) :: [String.t()]
  def cgroup_rules(%Config{} = config, protected?) when is_boolean(protected?) do
    blanket(config.full_access, protected?) ++ Enum.flat_map(config.devices, &rule/1)
  end

  defp blanket(true, false), do: @blanket
  defp blanket(_full_access, _protected?), do: []

  defp rule(path) when is_binary(path) do
    case File.stat(path) do
      # `File.stat/1`, not `lstat` — 2026.x accepts stable `/dev/serial/by-id/…`
      # symlinks, and the rule has to describe the node they point at.
      {:ok, %File.Stat{mode: mode, minor_device: rdev}} ->
        emit(device_type(mode), rdev, path)

      {:error, :enoent} ->
        skip(path, enoent_hint(path))

      {:error, reason} ->
        skip(path, "cannot stat (#{inspect(reason)})")
    end
  end

  defp rule(path), do: skip(path, "not a path")

  # Add-ons written for HA < 2023 declare `path:path:rwm`. That stats as ENOENT
  # and would otherwise be indistinguishable from a genuinely absent node,
  # sending the author hunting for a hardware fault instead of a config edit.
  defp enoent_hint(path) do
    if String.contains?(path, ":") do
      "no such node — this looks like the legacy `path:path:perms` format, use a bare path"
    else
      "no such node"
    end
  end

  defp emit(nil, _rdev, path), do: skip(path, "not a character or block device")

  defp emit(type, rdev, path) do
    {major, minor} = decode_rdev(rdev)
    rule = "#{type} #{major}:#{minor} rwm"

    # The resolved devnum, not just the declared path: a `devices:` entry may
    # be a symlink, so the config alone doesn't say what was actually granted
    # and this line is the only record that does.
    Logger.info("Vagus.Addon.Devices: granting #{inspect(path)} as #{rule}")
    [rule]
  end

  defp device_type(mode) do
    case mode &&& @s_ifmt do
      @s_ifchr -> "c"
      @s_ifblk -> "b"
      _other -> nil
    end
  end

  # Linux's `st_rdev` packing: 12 low major bits at 8, 20 minor bits split
  # across the low byte and bits 20+ (`MAJOR`/`MINOR` in <linux/kdev_t.h>).
  defp decode_rdev(rdev) do
    {rdev >>> 8 &&& 0xFFF, (rdev &&& 0xFF) ||| (rdev >>> 12 &&& 0xFFF00)}
  end

  defp skip(path, why) do
    Logger.warning("Vagus.Addon.Devices: skipping device #{inspect(path)} — #{why}")
    []
  end
end
