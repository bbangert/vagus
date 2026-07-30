defmodule Vagus.Addon.Availability do
  @moduledoc """
  Whether an add-on can run on THIS device at all (phase 6 chunk A, audit
  G1) — independent of whether it's installed, running, or even still in
  the store's catalog. Before this module existed, `available` was
  hardcoded `true` everywhere (`Vagus.Addon.Info`/`Vagus.Addon.StoreView`),
  so an amd64-only add-on on this aarch64 board showed an enabled Install
  button and failed LATE with a raw image-pull error; real Supervisor
  refuses up front.

  Mirrors upstream's `AppModel._validate_availability`/`has_supported_machine`
  (`home-assistant-libs/supervisor` `apps/model.py`, verified directly
  against source at tag `2026.07.5` — not just a description of it, see the
  machine note below) — three checks, same order upstream runs them in
  (architecture first, since a wrong-arch pull is the loudest failure mode
  this was fixing):

    1. **Architecture.** The device's own CPU arch (`Vagus.API.StaticData.arch/0`)
       must be one of `config.arch`'s declared values.

    2. **Machine.** If `config.machine` is non-empty, it is a **positive
       whitelist**, not an exclude-list: the device's board identity
       (`Vagus.API.StaticData.machine/0`) must appear in the list verbatim,
       AND its negated form (`"!" <> machine`) must NOT also appear.

       This is the one place this module intentionally does NOT match a
       naive reading of the `"!"` syntax ("`!qemux86` means available
       everywhere except qemux86") — that reading does not hold in the real
       source. `has_supported_machine` is literally `sys_machine not
       negated AND sys_machine positively listed`; with only negated
       entries (e.g. `["!qemux86"]`), the positive-listing half of that AND
       has nothing to match, so the add-on is unavailable on EVERY device,
       this one included. Negation only does anything alongside an
       otherwise-matching positive entry — list every board you support,
       then also negate one you build for but don't want offered. This
       module mirrors the real (whitelist) behavior rather than the more
       forgiving "exclude-only" reading, because the entire point of this
       module is to match what a real Supervisor would decide.

    3. **Home Assistant version floor.** If `config.homeassistant` is set,
       the installed Core version must be >= it. Mirrors upstream's
       `with suppress(AwesomeVersionException, TypeError)`: an unparseable
       OR unknown (Core not yet adopted) installed version does NOT fail
       this check — it reads as "floor satisfied". Refuse only on a
       *definite* violation, never on an indeterminate one.

  `Vagus.Core.Versions.installed/1` is a `GenServer.call`; `check/1` (the
  zero-arg-device-facts variant `Info`/`StoreView`/the router's install
  gate actually call) wraps it in a `catch :exit` so a Versions
  timeout/crash degrades to "unknown -> floor satisfied" rather than
  taking down whatever asked whether an add-on is available (a later
  phase-6 chunk fixes the underlying `Versions` timeout risk directly;
  this is defense at the call site, not a fix to that module).
  """

  alias Vagus.Addon.Config
  alias Vagus.API.StaticData
  alias Vagus.Core.Versions

  @doc "The boolean half of `check/1` — what `Info`/`StoreView` render as `available`."
  @spec available?(Config.t()) :: boolean()
  def available?(%Config{} = config) do
    match?({true, nil}, check(config))
  end

  @doc """
  `{true, nil}` if `config` can run on this device, else `{false, reason}`
  with a human-readable cause (arch / machine / Core version) — what
  `Vagus.API.Router`'s install route puts in its 400 body so a refusal
  names the actual reason instead of a generic failure.

  Reads this device's own arch/machine (`Vagus.API.StaticData`) and the
  installed Core version (`Vagus.Core.Versions`, defensively) — see `check/4`
  for the pure variant with all four facts supplied explicitly (what the
  test suite drives).
  """
  @spec check(Config.t()) :: {true, nil} | {false, String.t()}
  def check(%Config{} = config) do
    check(config, StaticData.arch(), StaticData.machine(), installed_core_version())
  end

  @doc "Same decision as `check/1`, with the device facts supplied explicitly."
  @spec check(Config.t(), String.t(), String.t(), String.t() | nil) ::
          {true, nil} | {false, String.t()}
  def check(%Config{} = config, device_arch, device_machine, core_version) do
    cond do
      device_arch not in config.arch ->
        {false,
         "App #{config.name} not supported on this platform, supported architectures: " <>
           Enum.join(config.arch, ", ")}

      not machine_supported?(config.machine, device_machine) ->
        {false,
         "App #{config.name} not supported on this machine, supported machine types: " <>
           Enum.join(config.machine, ", ")}

      not homeassistant_new_enough?(config.homeassistant, core_version) ->
        {false,
         "App #{config.name} not supported on this system, requires Home Assistant version " <>
           "#{config.homeassistant} or greater"}

      true ->
        {true, nil}
    end
  end

  # No `machine:` restriction at all -> every device qualifies.
  defp machine_supported?([], _device_machine), do: true

  defp machine_supported?(machine_types, device_machine) do
    ("!" <> device_machine) not in machine_types and device_machine in machine_types
  end

  # No floor declared, or nothing definite to compare against -> satisfied.
  defp homeassistant_new_enough?(nil, _core_version), do: true
  defp homeassistant_new_enough?(_floor, nil), do: true

  defp homeassistant_new_enough?(floor, core_version) do
    case {version_segments(core_version), version_segments(floor)} do
      {{:ok, installed}, {:ok, required}} -> at_least?(installed, required)
      # Either side didn't parse as a dotted-integer version (a beta/rc tag,
      # e.g.) -> can't make a definite call, so don't refuse over it.
      _ -> true
    end
  end

  # "2026.7.2" -> {:ok, [2026, 7, 2]}; anything with a non-numeric segment
  # (or that isn't a string at all) -> :error.
  defp version_segments(v) when is_binary(v) do
    segments = String.split(v, ".")

    if segments != [] and Enum.all?(segments, &Regex.match?(~r/^\d+$/, &1)) do
      {:ok, Enum.map(segments, &String.to_integer/1)}
    else
      :error
    end
  end

  defp version_segments(_v), do: :error

  # Zero-pads the shorter list so "2026.7" compares equal-length against
  # "2026.7.0" — Erlang's term ordering on same-length integer lists is
  # already the element-wise lexicographic compare this needs.
  defp at_least?(installed, required) do
    len = max(length(installed), length(required))
    pad(installed, len) >= pad(required, len)
  end

  defp pad(list, len), do: list ++ List.duplicate(0, len - length(list))

  # `Versions.installed/1` always replies immediately from in-memory state
  # (it is never queued behind the 24h `latest`-fetch machinery — see that
  # module's moduledoc), but it is still a `GenServer.call`: a dead/wedged
  # process would `exit` the caller. Caught here rather than left to
  # propagate, because "the Versions store is unhappy" must never turn into
  # "every store card 400s".
  defp installed_core_version do
    Versions.installed()
  catch
    :exit, _ -> nil
  end
end
