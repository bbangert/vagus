defmodule Vagus.Host.ShutdownTest do
  @moduledoc """
  Every test injects the orchestrator's stop sequence and the runtime call,
  so nothing here stops a container or calls `Nerves.Runtime`. The injected
  orchestrator runs in a `Vagus.Jobs.TaskSupervisor` task, not the test
  process, so it reports back by message.

  `async: false` because the in-flight flag is one `:persistent_term` key
  that `Vagus.Addon.Watchdog` reads too; `setup` erases it around each test.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Vagus.Host.Shutdown

  @stopped {{2, 2}, :ok}

  setup do
    :persistent_term.erase({Shutdown, :in_flight})
    on_exit(fn -> :persistent_term.erase({Shutdown, :in_flight}) end)
    test_pid = self()
    {:ok, test_pid: test_pid, resume: fn -> send(test_pid, :resumed) end}
  end

  defp reporting(test_pid, result \\ @stopped) do
    fn ->
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
      orchestrator: fn ->
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
      orchestrator: fn -> raise "boom" end,
      runtime_reboot: fn -> send(ctx.test_pid, :runtime_called) end,
      resume: ctx.resume
    ]

    assert Shutdown.reboot(opts) == :ok
    assert_received :runtime_called
  end

  test "a second caller while a shutdown is in flight is a no-op", ctx do
    first_opts = [
      orchestrator: fn ->
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
end
