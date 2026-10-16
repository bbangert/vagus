defmodule Vagus.App.CoreUnitTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.App.CoreUnit

  defp sequence(results) do
    counter = :counters.new(1, [])

    fn ->
      :counters.add(counter, 1, 1)
      Enum.at(results, :counters.get(counter, 1) - 1, List.last(results))
    end
  end

  describe "stop/1" do
    test "a busy Core is retried until it stops" do
      stop = sequence([{:error, :busy}, {:error, :busy}, :ok])
      assert CoreUnit.stop(stop: stop, busy_backoff_ms: 0) == :ok
    end

    test "a Core that stays busy gives up after the budget" do
      log =
        capture_log(fn ->
          assert CoreUnit.stop(
                   stop: fn -> {:error, :busy} end,
                   busy_retry_budget_ms: 20,
                   busy_backoff_ms: 1
                 ) ==
                   {:error, :busy}
        end)

      assert log =~ "stayed busy"
    end

    test "a deadline sooner than the retry budget ends the retries" do
      stop =
        Task.async(fn ->
          CoreUnit.stop(stop: fn -> {:error, :busy} end, busy_backoff_ms: 1, deadline: 20)
        end)

      assert Task.await(stop, 1_000) == {:error, :busy}
    end

    test "the backoff sleep is capped to the time left and no attempt starts past the deadline" do
      clock = :atomics.new(1, [])
      calls = :counters.new(1, [])
      sleeps = :ets.new(:sleeps, [:public, :bag])

      stop = fn ->
        :counters.add(calls, 1, 1)
        {:error, :busy}
      end

      sleep = fn ms ->
        :ets.insert(sleeps, {ms})
        :atomics.add(clock, 1, ms)
      end

      capture_log(fn ->
        assert CoreUnit.stop(
                 stop: stop,
                 sleep: sleep,
                 now: fn -> :atomics.get(clock, 1) end,
                 busy_retry_budget_ms: 20,
                 busy_backoff_ms: 1_000
               ) == {:error, :busy}
      end)

      assert :ets.tab2list(sleeps) == [{20}]
      assert :counters.get(calls, 1) == 1
    end

    test "any other failure is returned without a retry" do
      stop = sequence([{:error, :engine_down}, :ok])
      assert CoreUnit.stop(stop: stop, busy_backoff_ms: 0) == {:error, :engine_down}
    end

    test "a raising stop becomes an error result" do
      assert {:error, {:raised, %RuntimeError{}}} = CoreUnit.stop(stop: fn -> raise "boom" end)
    end
  end

  describe "start/1" do
    test "an absent Core with no version installed is ready with a warning and nothing started" do
      log =
        capture_log(fn ->
          assert CoreUnit.start(
                   adopt: fn -> :absent end,
                   installed: fn -> nil end,
                   start: fn -> flunk("started") end
                 ) ==
                   :ok
        end)

      assert log =~ "no Core container"
    end

    test "an absent Core with a version installed is created, then waited on" do
      test_pid = self()

      opts = [
        adopt: fn -> :absent end,
        installed: fn -> "2026.10.1" end,
        image_present?: fn version -> send(test_pid, {:present?, version}) && true end,
        start: fn -> send(test_pid, :started) && :ok end,
        health: fn opts -> send(test_pid, {:health, opts}) && :healthy end,
        deadline: 42
      ]

      log = capture_log(fn -> assert CoreUnit.start(opts) == :ok end)
      assert log =~ "creating the Core 2026.10.1 container"
      assert_received {:present?, "2026.10.1"}
      assert_received :started
      assert_received {:health, [deadline: 42]}
    end

    test "an absent Core whose image is absent too is left to the Provisioner, and boot goes on" do
      log =
        capture_log(fn ->
          assert CoreUnit.start(
                   adopt: fn -> :absent end,
                   installed: fn -> "2026.10.1" end,
                   image_present?: fn _version -> false end,
                   start: fn -> flunk("started") end
                 ) == :ok
        end)

      assert log =~ "image is absent; Vagus.Provisioner pulls it"
    end

    test "a create that fails is handed to the Provisioner's retries, with the stops seen before it" do
      test_pid = self()

      log =
        capture_log(fn ->
          assert CoreUnit.start(
                   adopt: fn -> :absent end,
                   installed: fn -> "2026.10.1" end,
                   image_present?: fn _version -> true end,
                   stops: fn -> 7 end,
                   start: fn -> {:error, {:failed, :create, "boom"}} end,
                   retry: fn seen -> send(test_pid, {:retry, seen}) end
                 ) == {:error, {:failed, :create, "boom"}}
        end)

      assert_received {:retry, 7}
      assert log =~ "Vagus.Provisioner retries it"
    end

    test "boot's create passes the stops it saw, so a stop since wins under the lock" do
      test_pid = self()

      assert CoreUnit.start(
               adopt: fn -> :absent end,
               installed: fn -> "2026.10.1" end,
               image_present?: fn _version -> true end,
               stops: fn -> 4 end,
               start: fn seen -> send(test_pid, {:start, seen}) && :ok end,
               health: fn _opts -> :healthy end
             ) == :ok

      assert_received {:start, 4}
    end

    test "a stop that lands during the presence check refuses boot's create" do
      stops = :counters.new(1, [])

      assert CoreUnit.start(
               adopt: fn -> :absent end,
               installed: fn -> "2026.10.1" end,
               image_present?: fn _version -> :counters.add(stops, 1, 1) && true end,
               stops: fn -> :counters.get(stops, 1) end,
               start: fn seen ->
                 if seen == :counters.get(stops, 1), do: :ok, else: {:error, :stopped}
               end,
               health: fn _opts -> :healthy end,
               retry: fn _seen -> flunk("handed off") end
             ) == {:error, :stopped}
    end

    test "a create that succeeds hands nothing off" do
      assert CoreUnit.start(
               adopt: fn -> :absent end,
               installed: fn -> "2026.10.1" end,
               image_present?: fn _version -> true end,
               stops: fn -> 0 end,
               start: fn -> :ok end,
               health: fn _opts -> :healthy end,
               retry: fn _seen -> flunk("handed off") end
             ) == :ok
    end

    test "a presence check that errors still tries the create, which reports what is wrong" do
      assert CoreUnit.start(
               adopt: fn -> :absent end,
               installed: fn -> "2026.10.1" end,
               image_present?: fn _version -> {:error, :timeout} end,
               start: fn -> {:error, {:failed, :create, :image_not_found}} end
             ) == {:error, {:failed, :create, :image_not_found}}
    end
  end
end
