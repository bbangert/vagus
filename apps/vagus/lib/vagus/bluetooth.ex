defmodule Vagus.Bluetooth do
  @moduledoc """
  Daemons-only slice of the `Bluez` stack: `dbus-daemon --system` and
  `bluetoothd -E` as `MuonTrap`-supervised OS processes, plus the vendored
  rebus runtime and the `Bluez.BusReady` gate they ride on — everything in
  `Bluez.children/1` up to and including the `:bluetoothd` child, nothing
  after it.

  HA Core is the BLE consumer on this system: its container gets `/run/dbus`
  bound read-only (real-Supervisor parity, `MOUNT_DBUS`) and habluetooth
  drives the adapter over BlueZ's D-Bus API. Vagus deliberately does not
  start the bluez library's scanning/GATT/audio clients — a second scanner
  would compete with Core for the radio and burn CPU D-Bus-decoding adverts
  nobody consumes. Slicing by child id (not position) keeps the cut robust
  to upstream reordering while inheriting the library's hardware-proven
  daemon specs (socket cleanup, machine-id, restart budget rationale).

  Started from `target_children/0` only. `start_link/1` returns `:ignore`
  when either daemon binary is absent (e.g. a system built without
  `BR2_PACKAGE_BLUEZ5_UTILS`) so a misbuilt firmware degrades to "no
  Bluetooth" instead of an app-toppling supervision crash loop — same
  pattern as `Vagus.Addon.BootStarter`.

  Phase 2 (vagus-improv): the tree's tail carries the Improv-over-BLE
  Wi-Fi provisioning group + its reaper (see `Vagus.Improv` /
  `Vagus.Improv.Reaper`), mounted per improv's contract — appended last
  under `:rest_for_one`, so a `bluetoothd` restart rebuilds the group
  while an Improv fault never disturbs the daemons. The group idles
  disarmed on an online boot and is reaped once the network is up;
  disable entirely with `improv: false` in opts.
  """

  use Supervisor

  require Logger

  @default_dbus_daemon "/usr/bin/dbus-daemon"
  @default_bluetoothd "/usr/libexec/bluetooth/bluetoothd"

  def start_link(opts \\ []) do
    # Normalize the daemon paths INTO opts before anything reads them, so the
    # existence check here and the child specs `Bluez.children/1` builds in
    # `init/1` can never disagree — Bluez applies its own defaults for these
    # keys, which happen to match @default_* today but aren't contractually
    # tied to them (Copilot review, PR #4).
    opts =
      opts
      |> Keyword.put_new(:dbus_daemon_path, @default_dbus_daemon)
      |> Keyword.put_new(:bluetoothd_path, @default_bluetoothd)

    dbus_daemon = Keyword.fetch!(opts, :dbus_daemon_path)
    bluetoothd = Keyword.fetch!(opts, :bluetoothd_path)

    if File.exists?(dbus_daemon) and File.exists?(bluetoothd) do
      Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    else
      Logger.warning(
        "Vagus.Bluetooth: #{dbus_daemon} or #{bluetoothd} missing; Bluetooth daemons not started"
      )

      :ignore
    end
  end

  @impl Supervisor
  def init(opts) do
    # Creates /run/dbus (+ machine-id, stale-socket cleanup) and
    # /data/bluetooth before the daemons launch; idempotent per restart.
    Bluez.prepare_runtime()

    # Same explicit budget as the upstream tree: a daemon crash-loop
    # escalates to Vagus.Supervisor within a minute instead of cycling
    # silently forever.
    Supervisor.init(children(opts),
      strategy: :rest_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  @doc """
  The full child list: the daemon slice plus (unless `improv: false`) the
  Improv provisioning tail. Public for child-order tests.
  """
  @spec children(keyword()) :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children(opts \\ []) do
    daemon_children(opts) ++ improv_children(opts)
  end

  defp improv_children(opts) do
    if Keyword.get(opts, :improv, true) do
      [Vagus.Improv.supervisor_child(), Vagus.Improv.Reaper]
    else
      []
    end
  end

  @doc """
  The daemon prefix of `Bluez.children/1`: every child up to and including
  the `:bluetoothd` spec. Public for child-order tests (mirrors upstream's
  exposed `children/1`).
  """
  @spec daemon_children(keyword()) :: [Supervisor.child_spec() | {module(), term()} | module()]
  def daemon_children(opts \\ []) do
    case Enum.split_while(Bluez.children(opts), &(child_id(&1) != :bluetoothd)) do
      {prefix, [bluetoothd | _clients]} ->
        prefix ++ [bluetoothd]

      {_all, []} ->
        # Upstream contract change — fail loud at startup, not with a
        # silently client-inclusive tree.
        raise "Bluez.children/1 has no :bluetoothd child; bluez #{Application.spec(:bluez, :vsn)} incompatible"
    end
  end

  defp child_id(%{id: id}), do: id
  defp child_id(_), do: nil
end
