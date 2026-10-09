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

    test "any other failure is returned without a retry" do
      stop = sequence([{:error, :engine_down}, :ok])
      assert CoreUnit.stop(stop: stop, busy_backoff_ms: 0) == {:error, :engine_down}
    end

    test "a raising stop becomes an error result" do
      assert {:error, {:raised, %RuntimeError{}}} = CoreUnit.stop(stop: fn -> raise "boom" end)
    end
  end

  describe "start/1" do
    test "an absent Core is ready with a warning and nothing started" do
      log =
        capture_log(fn ->
          assert CoreUnit.start(adopt: fn -> :absent end, start: fn -> flunk("started") end) ==
                   :ok
        end)

      assert log =~ "no Core container"
    end

    test "an adopted Core is started, then waited on within the deadline" do
      test_pid = self()

      opts = [
        adopt: fn -> {:adopted, %{"Id" => "0123456789abcdef"}} end,
        start: fn -> send(test_pid, :started) && :ok end,
        health: fn opts -> send(test_pid, {:health, opts}) && :healthy end,
        deadline: 42
      ]

      assert CoreUnit.start(opts) == :ok
      assert_received :started
      assert_received {:health, [deadline: 42]}
    end

    test "a Core that never answers is a failed start" do
      opts = [
        adopt: fn -> {:adopted, %{}} end,
        start: fn -> :ok end,
        health: fn _opts -> :timeout end
      ]

      assert CoreUnit.start(opts) == {:error, :health_timeout}
    end

    test "a failed adopt or start is returned" do
      assert CoreUnit.start(adopt: fn -> {:error, :engine_down} end) == {:error, :engine_down}

      assert CoreUnit.start(
               adopt: fn -> {:adopted, %{}} end,
               start: fn -> {:error, :no_image} end
             ) ==
               {:error, :no_image}
    end
  end
end
