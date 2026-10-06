defmodule Vagus.Addon.WatchdogTest do
  @moduledoc """
  M4B-IW-P1-T2, `docs/contract-2026.7-m4b-ingress-watchdog.md` §B6. Every
  test injects `:manager`, `:running_check`, `:state`, and `:clock` so
  nothing here touches a real docker daemon, the real `Vagus.Addon.State`
  singleton, or a real clock — same hermetic-injection style as
  `boot_starter_test.exs`. The tests that give up through the real
  `Vagus.Addon.Manager` use the real `State`, the only one it reads.

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

  import ExUnit.CaptureLog

  alias Vagus.Addon.{Backend.Fake, Config, Registry, State, Watchdog}
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
  defp set_demote(fun), do: Application.put_env(:vagus, :watchdog_test_demote_fun, fun)

  # What `Vagus.Addon.Manager.demote/2` does to the real `State`, against the
  # private one the Watchdog under test reads.
  defp demote_in(state_pid, slug) do
    with {:ok, %{config: config}} <- State.get(slug, state_pid) do
      State.put(config, :stopped, server: state_pid)
    end

    :ok
  end

  # The real `State` and `Registry`, with a token registered for the add-on.
  defp seed_real(slug) do
    config = fixture_config(slug)
    :ok = State.put(config, :started)
    :ok = State.put_setting(slug, :watchdog, true)
    token = "token-#{slug}"
    :ok = Registry.register(token, Registry.identity_from_config(config))

    Fake.reset_calls()

    on_exit(fn ->
      State.delete(slug)
      Registry.unregister_slug(slug)
    end)

    set_demote(fn slug -> Vagus.Addon.Manager.demote(slug, backend: Fake) end)
    token
  end

  # A `:sleep` that parks the sequence at each backoff, so the test learns
  # its pid while it is still alive.
  defp parking_sleep do
    test = self()

    fn _ms ->
      send(test, {:backoff, self()})

      receive do
        :resume -> :ok
      end
    end
  end

  # Walks a parked sequence through its four backoffs and returns the reason
  # it went down with.
  defp run_to_give_up do
    assert_receive {:backoff, sequence}, 5_000
    ref = Process.monitor(sequence)
    send(sequence, :resume)

    for _ <- 2..4 do
      assert_receive {:backoff, ^sequence}, 5_000
      send(sequence, :resume)
    end

    assert_receive {:DOWN, ^ref, :process, ^sequence, reason}, 5_000
    reason
  end

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
      Application.delete_env(:vagus, :watchdog_test_demote_fun)
    end)

    state_pid = start_state()
    set_demote(&demote_in(state_pid, &1))
    %{state_pid: state_pid}
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

  test "a manager that always fails is retried 5 times with a doubling backoff, then State is demoted",
       %{state_pid: state_pid} do
    parent = self()
    slug = unique_slug("wd")
    seed(state_pid, slug, :started, true)
    set_manager_result(always({:error, :boom}))

    pid =
      start_watchdog(
        state: state_pid,
        manager: FakeManager,
        running_check: fn _slug -> false end,
        backoff_base_ms: 5,
        # Record the COMPUTED backoff instead of sleeping. Formerly this test
        # measured real elapsed gaps and asserted `g2 >= g1 * 1.8`, which a
        # loaded CI runner perturbed (the `@tag :flaky` root cause). Injecting
        # the sleep makes the schedule exact + instant.
        sleep: fn ms -> send(parent, {:backoff, ms}) end
      )

    send(pid, die_event(slug))

    # 5 attempts (all fail) → 4 backoffs between them; base 5ms doubling each
    # time: 5, 10, 20, 40. Exact growth, no timing measurement. The 5th attempt
    # gives up without sleeping.
    for expected <- [5, 10, 20, 40] do
      assert_receive {:backoff, ^expected}, 1_000
    end

    assert eventually(fn -> match?({:ok, %{state: :stopped}}, State.get(slug, state_pid)) end)
    # Exactly four backoffs — the sequence gave up on attempt 5, not slept again.
    refute_received {:backoff, _}
  end

  test "giving up records a dead add-on :stopped and revokes its token" do
    slug = unique_slug("wd")
    token = seed_real(slug)
    set_manager_result(always({:error, :boom}))

    pid =
      start_watchdog(
        manager: FakeManager,
        running_check: fn _slug -> false end,
        sleep: parking_sleep()
      )

    send(pid, die_event(slug))
    assert_receive {:start_slug, ^slug}, 5_000
    assert {:ok, %{slug: ^slug}} = Registry.identity_for_token(token)

    assert run_to_give_up() == :normal
    assert {:ok, %{state: :stopped}} = State.get(slug)
    assert :error = Registry.identity_for_token(token)
  end

  # Something else started it after the last failed attempt.
  test "giving up leaves an add-on that is running after all :started, with its token" do
    slug = unique_slug("wd")
    token = seed_real(slug)
    :ok = Fake.start("addon_#{slug}")
    set_manager_result(always({:error, :boom}))

    pid =
      start_watchdog(
        manager: FakeManager,
        running_check: fn _slug -> false end,
        sleep: parking_sleep()
      )

    send(pid, die_event(slug))

    log = capture_log(fn -> assert run_to_give_up() == :normal end)

    assert_received {:demote, ^slug}
    assert {:ok, %{state: :started}} = State.get(slug)
    assert {:ok, %{slug: ^slug}} = Registry.identity_for_token(token)
    assert log =~ "#{slug} is running after all"
  end

  for {name, demote, logged} <- [
        {"hangs", quote(do: fn _slug -> receive(do: (:never -> :ok)) end), "timed out"},
        {"exits", quote(do: fn _slug -> exit(:boom) end), "failed"},
        {"raises", quote(do: fn _slug -> raise "boom" end), "failed"},
        {"returns an error", quote(do: fn _slug -> {:error, :boom} end), "failed"},
        {"finds no State", quote(do: fn _slug -> {:error, :state_unavailable} end),
         "found no State to record it in"}
      ] do
    test "a demotion that #{name} is logged as such, and the sequence still ends", %{
      state_pid: state_pid
    } do
      slug = unique_slug("wd")
      seed(state_pid, slug, :started, true)
      set_manager_result(always({:error, :boom}))
      set_demote(unquote(demote))

      pid =
        start_watchdog(
          state: state_pid,
          manager: FakeManager,
          running_check: fn _slug -> false end,
          sleep: parking_sleep(),
          attempt_timeout_ms: 200
        )

      send(pid, die_event(slug))

      log = capture_log(fn -> assert run_to_give_up() == :normal end)

      assert_received {:demote, ^slug}
      assert log =~ "demoting #{slug} #{unquote(logged)};"
      refute log =~ "boom"
    end
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

  ## 9 (issue #39): shutdown_check gates maybe_start_sequence/3

  test "shutdown_check: true suppresses a die event for an otherwise-eligible slug — no restart sequence",
       %{state_pid: state_pid} do
    slug = unique_slug("wd")
    seed(state_pid, slug, :started, true)
    set_manager_result(always({:ok, %{}}))

    pid =
      start_watchdog(
        state: state_pid,
        manager: FakeManager,
        running_check: fn _slug -> false end,
        backoff_base_ms: 5,
        shutdown_check: fn -> true end
      )

    send(pid, die_event(slug))

    refute_receive {:start_slug, ^slug}, 200
  end

  test "shutdown_check: false (explicitly injected) leaves the same event free to restart", %{
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
        backoff_base_ms: 5,
        shutdown_check: fn -> false end
      )

    send(pid, die_event(slug))

    assert_receive {:start_slug, ^slug}, 500
  end

  defmodule FakeManager do
    @moduledoc false

    def start_slug(slug, opts), do: dispatch(:start_slug, slug, opts)
    def restart(slug, opts), do: dispatch(:restart, slug, opts)

    def demote(slug, _opts) do
      notify(:demote, slug)
      Application.get_env(:vagus, :watchdog_test_demote_fun, fn _slug -> :ok end).(slug)
    end

    defp notify(kind, slug) do
      case Application.get_env(:vagus, :watchdog_test_pid) do
        pid when is_pid(pid) ->
          send(pid, {kind, slug})

        _ ->
          :ok
      end
    end

    defp dispatch(kind, slug, _opts) do
      notify(kind, slug)

      fun =
        Application.get_env(:vagus, :watchdog_test_result_fun, fn _kind, _slug ->
          {:error, :unconfigured}
        end)

      fun.(kind, slug)
    end
  end
end
