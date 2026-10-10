defmodule Vagus.App.DefaultBootTest do
  # The real units on host: no engine, no Core. `async: false` so no other
  # test's apps are booted by it.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Vagus.App.Orchestrator
  alias Vagus.Core.EventPusher

  @moduletag :capture_log

  @complete %{
    "event" => "supervisor_update",
    "update_key" => "supervisor",
    "data" => %{"startup" => "complete"}
  }

  test "boots through the default units to up, pushing startup complete" do
    Vagus.AppFixtures.listening_api_port()
    name = :"orchestrator_#{System.unique_integer([:positive])}"

    # The boot task logs from init/handle_continue onward, so capture must
    # start before the Orchestrator does or early lines escape it.
    {{pid, ref}, log} =
      with_log(fn ->
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

        with %{task: %Task{pid: task_pid}} <- :sys.get_state(name) do
          task_ref = Process.monitor(task_pid)
          assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _reason}, 10_000
        end

        {pid, ref}
      end)

    refute_received {:DOWN, ^ref, :process, ^pid, _reason}
    assert log =~ "gate tree passed"
    assert log =~ "gate api passed"
    assert %{phase: :up, task: nil} = :sys.get_state(name)
    assert @complete in :queue.to_list(:sys.get_state(EventPusher).queue)
  end
end
