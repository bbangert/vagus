defmodule Vagus.Resource.RuntimeBoundTest do
  use ExUnit.Case, async: true

  import Vagus.Resource.Harness

  alias Vagus.Resource.{Runtime, Store}
  alias Vagus.Resource.Toys.Probe

  @moduletag :capture_log

  @names ["a", "b", "c", "d", "e"]

  # Five probes whose every observation parks, created in name order. The
  # store announces them in that order, so that is the order they queue in.
  defp parked(runtime) do
    sys = start_system(controllers: [Probe], runtime: runtime)
    for name <- @names, do: put_fact(sys, {:observe, name}, :block)
    for name <- @names, do: {:ok, _} = Store.create(:probe, name, %{}, sys.i)
    sys
  end

  defp observing(sys, name) do
    assert_receive {:observing, ^name, step}, sys.wait
    step
  end

  defp release(sys, name, step) do
    put_fact(sys, {:observe, name}, nil)
    send(step, :go)
  end

  defp in_flight(info), do: info.in_flight |> Map.keys() |> Enum.sort()

  test "no more steps are in flight than the cap, and the rest wait in the order they came" do
    sys = parked(max_in_flight_steps: 2)
    for name <- ["a", "b"], do: observing(sys, name)

    assert %{queued: ["c", "d", "e"], steps: 2} = info = info(sys, Probe)
    assert in_flight(info) == ["a", "b"]
    refute_received {:observing, _name, _step}
  end

  test "a step that ends starts exactly one more, and its own next pass goes to the back" do
    sys = parked(max_in_flight_steps: 2)
    [a, _b] = for name <- ["a", "b"], do: observing(sys, name)

    # "a" visits, which asks for another pass of it at once.
    release(sys, "a", a)
    observing(sys, "c")

    assert %{queued: ["d", "e", "a"], steps: 3} = info = info(sys, Probe)
    assert in_flight(info) == ["b", "c"]
    refute_received {:observing, _name, _step}
  end

  test "the cap holds across a resync and across hints, and nobody loses their place" do
    sys = parked(max_in_flight_steps: 2)
    for name <- ["a", "b"], do: observing(sys, name)

    resync(sys, Probe)
    for name <- ["e", "a", "nobody"], do: :ok = Runtime.enqueue(Probe, name, sys.i)

    # The hint for a name the kind does not hold waits its turn like any
    # other, and is dropped when that comes.
    assert %{queued: ["c", "d", "e", "nobody"], hinted: ["a"], dirty: ["a", "b"], steps: 2} =
             info = Runtime.info(Probe, sys.i)

    assert in_flight(info) == ["a", "b"]
    refute_received {:observing, _name, _step}
  end

  test "every resource gets its step" do
    sys = parked(max_in_flight_steps: 2)
    steps = for name <- ["a", "b"], do: {name, observing(sys, name)}

    for name <- @names, do: put_fact(sys, {:observe, name}, nil)
    for {_name, step} <- steps, do: send(step, :go)

    for name <- @names, do: await!(sys, :probe, name, :ready)
    settle(sys)
    assert for(name <- @names, do: fact(sys, {:seen, name})) == [1, 1, 1, 1, 1]
  end

  test "a shutdown starts nothing from the queue, and what waited starts in order after it" do
    sys = parked(max_in_flight_steps: 1)
    a = observing(sys, "a")

    shutdown(sys, true)
    release(sys, "a", a)
    settle(sys)
    assert %{queued: ["b", "c", "d", "e", "a"], steps: 1} = Runtime.info(Probe, sys.i)

    shutdown(sys, false)
    observing(sys, "b")
    assert %{queued: ["c", "d", "e", "a"], steps: 2} = info(sys, Probe)
  end

  test "the cap is the application's unless the runtime is given one" do
    sys = parked([])
    for name <- ["a", "b", "c", "d"], do: observing(sys, name)

    assert Application.fetch_env!(:vagus, :max_in_flight_steps) == 4
    assert %{queued: ["e"], steps: 4} = info(sys, Probe)
  end

  test "a cap that would start nothing is refused" do
    Process.flag(:trap_exit, true)

    for cap <- [0, -1, :all] do
      declaration = Vagus.Resource.Controller.declare(Probe)
      opts = [declaration: declaration, tasks: __MODULE__.Tasks, instance: __MODULE__]

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Runtime.start_link([max_in_flight_steps: cap] ++ opts)

      assert message =~ "max_in_flight_steps must be a positive integer"
    end
  end
end
