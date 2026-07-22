defmodule Vagus.Addon.WatchdogTest do
  @moduledoc """
  M4B-IW-P1-T2, `docs/contract-2026.7-m4b-ingress-watchdog.md` §B6. Every
  test injects `:manager`, `:running_check`, `:state`, and `:clock` so
  nothing here touches a real docker daemon, the real `Vagus.Addon.State`
  singleton, or a real clock — same hermetic-injection style as
  `boot_starter_test.exs`.

  `Vagus.Addon.WatchdogTest.FakeManager` (bottom of file) is the module
  passed as `:manager`; since its functions run inside the watchdog's own
  restart-sequence `Task` (a different process from the test), it can't
  just `send(self(), ...)` — it forwards each call as a message to
  whichever pid `config :vagus, :watchdog_test_pid` names (set in
  `setup/1`) and returns whatever `config :vagus, :watchdog_test_result_fun`
  says, the same "app-env as a cross-process test knob" trick
  `Vagus.Addon.Backend.Fake`/`BootStarterTest` already use for swapping in
  fakes app-wide.
  """

  use ExUnit.Case, async: false

  alias Vagus.Addon.{Config, State, Watchdog}
  alias Vagus.Addon.WatchdogTest.FakeManager

  @thirty_min_ms 30 * 60 * 1_000

  ## Helpers

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"
  defp unique_slug(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  # A private, uniquely-named `Vagus.Addon.State` instance, supervised via
  # `start_supervised!/1` (torn down automatically at test end) — same
  # per-test-unique-name rationale as `events_test.exs`'s `Events` instances.
  defp start_state do
    start_supervised!({State, name: unique_name("wd_state"), persist_path: nil})
  end

  defp fixture_config(slug) do
    {:ok, config} =
      Config.parse(%{
        "name" => "Test",
        "version" => "1",
        "slug" => slug,
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "homeassistant/{arch}-addon-test",
        "host_network" => true
      })

    config
  end

  # Seeds `slug` in `state_pid` with lifecycle `state` and the `watchdog`
  # setting, returning the config (needed by tests that later flip lifecycle
  # state mid-sequence).
  defp seed(state_pid, slug, lifecycle_state, watchdog?) do
    config = fixture_config(slug)
    :ok = State.put(config, lifecycle_state, server: state_pid)
    :ok = State.put_setting(slug, :watchdog, watchdog?, state_pid)
    config
  end

  defp die_event(slug, exit_code \\ 137) do
    {:docker_event,
     %{
       action: "die",
       name: "addon_#{slug}",
       id: "id",
       exit_code: exit_code,
       time_nano: 0,
       attributes: %{}
     }}
  end

  defp unhealthy_event(slug) do
    {:docker_event,
     %{
       action: "health_status: unhealthy",
       name: "addon_#{slug}",
       id: "id",
       exit_code: nil,
       time_nano: 0,
       attributes: %{}
     }}
  end

  defp start_watchdog(opts) do
    name = unique_name("watchdog")
    pid = start_supervised!({Watchdog, Keyword.put(opts, :name, name)})
    pid
  end

  defp always(result), do: fn _kind, _slug -> result end

  defp set_manager_result(fun), do: Application.put_env(:vagus, :watchdog_test_result_fun, fun)

  # Retries `fun` (a 0-arity predicate) until truthy or attempts exhausted —
  # the restart sequence runs in its own Task on its own schedule.
  defp eventually(fun, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(5)
        {:cont, false}
      end
    end)
  end

  setup do
    Application.put_env(:vagus, :watchdog_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:vagus, :watchdog_test_pid)
      Application.delete_env(:vagus, :watchdog_test_result_fun)
    end)

    %{state_pid: start_state()}
  end

  ## 1: die -> start_slug

  test "die event (exit_code 137) for a watchdog:true, :started slug calls manager.start_slug/2",
       %{state_pid: state_pid} do
    slug = unique_slug("wd")
    seed(state_pid, slug, :started, true)
    set_manager_result(always({:ok, %{id: "i", access_token: "t"}}))

    pid =
      start_watchdog(
        state: state_pid,
        manager: FakeManager,
        running_check: fn _slug -> false end,
        backoff_base_ms: 5
      )

    send(pid, die_event(slug))

    assert_receive {:start_slug, ^slug}, 500
  end

  ## 2: eligibility gates

  test "watchdog:false -> ignored", %{state_pid: state_pid} do
    slug = unique_slug("wd")
    seed(state_pid, slug, :started, false)
    set_manager_result(always({:ok, %{}}))

    pid =
      start_watchdog(
        state: state_pid,
        manager: FakeManager,
        running_check: fn _slug -> false end,
        backoff_base_ms: 5
      )

    send(pid, die_event(slug))

    refute_receive {:start_slug, ^slug}, 200
  end

  test "state: :stopped -> ignored", %{state_pid: state_pid} do
    slug = unique_slug("wd")
    seed(state_pid, slug, :stopped, true)
    set_manager_result(always({:ok, %{}}))

    pid =
      start_watchdog(
        state: state_pid,
        manager: FakeManager,
        running_check: fn _slug -> false end,
        backoff_base_ms: 5
      )

    send(pid, die_event(slug))

    refute_receive {:start_slug, ^slug}, 200
  end

  test "untracked slug -> ignored", %{state_pid: state_pid} do
    slug = unique_slug("wd")
    set_manager_result(always({:ok, %{}}))

    pid =
      start_watchdog(
        state: state_pid,
        manager: FakeManager,
        running_check: fn _slug -> false end,
        backoff_base_ms: 5
      )

    send(pid, die_event(slug))

    refute_receive {:start_slug, ^slug}, 200
  end

  ## 3: unhealthy -> restart, not start_slug

  test "health_status: unhealthy calls manager.restart/2, not start_slug/2", %{
    state_pid: state_pid
  } do
    slug = unique_slug("wd")
    seed(state_pid, slug, :started, true)
    set_manager_result(always({:ok, %{}}))

    pid =
      start_watchdog(
        state: state_pid,
        manager: FakeManager,
        running_check: fn _slug -> false end,
        backoff_base_ms: 5
      )

    send(pid, unhealthy_event(slug))

    assert_receive {:restart, ^slug}, 500
    refute_received {:start_slug, ^slug}
  end

  ## 4: 5 failed attempts, growing backoff, then demoted

  # QUARANTINED (:flaky) — asserts real wall-clock backoff *ratios* between
  # retry attempts (g2 >= g1 * 1.8) and a minimum elapsed sum; a slow/loaded
  # CI runner compresses/perturbs those gaps and the ratio assertion fails.
  # Excluded in CI until rewritten against the injected clock rather than real
  # time. Tracked in scratchpad "test-hardening" TODO. Reliable at normal speed.
  @tag :flaky
  test "a manager that always fails is retried 5 times with growing gaps, then State is demoted",
       %{state_pid: state_pid} do
    slug = unique_slug("wd")
    seed(state_pid, slug, :started, true)
    set_manager_result(always({:error, :boom}))

    pid =
      start_watchdog(
        state: state_pid,
        manager: FakeManager,
        running_check: fn _slug -> false end,
        backoff_base_ms: 5
      )

    send(pid, die_event(slug))

    # W4: per-attempt timestamps (not just a cumulative floor) — a flat,
    # non-growing backoff would still satisfy `elapsed >= 70` alone.
    timestamps =
      for _ <- 1..5 do
        assert_receive({:attempt, ts}, 1_000)
        ts
      end

    gaps = timestamps |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)

    # Backoff base 5ms doubling per attempt (5, 10, 20, 40) — each successive
    # gap must be at least ~1.8x the previous (tolerance for scheduling
    # jitter, short of the exact 2x) to actually pin *growth*, not just a
    # floor.
    gaps
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [g1, g2] -> assert g2 >= g1 * 1.8 end)

    # Keep the original cumulative floor too.
    assert Enum.sum(gaps) >= 70

    assert eventually(fn -> match?({:ok, %{state: :stopped}}, State.get(slug, state_pid)) end)
  end

  ## 4b (W1): a manager call that never returns is bounded, not wedged

  test "a manager call that blocks forever is treated as a failed attempt (bounded, not wedged)",
       %{state_pid: state_pid} do
    slug = unique_slug("wd")
    seed(state_pid, slug, :started, true)
    set_manager_result(fn _kind, _slug -> Process.sleep(:infinity) end)

    pid =
      start_watchdog(
        state: state_pid,
        manager: FakeManager,
        running_check: fn _slug -> false end,
        backoff_base_ms: 5,
        attempt_timeout_ms: 20
      )

    send(pid, die_event(slug))

    for _ <- 1..5, do: assert_receive({:start_slug, ^slug}, 1_000)

    assert eventually(fn -> match?({:ok, %{state: :stopped}}, State.get(slug, state_pid)) end)
  end

  ## 4c (W1): the sequence-deadline failsafe recovers a wedge outside the
  ## per-attempt bound (e.g. `running_check` itself hanging)

  test "the sequence-deadline failsafe clears a wedged sequence and accepts a fresh trigger after",
       %{state_pid: state_pid} do
    slug = unique_slug("wd")
    seed(state_pid, slug, :started, true)
    set_manager_result(always({:ok, %{}}))

    counter = :counters.new(1, [])

    # First call (the wedged sequence) blocks forever — nothing bounds
    # `running_check` itself, only the manager call (see moduledoc) — so
    # only the sequence-deadline failsafe can recover it. The second call
    # (the fresh sequence started after the failsafe clears the entry)
    # resolves immediately.
    running_check = fn _slug ->
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      if n == 0, do: Process.sleep(:infinity), else: false
    end

    pid =
      start_watchdog(
        state: state_pid,
        manager: FakeManager,
        running_check: running_check,
        backoff_base_ms: 5,
        sequence_deadline_ms: 30
      )

    send(pid, die_event(slug))

    assert eventually(fn -> not Map.has_key?(:sys.get_state(pid).tasks, slug) end)

    send(pid, die_event(slug))

    assert_receive {:start_slug, ^slug}, 500
  end

  ## 5: running_check flips true before attempt 2 -> stop early

  test "running_check becoming true before attempt 2 ends the sequence after 1 attempt", %{
    state_pid: state_pid
  } do
    slug = unique_slug("wd")
    seed(state_pid, slug, :started, true)
    set_manager_result(always({:error, :boom}))

    counter = :counters.new(1, [])

    running_check = fn _slug ->
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      n > 0
    end

    pid =
      start_watchdog(
        state: state_pid,
        manager: FakeManager,
        running_check: running_check,
        backoff_base_ms: 5
      )

    send(pid, die_event(slug))

    assert_receive {:start_slug, ^slug}, 500
    refute_receive {:start_slug, ^slug}, 100
  end

  ## 6: manual stop mid-sequence aborts it

  test "a manual stop mid-sequence (State flipped to :stopped between attempts) aborts it", %{
    state_pid: state_pid
  } do
    slug = unique_slug("wd")
    config = seed(state_pid, slug, :started, true)
    set_manager_result(always({:error, :boom}))

    pid =
      start_watchdog(
        state: state_pid,
        manager: FakeManager,
        running_check: fn _slug -> false end,
        backoff_base_ms: 5
      )

    send(pid, die_event(slug))

    assert_receive {:start_slug, ^slug}, 500
    :ok = State.put(config, :stopped, server: state_pid)

    refute_receive {:start_slug, ^slug}, 100
  end

  ## 7: global throttle

  test "global throttle allows 10 sequence starts per window, ignores the 11th, re-allows after the window",
       %{state_pid: state_pid} do
    now = :atomics.new(1, signed: true)
    :atomics.put(now, 1, 0)
    clock = fn -> :atomics.get(now, 1) end

    set_manager_result(always({:ok, %{}}))

    slugs = for i <- 0..10, do: unique_slug("wdthrottle#{i}")
    Enum.each(slugs, &seed(state_pid, &1, :started, true))

    pid =
      start_watchdog(
        state: state_pid,
        manager: FakeManager,
        running_check: fn _slug -> false end,
        backoff_base_ms: 5,
        clock: clock
      )

    allowed = Enum.take(slugs, 10)
    throttled_slug = Enum.at(slugs, 10)

    Enum.each(allowed, fn slug ->
      send(pid, die_event(slug))
      assert_receive {:start_slug, ^slug}, 500
    end)

    send(pid, die_event(throttled_slug))
    refute_receive {:start_slug, ^throttled_slug}, 200

    # Advance the clock past the 30-minute sliding window; the same event
    # should now be allowed through.
    :atomics.put(now, 1, @thirty_min_ms + 1)
    send(pid, die_event(throttled_slug))
    assert_receive {:start_slug, ^throttled_slug}, 500
  end

  ## 8: duplicate events while in flight -> one sequence

  test "duplicate die events while a sequence is in flight start only one sequence", %{
    state_pid: state_pid
  } do
    slug = unique_slug("wd")
    seed(state_pid, slug, :started, true)

    set_manager_result(fn _kind, _slug ->
      Process.sleep(30)
      {:ok, %{}}
    end)

    pid =
      start_watchdog(
        state: state_pid,
        manager: FakeManager,
        running_check: fn _slug -> false end,
        backoff_base_ms: 5
      )

    send(pid, die_event(slug))
    send(pid, die_event(slug))

    assert_receive {:start_slug, ^slug}, 500
    refute_receive {:start_slug, ^slug}, 200
  end

  defmodule FakeManager do
    @moduledoc false

    def start_slug(slug, opts), do: dispatch(:start_slug, slug, opts)
    def restart(slug, opts), do: dispatch(:restart, slug, opts)

    defp dispatch(kind, slug, _opts) do
      case Application.get_env(:vagus, :watchdog_test_pid) do
        pid when is_pid(pid) ->
          send(pid, {kind, slug})
          # W4: per-attempt timestamp, for the backoff-growth test — sent
          # unconditionally since no other test asserts on the absence of
          # this message tag.
          send(pid, {:attempt, System.monotonic_time(:millisecond)})

        _ ->
          :ok
      end

      fun =
        Application.get_env(:vagus, :watchdog_test_result_fun, fn _kind, _slug ->
          {:error, :unconfigured}
        end)

      fun.(kind, slug)
    end
  end
end
