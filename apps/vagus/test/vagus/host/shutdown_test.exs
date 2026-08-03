defmodule Vagus.Host.ShutdownTest do
  @moduledoc """
  Plan task 3.1 (`.claude/plans/vagus-graceful-shutdown/plan.md`, issue #39).
  Every test injects `:addons`, `:stop_addon`, `:stop_core`, `:runtime_reboot`/
  `:runtime_poweroff`, and the various budget knobs — same hermetic-injection
  style as `watchdog_test.exs` — so nothing here touches a real docker
  daemon, the real `Vagus.Addon.State`/`Vagus.Core.Lifecycle` singletons, or
  `Nerves.Runtime.reboot/0`/`poweroff/0` (which would be disastrous to call
  for real from a test run). `Vagus.Jobs.TaskSupervisor` is the one real,
  shared piece of infrastructure used as-is: it's already started by
  `Vagus.Application` in the test env, and `Vagus.Host.Shutdown` depends on
  its specific name, so faking it would test nothing.

  `async: false` is MANDATORY, not a style choice: `Vagus.Host.Shutdown`
  marks a shutdown in flight via the process-wide `:persistent_term` key
  `{Vagus.Host.Shutdown, :in_flight}` and — by design (see the moduledoc's
  "Watchdog stand-down" section) — never clears it, because in production
  there is no "shutdown aborted, back to normal" state to return to. Tests
  are the one place that invariant is wrong: `Vagus.Addon.Watchdog`'s
  default `:shutdown_check` reads this exact key, so a stray `true` left
  behind by one test would silently suppress watchdog restarts in a
  *different* test file running concurrently. `setup` here erases the key
  both before and after every test (before, in case some earlier test in a
  different file already left it set; after, via `on_exit`) to keep this
  file from leaking into anyone else, and `async: false` keeps this file's
  own tests from leaking into each other (they all touch the same global
  key).

  `@moduletag :capture_log` — every path through the module under test logs
  a warning or error by design (see "Availability over cleanliness"); that's
  signal, not noise, and asserting on it isn't the point of these tests.

  A recurring shape below: the injected `:stop_addon`/`:stop_core`/runtime
  functions run inside a `Vagus.Jobs.TaskSupervisor` task, NOT the test
  process, so closures capture `test_pid = self()` up front and `send/2`
  tagged messages back rather than mutating test-process state directly.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Vagus.Host.Shutdown

  ## Helpers

  defp docker_addon(slug, state \\ :started) do
    %{state: state, config: %{slug: slug, backend: :docker}}
  end

  setup do
    :persistent_term.erase({Shutdown, :in_flight})
    on_exit(fn -> :persistent_term.erase({Shutdown, :in_flight}) end)
    :ok
  end

  ## 1: ordering — add-ons, then core, then runtime

  test "add-ons are stopped, then core, then the runtime call — in that order" do
    test_pid = self()

    opts = [
      addons: fn -> [docker_addon("a"), docker_addon("b")] end,
      stop_addon: fn name, _timeout_s ->
        send(test_pid, {:addon_stopped, name})
        :ok
      end,
      stop_core: fn ->
        send(test_pid, :core_stopped)
        :ok
      end,
      runtime_reboot: fn ->
        send(test_pid, :runtime_called)
        :ok
      end
    ]

    assert Shutdown.reboot(opts) == :ok

    {:messages, msgs} = Process.info(self(), :messages)

    addon_indices =
      for {msg, i} <- Enum.with_index(msgs), match?({:addon_stopped, _}, msg), do: i

    core_index = Enum.find_index(msgs, &(&1 == :core_stopped))
    runtime_index = Enum.find_index(msgs, &(&1 == :runtime_called))

    assert length(addon_indices) == 2
    assert Enum.all?(addon_indices, &(&1 < core_index))
    assert core_index < runtime_index
  end

  ## 2: native-backend add-ons are skipped

  test "native-backend add-ons are skipped; a docker add-on is stopped once" do
    test_pid = self()

    opts = [
      addons: fn ->
        [
          %{state: :started, config: %{slug: "core_mqtt", backend: :native}},
          docker_addon("d"),
          docker_addon("already_stopped", :stopped)
        ]
      end,
      stop_addon: fn name, _timeout_s ->
        send(test_pid, {:addon_stopped, name})
        :ok
      end,
      stop_core: fn -> :ok end,
      runtime_reboot: fn -> :ok end
    ]

    assert Shutdown.reboot(opts) == :ok

    assert_receive {:addon_stopped, "addon_d"}
    refute_received {:addon_stopped, _}
  end

  ## 3: in_flight?/0 flips true before the stop stages

  test "in_flight?/0 is already true by the time the stop stages run" do
    test_pid = self()

    opts = [
      addons: fn -> [] end,
      stop_core: fn ->
        send(test_pid, {:in_flight_during_core, Shutdown.in_flight?()})
        :ok
      end,
      runtime_reboot: fn -> :ok end
    ]

    refute Shutdown.in_flight?()
    assert Shutdown.reboot(opts) == :ok
    assert_receive {:in_flight_during_core, true}
  end

  ## 4: :busy retried, then succeeds

  test "a core stop that returns :busy once is retried and then succeeds" do
    test_pid = self()
    counter = :counters.new(1, [])

    opts = [
      addons: fn -> [] end,
      stop_core: fn ->
        n = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        if n == 0, do: {:error, :busy}, else: :ok
      end,
      runtime_reboot: fn ->
        send(test_pid, :runtime_called)
        :ok
      end,
      busy_backoff_ms: 1
    ]

    assert Shutdown.reboot(opts) == :ok
    assert_receive :runtime_called
    assert :counters.get(counter, 1) == 2
  end

  ## 5: :busy exhausts its retry budget, shutdown proceeds anyway

  test "a core stop that stays :busy exhausts its retry budget but the runtime call still happens" do
    test_pid = self()

    opts = [
      addons: fn -> [] end,
      stop_core: fn -> {:error, :busy} end,
      runtime_reboot: fn ->
        send(test_pid, :runtime_called)
        :ok
      end,
      busy_retry_budget_ms: 20,
      busy_backoff_ms: 5
    ]

    assert Shutdown.reboot(opts) == :ok
    assert_receive :runtime_called
  end

  ## 6: a wedged stop_addon is bounded by addon_task_timeout_ms

  test "a wedged stop_addon is bounded — the other add-on still stops and the runtime call happens" do
    test_pid = self()

    opts = [
      addons: fn -> [docker_addon("wedged"), docker_addon("fast")] end,
      stop_addon: fn
        "addon_wedged", _timeout_s ->
          Process.sleep(:infinity)

        name, _timeout_s ->
          send(test_pid, {:addon_stopped, name})
          :ok
      end,
      stop_core: fn -> :ok end,
      runtime_reboot: fn ->
        send(test_pid, :runtime_called)
        :ok
      end,
      addon_task_timeout_ms: 50
    ]

    started_at = System.monotonic_time(:millisecond)
    assert Shutdown.reboot(opts) == :ok
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert_receive {:addon_stopped, "addon_fast"}
    assert_receive :runtime_called
    assert elapsed < 2_000
  end

  ## 7: the total budget bounds a wedged core stop

  test "a wedged core stop is bounded by total_budget_ms — the runtime call still happens" do
    test_pid = self()

    opts = [
      addons: fn -> [] end,
      stop_core: fn -> Process.sleep(:infinity) end,
      runtime_reboot: fn ->
        send(test_pid, :runtime_called)
        :ok
      end,
      total_budget_ms: 50
    ]

    started_at = System.monotonic_time(:millisecond)
    assert Shutdown.reboot(opts) == :ok
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert_receive :runtime_called
    assert elapsed < 2_000
  end

  ## 8: reentrancy — a second caller while one is in flight is a no-op

  test "a second caller while a shutdown is in flight is a no-op — only the first runtime call happens" do
    test_pid = self()

    first_opts = [
      addons: fn -> [] end,
      stop_core: fn ->
        send(test_pid, {:first_blocked, self()})

        receive do
          :release -> :ok
        end
      end,
      runtime_reboot: fn ->
        send(test_pid, :runtime_first)
        :ok
      end
    ]

    task = Task.async(fn -> Shutdown.reboot(first_opts) end)

    assert_receive {:first_blocked, blocked_pid}

    second_opts = [
      addons: fn -> [] end,
      stop_core: fn -> :ok end,
      runtime_reboot: fn ->
        send(test_pid, :runtime_second)
        :ok
      end
    ]

    # The second caller must not block waiting for the first — `:global.trans`
    # with `retries: 0` returns `:aborted` immediately.
    assert Shutdown.reboot(second_opts) == :ok
    refute_receive :runtime_second, 100

    send(blocked_pid, :release)

    assert Task.await(task) == :ok
    assert_receive :runtime_first
    refute_received :runtime_second
  end

  ## 9: poweroff/1 delegates to :runtime_poweroff, never :runtime_reboot

  test "poweroff/1 calls :runtime_poweroff and never :runtime_reboot" do
    test_pid = self()

    opts = [
      addons: fn -> [] end,
      stop_core: fn -> :ok end,
      runtime_poweroff: fn ->
        send(test_pid, :poweroff_called)
        :ok
      end,
      runtime_reboot: fn ->
        send(test_pid, :reboot_called)
        :ok
      end
    ]

    assert Shutdown.poweroff(opts) == :ok
    assert_receive :poweroff_called
    refute_received :reboot_called
  end

  ## 10: crash resilience — a raising :addons fun still lets the runtime call happen

  test "an :addons fun that raises still lets the runtime call happen (degraded, not blocked)" do
    test_pid = self()

    opts = [
      addons: fn -> raise "boom" end,
      stop_core: fn -> :ok end,
      runtime_reboot: fn ->
        send(test_pid, :runtime_called)
        :ok
      end
    ]

    assert Shutdown.reboot(opts) == :ok
    assert_receive :runtime_called
  end
end
