defmodule Vagus.Improv do
  @moduledoc """
  Improv-over-BLE Wi-Fi provisioning glue (bluetooth phase 2).

  Builds the `Improv.Supervisor` child that `Vagus.Bluetooth` mounts at the
  tail of its `:rest_for_one` tree (the improv mounting contract: appended
  last, so a `bluetoothd` restart rebuilds the group while an Improv fault
  disturbs nothing before it) and supplies every app-side callback:

    * `network_type/0` — the arm gate. Returns `:disconnected` only when
      neither ethernet nor wifi (nor anything else vintage_net aggregates)
      has at least LAN connectivity; `Improv` then arms once per boot after
      its 20s grace and advertises "Vagus <suffix>" for the HA companion
      app. HA Core needs no gating of its own: `Vagus.Engine.Manager`
      already withholds the container engine (and with it the Core
      container) until the aggregate connection reaches `:internet` — the
      exact event a successful provision produces.
    * `identify/0` — best-effort onboard-LED blink (runs fire-and-forget
      under `Improv.TaskSupervisor`; blocking is fine there).
    * `device_info` — firmware name/version from this app, hardware from
      the device tree, advert-matching device name.

  Force-offline override for on-device testing (no ethernet unplugging):
  `touch #{"/root/vagus/improv_force_offline"}` on the device (real path —
  `/data` is a symlink) and reboot; `network_type/0` then reports
  `:disconnected` regardless of real connectivity, so the FSM arms after
  the boot grace. Remove the marker and reboot to undo. `config :vagus,
  :improv_force_offline, true` does the same for tests.
  """

  require Logger

  @force_offline_marker "/root/vagus/improv_force_offline"

  # rpi3's green activity LED registers as "led0" ("ACT" and "PWR" cover
  # other Pi revisions). First match wins.
  @led_candidates ["led0", "ACT", "PWR"]
  @blink_count 8
  @blink_half_period_ms 250

  @doc """
  The `{Improv.Supervisor, opts}` child `Vagus.Bluetooth` mounts after the
  BlueZ daemons.
  """
  @spec supervisor_child() :: {module(), keyword()}
  def supervisor_child, do: {Improv.Supervisor, supervisor_opts()}

  @doc "The full improv option surface. Public for hermetic tests."
  @spec supervisor_opts() :: keyword()
  def supervisor_opts do
    [
      network_type: &__MODULE__.network_type/0,
      name_prefix: "Vagus",
      identify_fun: &__MODULE__.identify/0,
      device_info: [
        firmware_name: "Vagus",
        firmware_version: vsn(),
        hardware: hardware(),
        # Matches the BLE-advertised name ("Vagus <last-4-hex-of-MAC>").
        device_name: "Vagus #{Improv.Advert.device_suffix()}"
      ]
    ]
  end

  @doc """
  Improv's arm gate: `:disconnected` iff nothing has connectivity (improv
  only compares against `:disconnected`; the richer atoms are for logs).
  """
  @spec network_type() :: :disconnected | :wifi | :ethernet | :other
  def network_type do
    if force_offline?() do
      :disconnected
    else
      classify(connection("eth0"), connection("wlan0"), aggregate_connection())
    end
  end

  @doc """
  Pure connectivity classification, host-testable. Values are vintage_net
  connection statuses (`:disconnected | :lan | :internet`, `nil` when the
  interface doesn't exist). `aggregate` is vintage_net's best-of-all-
  interfaces `["connection"]` property — the catch-all for interfaces we
  don't name (usb0, ...). Wifi wins over ethernet only for the label; the
  arm gate cares solely about `:disconnected` vs anything else.
  """
  @spec classify(atom() | nil, atom() | nil, atom() | nil) ::
          :disconnected | :wifi | :ethernet | :other
  def classify(eth_conn, wlan_conn, aggregate_conn) do
    cond do
      connected?(wlan_conn) -> :wifi
      connected?(eth_conn) -> :ethernet
      connected?(aggregate_conn) -> :other
      true -> :disconnected
    end
  end

  defp connected?(conn), do: conn in [:lan, :internet]

  @doc """
  Improv identify (0x02): blink the onboard LED so the user can tell which
  physical device is advertising. Best-effort — a Pi without a writable
  LED just logs. Runs under `Improv.TaskSupervisor`, so sleeping is fine.
  """
  @spec identify() :: :ok
  def identify do
    case find_led() do
      nil ->
        Logger.info("Vagus.Improv: identify requested (no controllable LED found)")

      led_dir ->
        Logger.info("Vagus.Improv: identify — blinking #{led_dir}")
        blink(led_dir)
    end

    :ok
  end

  defp force_offline? do
    Application.get_env(:vagus, :improv_force_offline, false) or
      File.exists?(@force_offline_marker)
  end

  defp vsn do
    case Application.spec(:vagus, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  # Device-tree model string ("Raspberry Pi 3 Model B Rev 1.2"); it carries
  # a trailing NUL. Off-target the file is absent.
  defp hardware do
    case File.read("/proc/device-tree/model") do
      {:ok, model} -> String.trim_trailing(model, <<0>>)
      {:error, _} -> "unknown"
    end
  end

  defp find_led do
    Enum.find_value(@led_candidates, fn name ->
      dir = "/sys/class/leds/#{name}"
      if File.exists?(Path.join(dir, "brightness")), do: dir
    end)
  end

  # The LED's kernel trigger (mmc0 activity on the ACT LED) keeps rewriting
  # brightness underneath us, so park it on "none" for the blink and restore
  # the original afterwards. If the original trigger can't be read/parsed,
  # DON'T park at all: blinking against a live trigger just flickers, while
  # parking with nothing to restore would leave the activity LED dead until
  # reboot. All writes best-effort: sysfs paths are module-internal
  # constants, and an unwritable LED must never crash the identify task.
  # sobelow_skip ["Traversal.FileModule"]
  defp blink(led_dir) do
    brightness = Path.join(led_dir, "brightness")
    trigger = Path.join(led_dir, "trigger")
    original_trigger = current_trigger(trigger)

    if original_trigger, do: _ = File.write(trigger, "none")

    for _ <- 1..@blink_count do
      _ = File.write(brightness, "1")
      Process.sleep(@blink_half_period_ms)
      _ = File.write(brightness, "0")
      Process.sleep(@blink_half_period_ms)
    end

    if original_trigger, do: _ = File.write(trigger, original_trigger)
    :ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp current_trigger(trigger_path) do
    case File.read(trigger_path) do
      {:ok, contents} -> parse_trigger(contents)
      {:error, _} -> nil
    end
  end

  @doc """
  Parses a sysfs LED `trigger` file's contents — every available trigger
  space-separated, the active one bracketed (`"none mmc0 [heartbeat]"` →
  `"heartbeat"`); `nil` when nothing is bracketed. Public (`@doc false`
  would hide it, and the parse rules are worth documenting) purely so the
  pure half of the LED handling is unit-testable.
  """
  @spec parse_trigger(String.t()) :: String.t() | nil
  def parse_trigger(contents) do
    case Regex.run(~r/\[(\S+)\]/, contents) do
      [_, active] -> active
      nil -> nil
    end
  end

  # vintage_net is a target-only dep (`targets: @all_targets` in mix.exs);
  # compile-time branching keeps the reference out of the :host build, same
  # as Vagus.Engine.Manager. Host stubs answer :disconnected — irrelevant
  # in practice since Vagus.Bluetooth (the only thing mounting improv)
  # never starts on :host.
  if Mix.target() == :host do
    defp connection(_ifname), do: :disconnected
    defp aggregate_connection, do: :disconnected
  else
    defp connection(ifname) do
      VintageNet.get(["interface", ifname, "connection"], :disconnected)
    end

    defp aggregate_connection do
      VintageNet.get(["connection"], :disconnected)
    end
  end
end
