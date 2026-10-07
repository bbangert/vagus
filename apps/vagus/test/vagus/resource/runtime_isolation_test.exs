defmodule Vagus.Resource.RuntimeIsolationTest do
  # Not async: it traces every process started while it runs, and a process
  # has one tracer, so a test tracing its own processes meanwhile would fail.
  use ExUnit.Case, async: false

  import Vagus.Resource.Harness

  alias Vagus.Resource.{Runtime, Store, Verdict}

  @moduletag :capture_log
  @moduletag :scenario

  defmodule Watched do
    @moduledoc "Owns `:watched`, and has every callback a controller can have."
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.Harness

    @impl true
    def kind, do: :watched
    @impl true
    def condition_types, do: [:ready]
    @impl true
    def retention, do: %{keep: 9, ttl_ms: :infinity}
    @impl true
    def finalizer, do: :watched
    @impl true
    def writer_entries, do: [["holds"]]
    @impl true
    def validate(spec), do: {:ok, spec}
    @impl true
    def encode_spec(spec), do: spec
    @impl true
    def decode_spec(spec), do: spec
    @impl true
    def references(_watched), do: []
    @impl true
    def action_class(:touch), do: :engine

    @impl true
    def observe(%{name: name}, context), do: %{touched: Harness.fact(context, {:touched, name})}

    @impl true
    def reconcile(%{deleting?: true, name: name}, _observed),
      do: {:no_verdict, [{:remove_finalizer, :watched, name, :watched}]}

    def reconcile(%{spec: spec}, %{touched: touched}) do
      n = Map.get(spec, "n", 0)

      {Verdict.new(ready: {touched == n, :touching}),
       if(touched == n, do: [], else: [{:action, :touch, n}])}
    end

    @impl true
    def act(:touch, n, %{resource: %{name: name}} = context),
      do: Harness.put_fact(context, {:touched, name}, n)
  end

  defp calls(seen \\ []) do
    receive do
      {:trace, pid, :call, {Watched, function, _args}} -> calls([{pid, function} | seen])
    after
      0 -> seen
    end
  end

  test "no runtime ever runs its controller's code, from its start to its replacement's work" do
    :erlang.trace_pattern({Watched, :_, :_}, true, [:local])
    :erlang.trace(:new_processes, true, [:call])

    sys = start_system(controllers: [Watched])
    first = Process.whereis(Runtime.name(sys.instance, Watched))
    store = Process.whereis(Store.name(sys.instance))
    supervisor = Process.whereis(Module.concat(sys.instance, Supervisor))

    given_ready(sys, {:watched, "w", %{}})
    {:ok, _} = Store.update_spec(:watched, "w", %{"n" => 1}, sys.i)
    await!(sys, :watched, "w", :ready)

    second = kill_runtime(sys, Watched)
    resync(sys, Watched)
    {:ok, _} = Store.update_spec(:watched, "w", %{"n" => 2}, sys.i)
    await!(sys, :watched, "w", :ready)
    {:ok, _} = Store.delete(:watched, "w", sys.i)
    await!(sys, :watched, "w", :gone)
    settle(sys)

    :erlang.trace(:new_processes, false, [:call])
    :erlang.trace_pattern({Watched, :_, :_}, false, [:local])
    calls = calls()
    by = fn pid -> for {^pid, function} <- calls, uniq: true, do: function end

    # Everything was called, by somebody.
    for function <- [
          :kind,
          :condition_types,
          :retention,
          :finalizer,
          :writer_entries,
          :validate,
          :encode_spec,
          :decode_spec,
          :references,
          :action_class,
          :observe,
          :reconcile,
          :act
        ] do
      assert Enum.any?(calls, &(elem(&1, 1) == function)), "#{function} was never called"
    end

    assert by.(first) == []
    assert by.(second) == []

    # The declarations once, where a failure fails the start; admission and
    # the codec in the store.
    assert Enum.sort(by.(supervisor)) ==
             [:condition_types, :finalizer, :kind, :retention, :writer_entries]

    assert Enum.sort(by.(store)) == [:decode_spec, :encode_spec, :validate]
  end
end
