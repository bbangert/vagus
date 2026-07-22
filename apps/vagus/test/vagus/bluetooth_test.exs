defmodule Vagus.BluetoothTest do
  use ExUnit.Case, async: true

  # Child-order/slice tests against the pure `Bluez.children/1` list — no
  # daemons, no D-Bus. Guards the load-bearing cut: everything up to and
  # including :bluetoothd, none of the client/audio stack (which would
  # compete with HA Core for the radio — see the moduledoc).
  describe "daemon_children/1" do
    test "ends at the :bluetoothd spec and includes the daemon prerequisites" do
      children = Vagus.Bluetooth.daemon_children()

      assert %{id: :bluetoothd} = List.last(children)
      assert Enum.any?(children, &match?(%{id: :dbus_daemon}, &1))
      # The socket gate between the two daemons.
      assert Bluez.BusReady in children
      # The rebus runtime the BusReady gate rides on.
      assert Enum.any?(children, &match?({Bluez.Rebus.SignalHandler, _}, &1))
    end

    test "excludes every client and audio child" do
      children = Vagus.Bluetooth.daemon_children()

      for excluded <- [Bluez.Client, Bluez.Agent, Bluez.Gatt, Bluez.BlueAlsa] do
        refute Enum.any?(children, fn
                 {mod, _opts} -> mod == excluded
                 %{id: id} -> id == excluded
                 mod -> mod == excluded
               end),
               "expected #{inspect(excluded)} to be sliced off"
      end

      refute Enum.any?(children, &match?(%{id: :bluealsad}, &1))
    end
  end

  describe "start_link/1" do
    import ExUnit.CaptureLog

    test "returns :ignore when the daemon binaries are missing" do
      # capture_log contains the expected warning so it can't pollute a
      # concurrent test's log assertions (see the CaptureLog note in
      # the project memory: capture is process-wide under async: true).
      log =
        capture_log(fn ->
          assert :ignore =
                   Vagus.Bluetooth.start_link(
                     dbus_daemon_path: "/nonexistent/dbus-daemon",
                     bluetoothd_path: "/nonexistent/bluetoothd"
                   )
        end)

      assert log =~ "/nonexistent/dbus-daemon"
    end
  end
end
