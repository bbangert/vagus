defmodule Vagus.Resource.StoreTest do
  use ExUnit.Case, async: true

  alias Vagus.Resource
  alias Vagus.Resource.{Store, Tables, TestInstance, Watch}

  setup do
    instance = TestInstance.start!()
    i = [instance: instance]
    :ok = Store.register_kind(:thing, Owner, [conditions: [:ready]] ++ i)
    :ok = Store.register_writer(:thing, Dns, [conditions: [:dns_ready]] ++ i)
    %{i: i, instance: instance, store: Process.whereis(Store.name(instance))}
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

    test "validators run in the order the kind lists them, each on the last one's spec" do
      first = &{:ok, Map.put(&1, "first", true)}

      second = fn
        %{"first" => true} = spec -> {:ok, Map.put(spec, "second", true)}
        _spec -> {:error, :out_of_order}
      end

      i = [instance: TestInstance.start!(kinds: %{part: [validators: [first, second]]})]

      assert {:ok, %{spec: %{"first" => true, "second" => true}}} =
               Store.create(:part, "p", %{}, i)
    end

    test "a kind the store was not started with is refused", %{i: i} do
      assert {:error, {:unknown_kind, :ghost}} = Store.create(:ghost, "g", %{}, i)
      assert {:error, {:unknown_kind, :ghost}} = Store.register_kind(:ghost, Owner, i)
    end

    test "a spec JSON cannot hold is refused with no file configured", %{i: i} do
      assert {:error, {:not_persistable, _}} = Store.create(:part, "p", %{"pid" => self()}, i)
      assert Store.get(:part, "p", i) == nil
    end

    test "a spec that would not read back the same is refused with no file configured",
         %{i: i} do
      # `:part` has no hooks, and JSON returns an atom key as a string.
      assert {:error, {:not_round_trippable, {:part, "p"}}} =
               Store.create(:part, "p", %{n: 1}, i)

      assert Store.get(:part, "p", i) == nil
      assert {:ok, %{spec: %{"n" => 1}}} = Store.create(:part, "p", %{"n" => 1}, i)
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

    test "owning a path refuses another writer anything beneath it", %{i: i} do
      {:ok, _} = Store.create(:thing, "t", %{}, i)
      {:ok, _} = Store.update_spec(:thing, "t", %{a: %{}}, [writer: :ctl] ++ i)

      assert {:error, {:conflict, [:a], :ctl}} =
               Store.update_spec(:thing, "t", [{:put, [:a, :b], 1}], [writer: :other] ++ i)
    end

    test "force without a writer takes ownership away and gives it to nobody", %{i: i} do
      {:ok, _} = Store.create(:thing, "t", %{a: 1}, [writer: :ctl] ++ i)

      assert {:ok, %{spec: %{a: 2}, managed_fields: fields}} =
               Store.update_spec(:thing, "t", %{a: 2}, [force: true] ++ i)

      assert fields == %{}
    end

    test "a release by someone who does not own the path changes nothing", %{i: i} do
      {:ok, before} = Store.create(:thing, "t", %{a: 1}, [writer: :ctl] ++ i)

      assert {:ok, ^before} =
               Store.update_spec(:thing, "t", [{:release, [:a]}], [writer: :other] ++ i)

      assert {:ok, ^before} = Store.update_spec(:thing, "t", [{:release, [:a]}], i)
    end

    test "deleting a path gives up everything the writer owned beneath it", %{i: i} do
      {:ok, _} = Store.create(:thing, "t", %{}, i)
      x = [writer: :x] ++ i

      {:ok, %{managed_fields: fields}} =
        Store.update_spec(
          :thing,
          "t",
          [{:put, [:holds, "x", "a"], 1}, {:put, [:holds, "x", "b"], 2}, {:put, [:a], 1}],
          x
        )

      assert map_size(fields) == 3

      assert {:ok, %{spec: %{holds: holds}, managed_fields: fields}} =
               Store.update_spec(:thing, "t", [{:delete, [:holds, "x"]}], x)

      assert holds == %{}
      assert fields == %{[:a] => :x}
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
      {:ok, _} = Store.create(:thing, "t", %{}, i)
      failed = %{conditions: [Resource.condition(:failed, true, :crashed, 1)]}
      owner = [writer: Owner] ++ i

      assert {:error, {:not_owner, :failed, Owner}} =
               Store.patch_status(:thing, "t", failed, owner)

      assert :ok = Store.register_kind(:thing, Owner, [conditions: [:failed]] ++ i)
      assert {:ok, _} = Store.patch_status(:thing, "t", failed, owner)

      # The second registration replaced the first; it did not add to it.
      ready = %{conditions: [Resource.condition(:ready, true, :running, 1)]}
      assert {:error, {:not_owner, :ready, Owner}} = Store.patch_status(:thing, "t", ready, owner)
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

    test "a uid is not given out again once its resource is gone", %{i: i} do
      {:ok, %{uid: 1}} = Store.create(:part, "a", %{}, i)
      {:ok, %{uid: 2}} = Store.create(:part, "b", %{}, i)
      {:ok, _} = Store.delete(:part, "b", i)

      assert {:ok, %{uid: 3}} = Store.create(:part, "b", %{}, i)
    end

    test "created and deleted in one commit: the uid is spent and nobody is told", %{i: i} do
      :ok = Watch.subscribe({:kind, :part}, i)

      assert {:ok, [%{uid: 1}, %{uid: 1, deleting?: true}]} =
               Store.commit([{:create, :part, "p", %{}, []}, {:delete, :part, "p"}], i)

      assert Store.get(:part, "p", i) == nil
      assert {:ok, %{uid: 2}} = Store.create(:part, "p", %{}, i)

      assert_received {Watch, :changed, %{name: "p", uid: 2}}
      refute_received {Watch, _, _}
    end

    test "deleted and created again in one commit: the old one is announced gone", %{i: i} do
      {:ok, %{uid: 1}} = Store.create(:part, "p", %{}, i)
      :ok = Watch.subscribe({:kind, :part}, i)

      assert {:ok, [_, %{uid: 2}]} =
               Store.commit([{:delete, :part, "p"}, {:create, :part, "p", %{}, []}], i)

      assert_received {Watch, :removed, %{name: "p", uid: 1}}
      assert_received {Watch, :changed, %{name: "p", uid: 2}}
    end

    test "an owner reference of the wrong shape is refused before it is written", %{i: i} do
      for ref <- [
            %{kind: :thing, name: "x", uid: nil},
            %{kind: :thing, name: :x, uid: 1},
            %{kind: :thing, name: "x", uid: 1, extra: true},
            {:thing, "x", 1}
          ] do
        assert {:error, {:bad_owner_ref, ^ref}} =
                 Store.create(:part, "p", %{}, [owner_refs: [ref]] ++ i)
      end

      assert {:error, {:bad_owner_ref, :not_a_list}} =
               Store.create(:part, "p", %{}, [owner_refs: :not_a_list] ++ i)
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

      assert {:error, {:bad_op, :tail}} =
               Store.commit([{:create, :part, "p", %{}, []} | :tail], i)

      assert Store.get(:part, "p", i) == nil
    end
  end

  describe "input the store must survive" do
    setup %{i: i} do
      {:ok, _} = Store.create(:thing, "t", %{a: 1, word: "x"}, i)
      :ok
    end

    defp same_store?(instance, store), do: Process.whereis(Store.name(instance)) == store

    test "a spec op that is not one", %{i: i, instance: instance, store: store} do
      for op <- [{:set, [:a], 1}, {:put, [], 1}, {:delete, []}, {:put, :a, 1}, {:inc, []}, :put] do
        assert {:error, {:bad_op, ^op}} = Store.update_spec(:thing, "t", [op], i)
      end

      assert {:error, {:bad_op, {:put, [:a | :b], 1}}} =
               Store.update_spec(:thing, "t", [{:put, [:a | :b], 1}], i)

      assert same_store?(instance, store)
    end

    test "counting on a path that holds no number", %{i: i, instance: instance, store: store} do
      assert {:error, {:bad_op, {:inc, [:word]}}} =
               Store.update_spec(:thing, "t", [{:inc, [:word]}], i)

      assert {:ok, %{spec: %{a: 2, fresh: 1}}} =
               Store.update_spec(:thing, "t", [{:inc, [:a]}, {:inc, [:fresh]}], i)

      assert same_store?(instance, store)
    end

    test "spec ops that are neither a map nor a list",
         %{i: i, instance: instance, store: store} do
      assert {:error, {:bad_op, :nope}} = Store.update_spec(:thing, "t", :nope, i)

      assert {:error, {:bad_op, :tail}} =
               Store.update_spec(:thing, "t", [{:inc, [:a]} | :tail], i)

      assert same_store?(instance, store)
    end

    test "conditions that are not a list of conditions",
         %{i: i, instance: instance, store: store} do
      owner = [writer: Owner] ++ i

      for conditions <- [
            :ready,
            [%{type: :ready}],
            [Resource.condition(:ready, true, :ok, 1) | :x]
          ] do
        assert {:error, {:bad_op, {:patch_status, :thing, "t", %{conditions: ^conditions}, _}}} =
                 Store.patch_status(:thing, "t", %{conditions: conditions}, owner)
      end

      assert same_store?(instance, store)
    end

    test "finalizers and condition types that are not atoms",
         %{i: i, instance: instance, store: store} do
      for finalizers <- [:tidy, ["tidy"]] do
        assert {:error, {:bad_op, {:create, :part, "p", _, _}}} =
                 Store.create(:part, "p", %{}, [finalizers: finalizers] ++ i)
      end

      assert {:error, {:bad_op, {:add_finalizer, :thing, "t", "tidy"}}} =
               Store.add_finalizer(:thing, "t", "tidy", i)

      assert {:error, {:bad_op, {:remove_finalizer, :thing, "t", "tidy"}}} =
               Store.remove_finalizer(:thing, "t", "tidy", i)

      assert {:error, {:bad_conditions, :ready}} =
               Store.register_writer(:thing, Late, [conditions: :ready] ++ i)

      assert same_store?(instance, store)
    end

    test "a message nobody should have sent it", %{i: i, instance: instance, store: store} do
      send(store, :stray)
      :sys.get_state(store)

      assert same_store?(instance, store)
      assert {:ok, _} = Store.update_spec(:thing, "t", %{a: 2}, i)
    end
  end

  describe "watch" do
    test "a subscriber hears about its object, its kind, or its owner's children, and no other",
         %{i: i} do
      {:ok, app} = Store.create(:thing, "app", %{}, i)
      {:ok, _} = Store.create(:thing, "other", %{}, i)
      test = self()
      keys = [{:object, :thing, "app"}, {:kind, :part}, {:owner, :thing, "app"}]

      # Every relay also watches a sentinel. The store sends to a relay in
      # order, so once the sentinel has come through, everything the store
      # sent that relay before it has too, and the list is complete.
      for key <- keys do
        spawn_link(fn ->
          :ok = Watch.subscribe(key, i)
          :ok = Watch.subscribe({:object, :thing, "sentinel"}, i)
          send(test, {:subscribed, key})
          relay(test, key)
        end)

        assert_receive {:subscribed, ^key}, 1_000
      end

      {:ok, _} = Store.update_spec(:thing, "other", %{a: 1}, i)
      {:ok, _} = Store.create(:part, "p", %{}, [owner_refs: [Resource.ref(app)]] ++ i)
      {:ok, _} = Store.create(:part, "stranger", %{}, [owner_refs: [Resource.ref(app)]] ++ i)
      {:ok, _} = Store.update_spec(:thing, "app", %{a: 1}, i)
      {:ok, _} = Store.delete(:part, "stranger", i)
      {:ok, _} = Store.create(:thing, "sentinel", %{}, i)

      assert relayed({:object, :thing, "app"}) == [changed: "app"]

      assert relayed({:kind, :part}) ==
               [changed: "p", changed: "stranger", removed: "stranger"]

      assert relayed({:owner, :thing, "app"}) ==
               [changed: "p", changed: "stranger", removed: "stranger"]
    end

    test "a write that changes nothing is not announced, nor anything after unsubscribing",
         %{i: i} do
      {:ok, _} = Store.create(:thing, "t", %{a: 1}, i)
      status = %{conditions: [Resource.condition(:ready, true, :running, 1)]}
      :ok = Watch.subscribe({:object, :thing, "t"}, i)

      {:ok, _} = Store.patch_status(:thing, "t", status, [writer: Owner] ++ i)
      assert_received {Watch, :changed, %{name: "t", generation: 1}}

      {:ok, _} = Store.patch_status(:thing, "t", status, [writer: Owner] ++ i)
      {:ok, _} = Store.update_spec(:thing, "t", %{a: 1}, i)
      {:ok, _} = Store.update_spec(:thing, "t", [{:release, [:a]}], [writer: :nobody] ++ i)
      refute_received {Watch, _, _}

      {:ok, _} = Store.update_spec(:thing, "t", %{a: 2}, i)
      assert_received {Watch, :changed, %{name: "t", generation: 2}}

      :ok = Watch.unsubscribe({:object, :thing, "t"}, i)
      {:ok, _} = Store.update_spec(:thing, "t", %{a: 3}, i)
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
      table = Tables.resources(i[:instance])

      inserted =
        Enum.find_index(messages, fn
          {:trace, ^store, :call, {:ets, :insert, [^table, rows]}} ->
            Enum.any?(rows, &match?({{:thing, "t"}, %Resource{generation: 2}}, &1))

          _other ->
            false
        end)

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

      pid =
        spawn(fn ->
          :ok = Store.claim(:thing, "t", i)
          send(test, :claimed)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :claimed, 1_000
      assert Store.claim(:thing, "t", i) == {:error, :busy}

      TestInstance.kill_observed(pid, store)

      assert Store.claimant(:thing, "t", i) == nil
      assert :ok = Store.claim(:thing, "t", i)
    end
  end

  defp relay(test, key) do
    receive do
      {Watch, event, meta} -> send(test, {key, event, meta.name})
    end

    relay(test, key)
  end

  defp relayed(key, seen \\ []) do
    receive do
      {^key, _event, "sentinel"} -> Enum.reverse(seen)
      {^key, event, name} -> relayed(key, [{event, name} | seen])
    after
      1_000 -> flunk("#{inspect(key)} never saw the sentinel; so far: #{inspect(seen)}")
    end
  end
end
