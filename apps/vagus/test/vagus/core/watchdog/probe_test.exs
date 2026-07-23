defmodule Vagus.Core.Watchdog.ProbeTest do
  @moduledoc """
  Hermetic tests for the Core API watchdog — every collaborator injected
  (scripted check/restart/rebuild fns, a private `Vagus.Core.TokenStore`
  instance), ticks driven by sending `:tick` directly rather than waiting
  out the interval timer (the real timer is parked at a large interval).
  """

  use ExUnit.Case, async: true

  alias Vagus.Core.{TokenStore, Watchdog}

  # Parked far enough out that the timer never fires inside a test run;
  # ticks are sent by hand.
  @parked_interval 600_000

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "vagus_test_core_probe_#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    store = :"core_probe_store_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: store, start: {TokenStore, :start_link, [[name: store, path: path]]}})

    # Scripted results: each fn pops the next scripted value, falling back to
    # a default when the script runs dry.
    script = start_supervised!({Agent, fn -> %{} end})

    %{store: store, script: script}
  end

  defp script_push(script, key, results) when is_list(results) do
    Agent.update(script, &Map.update(&1, key, results, fn old -> old ++ results end))
  end

  defp script_pop(script, key, default) do
    Agent.get_and_update(script, fn state ->
      case Map.get(state, key, []) do
        [] -> {default, state}
        [next | rest] -> {next, Map.put(state, key, rest)}
      end
    end)
  end

  defp start_probe(ctx, opts \\ []) do
    test_pid = self()
    script = ctx.script

    defaults = [
      name: :"core_probe_#{System.unique_integer([:positive])}",
      interval: @parked_interval,
      token_store: ctx.store,
      check: fn -> script_pop(script, :check, :healthy) end,
      restart: fn ->
        result = script_pop(script, :restart, :ok)
        send(test_pid, {:restart_called, result})
        result
      end,
      rebuild: fn ->
        result = script_pop(script, :rebuild, :ok)
        send(test_pid, {:rebuild_called, result})
        result
      end,
      running_check: fn -> true end
    ]

    start_supervised!({Watchdog.Probe, Keyword.merge(defaults, opts)})
  end

  defp tick(pid) do
    send(pid, :tick)
    # :sys.get_state is a message-order barrier: the tick (and anything the
    # tick handler itself sent) has been processed once it returns.
    :sys.get_state(pid)
  end

  # Ticks, then waits for any dispatched action Task to complete and have its
  # result folded back into the ladder.
  defp tick_and_settle(pid) do
    send(pid, :tick)
    wait_until(fn -> :sys.get_state(pid).action == nil end)
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

  defp drive_reanimation(pid, ctx, restart_result) do
    script_push(ctx.script, :check, [:unhealthy, :unhealthy])
    script_push(ctx.script, :restart, [restart_result])
    tick(pid)
    tick_and_settle(pid)
    assert_receive {:restart_called, ^restart_result}
  end

  describe "miss ladder" do
    test "first miss warns only, second consecutive miss restarts", ctx do
      pid = start_probe(ctx)

      script_push(ctx.script, :check, [:unhealthy])
      tick(pid)
      refute_receive {:restart_called, _}, 50

      script_push(ctx.script, :check, [:unhealthy])
      tick_and_settle(pid)
      assert_receive {:restart_called, :ok}
    end

    test "a healthy tick resets the miss counter", ctx do
      pid = start_probe(ctx)

      # miss, healthy, miss — never two consecutive, so never a restart.
      script_push(ctx.script, :check, [:unhealthy, :healthy, :unhealthy])
      tick(pid)
      tick(pid)
      tick(pid)

      refute_receive {:restart_called, _}, 50
      assert :sys.get_state(pid).misses == 1
    end
  end

  describe "reanimation escalation" do
    test "after 5 reanimations the next trigger is one rebuild, then given up", ctx do
      pid = start_probe(ctx)

      for _cycle <- 1..5 do
        # Restart "succeeds" but Core hangs again before a stable streak —
        # each cycle consumes one reanimation.
        drive_reanimation(pid, ctx, :ok)
      end

      assert :sys.get_state(pid).reanimations == 5

      script_push(ctx.script, :check, [:unhealthy, :unhealthy])
      tick(pid)
      tick_and_settle(pid)

      assert_receive {:rebuild_called, :ok}
      refute_receive {:restart_called, _}, 50
      assert :sys.get_state(pid).given_up == true
    end

    test "failed restarts count as reanimations too", ctx do
      pid = start_probe(ctx)

      drive_reanimation(pid, ctx, {:error, :health_timeout})
      assert :sys.get_state(pid).reanimations == 1
    end

    test "a stable healthy streak resets the reanimation counter", ctx do
      pid = start_probe(ctx)

      drive_reanimation(pid, ctx, :ok)
      assert :sys.get_state(pid).reanimations == 1

      # 5 consecutive healthy ticks (the default script) — stable again.
      for _ <- 1..5, do: tick(pid)
      assert :sys.get_state(pid).reanimations == 0
    end
  end

  describe "given-up latch" do
    test "no further actions while given up; toggling the watchdog option revives", ctx do
      pid = start_probe(ctx)

      for _cycle <- 1..5, do: drive_reanimation(pid, ctx, :ok)
      script_push(ctx.script, :check, [:unhealthy, :unhealthy])
      tick(pid)
      tick_and_settle(pid)
      assert_receive {:rebuild_called, :ok}
      assert :sys.get_state(pid).given_up == true

      # Latched: unhealthy ticks are no-ops (check fn isn't even consulted —
      # scripted values stay queued).
      script_push(ctx.script, :check, [:unhealthy, :unhealthy])
      tick(pid)
      tick(pid)
      refute_receive {:restart_called, _}, 50
      refute_receive {:rebuild_called, _}, 50

      # Toggle off → on via the real TokenStore round-trip (the probe is
      # subscribed): the ladder resets fully.
      :ok = TokenStore.put_options(%{"watchdog" => false}, ctx.store)
      :ok = TokenStore.put_options(%{"watchdog" => true}, ctx.store)
      wait_until(fn -> :sys.get_state(pid).given_up == false end)
      assert :sys.get_state(pid).reanimations == 0

      # The two still-queued unhealthy results now drive a fresh restart.
      tick(pid)
      tick_and_settle(pid)
      assert_receive {:restart_called, :ok}
    end
  end

  describe "busy skip" do
    test "{:error, :busy} from restart consumes no reanimation attempt", ctx do
      pid = start_probe(ctx)

      script_push(ctx.script, :check, [:unhealthy, :unhealthy, :unhealthy])
      script_push(ctx.script, :restart, [{:error, :busy}, :ok])

      tick(pid)
      tick_and_settle(pid)
      assert_receive {:restart_called, {:error, :busy}}
      assert :sys.get_state(pid).reanimations == 0

      # Misses were not reset by the busy skip — the very next unhealthy
      # tick retries the restart, which now goes through and counts.
      tick_and_settle(pid)
      assert_receive {:restart_called, :ok}
      assert :sys.get_state(pid).reanimations == 1
    end

    test "{:error, :busy} from the last-ditch rebuild does not latch given-up", ctx do
      pid = start_probe(ctx)

      for _cycle <- 1..5, do: drive_reanimation(pid, ctx, :ok)

      script_push(ctx.script, :check, [:unhealthy, :unhealthy, :unhealthy])
      script_push(ctx.script, :rebuild, [{:error, :busy}, :ok])
      tick(pid)
      tick_and_settle(pid)
      assert_receive {:rebuild_called, {:error, :busy}}
      assert :sys.get_state(pid).given_up == false

      # Next unhealthy tick retries the rebuild, which now latches.
      tick_and_settle(pid)
      assert_receive {:rebuild_called, :ok}
      assert :sys.get_state(pid).given_up == true
    end
  end

  describe "skips that are not strikes" do
    test "watchdog-off ticks are no-ops", ctx do
      :ok = TokenStore.put_options(%{"watchdog" => false}, ctx.store)
      pid = start_probe(ctx)

      script_push(ctx.script, :check, [:unhealthy, :unhealthy])
      tick(pid)
      tick(pid)

      refute_receive {:restart_called, _}, 50
      assert :sys.get_state(pid).misses == 0
      # The probe never even ran — both scripted results are still queued.
      assert Agent.get(ctx.script, &Map.get(&1, :check)) == [:unhealthy, :unhealthy]
    end

    test "container-not-running ticks are no-ops", ctx do
      pid = start_probe(ctx, running_check: fn -> false end)

      script_push(ctx.script, :check, [:unhealthy, :unhealthy])
      tick(pid)
      tick(pid)

      refute_receive {:restart_called, _}, 50
      assert :sys.get_state(pid).misses == 0
    end

    test "ticks while an action is in flight skip probing", ctx do
      test_pid = self()

      pid =
        start_probe(ctx,
          # The fn runs inside the bounded-call's inner Task — hand its own
          # pid out so the test can release it.
          restart: fn ->
            send(test_pid, {:restart_started, self()})

            receive do
              :finish_restart -> :ok
            end
          end
        )

      script_push(ctx.script, :check, [:unhealthy, :unhealthy])
      tick(pid)
      tick(pid)
      assert_receive {:restart_started, restart_pid}

      # In flight: another tick consults neither check nor restart.
      script_push(ctx.script, :check, [:unhealthy])
      tick(pid)
      assert Agent.get(ctx.script, &Map.get(&1, :check)) == [:unhealthy]

      send(restart_pid, :finish_restart)
      wait_until(fn -> :sys.get_state(pid).action == nil end)
      assert :sys.get_state(pid).reanimations == 1
    end
  end

  describe "tolerant startup" do
    test "starts fine when the token store is absent (probe half still works)", ctx do
      pid = start_probe(ctx, token_store: :nonexistent_token_store_for_probe_test)
      assert Process.alive?(pid)
    end
  end
end
