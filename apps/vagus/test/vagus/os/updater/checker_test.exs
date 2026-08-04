defmodule Vagus.OS.Updater.CheckerTest do
  @moduledoc """
  `Vagus.OS.Updater.Checker` — the daily-check timer GenServer. Unlike
  `Vagus.OS.UpdaterTest`, the injected `:updater` seam here is called
  from the Checker's *own* process, not the test process, so a
  process-dictionary stub wouldn't be visible to it. `FakeUpdater` below
  is backed by a named `Agent` instead — `async: false` because that
  name is global for the whole module.
  """
  use ExUnit.Case, async: false

  alias Vagus.OS.Updater.Checker

  defmodule FakeUpdater do
    @moduledoc """
    `check/0` pops the next scripted `state/0` result off a queue (the
    last one repeats once the queue is empty) and counts calls — enough
    to drive the Checker through several check cycles with a different
    "latest release" each time, without simulating the library's real
    :checking/:idle phase transition (that's covered by
    `Vagus.OS.UpdaterTest`'s `install/2` tests instead).
    """
    use Agent

    @idle %{phase: :idle, last_error: nil, last_release: nil}

    def start_link(script),
      do:
        Agent.start_link(fn -> %{calls: 0, script: script, current: @idle} end, name: __MODULE__)

    def check do
      Agent.update(__MODULE__, fn s ->
        case s.script do
          [next | rest] -> %{s | calls: s.calls + 1, script: rest, current: next}
          [] -> %{s | calls: s.calls + 1}
        end
      end)

      :ok
    end

    def state, do: Agent.get(__MODULE__, & &1.current)
    def calls, do: Agent.get(__MODULE__, & &1.calls)
  end

  # Stateless (no shared mutable seam) — safe to reuse across tests
  # without an Agent: `state/0` never changes no matter how many times
  # `check/0` is "called".
  defmodule StuckUpdater do
    @moduledoc "Simulates a check that never settles: state/0 is always :checking."
    def check, do: :ok
    def state, do: %{phase: :checking, last_error: nil, last_release: nil}
  end

  defmodule ErroredUpdater do
    @moduledoc "Simulates a check that settles into :error."
    def check, do: :ok
    def state, do: %{phase: :error, last_error: :boom, last_release: nil}
  end

  defp tag(t), do: %{phase: :idle, last_error: nil, last_release: %{tag_name: t}}

  test "the first check runs only after first_check_ms, not at t=0" do
    test_pid = self()
    start_supervised!({FakeUpdater, [tag("0.4.0")]})

    start_supervised!(
      {Checker,
       updater: FakeUpdater,
       notify: fn -> send(test_pid, :notified) end,
       first_check_ms: 80,
       first_check_jitter_ms: 0,
       interval_ms: 10_000,
       interval_jitter_ms: 0,
       settle_timeout_ms: 200,
       settle_poll_ms: 2,
       name: nil}
    )

    refute_receive :notified, 30
    assert FakeUpdater.calls() == 0

    assert_receive :notified, 400
    assert FakeUpdater.calls() == 1
  end

  test "notify fires only when the settled tag is new, not on every check" do
    test_pid = self()

    start_supervised!({FakeUpdater, [tag("0.4.0"), tag("0.4.0"), tag("0.4.1")]})

    start_supervised!(
      {Checker,
       updater: FakeUpdater,
       notify: fn -> send(test_pid, :notified) end,
       first_check_ms: 5,
       first_check_jitter_ms: 0,
       interval_ms: 10,
       interval_jitter_ms: 0,
       settle_timeout_ms: 200,
       settle_poll_ms: 1,
       name: nil}
    )

    # Long enough for the scripted cycle1 (new "0.4.0"), cycle2 (unchanged
    # "0.4.0"), cycle3 (new "0.4.1") — and several more repeats of "0.4.1"
    # past that, none of which should notify again.
    Process.sleep(300)

    assert count_messages(:notified) == 2
    assert FakeUpdater.calls() >= 3
  end

  test "a nil last_release (check never produced a release) does not count as a new tag" do
    test_pid = self()
    start_supervised!({FakeUpdater, [%{phase: :idle, last_error: nil, last_release: nil}]})

    start_supervised!(
      {Checker,
       updater: FakeUpdater,
       notify: fn -> send(test_pid, :notified) end,
       first_check_ms: 5,
       first_check_jitter_ms: 0,
       interval_ms: 10_000,
       interval_jitter_ms: 0,
       settle_timeout_ms: 200,
       settle_poll_ms: 1,
       name: nil}
    )

    refute_receive :notified, 200
  end

  test "a check that never settles logs no notify and leaves the process alive" do
    test_pid = self()

    pid =
      start_supervised!(
        {Checker,
         updater: StuckUpdater,
         notify: fn -> send(test_pid, :notified) end,
         first_check_ms: 5,
         first_check_jitter_ms: 0,
         interval_ms: 10_000,
         interval_jitter_ms: 0,
         settle_timeout_ms: 20,
         settle_poll_ms: 5,
         name: nil}
      )

    refute_receive :notified, 200
    assert Process.alive?(pid)
  end

  test "a check that settles into :error sends no notify and leaves the process alive" do
    test_pid = self()

    pid =
      start_supervised!(
        {Checker,
         updater: ErroredUpdater,
         notify: fn -> send(test_pid, :notified) end,
         first_check_ms: 5,
         first_check_jitter_ms: 0,
         interval_ms: 10_000,
         interval_jitter_ms: 0,
         settle_timeout_ms: 100,
         settle_poll_ms: 5,
         name: nil}
      )

    refute_receive :notified, 200
    assert Process.alive?(pid)
  end

  defp count_messages(tag, acc \\ 0) do
    receive do
      ^tag -> count_messages(tag, acc + 1)
    after
      0 -> acc
    end
  end
end
