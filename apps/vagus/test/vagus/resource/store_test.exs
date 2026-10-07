defmodule Vagus.Resource.StoreTest do
  use ExUnit.Case, async: true

  alias Vagus.Resource
  alias Vagus.Resource.{Store, TestInstance, Watch}

  setup do
    instance = TestInstance.start!()
    i = [instance: instance]
    :ok = Store.register_kind(:thing, Owner, [conditions: [:ready]] ++ i)
    :ok = Store.register_writer(:thing, Dns, [conditions: [:dns_ready]] ++ i)
    %{i: i, store: Process.whereis(Store.name(instance))}
  end

  describe "create" do
    test "eight concurrent creates of one name: one succeeds, seven already exist", %{i: i} do
      results =
        1..8
        |> Enum.map(fn n -> Task.async(fn -> Store.create(:thing, "t", %{a: n}, i) end) end)
        |> Task.await_many()

      assert Enum.count(results, &match?({:ok, %Resource{}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :already_exists})) == 7
    end

    test "gives a fresh uid and generation 1, and stores the spec the validators return",
         %{i: i} do
      assert {:ok, %Resource{uid: uid, generation: 1, spec: %{a: 1, holds: %{}}} = created} =
               Store.create(:thing, "t", %{a: 1}, i)

      assert {:ok, %Resource{uid: other}} = Store.create(:thing, "u", %{}, i)
      assert other > uid
      assert Store.get(:thing, "t", i) == created
      assert Store.fetch(:thing, "t", i) == {:ok, created}
    end

    test "a spec a validator rejects creates nothing", %{i: i} do
      assert {:error, {:invalid, :bad}} = Store.create(:thing, "t", %{bad: true}, i)
      assert Store.get(:thing, "t", i) == nil
      assert Store.fetch(:thing, "t", i) == {:error, :not_found}
    end

    test "the owner's registered validators run after the kind's own", %{i: i} do
      odd = fn spec -> if spec[:a] == 3, do: {:error, :three}, else: {:ok, spec} end
      :ok = Store.register_kind(:thing, Owner, [validators: [odd], conditions: [:ready]] ++ i)

      assert {:error, {:invalid, :three}} = Store.create(:thing, "t", %{a: 3}, i)
      assert {:ok, %{spec: %{holds: %{}}}} = Store.create(:thing, "t", %{a: 4}, i)
      assert {:error, {:invalid, :three}} = Store.update_spec(:thing, "t", %{a: 3}, i)
    end

    test "a kind the store was not started with is refused", %{i: i} do
      assert {:error, {:unknown_kind, :ghost}} = Store.create(:ghost, "g", %{}, i)
      assert {:error, {:unknown_kind, :ghost}} = Store.register_kind(:ghost, Owner, i)
    end

    test "a spec that could not be written to flash is refused with no file configured",
         %{i: i} do
      assert {:error, {:not_persistable, _}} = Store.create(:part, "p", %{pid: self()}, i)
      assert Store.get(:part, "p", i) == nil
    end
  end

  describe "update_spec" do
    test "the generation moves on a spec change and only then", %{i: i} do
      {:ok, _} = Store.create(:thing, "t", %{a: 1}, i)

      assert {:ok, %{generation: 2}} = Store.update_spec(:thing, "t", %{a: 2}, i)
      assert {:ok, %{generation: 2}} = Store.update_spec(:thing, "t", %{a: 2}, i)

      assert {:ok, %{generation: 3, spec: %{n: 1}}} =
               Store.update_spec(:thing, "t", [{:inc, [:n]}], i)

      assert {:error, :not_found} = Store.update_spec(:thing, "missing", %{a: 1}, i)
    end

    test "a path one writer owns refuses every other writer", %{i: i} do
      {:ok, _} = Store.create(:thing, "t", %{a: 1, b: 1}, i)

      assert {:ok, %{managed_fields: %{[:a] => :ctl}}} =
               Store.update_spec(:thing, "t", %{a: 2}, [writer: :ctl] ++ i)

      assert {:error, {:conflict, [:a], :ctl}} = Store.update_spec(:thing, "t", %{a: 3}, i)

      assert {:error, {:conflict, [:a], :ctl}} =
               Store.update_spec(:thing, "t", %{a: 3}, [writer: :other] ++ i)

      # A write without a writer owns nothing, so it blocks nobody later.
      assert {:ok, %{managed_fields: %{[:a] => :ctl} = fields}} =
               Store.update_spec(:thing, "t", %{b: 2}, i)

      assert map_size(fields) == 1
      assert %{a: 2, b: 2} = Store.get(:thing, "t", i).spec
    end

    test "force takes an owned path over", %{i: i} do
      {:ok, _} = Store.create(:thing, "t", %{a: 1}, [writer: :ctl] ++ i)

      assert {:ok, %{spec: %{a: 5}, managed_fields: %{[:a] => :other}}} =
               Store.update_spec(:thing, "t", %{a: 5}, [writer: :other, force: true] ++ i)

      assert {:error, {:conflict, [:a], :other}} =
               Store.update_spec(:thing, "t", %{a: 6}, [writer: :ctl] ++ i)
    end

    test "after a release the other writer succeeds, and the value was left alone", %{i: i} do
      {:ok, _} = Store.create(:thing, "t", %{a: 1}, [writer: :ctl] ++ i)

      assert {:ok, %{generation: 1, spec: %{a: 1}, managed_fields: fields}} =
               Store.update_spec(:thing, "t", [{:release, [:a]}], [writer: :ctl] ++ i)

      assert fields == %{}

      assert {:ok, %{spec: %{a: 2}, managed_fields: %{[:a] => :other}}} =
               Store.update_spec(:thing, "t", %{a: 2}, [writer: :other] ++ i)
    end

    test "members of a map are owned one by one, and the whole map collides with them",
         %{i: i} do
      {:ok, _} = Store.create(:thing, "t", %{}, i)
      x = [writer: :x] ++ i
      y = [writer: :y] ++ i

      assert {:ok, _} = Store.update_spec(:thing, "t", [{:put, [:holds, "x"], true}], x)
      assert {:ok, _} = Store.update_spec(:thing, "t", [{:put, [:holds, "y"], true}], y)

      assert {:error, {:conflict, [:holds, "x"], :x}} =
               Store.update_spec(:thing, "t", [{:delete, [:holds, "x"]}], y)

      assert {:error, {:conflict, [:holds, "x"], :x}} =
               Store.update_spec(:thing, "t", %{holds: %{}}, i)

      assert {:ok, %{spec: %{holds: holds}, managed_fields: fields}} =
               Store.update_spec(:thing, "t", [{:delete, [:holds, "x"]}], x)

      assert holds == %{"y" => true}
      assert fields == %{[:holds, "y"] => :y}
    end

    test "a deleting resource takes nothing new, but a writer can still let go", %{i: i} do
      {:ok, _} = Store.create(:thing, "t", %{a: 1}, [writer: :ctl, finalizers: [:tidy]] ++ i)
      {:ok, _} = Store.delete(:thing, "t", i)

      assert {:error, :deleting} = Store.update_spec(:thing, "t", %{a: 2}, [writer: :ctl] ++ i)
      assert {:error, :deleting} = Store.add_finalizer(:thing, "t", :late, i)

      assert {:ok, %{managed_fields: fields}} =
               Store.update_spec(:thing, "t", [{:release, [:a]}], [writer: :ctl] ++ i)

      assert fields == %{}
    end
  end

  describe "status and progress" do
    test "each writer keeps its own condition, and status never moves the generation",
         %{i: i} do
      {:ok, _} = Store.create(:thing, "t", %{}, i)
      owner = [writer: Owner] ++ i

      {:ok, _} =
        Store.patch_status(
          :thing,
          "t",
          %{conditions: [Resource.condition(:ready, false, :starting, 1)], instance: "c1"},
          owner
        )

      {:ok, _} =
        Store.patch_status(
          :thing,
          "t",
          %{conditions: [Resource.condition(:dns_ready, true, :registered, 1)]},
          [writer: Dns] ++ i
        )

      {:ok, _} =
        Store.patch_status(
          :thing,
          "t",
          %{conditions: [Resource.condition(:ready, true, :running, 1)]},
          owner
        )

      resource = Store.get(:thing, "t", i)
      assert resource.generation == 1
      assert resource.status.instance == "c1"
      assert %{status: true, reason: :running} = Resource.get_condition(resource, :ready)
      assert %{status: true, reason: :registered} = Resource.get_condition(resource, :dns_ready)
    end

    test "a condition type the writer does not own is rejected", %{i: i} do
      {:ok, before} = Store.create(:thing, "t", %{}, i)
      ready = %{conditions: [Resource.condition(:ready, true, :running, 1)]}

      assert {:error, {:not_owner, :ready, Dns}} =
               Store.patch_status(:thing, "t", ready, [writer: Dns] ++ i)

      assert {:error, {:not_owner, :ready, Stranger}} =
               Store.patch_status(:thing, "t", ready, [writer: Stranger] ++ i)

      assert {:error, {:not_owner, :ready, nil}} = Store.patch_status(:thing, "t", ready, i)
      assert Store.get(:thing, "t", i) == before
    end

    test "status outside conditions belongs to the kind's owner", %{i: i} do
      {:ok, before} = Store.create(:thing, "t", %{}, i)

      assert {:error, {:not_owner, :instance, Dns}} =
               Store.patch_status(:thing, "t", %{instance: "c1"}, [writer: Dns] ++ i)

      assert Store.get(:thing, "t", i) == before
    end

    test "only the kind's owner writes progress", %{i: i} do
      {:ok, _} = Store.create(:thing, "t", %{}, i)

      assert {:error, {:not_owner, :progress, Dns}} =
               Store.put_progress(:thing, "t", %{phase: :applied}, [writer: Dns] ++ i)

      assert {:ok, %{generation: 1, progress: %{phase: :applied}}} =
               Store.put_progress(:thing, "t", %{phase: :applied}, [writer: Owner] ++ i)
    end

    test "a kind has one owner, who may register again", %{i: i} do
      assert {:error, {:kind_owned, Owner}} = Store.register_kind(:thing, Usurper, i)
      assert :ok = Store.register_kind(:thing, Owner, [conditions: [:ready, :failed]] ++ i)
    end

    test "a condition type has one writer per kind", %{i: i} do
      assert {:error, {:condition_owned, :ready, Owner}} =
               Store.register_writer(:thing, Ingress, [conditions: [:ingress_ready, :ready]] ++ i)

      {:ok, _} = Store.create(:thing, "t", %{}, i)
      ingress = %{conditions: [Resource.condition(:ingress_ready, true, :ok, 1)]}

      assert {:error, {:not_owner, :ingress_ready, Ingress}} =
               Store.patch_status(:thing, "t", ingress, [writer: Ingress] ++ i)
    end
  end

  describe "deletion" do
    test "with finalizers: marked, still readable, removed with the last one, and said so",
         %{i: i} do
      {:ok, owner} = Store.create(:thing, "app", %{}, i)
      owner_ref = Resource.ref(owner)

      {:ok, %{generation: 1, uid: uid}} =
        Store.create(:part, "p", %{}, [owner_refs: [owner_ref], finalizers: [:auth, :tidy]] ++ i)

      :ok = Watch.subscribe({:object, :part, "p"}, i)

      assert {:ok, %{deleting?: true, generation: 2}} = Store.delete(:part, "p", i)
      assert_receive {Watch, :changed, %{name: "p", deleting?: true, generation: 2}}
      assert %Resource{deleting?: true, finalizers: [:auth, :tidy]} = Store.get(:part, "p", i)

      # Asking twice is not a second change.
      assert {:ok, %{generation: 2}} = Store.delete(:part, "p", i)
      refute_received {Watch, _, _}

      assert {:ok, %{finalizers: [:tidy]}} = Store.remove_finalizer(:part, "p", :auth, i)
      assert_receive {Watch, :changed, %{name: "p"}}
      assert %Resource{finalizers: [:tidy]} = Store.get(:part, "p", i)

      assert {:ok, %{finalizers: []}} = Store.remove_finalizer(:part, "p", :tidy, i)

      assert_receive {Watch, :removed,
                      %{
                        kind: :part,
                        name: "p",
                        uid: ^uid,
                        deleting?: true,
                        generation: 2,
                        owner_refs: [^owner_ref]
                      }}

      assert Store.get(:part, "p", i) == nil
      assert {:error, :not_found} = Store.delete(:part, "p", i)
    end

    test "without finalizers the resource is removed at once", %{i: i} do
      {:ok, _} = Store.create(:part, "p", %{}, i)
      :ok = Watch.subscribe({:kind, :part}, i)

      assert {:ok, %{deleting?: true}} = Store.delete(:part, "p", i)
      assert Store.get(:part, "p", i) == nil
      assert_receive {Watch, :removed, %{name: "p"}}
      refute_received {Watch, :changed, _}
    end

    test "a finalizer added before deletion holds the resource", %{i: i} do
      {:ok, _} = Store.create(:part, "p", %{}, i)
      assert {:ok, %{finalizers: [:auth]}} = Store.add_finalizer(:part, "p", :auth, i)
      assert {:ok, %{finalizers: [:auth]}} = Store.add_finalizer(:part, "p", :auth, i)

      {:ok, _} = Store.delete(:part, "p", i)
      assert %Resource{deleting?: true} = Store.get(:part, "p", i)
    end

    test "a re-created resource has a new uid, so it is not its predecessor's owner", %{i: i} do
      {:ok, first} = Store.create(:thing, "app", %{}, i)
      {:ok, _} = Store.create(:part, "p", %{}, [owner_refs: [Resource.ref(first)]] ++ i)
      {:ok, _} = Store.create(:part, "q", %{}, i)
      {:ok, _} = Store.delete(:thing, "app", i)
      {:ok, second} = Store.create(:thing, "app", %{}, i)

      assert second.uid != first.uid
      assert [%Resource{name: "p"}] = Store.owned_by(Resource.ref(first), i)
      assert Store.owned_by(Resource.ref(second), i) == []
    end

    test "an owner reference to a kind the store does not have is refused", %{i: i} do
      ghost = %{kind: :ghost, name: "g", uid: 1}

      assert {:error, {:bad_owner_ref, ^ghost}} =
               Store.create(:part, "p", %{}, [owner_refs: [ghost]] ++ i)
    end
  end

  describe "commit" do
    test "applies ops across resources in order and returns each result", %{i: i} do
      :ok = Watch.subscribe({:kind, :thing}, i)
      :ok = Watch.subscribe({:kind, :part}, i)

      assert {:ok,
              [%Resource{name: "app", generation: 1}, %Resource{name: "app", generation: 2}, part]} =
               Store.commit(
                 [
                   {:create, :thing, "app", %{version: 1}, []},
                   {:update_spec, :thing, "app", %{version: 2}, [writer: :update]},
                   {:create, :part, "p", %{}, []}
                 ],
                 i
               )

      assert Store.get(:part, "p", i) == part
      assert %{spec: %{version: 2}} = Store.get(:thing, "app", i)

      # One round: a resource touched twice is announced once, as it ended.
      assert_receive {Watch, :changed, %{name: "app", generation: 2}}
      assert_receive {Watch, :changed, %{name: "p"}}
      refute_received {Watch, _, _}
    end

    test "a rejected op rejects every op before it", %{i: i} do
      {:ok, a} = Store.create(:thing, "a", %{v: 1}, i)
      {:ok, b} = Store.create(:thing, "b", %{v: 1}, [writer: :ctl] ++ i)
      :ok = Watch.subscribe({:kind, :thing}, i)

      assert {:error, {:conflict, [:v], :ctl}} =
               Store.commit(
                 [
                   {:update_spec, :thing, "a", %{v: 2}, []},
                   {:create, :thing, "c", %{}, []},
                   {:update_spec, :thing, "b", %{v: 2}, []}
                 ],
                 i
               )

      assert Store.get(:thing, "a", i) == a
      assert Store.get(:thing, "b", i) == b
      assert Store.get(:thing, "c", i) == nil
      refute_received {Watch, _, _}
    end

    test "something that is not an op is an error, not a crash", %{i: i} do
      assert {:error, {:bad_op, {:frobnicate, :thing}}} =
               Store.commit([{:frobnicate, :thing}], i)

      {:ok, _} = Store.create(:thing, "t", %{}, i)

      assert {:error, {:bad_op, {:set, [:a], 1}}} =
               Store.update_spec(:thing, "t", [{:set, [:a], 1}], i)
    end
  end

  describe "watch" do
    test "a subscriber hears about its object, its kind, or its owner's children, and no other",
         %{i: i} do
      {:ok, app} = Store.create(:thing, "app", %{}, i)
      {:ok, _} = Store.create(:thing, "other", %{}, i)
      test = self()

      for key <- [{:object, :thing, "app"}, {:kind, :part}, {:owner, :thing, "app"}] do
        spawn_link(fn ->
          :ok = Watch.subscribe(key, i)
          send(test, {:subscribed, key})

          receive do
            {Watch, event, meta} -> send(test, {key, event, meta.name})
          end

          receive do
            :stop -> :ok
          end
        end)

        assert_receive {:subscribed, ^key}
      end

      {:ok, _} = Store.update_spec(:thing, "other", %{a: 1}, i)
      {:ok, _} = Store.create(:part, "p", %{}, [owner_refs: [Resource.ref(app)]] ++ i)
      {:ok, _} = Store.update_spec(:thing, "app", %{a: 1}, i)

      assert_receive {{:kind, :part}, :changed, "p"}
      assert_receive {{:owner, :thing, "app"}, :changed, "p"}
      assert_receive {{:object, :thing, "app"}, :changed, "app"}
    end

    test "a write that changes nothing is not announced", %{i: i} do
      {:ok, _} = Store.create(:thing, "t", %{a: 1}, i)
      status = %{conditions: [Resource.condition(:ready, true, :running, 1)]}
      {:ok, _} = Store.patch_status(:thing, "t", status, [writer: Owner] ++ i)
      :ok = Watch.subscribe({:object, :thing, "t"}, i)

      {:ok, _} = Store.patch_status(:thing, "t", status, [writer: Owner] ++ i)
      {:ok, _} = Store.update_spec(:thing, "t", %{a: 1}, i)
      refute_received {Watch, _, _}

      :ok = Watch.unsubscribe({:object, :thing, "t"}, i)
      {:ok, _} = Store.update_spec(:thing, "t", %{a: 2}, i)
      refute_received {Watch, _, _}
    end

    test "the store writes ETS before it tells a subscriber", %{i: i, store: store} do
      {:ok, _} = Store.create(:thing, "t", %{a: 1}, i)
      :ok = Watch.subscribe({:object, :thing, "t"}, i)

      # A subscriber racing the store proves nothing either way, so the
      # order is read off the store's own trace: its insert, then its send.
      :erlang.trace_pattern({:ets, :insert, 2}, true, [])
      on_exit(fn -> :erlang.trace_pattern({:ets, :insert, 2}, false, []) end)
      :erlang.trace(store, true, [:call, :send])
      {:ok, %{generation: 2}} = Store.update_spec(:thing, "t", %{a: 2}, i)
      :erlang.trace(store, false, [:call, :send])
      delivered = :erlang.trace_delivered(store)
      assert_receive {:trace_delivered, ^store, ^delivered}

      {:messages, messages} = Process.info(self(), :messages)

      inserted =
        Enum.find_index(messages, &match?({:trace, ^store, :call, {:ets, :insert, _}}, &1))

      told =
        Enum.find_index(
          messages,
          &match?({:trace, ^store, :send, {Watch, :changed, %{generation: 2}}, _}, &1)
        )

      assert is_integer(inserted) and is_integer(told)
      assert inserted < told

      assert_receive {Watch, :changed, %{generation: 2}}
      assert Store.get(:thing, "t", i).generation == 2
    end
  end

  describe "operation claims" do
    test "a second claimant is refused until the first lets go", %{i: i} do
      test = self()
      assert :ok = Store.claim(:thing, "t", i)
      assert Store.claimant(:thing, "t", i) == test

      assert Task.await(Task.async(fn -> Store.claim(:thing, "t", i) end)) == {:error, :busy}
      assert Store.claim(:thing, "t", i) == {:error, :busy}
      assert :ok = Store.claim(:thing, "u", i)

      assert :ok = Store.release_claim(:thing, "t", i)
      assert Store.claimant(:thing, "t", i) == nil
      assert Task.await(Task.async(fn -> Store.claim(:thing, "t", i) end)) == :ok
    end

    test "only the holder can release", %{i: i} do
      assert :ok = Store.claim(:thing, "t", i)

      assert Task.await(Task.async(fn -> Store.release_claim(:thing, "t", i) end)) ==
               {:error, :not_holder}

      assert Store.claimant(:thing, "t", i) == self()
      assert Store.release_claim(:thing, "nobody", i) == {:error, :not_holder}
    end

    test "a claimant that dies gives its claim up", %{i: i, store: store} do
      test = self()

      {pid, ref} =
        spawn_monitor(fn ->
          :ok = Store.claim(:thing, "t", i)
          send(test, :claimed)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :claimed
      assert Store.claim(:thing, "t", i) == {:error, :busy}

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      :sys.get_state(store)

      assert Store.claimant(:thing, "t", i) == nil
      assert :ok = Store.claim(:thing, "t", i)
    end
  end
end
