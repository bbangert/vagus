defmodule Vagus.Resource.StorePersistenceTest do
  use ExUnit.Case, async: true

  alias Vagus.Resource
  alias Vagus.Resource.{Persistence, Stamp, Store, TestInstance, Watch}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{path: Path.join(dir, "resources.json")}
  end

  # Writes for real and reports each flash write to the test.
  defp counting(test) do
    fn path, data ->
      send(test, {:persisted, path})
      Persistence.write(path, data)
    end
  end

  # Writes for real, then does `then` if the test left a marker beside the
  # file, so one chosen write of a store's life goes wrong.
  defp marked(then) do
    fn path, data ->
      result = Persistence.write(path, data)
      if File.rm(path <> ".marker") == :ok, do: then.(), else: result
    end
  end

  defp mark(path), do: File.write!(path <> ".marker", "")

  defp rewrite(path, fun),
    do: File.write!(path, path |> File.read!() |> Jason.decode!() |> fun.() |> Jason.encode!())

  defp start!(path, opts \\ []) do
    [instance: TestInstance.start!([path: path, owned: %{thing: [{Owner, [:ready]}]}] ++ opts)]
  end

  defp restart!(i, path) do
    :ok = stop_supervised(i[:instance])
    start!(path)
  end

  describe "what reaches flash" do
    test "status never does, nor a write that changes nothing", %{path: path} do
      i = start!(path, persist: counting(self()))
      {:ok, _} = Store.create(:thing, "t", %{a: 1}, i)
      assert_received {:persisted, ^path}

      status = %{conditions: [Resource.condition(:ready, true, :running, 1)], instance: "c1"}

      {:ok, %{status: %{instance: "c1"}}} =
        Store.patch_status(:thing, "t", status, [writer: Owner] ++ i)

      {:ok, _} = Store.update_spec(:thing, "t", %{a: 1}, i)

      refute_received {:persisted, _}
    end

    test "progress, a finalizer and a deletion each do, by themselves", %{path: path} do
      i = start!(path, persist: counting(self()))
      {:ok, _} = Store.create(:thing, "t", %{a: 1}, i)
      assert_received {:persisted, ^path}

      {:ok, _} = Store.put_progress(:thing, "t", %{phase: :applied}, [writer: Owner] ++ i)
      assert_received {:persisted, ^path}

      {:ok, _} = Store.add_finalizer(:thing, "t", :tidy, i)
      assert_received {:persisted, ^path}

      {:ok, %{deleting?: true}} = Store.delete(:thing, "t", i)
      assert_received {:persisted, ^path}

      refute_received {:persisted, _}
    end

    test "a create and delete in one commit still writes the spent uid", %{path: path} do
      i = start!(path, persist: counting(self()))
      {:ok, _} = Store.commit([{:create, :part, "p", %{}, []}, {:delete, :part, "p"}], i)
      assert_received {:persisted, ^path}

      i = restart!(i, path)

      assert {:ok, %{uid: 2}} = Store.create(:part, "p", %{}, i)
    end

    test "a commit that changes specs is written exactly once", %{path: path} do
      i = start!(path, persist: counting(self()))

      {:ok, _} =
        Store.commit(
          [{:create, :thing, "a", %{v: 1}, []}, {:create, :thing, "b", %{v: 1}, []}],
          i
        )

      assert_received {:persisted, ^path}
      refute_received {:persisted, _}

      {:ok, _} =
        Store.commit(
          [
            {:update_spec, :thing, "a", %{v: 2}, []},
            {:patch_status, :thing, "a", %{instance: "c1"}, [writer: Owner]},
            {:update_spec, :thing, "b", %{v: 2}, []}
          ],
          i
        )

      assert_received {:persisted, ^path}
      refute_received {:persisted, _}
    end

    test "the file is readable JSON and holds no status", %{path: path} do
      i = start!(path)
      {:ok, _} = Store.create(:thing, "t", %{a: 1}, i)
      {:ok, _} = Store.patch_status(:thing, "t", %{instance: "sekrit"}, [writer: Owner] ++ i)
      {:ok, _} = Store.update_spec(:thing, "t", %{a: 2}, i)

      content = File.read!(path)
      refute content =~ "sekrit"
      refute content =~ "status"
      assert content =~ "\n"

      assert %{
               "version" => 1,
               "resources" => [%{"kind" => "thing", "name" => "t", "spec" => spec}]
             } =
               Jason.decode!(content)

      assert spec == %{"a" => 2, "holds" => %{}}
    end

    test "a rejected commit leaves the store, the file and every subscriber alone",
         %{path: path} do
      i = start!(path, persist: counting(self()))
      {:ok, a} = Store.create(:thing, "a", %{v: 1}, i)
      {:ok, b} = Store.create(:thing, "b", %{v: 1}, [writer: :ctl] ++ i)
      before = File.read!(path)
      :ok = Watch.subscribe({:kind, :thing}, i)
      assert_received {:persisted, ^path}
      assert_received {:persisted, ^path}

      assert {:error, {:conflict, [:v], :ctl}} =
               Store.commit(
                 [
                   {:update_spec, :thing, "a", %{v: 2}, []},
                   {:delete, :thing, "a"},
                   {:update_spec, :thing, "b", %{v: 2}, []}
                 ],
                 i
               )

      assert Store.get(:thing, "a", i) == a
      assert Store.get(:thing, "b", i) == b
      assert File.read!(path) == before
      refute_received {:persisted, _}
      refute_received {Watch, _, _}
    end

    test "a flash write that fails rejects the commit", %{path: path} do
      i = start!(path, persist: fn _path, _data -> {:error, :enospc} end)
      :ok = Watch.subscribe({:kind, :thing}, i)

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert {:error, {:persist_failed, :enospc}} = Store.create(:thing, "t", %{}, i)
             end) =~ "not written"

      assert Store.get(:thing, "t", i) == nil
      refute_received {Watch, _, _}
    end

    @tag :capture_log
    test "a flash write that fails after its rename stops the store, and the next has it",
         %{path: path} do
      i = start!(path, persist: marked(fn -> {:unknown, :eio} end))
      {:ok, _} = Store.create(:thing, "t", %{a: 1}, i)
      :ok = Watch.subscribe({:object, :thing, "t"}, i)

      mark(path)

      assert {{:persist_outcome_unknown, :eio}, _call} =
               catch_exit(Store.update_spec(:thing, "t", %{a: 2}, i))

      assert_receive {Watch, :changed, %{name: "t", generation: 2}}, 1_000
      assert %Resource{spec: %{a: 2}} = Store.get(:thing, "t", i)
    end

    test "a write that fails before the rename leaves the file and no temporary",
         %{path: path} do
      :ok = Persistence.write(path, "first")

      assert {:error, :badarg} = Persistence.write(path, [:not_iodata])

      assert File.read!(path) == "first"
      assert File.ls!(Path.dirname(path)) == ["resources.json"]
    end

    test "a write that fails after the rename says the outcome is unknown", %{tmp_dir: dir} do
      locked = Path.join(dir, "locked")
      path = Path.join(locked, "resources.json")
      :ok = Persistence.write(path, "first")

      # Entries can still be made and renamed; the directory cannot be
      # opened, which is what syncing it needs.
      File.chmod!(locked, 0o300)
      on_exit(fn -> File.chmod!(locked, 0o700) end)

      assert {:unknown, :eacces} = Persistence.write(path, "second")

      File.chmod!(locked, 0o700)
      assert File.read!(path) == "second"
    end

    test "a write replaces the file whole and leaves no temporary behind", %{tmp_dir: dir} do
      path = Path.join([dir, "made", "on", "demand", "resources.json"])

      assert :ok = Persistence.write(path, "first, and rather longer")
      assert :ok = Persistence.write(path, ["sec", "ond"])

      assert File.read!(path) == "second"
      assert File.ls!(Path.dirname(path)) == ["resources.json"]
    end
  end

  describe "reload" do
    test "restores every durable field exactly, and no status", %{path: path} do
      i = start!(path)
      started = %Stamp{incarnation: 77, at: -5_000}

      {:ok, app} =
        Store.create(:thing, "app", %{mode: :fast, a: 1}, [finalizers: [:auth, :tidy]] ++ i)

      {:ok, _} =
        Store.commit(
          [
            {:update_spec, :thing, "app", [{:put, [:holds, ":odd"], true}],
             [writer: {:backup, "b1"}]},
            {:update_spec, :thing, "app", %{a: 2}, [writer: Owner]},
            {:put_progress, :thing, "app", %{phase: :applied, started: started}, [writer: Owner]},
            {:patch_status, :thing, "app", %{instance: "c1"}, [writer: Owner]},
            {:create, :part, "p", %{"n" => 1},
             [owner_refs: [Resource.ref(app)], finalizers: [:tidy]]},
            {:delete, :part, "p"}
          ],
          i
        )

      before = Store.get(:thing, "app", i)
      part = Store.get(:part, "p", i)
      assert before.status == %{instance: "c1"}
      assert part.deleting?

      i = restart!(i, path)

      assert Store.get(:thing, "app", i) == %{before | status: %{}}
      assert Store.get(:part, "p", i) == part

      assert %Resource{
               uid: 1,
               generation: 3,
               spec: %{mode: :fast, a: 2, holds: %{":odd" => true}},
               progress: %{phase: :applied, started: ^started},
               finalizers: [:auth, :tidy],
               managed_fields: %{[:holds, ":odd"] => {:backup, "b1"}, [:a] => Owner}
             } = Store.get(:thing, "app", i)

      assert %Resource{
               deleting?: true,
               finalizers: [:tidy],
               owner_refs: [%{kind: :thing, name: "app", uid: 1}]
             } =
               part
    end

    test "uids continue above every uid ever given, deleted ones included", %{path: path} do
      i = start!(path)
      {:ok, %{uid: 1}} = Store.create(:thing, "a", %{}, i)
      {:ok, %{uid: 2}} = Store.create(:thing, "b", %{}, i)
      {:ok, %{uid: 3}} = Store.create(:thing, "c", %{}, i)
      {:ok, _} = Store.delete(:thing, "c", i)

      i = restart!(i, path)

      assert {:ok, %{uid: 4}} = Store.create(:thing, "c", %{}, i)
    end

    test "a file whose counter is behind its resources still gives a fresh uid", %{path: path} do
      i = start!(path)
      {:ok, %{uid: 1}} = Store.create(:thing, "a", %{}, i)
      {:ok, %{uid: 2}} = Store.create(:thing, "b", %{}, i)
      :ok = stop_supervised(i[:instance])

      File.write!(
        path,
        path |> File.read!() |> Jason.decode!() |> Map.put("next_uid", 1) |> Jason.encode!()
      )

      i = start!(path)

      assert {:ok, %{uid: 3}} = Store.create(:thing, "c", %{}, i)
    end

    test "a path can be given up on a spec the kind would no longer admit", %{path: path} do
      i = start!(path)
      {:ok, _} = Store.create(:thing, "t", %{a: 1}, [writer: :ctl] ++ i)
      :ok = stop_supervised(i[:instance])

      stricter = put_in(TestInstance.kinds(), [:thing, :validators], [fn _ -> {:error, :no} end])
      i = start!(path, kinds: stricter)

      assert {:error, {:invalid, :no}} =
               Store.update_spec(:thing, "t", %{a: 2}, [writer: :ctl] ++ i)

      assert {:ok, %{spec: %{a: 1}, managed_fields: fields}} =
               Store.update_spec(:thing, "t", [{:release, [:a]}], [writer: :ctl] ++ i)

      assert fields == %{}
    end

    test "a missing file is an empty store", %{path: path} do
      i = start!(path)

      assert Store.list(:thing, i) == []
      assert {:ok, %{uid: 1}} = Store.create(:thing, "t", %{}, i)
      assert File.exists?(path)
    end
  end

  describe "a file that cannot be trusted fails the start" do
    @describetag :capture_log

    defp refused(path, opts \\ []) do
      assert {:error, {{:shutdown, {:failed_to_start_child, Store, reason}}, _spec}} =
               TestInstance.start([path: path] ++ opts)

      reason
    end

    test "unparseable", %{path: path} do
      File.write!(path, ~s({"version": 1, "resources": [))
      assert {:unparseable, _} = refused(path)
    end

    test "another version", %{path: path} do
      File.write!(path, ~s({"version": 99, "next_uid": 1, "resources": []}))
      assert refused(path) == {:unsupported_version, 99}
    end

    test "a resource of a kind nobody defined", %{path: path} do
      i = start!(path)
      {:ok, _} = Store.create(:thing, "t", %{}, i)
      {:ok, _} = Store.create(:part, "p", %{}, i)
      :ok = stop_supervised(i[:instance])

      File.write!(
        path,
        path |> File.read!() |> String.replace(~s("kind": "part"), ~s("kind": "ghost"))
      )

      assert refused(path) == {:unknown_kind, "ghost"}
    end

    test "unreadable", %{path: path} do
      File.mkdir_p!(path)
      assert refused(path) == {:unreadable, :eisdir}
    end

    test "a resource missing a field", %{path: path} do
      File.write!(
        path,
        ~s({"version": 1, "next_uid": 2, "resources": [{"kind": "thing", "name": "t"}]})
      )

      assert refused(path) == :malformed
    end

    test "no uid counter", %{path: path} do
      i = start!(path)
      {:ok, _} = Store.create(:thing, "t", %{}, i)
      :ok = stop_supervised(i[:instance])

      rewrite(path, &Map.delete(&1, "next_uid"))
      assert refused(path) == :malformed
    end

    test "something other than an object", %{path: path} do
      File.write!(path, "[]")
      assert refused(path) == :malformed
    end

    test "an owner reference of the wrong shape", %{path: path} do
      i = start!(path)
      {:ok, app} = Store.create(:thing, "app", %{}, i)
      {:ok, _} = Store.create(:part, "p", %{}, [owner_refs: [Resource.ref(app)]] ++ i)
      :ok = stop_supervised(i[:instance])

      rewrite(path, fn document ->
        Map.update!(document, "resources", fn resources ->
          Enum.map(resources, fn resource ->
            Map.update!(
              resource,
              "owner_refs",
              &Enum.map(&1, fn ref -> %{ref | "uid" => nil} end)
            )
          end)
        end)
      end)

      assert refused(path) == :malformed
    end

    test "an atom this build has never used", %{path: path} do
      i = start!(path)
      {:ok, _} = Store.create(:thing, "t", %{}, [finalizers: [:tidy]] ++ i)
      :ok = stop_supervised(i[:instance])

      File.write!(path, path |> File.read!() |> String.replace(":tidy", ":zz_not_an_atom_yet"))
      assert refused(path) == {:unknown_atom, "zz_not_an_atom_yet"}
    end

    # A store with one of each kind, stopped, and its file changed by `fun`,
    # which gets the `:thing` entry.
    defp tampered(path, fun) do
      i = start!(path)

      {:ok, _} =
        Store.create(:thing, "t", %{a: 1}, [writer: :ctl, finalizers: [:tidy]] ++ i)

      {:ok, _} = Store.create(:part, "p", %{}, i)
      :ok = stop_supervised(i[:instance])

      rewrite(path, fn document ->
        Map.update!(document, "resources", fn resources ->
          Enum.flat_map(resources, fn
            %{"kind" => "thing"} = thing -> List.wrap(fun.(thing))
            other -> [other]
          end)
        end)
      end)

      refused(path)
    end

    test "a spec that is not an object", %{path: path} do
      assert tampered(path, &%{&1 | "kind" => "part", "name" => "q", "spec" => nil}) ==
               :malformed
    end

    test "progress that is not an object", %{path: path} do
      assert tampered(path, &%{&1 | "kind" => "part", "name" => "q", "progress" => [1]}) ==
               :malformed
    end

    test "a finalizer listed twice", %{path: path} do
      assert tampered(path, &%{&1 | "finalizers" => [":tidy", ":tidy"]}) == :malformed
    end

    test "a deleting resource with no finalizer left", %{path: path} do
      assert tampered(path, &%{&1 | "deleting" => true, "finalizers" => []}) == :malformed
    end

    test "a uid or a generation that is not positive", %{path: path, tmp_dir: dir} do
      assert tampered(path, &%{&1 | "uid" => 0}) == :malformed
      other = Path.join(dir, "other.json")
      assert tampered(other, &%{&1 | "generation" => 0}) == :malformed
    end

    test "two resources of one name, or of one uid", %{path: path, tmp_dir: dir} do
      assert tampered(path, &[&1, %{&1 | "uid" => 9}]) == :malformed
      other = Path.join(dir, "other.json")
      assert tampered(other, &[&1, %{&1 | "name" => "twin"}]) == :malformed
    end

    test "an owned path that is empty, or owned by nobody", %{path: path, tmp_dir: dir} do
      owned = fn path, writer -> [%{"path" => path, "writer" => writer}] end

      assert tampered(path, &%{&1 | "managed_fields" => owned.([], ":ctl")}) == :malformed
      other = Path.join(dir, "other.json")
      assert tampered(other, &%{&1 | "managed_fields" => owned.([":a"], ":nil")}) == :malformed
    end

    test "a finalizer that is not an atom", %{path: path} do
      i = start!(path)
      {:ok, _} = Store.create(:thing, "t", %{}, [finalizers: [:tidy]] ++ i)
      :ok = stop_supervised(i[:instance])

      for finalizer <- ["tidy", 7] do
        rewrite(path, fn document ->
          Map.update!(document, "resources", fn [resource] ->
            [%{resource | "finalizers" => [finalizer]}]
          end)
        end)

        assert refused(path) == :malformed
      end
    end

    test "a kind whose decode hook raises", %{path: path} do
      i = start!(path)
      {:ok, _} = Store.create(:thing, "t", %{a: 1}, i)
      :ok = stop_supervised(i[:instance])

      raising = put_in(TestInstance.kinds(), [:thing, :decode_spec], fn _ -> raise "boom" end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert refused(path, kinds: raising) ==
                   {:hook_failed, :decode_spec, {:thing, "t"}, "boom"}
        end)

      assert log =~ "cannot start"
    end
  end

  describe "a store replaced while its file was ahead of ETS" do
    @describetag :capture_log

    setup %{path: path} do
      i = start!(path, persist: marked(fn -> exit(:kill) end))
      {:ok, _} = Store.create(:thing, "t", %{a: 1}, i)
      {:ok, _} = Store.patch_status(:thing, "t", %{instance: "c1"}, [writer: Owner] ++ i)
      :ok = Watch.subscribe({:object, :thing, "t"}, i)
      %{i: i}
    end

    test "a changed resource is taken from the file, keeps its status, and is announced",
         %{path: path, i: i} do
      mark(path)
      assert catch_exit(Store.update_spec(:thing, "t", %{a: 2}, i))

      assert_receive {Watch, :changed, %{name: "t", generation: 2}}, 1_000
      assert %Resource{spec: %{a: 2}, status: %{instance: "c1"}} = Store.get(:thing, "t", i)
    end

    test "a resource the file no longer has is removed and announced", %{path: path, i: i} do
      mark(path)
      assert catch_exit(Store.delete(:thing, "t", i))

      assert_receive {Watch, :removed, %{name: "t", uid: 1}}, 1_000
      assert Store.get(:thing, "t", i) == nil
    end

    test "a name the file gives another uid is the file's, without the old one's status",
         %{path: path, i: i} do
      mark(path)

      assert catch_exit(
               Store.commit([{:delete, :thing, "t"}, {:create, :thing, "t", %{a: 9}, []}], i)
             )

      assert_receive {Watch, :changed, %{name: "t", uid: 2}}, 1_000
      assert %Resource{uid: 2, spec: %{a: 9}, status: status} = Store.get(:thing, "t", i)
      assert status == %{}
    end

    test "nothing is announced when the file and ETS agree, and status stays", %{i: i} do
      before = Store.get(:thing, "t", i)

      TestInstance.restart_store(i[:instance])
      # The new store's answer follows anything it sent while starting.
      :ok = Store.relay([], nil, i)

      refute_received {Watch, _, _}
      assert Store.get(:thing, "t", i) == before
      assert before.status == %{instance: "c1"}
    end

    test "the uid counter is the highest of the file's, the table's and the uids",
         %{path: path, i: i} do
      {:ok, %{uid: 2}} = Store.create(:thing, "u", %{}, i)
      {:ok, _} = Store.delete(:thing, "u", i)
      supervisor = Module.concat(i[:instance], Supervisor)
      :ok = Supervisor.terminate_child(supervisor, Store)

      # Now only the table remembers that uid 2 was given out.
      rewrite(path, &Map.put(&1, "next_uid", 1))
      {:ok, _pid} = Supervisor.restart_child(supervisor, Store)

      assert {:ok, %{uid: 3}} = Store.create(:thing, "u", %{}, i)
    end
  end
end
