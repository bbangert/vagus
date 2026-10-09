defmodule Vagus.App.DefaultBootTest do
  # The real units on host: no engine, no Core, no apps. `async: false` so
  # no other test's apps are in State while this boot lists them.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vagus.App.Orchestrator
  alias Vagus.Core.EventPusher

  @moduletag :capture_log

  @complete %{
    "event" => "supervisor_update",
    "update_key" => "supervisor",
    "data" => %{"startup" => "complete"}
  }

  test "boots through the default units to up, pushing startup complete" do
    assert Vagus.Addon.State.list() == []
    Vagus.AppFixtures.listening_api_port()
    name = :"orchestrator_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Orchestrator,
         name: name,
         boot: true,
         gate_tries: 1,
         gate_interval: 0,
         tree_interval: 0,
         gate_timeout: 2_000,
         stage_timeout: 2_000}
      )

    ref = Process.monitor(pid)

    log =
      capture_log(fn ->
        with %{task: %Task{pid: task_pid}} <- :sys.get_state(name) do
          task_ref = Process.monitor(task_pid)
          assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _reason}, 10_000
        end
      end)

    refute_received {:DOWN, ^ref, :process, ^pid, _reason}
    assert log =~ "gate tree passed"
    assert log =~ "gate api passed"
    assert %{phase: :up, task: nil} = :sys.get_state(name)
    assert @complete in :queue.to_list(:sys.get_state(EventPusher).queue)
  end
end
