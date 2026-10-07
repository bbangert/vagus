defmodule Vagus.Resource.ControllerOptionsTest do
  use ExUnit.Case, async: true

  import Vagus.Resource.Harness

  alias Vagus.Resource.{Controller, Runtime, Store, TestInstance, Verdict}
  alias Vagus.Resource.Toys.{Follower, Kept, Probe, Tagger}

  defmodule Reader do
    @moduledoc "Owns `:reader`, and notes what of its context a pass was given."
    @behaviour Vagus.Resource.Controller

    @impl true
    def kind, do: :reader
    @impl true
    def condition_types, do: [:ready]

    @impl true
    def observe(%{name: name}, context) do
      seen = Map.take(context, [:flavour, :shared])
      Vagus.Resource.Harness.note(context, {__MODULE__, name, seen})
    end

    @impl true
    def reconcile(_reader, _observed), do: {Verdict.new(ready: {true, :read}), []}
    @impl true
    def act(_action, _args, _context), do: :ok
  end

  defmodule Reader2 do
    @moduledoc "As `Reader`, owning `:reader2`."
    @behaviour Vagus.Resource.Controller

    @impl true
    def kind, do: :reader2
    @impl true
    def condition_types, do: [:ready]

    @impl true
    def observe(%{name: name}, context) do
      seen = Map.take(context, [:flavour, :shared])
      Vagus.Resource.Harness.note(context, {__MODULE__, name, seen})
    end

    @impl true
    def reconcile(_reader, _observed), do: {Verdict.new(ready: {true, :read}), []}
    @impl true
    def act(_action, _args, _context), do: :ok
  end

  @moduletag :capture_log

  defp runtime_state(sys, controller),
    do: :sys.get_state(Process.whereis(Runtime.name(sys.instance, controller)))

  defp start_error(controllers) do
    Process.flag(:trap_exit, true)

    assert {:error, {{%ArgumentError{message: message}, _stack}, _child}} =
             TestInstance.start(controllers: controllers)

    message
  end

  describe "an entry with options" do
    test "has its own cap on steps in flight, whatever the shared one" do
      sys =
        start_system(
          controllers: [{Probe, max_in_flight_steps: 1}, Follower],
          runtime: [max_in_flight_steps: 3]
        )

      for name <- ["a", "b", "c"] do
        put_fact(sys, {:observe, name}, :block)
        {:ok, _} = Store.create(:probe, name, %{}, sys.i)
      end

      assert_receive {:observing, "a", step}, sys.wait
      assert %{queued: ["b", "c"], in_flight: in_flight} = info(sys, Probe)
      assert Map.keys(in_flight) == ["a"]
      refute_received {:observing, _name, _step}

      assert runtime_state(sys, Follower).max_in_flight == 3

      for name <- ["a", "b", "c"], do: put_fact(sys, {:observe, name}, nil)
      send(step, :go)
    end

    test "resyncs at its own interval, and the others at the shared one" do
      sys = start_system(controllers: [Probe, {Follower, resync: 15}], resync: :infinity)
      given_ready(sys, {:probe, "p", %{}})

      put_fact(sys, {:follow, "f"}, :block)
      {:ok, _} = Store.create(:follower, "f", %{"target" => "p"}, sys.i)

      # The first pass is the creation's. Nothing changes after it, so each
      # further one is a resync's.
      for _ <- 1..4 do
        assert_receive {:following, "f", step}, sys.wait
        send(step, :go)
      end

      assert runtime_state(sys, Follower).resync == 15
      assert runtime_state(sys, Probe).resync == :infinity
      put_fact(sys, {:follow, "f"}, nil)
    end

    test "is handed its own context on top of the shared one" do
      sys =
        start_system(
          controllers: [{Reader, context: %{flavour: :own}}, Reader2],
          context: %{flavour: :plain, shared: 1}
        )

      given_ready(sys, {:reader, "r", %{}})
      given_ready(sys, {:reader2, "r", %{}})

      seen = notes(sys) |> Enum.uniq() |> Enum.sort()

      # The world the harness shares reached both, or neither note exists.
      assert seen == [
               {Reader, "r", %{flavour: :own, shared: 1}},
               {Reader2, "r", %{flavour: :plain, shared: 1}}
             ]
    end

    test "may set the pacing options too, and one without options is as before" do
      sys =
        start_system(
          controllers: [
            {Probe, backoff: {3, 9}, unavailable_retry: 77, gate_poll: 11},
            {Follower, []}
          ],
          runtime: [backoff: {1, 8}]
        )

      assert %{backoff: {3, 9}, unavailable_retry: 77, gate_poll: 11} = runtime_state(sys, Probe)
      assert %{backoff: {1, 8}, unavailable_retry: 5, gate_poll: 5} = runtime_state(sys, Follower)
      assert sys.controllers == [Probe, Follower]
    end

    test "leaves what the controllers declare, and the kinds made of it, as they were" do
      plain = TestInstance.start!(controllers: [Kept, Tagger])
      own = TestInstance.start!(controllers: [{Kept, resync: 50}, {Tagger, context: %{a: 1}}])

      kinds = fn instance -> :sys.get_state(Process.whereis(Store.name(instance))).kinds end

      assert Map.keys(kinds.(own)) -- Map.keys(kinds.(plain)) == []
      assert kinds.(own).kept.owner == Kept
      assert kinds.(own).kept.conditions == kinds.(plain).kept.conditions
      assert kinds.(own).kept.finalizers == kinds.(plain).kept.finalizers
      assert Controller.kinds([Kept, Tagger]).kept.conditions == kinds.(own).kept.conditions
    end
  end

  describe "a list that cannot start says which controller and why" do
    test "an option that is not a runtime's, by name" do
      message = start_error([Follower, {Probe, resync: 5, rseync: 6}])

      assert message =~ "Vagus.Resource.Toys.Probe: unknown runtime option :rseync"
      assert message =~ ":resync, :max_in_flight_steps, :context"
    end

    test "an option that only a test's runtime takes" do
      assert start_error([{Probe, deliver_events: false}]) =~
               "Vagus.Resource.Toys.Probe: unknown runtime option :deliver_events"

      assert start_error([{Probe, instance: Elsewhere}]) =~ "unknown runtime option :instance"
    end

    test "options that are no keyword list, and an entry that is no controller" do
      assert start_error([{Probe, [:resync]}]) =~
               "Vagus.Resource.Toys.Probe: options must be a keyword list"

      assert start_error([{Probe, %{resync: 5}}]) =~ "is not a controller"
      assert start_error(["Probe"]) =~ ~s("Probe" is not a controller)
    end

    test "a controller listed twice with different options" do
      assert start_error([Probe, {Probe, resync: 5}]) =~
               "Vagus.Resource.Toys.Probe is listed twice, with different options"
    end

    test "but one listed twice the same way is one controller" do
      instance =
        TestInstance.start!(
          controllers: [{Probe, resync: 5}, {Probe, resync: 5}, Follower, Follower]
        )

      children = Supervisor.which_children(Vagus.Resource.Controllers.Supervisor.name(instance))
      assert length(children) == 2
    end

    test "a cap that would start nothing, given to one controller" do
      Process.flag(:trap_exit, true)

      assert {:error, reason} = TestInstance.start(controllers: [{Probe, max_in_flight_steps: 0}])
      assert inspect(reason) =~ "max_in_flight_steps must be a positive integer"
      assert inspect(reason) =~ "failed_to_start_child, Vagus.Resource.Toys.Probe"
    end
  end
end
