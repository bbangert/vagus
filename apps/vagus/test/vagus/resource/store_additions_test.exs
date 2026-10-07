defmodule Vagus.Resource.StoreAdditionsTest do
  use ExUnit.Case, async: true

  alias Vagus.Resource
  alias Vagus.Resource.{Store, TestInstance, Watch}

  setup do
    kinds =
      Map.merge(TestInstance.kinds(), %{
        held: [finalizers: [:auth, :tidy], writer_entries: [["holds"]]]
      })

    instance = TestInstance.start!(kinds: kinds)
    %{i: [instance: instance]}
  end

  describe "a kind's finalizers" do
    test "are on every resource of the kind from its creation, before the ones given", %{i: i} do
      assert {:ok, %{finalizers: [:auth, :tidy]}} = Store.create(:held, "a", %{}, i)

      assert {:ok, %{finalizers: [:auth, :tidy, :extra]}} =
               Store.create(:held, "b", %{}, [finalizers: [:tidy, :extra]] ++ i)

      assert {:ok, %{finalizers: []}} = Store.create(:part, "p", %{}, i)
    end

    test "hold a resource deleted in the commit that created it", %{i: i} do
      assert {:ok, [_created, %{deleting?: true}]} =
               Store.commit([{:create, :held, "a", %{}, []}, {:delete, :held, "a"}], i)

      assert %Resource{deleting?: true, finalizers: [:auth, :tidy]} = Store.get(:held, "a", i)
    end
  end

  describe "expect" do
    test "rejects the whole commit when the uid or the generation is another", %{i: i} do
      {:ok, %{uid: uid}} = Store.create(:part, "p", %{"a" => 1}, i)
      put = {:update_spec, :part, "p", %{"a" => 2}, []}

      assert {:error, {:precondition, {:part, "p"}, :uid}} =
               Store.commit([put, {:expect, :part, "p", uid: uid + 1}], i)

      assert {:error, {:precondition, {:part, "p"}, :generation}} =
               Store.commit([{:expect, :part, "p", uid: uid, generation: 2}, put], i)

      assert %{spec: %{"a" => 1}, generation: 1} = Store.get(:part, "p", i)

      assert {:ok, [%{generation: 1}, %{generation: 2}]} =
               Store.commit([{:expect, :part, "p", uid: uid, generation: 1}, put], i)
    end

    test "sees the commit so far, and a resource that is not there", %{i: i} do
      {:ok, %{uid: uid}} = Store.create(:part, "p", %{}, i)

      assert {:error, {:precondition, {:part, "p"}, :not_found}} =
               Store.commit([{:delete, :part, "p"}, {:expect, :part, "p", uid: uid}], i)

      assert {:error, {:precondition, {:part, "ghost"}, :not_found}} =
               Store.expect(:part, "ghost", [uid: 1], i)

      assert {:ok, %{uid: ^uid}} = Store.expect(:part, "p", [], i)
    end

    test "a namesake created after a delete is not the resource that was read", %{i: i} do
      {:ok, read} = Store.create(:part, "p", %{}, i)
      {:ok, _} = Store.delete(:part, "p", i)
      {:ok, _} = Store.create(:part, "p", %{}, i)

      assert {:error, {:precondition, {:part, "p"}, :uid}} =
               Store.commit(
                 [
                   {:expect, :part, "p", uid: read.uid},
                   {:update_spec, :part, "p", %{"late" => true}, []}
                 ],
                 i
               )

      assert Store.get(:part, "p", i).spec == %{}
    end

    test "anything but a uid and a generation is a bad op", %{i: i} do
      {:ok, _} = Store.create(:part, "p", %{}, i)

      for expected <- [[name: "p"], [uid: "1"], :uid, [{:uid, 1} | :tail]] do
        op = {:expect, :part, "p", expected}
        assert Store.commit([op], i) == {:error, {:bad_op, op}}
      end
    end
  end

  describe "release_writer" do
    setup %{i: i} do
      {:ok, _} = Store.create(:held, "h", %{"version" => 1}, i)
      update = Resource.writer(%Resource{kind: :part, name: "update", uid: 7})
      as_update = [writer: update] ++ i

      {:ok, _} =
        Store.update_spec(
          :held,
          "h",
          [{:put, ["version"], 2}, {:put, ["holds", "update"], true}],
          as_update
        )

      {:ok, _} =
        Store.update_spec(:held, "h", [{:put, ["holds", "other"], true}], [writer: :other] ++ i)

      %{update: update}
    end

    test "deletes the writer's entries, leaves its other values unowned, and spares the rest",
         %{i: i, update: update} do
      before = Store.get(:held, "h", i)

      assert {:ok, released} = Store.release_writer(:held, "h", update, i)
      assert released.spec == %{"version" => 2, "holds" => %{"other" => true}}
      assert released.managed_fields == %{["holds", "other"] => :other}
      assert released.generation == before.generation + 1

      assert {:ok, %{spec: %{"version" => 3}}} =
               Store.update_spec(:held, "h", %{"version" => 3}, i)
    end

    test "is a no-op for a writer that owns nothing, and works on a deleting resource",
         %{i: i, update: update} do
      before = Store.get(:held, "h", i)
      assert {:ok, ^before} = Store.release_writer(:held, "h", :stranger, i)

      {:ok, _} = Store.delete(:held, "h", i)

      assert {:ok, %{deleting?: true, managed_fields: fields}} =
               Store.release_writer(:held, "h", update, i)

      assert fields == %{["holds", "other"] => :other}
      assert {:error, :not_found} = Store.release_writer(:held, "ghost", update, i)
    end
  end

  describe "relay" do
    test "a subscriber gets the message after the notifications of every earlier commit", %{i: i} do
      :ok = Watch.subscribe({:kind, :part}, i)
      {:ok, _} = Store.create(:part, "a", %{}, i)
      {:ok, _} = Store.create(:part, "b", %{}, i)
      :ok = Store.relay([self(), :not_a_pid], :behind, i)

      assert {:messages,
              [{Watch, :changed, %{name: "a"}}, {Watch, :changed, %{name: "b"}}, :behind]} =
               Process.info(self(), :messages)
    end
  end

  describe "await" do
    test "returns what the function halts with, at once when it already holds", %{i: i} do
      {:ok, _} = Store.create(:part, "p", %{"n" => 1}, i)

      assert Store.await(:part, "p", &{:halt, &1.spec["n"]}, i) == {:ok, 1}
      assert Store.await(:part, "ghost", &{:halt, &1}, i) == {:ok, nil}
    end

    test "reads again on a notification, long before the poll", %{i: i} do
      {:ok, _} = Store.create(:part, "p", %{"n" => 1}, i)
      test = self()

      halt = fn resource ->
        send(test, {:read, resource.spec["n"]})
        if resource.spec["n"] == 2, do: {:halt, :two}, else: :cont
      end

      waiter =
        Task.async(fn -> Store.await(:part, "p", halt, [poll: 60_000, timeout: 60_000] ++ i) end)

      # The first read has happened, so the waiter is subscribed.
      assert_receive {:read, 1}, 5_000
      {:ok, _} = Store.update_spec(:part, "p", %{"n" => 2}, i)

      assert Task.await(waiter) == {:ok, :two}
    end

    test "reads again every poll, so a notification nobody sent does not hang it", %{i: i} do
      flips = :counters.new(1, [])

      halt = fn nil ->
        :counters.add(flips, 1, 1)
        if :counters.get(flips, 1) == 3, do: {:halt, :third}, else: :cont
      end

      assert Store.await(:part, "ghost", halt, [poll: 1, timeout: 60_000] ++ i) == {:ok, :third}
    end

    test "gives up at the deadline with what it last saw, and leaves nothing behind", %{i: i} do
      {:ok, created} = Store.create(:part, "p", %{}, i)

      assert Store.await(:part, "p", fn _ -> :cont end, [timeout: 20] ++ i) ==
               {:error, {:timeout, created}}

      {:ok, _} = Store.update_spec(:part, "p", %{"n" => 1}, i)
      refute_received {Watch, _event, _meta}
      assert Registry.keys(Watch.name(i[:instance]), self()) == []
    end
  end
end
