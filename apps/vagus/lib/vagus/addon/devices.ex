defmodule Vagus.Addon.Devices do
  @moduledoc """
  Resolves an add-on's `devices:` list (and `full_access:`) into the
  `HostConfig.DeviceCgroupRules` the engine wants (§A1.4).

  Upstream builds these from pyudev (`hardware/policy.py`'s `get_cgroups_rule`,
  reading the udev DB's `MAJOR`/`MINOR` properties and a `UdevSubsystem`
  char/block split). Nerves runs no udev daemon, so vagus reads the kernel's own
  answer with `stat(2)` instead: the S_IFMT bits of `mode` classify char vs
  block, and `minor_device` carries `st_rdev`. Different mechanism, same output
  for any device that is granted at all — which is what matters, since the
  probe-parity gate compares emitted container config, not how it was computed.

  Which devices are grantable is a second question, and upstream answers it in
  `allowed_for_access/1` *before* building the rule: system storage is refused
  outright. `Vagus.Addon.SystemDisk` is that check, and it is deliberately
  stricter than upstream — see its moduledoc for what diverges and why.

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

  alias Vagus.Addon.{Config, SystemDisk}

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

  A block device that is system storage (`Vagus.Addon.SystemDisk`) is skipped
  at `:error` for the same reason upstream does it — an add-on asking for the
  boot medium is a config the operator needs to see, not a crash.
  """
  @spec cgroup_rules(Config.t(), boolean()) :: [String.t()]
  def cgroup_rules(%Config{} = config, protected?) when is_boolean(protected?) do
    {rules, _blocked} =
      Enum.reduce(config.devices, {[], :unresolved}, fn path, {acc, blocked} ->
        {emitted, blocked} = rule(path, blocked)
        {[emitted | acc], blocked}
      end)

    blanket(config.full_access, protected?) ++ (rules |> Enum.reverse() |> List.flatten())
  end

  defp blanket(true, false), do: @blanket
  defp blanket(_full_access, _protected?), do: []

  defp rule(path, blocked) when is_binary(path) do
    case File.stat(path) do
      # `File.stat/1`, not `lstat` — 2026.x accepts stable `/dev/serial/by-id/…`
      # symlinks, and the rule has to describe the node they point at.
      {:ok, %File.Stat{mode: mode, minor_device: rdev}} ->
        emit(device_type(mode), rdev, path, blocked)

      {:error, :enoent} ->
        {skip(path, enoent_hint(path)), blocked}

      {:error, reason} ->
        {skip(path, "cannot stat (#{inspect(reason)})"), blocked}
    end
  end

  defp rule(path, blocked), do: {skip(path, "not a path"), blocked}

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

  defp emit(nil, _rdev, path, blocked),
    do: {skip(path, "not a character or block device"), blocked}

  # Block devices are the only ones the system-disk policy can refuse, and the
  # only ones worth reading the mount table for — resolving it lazily is what
  # keeps a char-only (or device-free) add-on from touching the filesystem
  # beyond its own nodes, which `build_spec/2`'s @doc promises.
  defp emit("b" = type, rdev, path, blocked) do
    blocked = if blocked == :unresolved, do: SystemDisk.devnums(), else: blocked
    {major, minor} = decode_rdev(rdev)

    if SystemDisk.blocked?(blocked, major, minor) do
      # Upstream logs this at error and skips the rule rather than failing the
      # start (`docker/app.py`); an add-on asking for the boot medium is a
      # config the operator should see, not a crash.
      Logger.error(
        "Vagus.Addon.Devices: add-on tried to access blocked device #{inspect(path)} " <>
          "(b #{major}:#{minor}) — system storage is never granted"
      )

      {[], blocked}
    else
      {[log_resolved(type, major, minor, path)], blocked}
    end
  end

  defp emit(type, rdev, path, blocked) do
    {major, minor} = decode_rdev(rdev)
    {[log_resolved(type, major, minor, path)], blocked}
  end

  defp log_resolved(type, major, minor, path) do
    rule = "#{type} #{major}:#{minor} rwm"

    # Resolution, deliberately not phrased as a grant: `build_spec/2` also runs
    # for image pulls and `Update`'s ref comparison, neither of which creates a
    # container, so "granted" here would put events in the audit trail that
    # never happened. What this does record is the devnum a declared path
    # resolved to — a `devices:` entry may be a symlink, so the config alone
    # doesn't say which node the rule will name.
    Logger.info("Vagus.Addon.Devices: #{inspect(path)} resolves to #{rule}")
    rule
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
