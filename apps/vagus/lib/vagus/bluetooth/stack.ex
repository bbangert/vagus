defmodule Vagus.Bluetooth.Stack do
  @moduledoc """
  The `:rest_for_one` tree under `Vagus.Bluetooth`: the daemon slice of
  `Bluez.children/1` followed by the Improv tail (`Vagus.Bluetooth.children/1`).
  One child of its parent so the whole stack stops and starts as a unit.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :stack_name))
  end

  @impl Supervisor
  def init(opts) do
    # Every (re)start, `start/1`'s included, clears the previous dbus-daemon's
    # socket file before BusReady polls for it, and creates /run/dbus +
    # /data/bluetooth before the daemons launch.
    Keyword.get(opts, :prepare_runtime, &Bluez.prepare_runtime/0).()

    # Same explicit budget as the upstream tree: a daemon crash loop gives
    # up within a minute instead of cycling silently forever.
    Supervisor.init(Keyword.get_lazy(opts, :children, fn -> Vagus.Bluetooth.children(opts) end),
      strategy: :rest_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end
end
