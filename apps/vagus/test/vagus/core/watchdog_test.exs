defmodule Vagus.Core.WatchdogTest do
  @moduledoc """
  Hermetic tests for the Core crash-loop watchdog — events driven by
  sending `{:docker_event, ...}` directly (the `Vagus.Addon.Watchdog` test
  pattern; no real `Vagus.Runtime.Events` instance), time driven by an
  injected clock, rebuild results scripted.
  """

  use ExUnit.Case, async: true

  alias Vagus.Core.{Container, TokenStore, Watchdog}

  @minute 60_000

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "vagus_test_core_watchdog_#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    store = :"core_watchdog_store_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: store, start: {TokenStore, :start_link, [[name: store, path: path]]}})

    clock = start_supervised!({Agent, fn -> 0 end})
    %{store: store, clock: clock}
  end

  defp advance(clock, ms), do: Agent.update(clock, &(&1 + ms))

  defp start_watchdog(ctx, opts \\ []) do
    test_pid = self()
    clock = ctx.clock

    defaults = [
      name: :"core_watchdog_#{System.unique_integer([:positive])}",
      events: :nonexistent_events_server_for_core_watchdog_test,
      token_store: ctx.store,
      clock: fn -> Agent.get(clock, & &1) end,
      rebuild: fn ->
        send(test_pid, :rebuild_called)
        :ok
      end
    ]

    start_supervised!({Watchdog, Keyword.merge(defaults, opts)})
  end

  defp die_event(name, exit_code) do
    %{
      action: "die",
      name: name,
      id: "core-test-id",
      exit_code: exit_code,
      time_nano: 1_700_000_000_000_000_000,
      attributes: %{}
    }
  end

  defp crash_die(pid, exit_code \\ 1) do
    send(pid, {:docker_event, die_event(Container.name(), exit_code)})
    :sys.get_state(pid)
  end

  defp settle(pid) do
    wait_until(fn -> :sys.get_state(pid).task == nil end)
    :sys.get_state(pid)
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline)
    end
  end

  # Drives one full trigger: 3 crash dies -> rebuild dispatched -> settled.
  defp trigger_loop(pid, ctx) do
    for _ <- 1..3 do
      advance(ctx.clock, 1_000)
      crash_die(pid)
    end

    settle(pid)
  end

  describe "crash-loop detection" do
    test "3 crash dies within the window trigger one rebuild and reset the window", ctx do
      pid = start_watchdog(ctx)

      crash_die(pid)
      crash_die(pid)
      refute_receive :rebuild_called, 150

      crash_die(pid)
      assert_receive :rebuild_called
      st = settle(pid)
      assert st.dies == []
    end

    test "2 dies then a quiet spell never trigger", ctx do
      pid = start_watchdog(ctx)

      crash_die(pid)
      crash_die(pid)
      # The third crash lands after the 10-min window has slid past the
      # first two — still only 1 in-window.
      advance(ctx.clock, 11 * @minute)
      st = crash_die(pid)

      refute_receive :rebuild_called, 150
      assert length(st.dies) == 1
    end

    test "zero-exit dies (deliberate stops) are never counted", ctx do
      pid = start_watchdog(ctx)

      for _ <- 1..3, do: crash_die(pid, 0)
      refute_receive :rebuild_called, 150
      assert :sys.get_state(pid).dies == []
    end

    test "a die with no parseable exit code is not counted", ctx do
      pid = start_watchdog(ctx)

      for _ <- 1..3 do
        send(pid, {:docker_event, die_event(Container.name(), nil)})
        :sys.get_state(pid)
      end

      refute_receive :rebuild_called, 150
      assert :sys.get_state(pid).dies == []
    end

    test "dies for other containers are ignored", ctx do
      pid = start_watchdog(ctx)

      for _ <- 1..3 do
        send(pid, {:docker_event, die_event("addon_foo", 137)})
        :sys.get_state(pid)
      end

      refute_receive :rebuild_called, 150
      assert :sys.get_state(pid).dies == []
    end

    test "non-die actions are ignored", ctx do
      pid = start_watchdog(ctx)

      for action <- ["start", "stop", "create"] do
        send(pid, {:docker_event, %{die_event(Container.name(), 1) | action: action}})
        :sys.get_state(pid)
      end

      refute_receive :rebuild_called, 150
      assert :sys.get_state(pid).dies == []
    end
  end

  describe "rate limiter" do
    test "caps watchdog rebuilds at 10 per 30 minutes, then recovers", ctx do
      pid = start_watchdog(ctx)

      for _ <- 1..10 do
        trigger_loop(pid, ctx)
        assert_receive :rebuild_called
      end

      # 11th loop inside the window: detected but dropped.
      trigger_loop(pid, ctx)
      refute_receive :rebuild_called, 150
      # The die window still reset — no stale strikes linger.
      assert :sys.get_state(pid).dies == []

      # Once the 30-min window slides past, actions flow again.
      advance(ctx.clock, 31 * @minute)
      trigger_loop(pid, ctx)
      assert_receive :rebuild_called
    end
  end

  describe "busy skip" do
    test "{:error, :busy} from rebuild is a quiet skip; fresh crashes retrigger", ctx do
      test_pid = self()

      pid =
        start_watchdog(ctx,
          rebuild: fn ->
            send(test_pid, :rebuild_called)
            {:error, :busy}
          end
        )

      trigger_loop(pid, ctx)
      assert_receive :rebuild_called
      assert Process.alive?(pid)

      # Nothing latched: three more crashes trigger again.
      trigger_loop(pid, ctx)
      assert_receive :rebuild_called
    end
  end

  describe "eligibility" do
    test "watchdog-off ignores crash dies entirely", ctx do
      :ok = TokenStore.put_options(%{"watchdog" => false}, ctx.store)
      pid = start_watchdog(ctx)

      for _ <- 1..3, do: crash_die(pid)
      refute_receive :rebuild_called, 150
      assert :sys.get_state(pid).dies == []
    end

    test "dies during an in-flight rebuild are ignored", ctx do
      test_pid = self()

      pid =
        start_watchdog(ctx,
          rebuild: fn ->
            send(test_pid, {:rebuild_started, self()})

            receive do
              :finish_rebuild -> :ok
            end
          end
        )

      trigger_loop_start = fn ->
        for _ <- 1..3 do
          advance(ctx.clock, 1_000)
          crash_die(pid)
        end
      end

      trigger_loop_start.()
      assert_receive {:rebuild_started, rebuild_pid}, 1_000

      # The old container's churn during our own rebuild is expected.
      for _ <- 1..3, do: crash_die(pid)
      assert :sys.get_state(pid).dies == []

      send(rebuild_pid, :finish_rebuild)
      settle(pid)
    end
  end

  describe "action-deadline failsafe" do
    test "force-clears a wedged rebuild so the watchdog can never stay stuck", ctx do
      test_pid = self()

      pid =
        start_watchdog(ctx,
          action_deadline_ms: 50,
          rebuild: fn ->
            send(test_pid, :rebuild_started)
            Process.sleep(:infinity)
          end
        )

      for _ <- 1..3 do
        advance(ctx.clock, 1_000)
        crash_die(pid)
      end

      assert_receive :rebuild_started, 1_000

      # The 50ms deadline fires, brutal-kills the wedged task, and clears
      # the in-flight slot — future crash windows can act again.
      wait_until(fn -> :sys.get_state(pid).task == nil end)
      assert Process.alive?(pid)
    end
  end

  describe "tolerant startup" do
    test "starts fine when the events server is absent (probe half unaffected)", ctx do
      pid = start_watchdog(ctx)
      assert Process.alive?(pid)
    end

    test "crash dies still count (watchdog-on default) when the token store is down", ctx do
      pid = start_watchdog(ctx, token_store: :nonexistent_store_for_core_watchdog_test)

      for _ <- 1..3, do: crash_die(pid)

      assert_receive :rebuild_called
      settle(pid)
      assert Process.alive?(pid)
    end
  end
end
