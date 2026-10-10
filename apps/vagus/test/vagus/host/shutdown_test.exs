defmodule Vagus.Host.ShutdownTest do
  @moduledoc """
  Every test injects the runtime call and either the orchestrator's stop
  sequence or a real orchestrator's units, so nothing here stops a container
  or calls `Nerves.Runtime`. The stop sequence runs in a `Vagus.Jobs.TaskSupervisor` task, not the test
  process, so it reports back by message.

  `async: false` because the in-flight flag is one `:persistent_term` key
  that every app process reads too; `setup` erases it around each test.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :capture_log

  alias Vagus.App.Orchestrator
  alias Vagus.Host.Shutdown

  @stopped {{2, 2}, :ok}

  setup do
    :persistent_term.erase({Shutdown, :in_flight})
    on_exit(fn -> :persistent_term.erase({Shutdown, :in_flight}) end)
    test_pid = self()
    {:ok, test_pid: test_pid, resume: fn -> send(test_pid, :resumed) end}
  end

  defp reporting(test_pid, result \\ @stopped) do
    fn _budget_ms ->
      send(test_pid, {:stopping, Shutdown.in_flight?()})
      result
    end
  end

  test "the stop sequence runs with the flag set, then the runtime call", ctx do
    opts = [
      orchestrator: reporting(ctx.test_pid),
      runtime_reboot: fn -> send(ctx.test_pid, :runtime_called) end,
      resume: ctx.resume
    ]

    refute Shutdown.in_flight?()
    assert Shutdown.reboot(opts) == :ok
    assert_received {:stopping, true}
    assert_received :runtime_called
    assert Shutdown.in_flight?()
    refute_received :resumed
  end

  test "a wedged stop sequence is bounded by total_budget_ms", ctx do
    opts = [
      orchestrator: fn _budget_ms ->
        send(ctx.test_pid, :stopping)

        receive do
        end
      end,
      runtime_reboot: fn -> send(ctx.test_pid, :runtime_called) end,
      total_budget_ms: 50,
      resume: ctx.resume
    ]

    assert Shutdown.reboot(opts) == :ok
    assert_received :stopping
    assert_received :runtime_called
  end

  test "a stop sequence that raises still lets the runtime call happen", ctx do
    opts = [
      orchestrator: fn _budget_ms -> raise "boom" end,
      runtime_reboot: fn -> send(ctx.test_pid, :runtime_called) end,
      resume: ctx.resume
    ]

    assert Shutdown.reboot(opts) == :ok
    assert_received :runtime_called
  end

  test "a second caller while a shutdown is in flight is a no-op", ctx do
    first_opts = [
      orchestrator: fn _budget_ms ->
        send(ctx.test_pid, {:first_blocked, self()})

        receive do
          :release -> @stopped
        end
      end,
      runtime_reboot: fn -> send(ctx.test_pid, :runtime_first) end,
      resume: ctx.resume
    ]

    task = Task.async(fn -> Shutdown.reboot(first_opts) end)
    assert_receive {:first_blocked, blocked_pid}

    second_opts = [
      orchestrator: reporting(ctx.test_pid),
      runtime_reboot: fn -> send(ctx.test_pid, :runtime_second) end,
      resume: ctx.resume
    ]

    # `retries: 0` on the lock: the second caller returns at once.
    assert Shutdown.reboot(second_opts) == :ok
    send(blocked_pid, :release)

    assert Task.await(task) == :ok
    assert_received :runtime_first
    refute_received :runtime_second
    refute_received {:stopping, _}
  end

  test "poweroff/1 calls :runtime_poweroff and never :runtime_reboot", ctx do
    opts = [
      orchestrator: reporting(ctx.test_pid),
      runtime_reboot: fn -> send(ctx.test_pid, :reboot_called) end,
      runtime_poweroff: fn -> send(ctx.test_pid, :poweroff_called) end,
      resume: ctx.resume
    ]

    assert Shutdown.poweroff(opts) == :ok
    assert_received :poweroff_called
    refute_received :reboot_called
  end

  test "a raising runtime call propagates, clears the flag and boots the apps again", ctx do
    opts = [
      orchestrator: reporting(ctx.test_pid),
      runtime_reboot: fn -> raise "runtime exploded" end,
      resume: fn -> send(ctx.test_pid, {:resumed, Shutdown.in_flight?()}) end
    ]

    assert_raise RuntimeError, "runtime exploded", fn -> Shutdown.reboot(opts) end
    assert_received {:stopping, true}
    assert_received {:resumed, false}
    refute Shutdown.in_flight?()
  end

  test "a throwing runtime call propagates, clears the flag and boots the apps again", ctx do
    opts = [
      orchestrator: reporting(ctx.test_pid),
      runtime_poweroff: fn -> throw(:boom) end,
      resume: ctx.resume
    ]

    assert catch_throw(Shutdown.poweroff(opts)) == :boom
    assert_received :resumed
    refute Shutdown.in_flight?()
  end

  test "the stop sequence gets the 300 s budget by default", ctx do
    opts = [
      orchestrator: fn budget_ms -> send(ctx.test_pid, {:budget, budget_ms}) && @stopped end,
      runtime_reboot: fn -> :ok end,
      resume: ctx.resume
    ]

    assert Shutdown.reboot(opts) == :ok
    assert_received {:budget, 300_000}
  end

  test "the real orchestrator stops Core through the facade", ctx do
    name = :"orchestrator_#{System.unique_integer([:positive])}"

    units = %{
      list: fn -> [] end,
      ensure: fn _slug -> :ok end,
      in_flight?: fn -> false end,
      core_stop: fn budget_ms -> send(ctx.test_pid, {:core_stop, budget_ms}) && :ok end
    }

    start_supervised!({Orchestrator, name: name, boot: false, units: units})

    opts = [
      orchestrator: &Orchestrator.shutdown(name, &1),
      runtime_reboot: fn -> send(ctx.test_pid, :runtime_called) end,
      resume: ctx.resume
    ]

    log = capture_log(fn -> assert Shutdown.reboot(opts) == :ok end)
    assert_received {:core_stop, budget_ms}
    assert budget_ms in 1..(300_000 - 35_000 - 5_000)
    assert_received :runtime_called
    assert log =~ "apps stopped 0/0, core :ok"
  end
end
