defmodule Vagus.Resource.StoreRestartTest do
  use ExUnit.Case, async: true

  alias Vagus.Resource
  alias Vagus.Resource.{Store, Tables, TestInstance, Watch}

  @moduletag :capture_log

  setup do
    instance = TestInstance.start!()
    i = [instance: instance]
    :ok = Store.register_kind(:thing, Owner, [conditions: [:ready]] ++ i)
    %{i: i, instance: instance}
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
    assert_receive {Watch, :changed, %{name: "t", generation: 2}}
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

  test "a claim outlives a store restart, and its holder's death still ends it",
       %{i: i, instance: instance} do
    test = self()

    {holder, ref} =
      spawn_monitor(fn ->
        :ok = Store.claim(:thing, "t", i)
        send(test, :claimed)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :claimed
    store = TestInstance.restart_store(instance)

    assert Store.claimant(:thing, "t", i) == holder
    assert Store.claim(:thing, "t", i) == {:error, :busy}

    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}
    :sys.get_state(store)

    assert :ok = Store.claim(:thing, "t", i)
  end

  test "the tables are lent to one holder at a time", %{instance: instance} do
    store = Process.whereis(Store.name(instance))
    assert Tables.take(instance) == {:error, {:held, store}}
    assert :ets.info(Tables.resources(instance), :owner) == store
  end
end
