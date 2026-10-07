defmodule Vagus.Resource.ControllerTest do
  use ExUnit.Case, async: true

  import Vagus.Resource.Harness

  alias Vagus.Resource
  alias Vagus.Resource.{Controller, Kind, Stamp, Store, Verdict}
  alias Vagus.Resource.Toys.{Atomic, Clasher, Kept, OneShot, Probe, Tagger}

  defmodule Rival do
    @moduledoc "A second owner of `:kept`."
    @behaviour Vagus.Resource.Controller
    def kind, do: :kept
    def condition_types, do: []
    def observe(_resource, _context), do: nil
    def reconcile(_resource, _observed), do: {:no_verdict, []}
    def act(_action, _args, _context), do: :ok
  end

  defmodule Vague do
    @moduledoc "Declares condition types that are not atoms."
    @behaviour Vagus.Resource.Controller
    def kind, do: :vague
    def condition_types, do: ["ready"]
    def observe(_resource, _context), do: nil
    def reconcile(_resource, _observed), do: {:no_verdict, []}
    def act(_action, _args, _context), do: :ok
  end

  defmodule Chatty do
    @moduledoc "Returns what the resource it is given says, as its effects."
    @behaviour Vagus.Resource.Controller
    def kind, do: :chatty
    def condition_types, do: [:ready]
    def observe(_resource, _context), do: nil
    def act(_action, _args, _context), do: :ok

    def reconcile(%{name: name}, _observed) do
      op = {:delete, :chatty, name}
      act = {:action, :say, nil}

      effects =
        case name do
          "status" -> [{:status, %{count: 1}}]
          "twice" -> [op, act, {:requeue_after, 5}, act]
          "after" -> [act, op]
          "fine" -> [{:requeue_after, 5}, op, act, {:requeue_after, 9}]
        end

      {Verdict.new(ready: {true, :ok}), effects}
    end
  end

  describe "the kinds derived from controllers" do
    test "an owner gives its kind its validator, its codec and every controller's finalizer" do
      assert %{kept: %Kind{} = kept, atomic: %Kind{} = atomic} =
               Controller.kinds([Kept, Tagger, Atomic])

      assert kept.finalizers == [:kept, :tagged]
      assert kept.owner == Kept
      assert kept.conditions == %{ready: Kept, tagged: Tagger}
      assert kept.writer_entries == [["holds"]]
      assert kept.validators == []
      assert kept.encode_spec.(%{a: 1}) == %{a: 1}

      assert [validate] = atomic.validators
      assert validate.(%{mode: :on}) == {:ok, %{mode: :on}}
      assert atomic.encode_spec.(%{mode: :on}) == %{"mode" => "on"}
      assert atomic.decode_spec.(%{"mode" => "on"}) == %{mode: :on}
      assert atomic.finalizers == []
      assert {atomic.owner, atomic.conditions} == {Atomic, %{ready: Atomic}}
    end

    test "two owners of one kind, or an attachment to a kind nobody owns, cannot start" do
      assert_raise ArgumentError, ~r/both own kind :kept/, fn ->
        Controller.kinds([Kept, Rival])
      end

      assert_raise ArgumentError, ~r/which no controller owns/, fn ->
        Controller.kinds([Tagger])
      end
    end

    test "one condition type declared twice on a kind, or types that are not atoms, cannot start" do
      assert_raise ArgumentError,
                   ~r/Kept and Vagus.Resource.Toys.Clasher both declare condition :ready on kind :kept/,
                   fn -> Controller.kinds([Kept, Clasher]) end

      assert_raise ArgumentError,
                   ~r/Vague.condition_types\/0 returned \["ready"\], not a list of atoms/,
                   fn ->
                     Controller.kinds([Vague])
                   end
    end

    test "a controller listed twice counts once" do
      assert %{kept: %Kind{finalizers: [:kept, :tagged]}} =
               Controller.kinds([Kept, Tagger, Tagger, Kept])
    end

    @tag :tmp_dir
    test "a spec with atoms is stored and read back through its controller's hooks",
         %{tmp_dir: dir} do
      path = Path.join(dir, "resources.json")
      sys = start_system(controllers: [Atomic], path: path)

      assert {:error, {:invalid, :no_mode}} = Store.create(:atomic, "a", %{}, sys.i)
      given_ready(sys, {:atomic, "a", %{mode: :on}})
      stop_system(sys)

      again = start_system(controllers: [Atomic], path: path)
      assert %Resource{spec: %{mode: :on}} = Store.get(:atomic, "a", again.i)
      await!(again, :atomic, "a", :ready)
    end
  end

  describe "a verdict" do
    test "is refused unless it has exactly the declared condition types" do
      full = Verdict.new(ready: {true, :ok}, progressing: {false, :ok, "nothing to do"})
      assert Verdict.problems(full, [:ready, :progressing], true) == []

      assert Verdict.problems(Verdict.new(ready: {true, :ok}), [:ready, :progressing], true) ==
               [missing: :progressing]

      assert Verdict.problems(full, [:ready], true) == [undeclared: :progressing]

      assert Verdict.problems(Verdict.new(ready: {:yes, :ok}), [:ready], true) == [
               bad_outcome: :ready
             ]

      assert Verdict.problems(%{conditions: %{}}, [], true) == [:not_a_verdict]
    end

    test "cannot carry what the runtime stamps, nor, from an attached controller, other status" do
      stamped = Verdict.new([ready: {true, :ok}], status: %{observed_generation: 9, finished: 1})

      assert Verdict.problems(stamped, [:ready], true) ==
               [reserved: :observed_generation, reserved: :finished]

      diary = Verdict.new([ready: {true, :ok}], status: %{count: 1})
      assert Verdict.problems(diary, [:ready], true) == []
      assert Verdict.problems(diary, [:ready], false) == [:status_not_owned]

      terminal = Verdict.new([ready: {true, :ok}], terminal?: true)
      assert Verdict.problems(terminal, [:ready], false) == [:terminal_not_owned]
    end

    test "with a terminal? that is not a boolean is refused, not crashed on" do
      for terminal? <- [nil, :yes, 1] do
        verdict = %{Verdict.new(ready: {true, :ok}) | terminal?: terminal?}
        assert Verdict.problems(verdict, [:ready], true) == [:bad_terminal]
      end
    end

    test "becomes conditions marked with the generation it is about" do
      verdict = Verdict.new(ready: {false, :pulling, "3 of 9"}, failed: {false, :none})

      assert Verdict.conditions(verdict, 4) == [
               Resource.condition(:failed, false, :none, 4),
               Resource.condition(:ready, false, :pulling, 4, "3 of 9")
             ]
    end
  end

  describe "an effect" do
    test "is an action, a timed re-queue, or a store op of a known shape" do
      for effect <- [
            {:action, :pull, %{image: "x"}},
            {:requeue_after, 0},
            {:create, :note, "n", %{}, [owner_refs: []]},
            {:update_spec, :app, "a", %{"run" => true}, []},
            {:update_spec, :app, "a", [{:release, ["version"]}], [writer: Probe]},
            {:put_progress, :update, "u", %{}, [writer: Probe]},
            {:add_finalizer, :app, "a", :dns},
            {:remove_finalizer, :app, "a", :dns},
            {:release_writer, :app, "a", {:update, "u", 3}},
            {:expect, :app, "a", [generation: 2]},
            {:delete, :app, "a"}
          ] do
        assert Controller.effect?(effect), inspect(effect)
      end
    end

    test "is never a status write, nor a tuple that only looks like an op" do
      for effect <- [
            {:status, %{}},
            {:patch_status, :app, "a", %{conditions: []}, [writer: Probe]},
            {:patch_status, :app, "a", %{observed_generation: 9}, []},
            {:anything, :app, "a"},
            {:delete, :app, :a},
            {:delete, "app", "a"},
            {:create, :note, "n", [], []},
            {:update_spec, :app, "a", %{}},
            {:remove_finalizer, :app, "a", "dns"},
            {:requeue_after, -1},
            {:action, "pull", nil},
            :delete
          ] do
        refute Controller.effect?(effect), inspect(effect)
      end
    end
  end

  describe "the verdict contract" do
    test "holds for every row of each toy controller" do
      probe = resource(:probe, "p", %{"n" => 2})
      failed = %{name: :visit, args: 2, reason: :boom, at: %Stamp{incarnation: 1, at: 0}}

      assert_verdict_contract(Probe, [
        {probe, {:unavailable, :engine_unavailable}},
        {probe, %{seen: nil, failed: nil, requeue: nil}},
        {probe, %{seen: 2, failed: nil, requeue: 50}},
        {probe, %{seen: nil, failed: failed, requeue: nil}},
        {%{probe | status: %{gave_up: 1}}, %{seen: nil, failed: nil, requeue: nil}}
      ])

      kept = resource(:kept, "k", %{})

      assert_verdict_contract(Kept, [
        {kept, %{made?: false}},
        {kept, %{made?: true}},
        {%{kept | deleting?: true}, %{made?: true}, :no_verdict}
      ])

      assert_verdict_contract(Tagger, [{kept, %{tagged?: false}}, {kept, %{tagged?: true}}])
      assert_verdict_contract(OneShot, [{resource(:oneshot, "o", %{}), %{}}])
    end

    test "catches a controller that reports a subset, and one that returns a status effect" do
      assert_raise ExUnit.AssertionError, ~r/must report \[:progressing, :ready\]/, fn ->
        assert_verdict_contract(Vagus.Resource.Toys.Sloppy, [
          {resource(:sloppy, "s", %{}), %{poked?: true}}
        ])
      end

      assert_raise ExUnit.AssertionError, ~r/non-effect/, fn ->
        assert_verdict_contract(Chatty, [{resource(:chatty, "status", %{}), nil}])
      end
    end

    test "catches a second action and an op after the action, wherever a re-queue stands" do
      for name <- ["twice", "after"] do
        assert_raise ExUnit.AssertionError, ~r/more than one action, or an op after/, fn ->
          assert_verdict_contract(Chatty, [{resource(:chatty, name, %{}), nil}])
        end
      end

      assert_verdict_contract(Chatty, [{resource(:chatty, "fine", %{}), nil}])
    end
  end
end
