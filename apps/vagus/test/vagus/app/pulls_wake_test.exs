defmodule Vagus.App.PullsWakeTest do
  @moduledoc "The pull worker beside real runtimes: who is woken, and who starts over."

  use ExUnit.Case, async: true

  import Vagus.Resource.Harness

  alias Vagus.App.Pulls
  alias Vagus.Resource.{Runtime, Store, TestInstance}
  alias Vagus.Resource.Toys.{Follower, Probe}
  alias Vagus.Test.FakeEngine

  @moduletag :capture_log

  # Two followers, each of which leaves a note per pass and writes nothing.
  setup do
    engine = FakeEngine.start_model()
    on_exit(fn -> FakeEngine.stop(engine) end)

    sys = start_system(controllers: [Probe, Follower], pulls: [engine: [socket: engine.socket]])

    given_ready(sys, {:probe, "p", %{}})

    for name <- ["f1", "f2"],
        do: {:ok, _} = Store.create(:follower, name, %{"target" => "p"}, sys.i)

    settle(sys)
    notes(sys)
    %{sys: sys}
  end

  test "the pass that follows a pull is the waiter's, and only the waiter's", %{sys: sys} do
    runtime = Process.whereis(Runtime.name(sys.instance, Follower))
    :erlang.trace(runtime, true, [:receive])

    :ok = Pulls.request("repo/a:1", {Follower, "f2"}, sys.i)

    assert_receive {:trace, ^runtime, :receive, {:"$gen_cast", {:enqueue, "f2"}}}, 2_000
    :erlang.trace(runtime, false, [:receive])
    settle(sys)

    assert notes(sys) == [{:followed, "f2", 1}]
  end

  test "when the worker dies, the runtimes are replaced and look at everything", %{sys: sys} do
    runtime = Process.whereis(Runtime.name(sys.instance, Follower))
    worker = Process.whereis(Pulls.name(sys.instance))
    supervisor = Process.whereis(Module.concat(sys.instance, Supervisor))

    TestInstance.kill_observed(worker, supervisor)
    settle(sys)

    assert Process.whereis(Runtime.name(sys.instance, Follower)) != runtime
    # Nothing asked for these passes but the new runtime's own listing.
    assert notes(sys) |> Enum.uniq() |> Enum.sort() == [
             {:followed, "f1", 1},
             {:followed, "f2", 1}
           ]
  end
end
