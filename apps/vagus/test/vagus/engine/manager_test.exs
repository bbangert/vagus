defmodule Vagus.Engine.ManagerTest do
  use ExUnit.Case, async: true

  alias Vagus.Engine.Manager

  describe "daemon_args/0" do
    test "matches the locked balena-engine-daemon flags" do
      assert Manager.daemon_args() == [
               "--data-root=/data/balena-engine",
               "--exec-root=/run/balena-engine",
               "--pidfile=/run/balena-engine.pid",
               "--host=unix:///run/balena-engine.sock",
               "--storage-driver=overlay2",
               "--exec-opt",
               "native.cgroupdriver=cgroupfs",
               "--iptables=true",
               "--live-restore"
             ]
    end

    test "includes --live-restore (containers survive daemon restarts)" do
      assert "--live-restore" in Manager.daemon_args()
    end
  end

  # These exercise `handle_info/2` directly against hand-built state, with
  # no live GenServer/DynamicSupervisor/VintageNet involved — the pure
  # state-machine transitions the review flagged (monitor feedback loop,
  # no-double-start guard) are testable this way without ever reaching
  # `start_daemon/1`'s real `ResolvConf.write/1` call (which would try to
  # write to the real `/run/resolv.conf` on this machine). See the
  # implementation report for why a fuller start_fun/live-process seam
  # wasn't added.
  describe "handle_info/2 (started-state guards, no live process)" do
    test "{VintageNet, connection, _, :internet, _} is a no-op once a daemon pid is recorded (no double start on flapping)" do
      state = %{
        daemon_supervisor: :irrelevant,
        daemon_pid: self(),
        daemon_monitor_ref: make_ref()
      }

      msg = {VintageNet, ["connection"], :internet, :internet, %{}}

      assert Manager.handle_info(msg, state) == {:noreply, state}
    end

    test ":DOWN for the monitored daemon clears started-state and schedules a retry" do
      ref = Process.monitor(self())
      state = %{daemon_supervisor: :irrelevant, daemon_pid: self(), daemon_monitor_ref: ref}

      assert {:noreply, new_state} =
               Manager.handle_info({:DOWN, ref, :process, self(), :killed}, state)

      assert new_state.daemon_pid == nil
      assert new_state.daemon_monitor_ref == nil
    end

    test ":DOWN for an unrelated ref is ignored" do
      state = %{
        daemon_supervisor: :irrelevant,
        daemon_pid: self(),
        daemon_monitor_ref: make_ref()
      }

      unrelated_ref = make_ref()

      assert Manager.handle_info({:DOWN, unrelated_ref, :process, self(), :noproc}, state) ==
               {:noreply, state}
    end

    test ":retry_daemon_start is a no-op once a daemon pid is already recorded" do
      state = %{
        daemon_supervisor: :irrelevant,
        daemon_pid: self(),
        daemon_monitor_ref: make_ref()
      }

      assert Manager.handle_info(:retry_daemon_start, state) == {:noreply, state}
    end
  end
end
