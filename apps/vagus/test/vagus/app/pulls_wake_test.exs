defmodule Vagus.App.PullsWakeTest do
  @moduledoc "A pull's end reaches a real runtime, and through it one resource."

  use ExUnit.Case, async: true

  import Vagus.Resource.Harness

  alias Vagus.App.Pulls
  alias Vagus.Resource.{Runtime, Store}
  alias Vagus.Resource.Toys.{Follower, Probe}
  alias Vagus.Test.FakeEngine

  @moduletag :capture_log

  test "the pass that follows a pull is the waiter's, and only the waiter's" do
    engine = FakeEngine.start_model()
    on_exit(fn -> FakeEngine.stop(engine) end)

    sys =
      start_system(controllers: [Probe, Follower], pulls: [engine: [socket: engine.socket]])

    given_ready(sys, {:probe, "p", %{}})

    for name <- ["f1", "f2"],
        do: {:ok, _} = Store.create(:follower, name, %{"target" => "p"}, sys.i)

    settle(sys)
    notes(sys)

    runtime = Process.whereis(Runtime.name(sys.instance, Follower))
    :erlang.trace(runtime, true, [:receive])

    :ok = Pulls.request("repo/a:1", [waiter: {Follower, "f2"}] ++ sys.i)

    assert_receive {:trace, ^runtime, :receive, {:"$gen_cast", {:enqueue, "f2"}}}, 2_000
    :erlang.trace(runtime, false, [:receive])
    settle(sys)

    assert notes(sys) == [{:followed, "f2", 1}]
  end
end
