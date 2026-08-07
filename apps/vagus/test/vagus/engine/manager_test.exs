defmodule Vagus.Engine.ManagerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.Engine.Manager

  describe "daemon_args/0" do
    test "matches the locked balena-engine-daemon flags" do
      assert Manager.daemon_args() == [
               "--data-root=/root/balena-engine",
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

  describe "ensure_core_socket_dir/1 (W2)" do
    defp tmp_dir do
      dir = Path.join(System.tmp_dir!(), "vagus_socket_dir_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      dir
    end

    defp mode(dir) do
      {:ok, %File.Stat{mode: mode}} = File.stat(dir)
      Bitwise.band(mode, 0o777)
    end

    test "creates the bind-mount source 0700, not umask's 0755" do
      dir = tmp_dir()

      assert Manager.ensure_core_socket_dir(dir) == :ok
      assert mode(dir) == 0o700
    end

    test "tightens a directory that already exists world-traversable" do
      dir = tmp_dir()
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o755)

      assert Manager.ensure_core_socket_dir(dir) == :ok
      assert mode(dir) == 0o700
    end

    test "a directory that can't be created is logged loudly, never raised" do
      blocker =
        Path.join(System.tmp_dir!(), "vagus_socket_blocker_#{System.unique_integer([:positive])}")

      File.write!(blocker, "not a directory")
      on_exit(fn -> File.rm(blocker) end)

      log = capture_log(fn -> Manager.ensure_core_socket_dir(Path.join(blocker, "run")) end)

      assert log =~ "failed to create"
      assert log =~ "Core's Supervisor socket mount will fail"
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

  describe "supervisor DNAT re-assert" do
    test ":assert_nat calls the seam and keeps the state untouched" do
      parent = self()
      state = %{nat_assert: fn -> send(parent, :asserted) && :ok end}

      assert Manager.handle_info(:assert_nat, state) == {:noreply, state}
      assert_receive :asserted
    end

    test "a failing re-assert is swallowed — the engine does not care" do
      state = %{nat_assert: fn -> {:error, {["-t", "nat", "-N"], "boom", 1}} end}

      assert Manager.handle_info(:assert_nat, state) == {:noreply, state}
    end

    test "init/1 defaults the seam to Vagus.Network.Nat and a post-start delay" do
      assert {:ok, state, _continue_or_nothing} = maybe_continue(Manager.init([]))

      assert state.nat_assert == (&Vagus.Network.Nat.ensure/0)
      assert state.nat_assert_ms == 10_000
    end

    test "init/1 takes both seams from opts" do
      seam = fn -> :ok end
      assert {:ok, state, _} = maybe_continue(Manager.init(nat_assert: seam, nat_assert_ms: 1))

      assert state.nat_assert == seam
      assert state.nat_assert_ms == 1
    end

    # `init/1` returns `{:ok, state}` on :host (no VintageNet), so normalize.
    defp maybe_continue({:ok, state}), do: {:ok, state, nil}
    defp maybe_continue(other), do: other
  end
end
