defmodule Vagus.Resource.RuntimeBoundTest do
  use ExUnit.Case, async: true

  import Vagus.Resource.Harness

  alias Vagus.Resource.{Runtime, Store}
  alias Vagus.Resource.Toys.{Probe, Spinner}

  @moduletag :capture_log

  # Created in this order, which is not the order a listing gives. The
  # store announces them as created, so that is the order they queue in.
  @names ["b", "a", "e", "d", "c"]

  # Probes whose every observation parks.
  defp parked(runtime, names \\ @names) do
    sys = start_system(controllers: [Probe], runtime: runtime)
    for name <- names, do: park(sys, name)
    sys
  end

  defp park(sys, name) do
    put_fact(sys, {:observe, name}, :block)
    {:ok, _} = Store.create(:probe, name, %{}, sys.i)
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
    for name <- ["b", "a"], do: observing(sys, name)

    assert %{queued: ["e", "d", "c"], steps: 2} = info = info(sys, Probe)
    assert in_flight(info) == ["a", "b"]
    refute_received {:observing, _name, _step}
  end

  test "a step that ends starts exactly one more, and its own next pass goes to the back" do
    sys = parked(max_in_flight_steps: 2)
    [b, _a] = for name <- ["b", "a"], do: observing(sys, name)

    # "b" visits, which asks for another pass of it at once.
    release(sys, "b", b)
    observing(sys, "e")

    assert %{queued: ["d", "c", "b"], steps: 3} = info = info(sys, Probe)
    assert in_flight(info) == ["a", "e"]
    refute_received {:observing, _name, _step}
  end

  test "the cap holds across a resync and across hints, and a name that waits keeps its place" do
    sys = parked(max_in_flight_steps: 2)
    for name <- ["b", "a"], do: observing(sys, name)

    # A listing names them in another order, and the hints are for the
    # first in line, one in the middle, one in flight and one nobody holds.
    resync(sys, Probe)
    for name <- ["e", "d", "a", "nobody"], do: :ok = Runtime.enqueue(Probe, name, sys.i)

    assert %{queued: ["e", "d", "c", "nobody"], hinted: ["a"], dirty: ["a", "b"], steps: 2} =
             info = Runtime.info(Probe, sys.i)

    assert in_flight(info) == ["a", "b"]
    refute_received {:observing, _name, _step}
  end

  test "every resource gets its step" do
    sys = parked(max_in_flight_steps: 2)
    steps = for name <- ["b", "a"], do: {name, observing(sys, name)}

    for name <- @names, do: put_fact(sys, {:observe, name}, nil)
    for {_name, step} <- steps, do: send(step, :go)

    for name <- @names, do: await!(sys, :probe, name, :ready)
    settle(sys)
    assert for(name <- @names, do: fact(sys, {:seen, name})) == [1, 1, 1, 1, 1]
  end

  test "a name that keeps coming round does not hold back one that waits" do
    sys = start_system(controllers: [Spinner], runtime: [max_in_flight_steps: 1])

    {:ok, _} = Store.create(:spinner, "x", %{}, sys.i)
    assert_receive {:spun, "x"}, sys.wait
    {:ok, _} = Store.create(:spinner, "y", %{}, sys.i)

    assert_receive {:spun, "y"}, sys.wait
    put_fact(sys, :stop, true)
    settle(sys)
  end

  test "a shutdown starts nothing from the queue, and what waited starts in order after it" do
    sys = parked(max_in_flight_steps: 1)
    b = observing(sys, "b")

    shutdown(sys, true)
    release(sys, "b", b)
    settle(sys)
    assert %{queued: ["a", "e", "d", "c", "b"], steps: 1} = Runtime.info(Probe, sys.i)

    shutdown(sys, false)
    observing(sys, "a")
    assert %{queued: ["e", "d", "c", "b"], steps: 2} = info(sys, Probe)
  end

  describe "a place that comes free goes to the next in line" do
    # A back-off too long to fire: the timer of a step that crashed is not
    # what starts the next.
    setup do
      sys = parked([max_in_flight_steps: 1, backoff: {600_000, 600_000}], ["a"])
      %{sys: sys, a: observing(sys, "a")}
    end

    test "past a name the kind does not hold, with nothing further to bring it", context do
      %{sys: sys, a: a} = context
      :ok = Runtime.enqueue(Probe, "nobody", sys.i)
      park(sys, "b")
      assert %{queued: ["nobody", "b"]} = info(sys, Probe)

      release(sys, "a", a)

      observing(sys, "b")
      assert %{queued: ["a"]} = info(sys, Probe)
    end

    test "when the step in flight is killed", %{sys: sys, a: a} do
      park(sys, "b")
      assert %{queued: ["b"]} = info(sys, Probe)

      Process.exit(a, :kill)

      observing(sys, "b")
    end

    test "when the step in flight was about a resource since replaced", %{sys: sys, a: a} do
      park(sys, "b")
      {:ok, _} = Store.delete(:probe, "a", sys.i)
      {:ok, _} = Store.create(:probe, "a", %{}, sys.i)
      assert %{queued: ["b"], dirty: ["a"]} = info(sys, Probe)

      send(a, :go)

      observing(sys, "b")
      assert %{queued: ["a"]} = info(sys, Probe)
    end

    test "when the step in flight was about a resource since deleted", %{sys: sys, a: a} do
      park(sys, "b")
      {:ok, _} = Store.delete(:probe, "a", sys.i)
      assert %{queued: ["b"]} = info(sys, Probe)

      send(a, :go)

      observing(sys, "b")
      assert %{queued: []} = info(sys, Probe)
    end
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

defmodule Vagus.Resource.RuntimeBoundDefaultTest do
  # Not async: it changes the application's environment.
  use ExUnit.Case, async: false

  import Vagus.Resource.Harness

  alias Vagus.Resource.Store
  alias Vagus.Resource.Toys.Probe

  @moduletag :capture_log

  test "the cap is the application's unless the runtime is given one" do
    configured = Application.fetch_env!(:vagus, :max_in_flight_steps)
    on_exit(fn -> Application.put_env(:vagus, :max_in_flight_steps, configured) end)
    assert configured == 4
    Application.put_env(:vagus, :max_in_flight_steps, 3)

    sys = start_system(controllers: [Probe])

    for name <- ["a", "b", "c", "d", "e"] do
      put_fact(sys, {:observe, name}, :block)
      {:ok, _} = Store.create(:probe, name, %{}, sys.i)
    end

    for name <- ["a", "b", "c"], do: assert_receive({:observing, ^name, _step}, sys.wait)
    assert %{queued: ["d", "e"], steps: 3} = info(sys, Probe)
  end
end
