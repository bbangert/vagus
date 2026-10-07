defmodule Vagus.Resource.StoreRestartTest do
  use ExUnit.Case, async: true

  alias Vagus.Resource
  alias Vagus.Resource.{Store, Tables, TestInstance, Watch}

  @moduletag :capture_log

  setup do
    instance = TestInstance.start!(owned: %{thing: [{Owner, [:ready]}, {Dns, [:dns_ready]}]})
    %{i: [instance: instance], instance: instance}
  end

  test "a killed store: status and subscriptions outlive it, and its replacement is heard",
       %{i: i, instance: instance} do
    {:ok, _} = Store.create(:thing, "t", %{a: 1}, i)
    ready = Resource.condition(:ready, true, :running, 1)
    {:ok, before} = Store.patch_status(:thing, "t", %{conditions: [ready]}, [writer: Owner] ++ i)
    :ok = Watch.subscribe({:object, :thing, "t"}, i)

    TestInstance.restart_store(instance)

    assert Store.get(:thing, "t", i) == before
    assert Resource.get_condition(Store.get(:thing, "t", i), :ready) == ready
    refute_received {Watch, _, _}

    assert {:ok, %{generation: 2}} = Store.update_spec(:thing, "t", %{a: 2}, i)
    assert_received {Watch, :changed, %{name: "t", generation: 2}}
  end

  test "a restarted store knows who owns what from its first message, with no runtime",
       %{i: i, instance: instance} do
    {:ok, _} = Store.create(:thing, "t", %{a: 1}, i)
    owner = [writer: Owner] ++ i
    ready = %{conditions: [Resource.condition(:ready, true, :running, 1)]}

    TestInstance.restart_store(instance)

    assert {:ok, %{status: %{instance: "c1", conditions: %{ready: %{status: true}}}}} =
             Store.patch_status(:thing, "t", Map.put(ready, :instance, "c1"), owner)

    assert {:ok, %{progress: %{phase: :applied}}} =
             Store.put_progress(:thing, "t", %{phase: :applied}, owner)

    dns = %{conditions: [Resource.condition(:dns_ready, true, :ok, 1)]}
    assert {:ok, _} = Store.patch_status(:thing, "t", dns, [writer: Dns] ++ i)

    assert {:error, {:not_owner, :ready, Dns}} =
             Store.patch_status(:thing, "t", ready, [writer: Dns] ++ i)

    assert {:error, {:not_owner, :instance, Dns}} =
             Store.patch_status(:thing, "t", %{instance: "c2"}, [writer: Dns] ++ i)

    assert {:error, {:not_owner, :progress, Dns}} =
             Store.put_progress(:thing, "t", %{phase: :applied}, [writer: Dns] ++ i)

    assert {:error, {:invalid, :bad}} = Store.update_spec(:thing, "t", %{bad: true}, i)
  end

  test "killing the tables' owner replaces the registry and the store with it",
       %{instance: instance} do
    [tables, watch, store] =
      for name <- [Tables.name(instance), Watch.name(instance), Store.name(instance)] do
        pid = Process.whereis(name)
        {pid, Process.monitor(pid)}
      end

    supervisor = Process.whereis(Module.concat(instance, Supervisor))
    TestInstance.kill_observed(elem(tables, 0), supervisor)

    for {pid, ref} <- [tables, watch, store] do
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end

    for {name, {old, _ref}} <- [
          {Tables.name(instance), tables},
          {Watch.name(instance), watch},
          {Store.name(instance), store}
        ] do
      new = Process.whereis(name)
      assert is_pid(new) and new != old
    end

    assert Store.list(:thing, instance: instance) == []
  end

  test "uids keep rising across a store restart with no file", %{i: i, instance: instance} do
    {:ok, %{uid: 1}} = Store.create(:thing, "a", %{}, i)
    {:ok, %{uid: 2}} = Store.create(:thing, "b", %{}, i)
    {:ok, _} = Store.delete(:thing, "b", i)

    TestInstance.restart_store(instance)

    assert {:ok, %{uid: 3}} = Store.create(:thing, "b", %{}, i)
  end

  test "reads are answered while the store is suspended", %{i: i, instance: instance} do
    {:ok, created} = Store.create(:thing, "t", %{a: 1}, i)
    {:ok, _} = Store.create(:part, "p", %{}, [owner_refs: [Resource.ref(created)]] ++ i)
    :ok = Store.claim(:thing, "t", i)

    store = Process.whereis(Store.name(instance))
    :ok = :sys.suspend(store)

    assert Store.get(:thing, "t", i) == created
    assert Store.fetch(:thing, "t", i) == {:ok, created}
    assert Store.list(:thing, i) == [created]
    assert [%Resource{name: "p"}] = Store.owned_by(Resource.ref(created), i)
    assert Store.claimant(:thing, "t", i) == self()

    :ok = :sys.resume(store)
    assert {:ok, %{generation: 2}} = Store.update_spec(:thing, "t", %{a: 2}, i)
  end

  test "with the store gone, a write exits and a read still answers", %{i: i, instance: instance} do
    {:ok, created} = Store.create(:thing, "t", %{a: 1}, i)
    supervisor = Module.concat(instance, Supervisor)
    :ok = Supervisor.terminate_child(supervisor, Store)

    assert Store.get(:thing, "t", i) == created
    assert {:noproc, _} = catch_exit(Store.update_spec(:thing, "t", %{a: 2}, i))
  end

  defp holder(i) do
    test = self()

    pid =
      spawn(fn ->
        :ok = Store.claim(:thing, "t", i)
        send(test, :claimed)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :claimed, 1_000
    pid
  end

  test "a claim outlives a store restart, and its holder's death still ends it",
       %{i: i, instance: instance} do
    holder = holder(i)
    store = TestInstance.restart_store(instance)

    assert Store.claimant(:thing, "t", i) == holder
    assert Store.claim(:thing, "t", i) == {:error, :busy}

    TestInstance.kill_observed(holder, store)

    assert :ok = Store.claim(:thing, "t", i)
  end

  test "a holder that died while the store was down has lost its claim when it is back",
       %{i: i, instance: instance} do
    holder = holder(i)
    ref = Process.monitor(holder)
    supervisor = Module.concat(instance, Supervisor)
    :ok = Supervisor.terminate_child(supervisor, Store)

    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}, 1_000
    assert Store.claimant(:thing, "t", i) == holder

    {:ok, store} = Supervisor.restart_child(supervisor, Store)
    # The store monitored a dead pid while starting, so its `DOWN` is
    # already ahead of this call.
    :sys.get_state(store)

    assert Store.claimant(:thing, "t", i) == nil
    assert :ok = Store.claim(:thing, "t", i)
  end

  test "the tables are lent to one holder at a time", %{instance: instance} do
    store = Process.whereis(Store.name(instance))
    assert Tables.take(instance) == {:error, {:held, store}}
    assert :ets.info(Tables.resources(instance), :owner) == store
  end
end
