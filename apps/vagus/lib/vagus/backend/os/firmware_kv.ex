defmodule Vagus.Backend.OS.FirmwareKV do
  @moduledoc """
  Shared `Nerves.Runtime.KV` reads for `OSInfo`'s firmware/boot-slot
  fields — identical mechanism on `:host` (InMemory-backed,
  `config/host.exs`) and a real target (UBoot-env-backed), so
  `Vagus.Backend.OS.HostStub` and `Vagus.Backend.OS.Nerves` both delegate
  here rather than duplicating the KV-key transcription.

  Key names transcribed from `config/host.exs`'s InMemory KV
  pre-population and the standard `nerves_runtime` fwup A/B convention:
  `"<slot>.nerves_fw_version"`, `"<slot>.nerves_fw_platform"`.

  The active slot is derived by matching `KV.get_active("nerves_fw_uuid")`
  against the per-slot UUIDs — the `nerves_system_vagus` UBoot env has no
  `"nerves_fw_active"` key (verified on device 2026-07-20: only `a.*`/`b.*`
  keys plus `nerves_fw_devpath`/`nerves_serial_number` exist), while
  `KV.get_active/1` resolves correctly via `nerves_runtime`'s own
  boot-slot detection.
  """

  alias Nerves.Runtime.KV
  alias Vagus.API.Models.BootSlot

  @doc "The active fwup slot, `\"a\"` or `\"b\"` (defaults to `\"a\"` if unknown)."
  @spec active_slot() :: String.t()
  def active_slot do
    active_uuid = KV.get_active("nerves_fw_uuid")

    cond do
      active_uuid == nil -> "a"
      KV.get("b.nerves_fw_uuid") == active_uuid -> "b"
      true -> "a"
    end
  end

  @doc "The firmware version recorded for `slot` (`\"a\"`/`\"b\"`), or `nil`."
  @spec version(String.t()) :: String.t() | nil
  def version(slot), do: KV.get("#{slot}.nerves_fw_version")

  @doc "The platform string recorded for `slot`, or `nil`."
  @spec platform(String.t()) :: String.t() | nil
  def platform(slot), do: KV.get("#{slot}.nerves_fw_platform")

  @doc """
  `OSInfo.boot_slots` — a `%{\"A\" => BootSlot attrs, \"B\" => BootSlot
  attrs}` map, keyed by the wire's uppercase slot names. The active slot
  is honestly reported `state: "active", status: "good"`; the inactive
  slot's `status` is left `nil` (this emulator doesn't validate the
  inactive slot's fwup image, so it can't honestly claim `"good"` or
  `"bad"`).
  """
  @spec boot_slots() :: map()
  def boot_slots do
    active = active_slot()

    %{
      "A" => BootSlot.build!(slot_attrs("a", active)),
      "B" => BootSlot.build!(slot_attrs("b", active))
    }
  end

  defp slot_attrs(slot, active) when slot == active do
    %{state: "active", status: "good", version: version(slot)}
  end

  defp slot_attrs(slot, _active) do
    %{state: "inactive", status: nil, version: version(slot)}
  end
end
