defmodule Vagus.Resource.Toys do
  @moduledoc """
  Controllers small enough to read at a glance, for exercising the runtime.
  Each acts on the harness's world, never on anything real, and takes its
  orders from facts the test puts there.
  """

  alias Vagus.Resource.Verdict

  @doc "Tells the test `message`, then waits for its `:go`."
  @spec parked(map(), term()) :: :ok
  def parked(context, message) do
    send(context.test, message)
    wait()
  end

  @doc "The effect that gives up `finalizer` on a resource still holding it."
  @spec release(Vagus.Resource.t(), atom()) :: [Vagus.Resource.Controller.effect()]
  def release(%{kind: kind, name: name, finalizers: finalizers}, finalizer) do
    if finalizer in finalizers, do: [{:remove_finalizer, kind, name, finalizer}], else: []
  end

  @doc "Waits for the test's `:go`, or for `{:fail, reason}`, which it returns as an error."
  @spec wait() :: :ok | {:error, term()}
  def wait do
    receive do
      :go -> :ok
      {:fail, reason} -> {:error, reason}
    end
  end

  @doc """
  Marks the calling step as inside `name` for as long as `fun` runs, and
  notes `{:overlap, name}` if another step already is.
  """
  @spec alone(map(), String.t(), (-> result)) :: result when result: var
  def alone(%{world: world} = context, name, fun) do
    key = {:inside, name}

    inside =
      Agent.get_and_update(
        world,
        &{&1.facts[key] || 0, put_in(&1.facts[key], (&1.facts[key] || 0) + 1)}
      )

    if inside > 0, do: Vagus.Resource.Harness.note(context, {:overlap, name})

    try do
      fun.()
    after
      Agent.update(world, &put_in(&1.facts[key], &1.facts[key] - 1))
    end
  end

  defmodule Probe do
    @moduledoc """
    Owns `:probe`. Wants the world to have seen `spec["n"]`, and visits to
    make it so; with `spec["lane"]` the visit is a `:fetch` in the `:pull`
    lane.

    Facts: `{:observe, name}` is `:block` (parks `observe/2` after telling
    the test `{:observing, name, pid}`) or `:raise`; `:engine` set to `:down`
    makes it unavailable, and with `:act_when_down` it asks for a visit even
    so, with a write to its spec; `{:act, name}` is `:block` (parks after
    `{:acting, name, n, pid}`, which every attempt sends, until `:go` or
    `{:fail, reason}`), `:raise` or `{:error, reason}`; `{:requeue, name}`
    is a delay to ask for once seen.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.{Harness, Toys}

    @impl true
    def kind, do: :probe
    @impl true
    def condition_types, do: [:ready, :progressing]
    @impl true
    def validate(spec), do: {:ok, Map.put_new(spec, "n", 1)}
    @impl true
    def action_class(:fetch), do: :pull
    def action_class(_other), do: nil

    @impl true
    def observe(%{name: name}, context) do
      case Harness.fact(context, {:observe, name}) do
        :block -> Toys.parked(context, {:observing, name, self()})
        :raise -> raise("probe #{name} was told not to look")
        nil -> :ok
      end

      if Harness.fact(context, :engine) == :down do
        {:unavailable,
         if(Harness.fact(context, :act_when_down), do: :acting_anyway, else: :engine_unavailable)}
      else
        %{
          seen: Harness.fact(context, {:seen, name}),
          failed: context.failed_action,
          requeue: Harness.fact(context, {:requeue, name})
        }
      end
    end

    @impl true
    def reconcile(%{name: name}, {:unavailable, :acting_anyway}) do
      {verdict(false, true, :engine_unavailable),
       [{:update_spec, :probe, name, %{"noted" => true}, []}, {:action, :visit, 0}]}
    end

    def reconcile(_probe, {:unavailable, reason}), do: {verdict(false, true, reason), []}

    def reconcile(%{spec: %{"n" => n} = spec, status: status, generation: generation}, observed) do
      cond do
        observed.failed ->
          gave_up = %{last_error: observed.failed.reason, gave_up: generation}
          {%{verdict(false, false, :action_failed) | status: gave_up}, []}

        # One failure is this toy's whole budget, until the spec changes.
        status[:gave_up] == generation ->
          {verdict(false, false, :action_failed), []}

        observed.seen == n ->
          {verdict(true, false, :seen),
           if(observed.requeue, do: [{:requeue_after, observed.requeue}], else: [])}

        true ->
          {verdict(false, true, :visiting),
           [{:action, if(spec["lane"], do: :fetch, else: :visit), n}]}
      end
    end

    defp verdict(ready?, progressing?, reason),
      do: Verdict.new(ready: {ready?, reason}, progressing: {progressing?, reason})

    @impl true
    def act(action, n, %{resource: %{name: name}} = context) when action in [:visit, :fetch] do
      send(context.test, {:acting, name, n, self()})

      case Harness.fact(context, {:act, name}) do
        {:error, _reason} = error ->
          error

        order ->
          if order == :raise, do: raise("probe #{name} was told to")

          with :ok <- if(order == :block, do: Toys.wait(), else: :ok) do
            Harness.record(context, {__MODULE__, name}, {action, n})
            Harness.put_fact(context, {:seen, name}, n)
          end
      end
    end
  end

  defmodule Kept do
    @moduledoc """
    Owns `:kept`, with a finalizer: makes something in the world for each
    resource and unmakes it before letting the resource go, once `Tagger`'s
    finalizer is off it. Entries under `spec["holds"]` belong to their
    writers. The
    fact `{:unmake, name}` set to `:block` parks the unmaking after telling
    the test `{:unmaking, name, pid}`.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.{Harness, Toys}

    @impl true
    def kind, do: :kept
    @impl true
    def condition_types, do: [:ready]
    @impl true
    def finalizer, do: :kept
    @impl true
    def writer_entries, do: [["holds"]]

    @impl true
    def observe(%{name: name}, context),
      do: %{made?: Harness.fact(context, {:made, name}) == true}

    @impl true
    def reconcile(%{deleting?: true, finalizers: finalizers} = kept, %{made?: made?}) do
      effects =
        cond do
          :tagged in finalizers -> []
          made? -> [{:action, :unmake, nil}]
          true -> Toys.release(kept, :kept)
        end

      {:no_verdict, effects}
    end

    def reconcile(_kept, %{made?: made?}) do
      {Verdict.new(ready: {made?, if(made?, do: :made, else: :making)}),
       if(made?, do: [], else: [{:action, :make, nil}])}
    end

    @impl true
    def act(action, nil, %{resource: %{name: name}} = context) when action in [:make, :unmake] do
      if action == :unmake and Harness.fact(context, {:unmake, name}) == :block,
        do: Toys.parked(context, {:unmaking, name, self()})

      Harness.record(context, {__MODULE__, name}, action)
      Harness.put_fact(context, {:made, name}, action == :make)
    end
  end

  defmodule Tagger do
    @moduledoc """
    Attached to `:kept`: tags each resource in the world, reports `:tagged`,
    and removes the tag before releasing its own finalizer. The fact
    `{:untag, name}` set to `:block` parks the untagging after telling the
    test `{:untagging, name, pid}`.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.{Harness, Toys}

    @impl true
    def kind, do: :kept
    @impl true
    def condition_types, do: [:tagged]
    @impl true
    def owned_conditions, do: [:tagged]
    @impl true
    def finalizer, do: :tagged

    @impl true
    def observe(%{name: name} = kept, context) do
      if kept.deleting?, do: Harness.note(context, {:tagger_saw_deleting, name})
      %{tagged?: Harness.fact(context, {:tag, name}) == true}
    end

    @impl true
    def reconcile(%{deleting?: true} = kept, %{tagged?: tagged?}) do
      {:no_verdict, if(tagged?, do: [{:action, :untag, nil}], else: Toys.release(kept, :tagged))}
    end

    def reconcile(_kept, %{tagged?: tagged?}) do
      {Verdict.new(tagged: {tagged?, if(tagged?, do: :tagged, else: :tagging)}),
       if(tagged?, do: [], else: [{:action, :tag, nil}])}
    end

    @impl true
    def act(action, nil, %{resource: %{name: name}} = context) when action in [:tag, :untag] do
      if action == :untag and Harness.fact(context, {:untag, name}) == :block,
        do: Toys.parked(context, {:untagging, name, self()})

      Harness.record(context, {__MODULE__, name}, action)
      Harness.put_fact(context, {:tag, name}, action == :tag)
    end
  end

  defmodule Linker do
    @moduledoc """
    Owns `:link`. Each link refers to the probe named in `spec["target"]`
    and reports that probe's `n` as `status.sees`. Notes every observation.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.{Harness, Store}

    @impl true
    def kind, do: :link
    @impl true
    def condition_types, do: [:ready]
    @impl true
    def references(%{spec: %{"target" => target}}), do: [{:probe, target}]

    @impl true
    def observe(%{name: name, spec: %{"target" => target}}, context) do
      Harness.note(context, {:link_observed, name})

      probe = Store.get(:probe, target, instance: context.instance)
      %{sees: probe && probe.spec["n"]}
    end

    @impl true
    def reconcile(_link, %{sees: sees}),
      do: {Verdict.new([ready: {sees != nil, :looked}], status: %{sees: sees}), []}

    @impl true
    def act(_action, _args, _context), do: :ok
  end

  defmodule Follower do
    @moduledoc """
    Owns `:follower`. Refers to the probe named in `spec["target"]`, notes
    the `n` it reads there as `{:followed, name, n}`, and writes nothing, so
    that nothing it does brings it back. With the fact `{:follow, name}` set
    to `:block` it parks after reading, having told the test `{:following,
    name, pid}`.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.{Harness, Store, Toys}

    @impl true
    def kind, do: :follower
    @impl true
    def condition_types, do: [:ready]
    @impl true
    def references(%{spec: %{"target" => target}}), do: [{:probe, target}]

    @impl true
    def observe(%{name: name, spec: %{"target" => target}}, context) do
      n = Store.get(:probe, target, instance: context.instance).spec["n"]

      if Harness.fact(context, {:follow, name}) == :block,
        do: Toys.parked(context, {:following, name, self()})

      Harness.note(context, {:followed, name, n})
    end

    @impl true
    def reconcile(_follower, _observed), do: {:no_verdict, []}
    @impl true
    def act(_action, _args, _context), do: :ok
  end

  defmodule OneShot do
    @moduledoc "Owns `:oneshot`: every resource is finished as soon as it is seen. Keeps two."
    @behaviour Vagus.Resource.Controller

    @impl true
    def kind, do: :oneshot
    @impl true
    def condition_types, do: [:done]
    @impl true
    def retention, do: %{keep: 2, ttl_ms: 100_000}
    @impl true
    def observe(_oneshot, _context), do: %{}
    @impl true
    def reconcile(_oneshot, _observed),
      do: {Verdict.new([done: {true, :done}], terminal?: true), []}

    @impl true
    def act(_action, _args, _context), do: :ok
  end

  defmodule Sloppy do
    @moduledoc "Owns `:sloppy` and declares two condition types, but reports only one."
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.Harness

    @impl true
    def kind, do: :sloppy
    @impl true
    def condition_types, do: [:ready, :progressing]
    @impl true
    def observe(%{name: name}, context),
      do: %{poked?: Harness.fact(context, {:poked, name}) == true}

    @impl true
    def reconcile(_sloppy, %{poked?: poked?}),
      do: {Verdict.new(ready: {true, :fine}), if(poked?, do: [], else: [{:action, :poke, nil}])}

    @impl true
    def act(:poke, nil, %{resource: %{name: name}} = context) do
      Harness.record(context, {__MODULE__, name}, :poke)
      Harness.put_fact(context, {:poked, name}, true)
    end
  end

  defmodule Batch do
    @moduledoc """
    Owns `:batch`. Each of its first two passes writes its spec, the first
    its progress too, and then marks the world; marked twice, it writes once
    more and is ready. Each mark notes the status it found.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.Harness

    @impl true
    def kind, do: :batch
    @impl true
    def condition_types, do: [:ready]
    @impl true
    def observe(%{name: name}, context), do: %{mark: Harness.fact(context, {:mark, name})}

    @impl true
    def reconcile(%{name: name}, %{mark: mark}) do
      put = &{:update_spec, :batch, name, %{&1 => true}, []}
      progress = {:put_progress, :batch, name, %{"phase" => "one"}, [writer: __MODULE__]}

      case mark do
        nil -> {marking(), [put.("a"), progress, {:action, :mark, 1}]}
        1 -> {marking(), [put.("b"), put.("c"), {:action, :mark, 2}]}
        2 -> {Verdict.new(ready: {true, :marked}), [put.("d")]}
      end
    end

    defp marking, do: Verdict.new(ready: {false, :marking})

    @impl true
    def act(:mark, n, %{resource: %{name: name}} = context) do
      status = Vagus.Resource.Store.get(:batch, name, instance: context.instance).status
      Harness.note(context, {:status_at_mark, n, status})
      Harness.record(context, {__MODULE__, name}, {:mark, n})
      Harness.put_fact(context, {:mark, name}, n)
    end
  end

  defmodule Scribe do
    @moduledoc """
    Owns `:scribe`. Writes one `:note` named after the uid of the resource
    it read; `observe/2` parks while the fact `:block_scribe` is set.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.{Harness, Store, Toys}

    @impl true
    def kind, do: :scribe
    @impl true
    def condition_types, do: [:ready]

    @impl true
    def observe(%{name: name, uid: uid}, context) do
      if Harness.fact(context, :block_scribe),
        do: Toys.parked(context, {:observing, name, self()})

      %{noted?: Store.get(:note, "by-#{uid}", instance: context.instance) != nil}
    end

    @impl true
    def reconcile(_scribe, %{noted?: true}), do: {Verdict.new(ready: {true, :noted}), []}

    def reconcile(%{uid: uid}, %{noted?: false}),
      do: {Verdict.new(ready: {false, :noting}), [{:create, :note, "by-#{uid}", %{}, []}]}

    @impl true
    def act(_action, _args, _context), do: :ok
  end

  defmodule Atomic do
    @moduledoc "Owns `:atomic`, whose spec has atom keys and so needs the codec hooks."
    @behaviour Vagus.Resource.Controller

    @impl true
    def kind, do: :atomic
    @impl true
    def condition_types, do: [:ready]
    @impl true
    def validate(%{mode: mode} = spec) when mode in [:on, :off], do: {:ok, spec}
    def validate(_spec), do: {:error, :no_mode}
    @impl true
    def encode_spec(%{mode: mode}), do: %{"mode" => Atom.to_string(mode)}
    @impl true
    def decode_spec(%{"mode" => mode}), do: %{mode: String.to_existing_atom(mode)}
    @impl true
    def observe(_atomic, _context), do: %{}
    @impl true
    def reconcile(%{spec: %{mode: mode}}, _observed),
      do: {Verdict.new(ready: {mode == :on, mode}), []}

    @impl true
    def act(_action, _args, _context), do: :ok
  end

  defmodule Stubborn do
    @moduledoc "Owns `:stubborn`: tries the same failing action on every pass and reports nothing."
    @behaviour Vagus.Resource.Controller

    @impl true
    def kind, do: :stubborn
    @impl true
    def condition_types, do: [:ready]
    @impl true
    def observe(_stubborn, _context), do: %{}
    @impl true
    def reconcile(_stubborn, _observed), do: {:no_verdict, [{:action, :try, nil}]}
    @impl true
    def act(:try, nil, _context), do: {:error, :never}
  end

  defmodule Stall do
    @moduledoc """
    Owns `:stall`. Every pass parks in `observe/2`, having told the test
    `{:stalled, name, pid}`, and once let go crashes in its action.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.Toys

    @impl true
    def kind, do: :stall
    @impl true
    def condition_types, do: [:ready]
    @impl true
    def observe(%{name: name}, context), do: Toys.parked(context, {:stalled, name, self()})
    @impl true
    def reconcile(_stall, _observed), do: {:no_verdict, [{:action, :fall, nil}]}
    @impl true
    def act(:fall, nil, _context), do: raise("as it always does")
  end

  defmodule Wild do
    @moduledoc """
    Owns `:wild`, and misbehaves as its spec says. `"refs"`: `"exit"` exits
    in `references/1`, `"hang"` never returns from it, `"self"` refers to
    itself. `"effect"`: `"refused"` writes to a resource that is not there,
    `"bad_act"` has an action return nonsense, `"non_effect"` returns a
    status write, `"two_actions"` and `"op_after_action"` return what their
    names say, each with a write to the spec, `"nil_action"` an action with no name, `"op_after_requeue"` an action,
    a re-queue and then a write, `"no_pair"` returns no pair at all,
    `"expect_generation"` expects a generation the resource does not have,
    `"requeue_after_action"` returns a `:fine` action, which tells the test
    `{:fine, name}`, and then a re-queue, `"requeues"` asks to be looked at
    after three delays, `"noop"` writes what is already there.
    """
    @behaviour Vagus.Resource.Controller

    @impl true
    def kind, do: :wild
    @impl true
    def condition_types, do: [:ready]

    @impl true
    def references(%{name: name, spec: spec}) do
      case spec["refs"] do
        "exit" -> GenServer.call(:"no process has this name", :anything)
        "hang" -> Process.sleep(:infinity)
        "self" -> [{:wild, name}, {:probe, "elsewhere"}]
        nil -> []
      end
    end

    @impl true
    def observe(_wild, _context), do: %{}

    @impl true
    def reconcile(%{spec: %{"effect" => "no_pair"}}, _observed), do: :nothing

    def reconcile(%{name: name, spec: spec}, _observed) do
      written = {:update_spec, :wild, name, %{"written" => true}, []}
      nonsense = {:action, :nonsense, nil}

      effects =
        case spec["effect"] do
          "refused" -> [{:update_spec, :wild, name <> "-missing", %{}, []}]
          "bad_act" -> [nonsense]
          "non_effect" -> [written, {:status, %{}}]
          "two_actions" -> [written, nonsense, nonsense]
          "op_after_action" -> [nonsense, written]
          "nil_action" -> [written, {:action, nil, nil}]
          "op_after_requeue" -> [nonsense, {:requeue_after, 5}, written]
          "expect_generation" -> [{:expect, :wild, name, generation: 99}]
          "requeue_after_action" -> [{:action, :fine, nil}, {:requeue_after, 600_000}]
          "requeues" -> for(ms <- [600_000, 300_000, 900_000], do: {:requeue_after, ms})
          "noop" -> noop(name)
          nil -> []
        end

      {Verdict.new(ready: {true, :fine}), effects}
    end

    # Three ops that the store accepts and that change nothing.
    defp noop(name) do
      [
        {:expect, :wild, name, []},
        {:update_spec, :wild, name, %{"effect" => "noop"}, []},
        {:release_writer, :wild, name, :nobody}
      ]
    end

    @impl true
    def act(:nonsense, nil, _context), do: :done

    def act(:fine, nil, %{resource: %{name: name}} = context) do
      send(context.test, {:fine, name})
      :ok
    end
  end

  defmodule Solo do
    @moduledoc """
    Owns `:solo`. Notes `{:overlap, name}` if two of its steps are ever
    inside `observe/2` or `act/3` for one resource at once. The fact
    `{:observe, name}` set to `:block` parks `observe/2` after telling the
    test `{:observing, name, pid}`.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.{Harness, Toys}

    @impl true
    def kind, do: :solo
    @impl true
    def condition_types, do: [:ready]

    @impl true
    def observe(%{name: name}, context) do
      Toys.alone(context, name, fn ->
        if Harness.fact(context, {:observe, name}) == :block,
          do: Toys.parked(context, {:observing, name, self()})

        %{seen: Harness.fact(context, {:seen, name})}
      end)
    end

    @impl true
    def reconcile(%{spec: spec}, %{seen: seen}) do
      n = Map.get(spec, "n", 0)

      {Verdict.new(ready: {seen == n, :caught_up}),
       if(seen == n, do: [], else: [{:action, :catch_up, n}])}
    end

    @impl true
    def act(:catch_up, n, %{resource: %{name: name}} = context) do
      Toys.alone(context, name, fn ->
        :erlang.yield()
        Harness.put_fact(context, {:seen, name}, n)
      end)
    end
  end

  defmodule Flaky do
    @moduledoc "Owns `:flaky`: every pass reports one more attempt in status, then crashes in its action."
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.Harness

    @impl true
    def kind, do: :flaky
    @impl true
    def condition_types, do: [:ready]

    @impl true
    def observe(%{name: name}, context),
      do: %{attempts: Harness.fact(context, {:attempts, name}) || 0}

    @impl true
    def reconcile(_flaky, %{attempts: attempts}) do
      {Verdict.new([ready: {false, :trying}], status: %{attempt: attempts + 1}),
       [{:action, :explode, nil}]}
    end

    @impl true
    def act(:explode, nil, %{resource: %{name: name}} = context) do
      attempts = Harness.fact(context, {:attempts, name}) || 0
      Harness.put_fact(context, {:attempts, name}, attempts + 1)
      raise "flaky #{name} exploded"
    end
  end

  defmodule Idle do
    @moduledoc """
    Owns `:idle`: every pass nudges, with an argument that differs each
    time, and decides nothing from what the nudge changed. With the fact
    `:engine` set to `:down` it cannot observe, and asks to be looked at
    again after `spec["requeue"]`, if that is set.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.Harness

    @impl true
    def kind, do: :idle
    @impl true
    def condition_types, do: [:ready]

    @impl true
    def observe(%{name: name}, context) do
      if Harness.fact(context, :engine) == :down,
        do: {:unavailable, :engine_unavailable},
        else: %{nudges: Harness.fact(context, {:nudges, name}) || 0}
    end

    @impl true
    def reconcile(%{spec: spec}, {:unavailable, _reason}),
      do: {:no_verdict, for(ms <- List.wrap(spec["requeue"]), do: {:requeue_after, ms})}

    def reconcile(_idle, %{nudges: nudges}), do: {:no_verdict, [{:action, :nudge, nudges}]}

    @impl true
    def act(:nudge, nudges, %{resource: %{name: name}} = context) do
      Harness.record(context, {__MODULE__, name}, :nudge)
      Harness.put_fact(context, {:nudges, name}, nudges + 1)
    end
  end

  defmodule Spinner do
    @moduledoc """
    Owns `:spinner`: every pass acts, under a name that alternates so that
    no pass repeats the one before, and tells the test `{:spun, name}`. It
    comes to rest only once the fact `:stop` is set.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.Harness

    @impl true
    def kind, do: :spinner
    @impl true
    def condition_types, do: [:ready]

    @impl true
    def observe(%{name: name}, context) do
      %{turns: Harness.fact(context, {:turns, name}) || 0, stop?: Harness.fact(context, :stop)}
    end

    @impl true
    def reconcile(_spinner, %{stop?: true}), do: {:no_verdict, []}

    def reconcile(_spinner, %{turns: turns}),
      do: {:no_verdict, [{:action, if(rem(turns, 2) == 0, do: :tick, else: :tock), turns}]}

    @impl true
    def act(_tick_or_tock, turns, %{resource: %{name: name}} = context) do
      send(context.test, {:spun, name})
      Harness.put_fact(context, {:turns, name}, turns + 1)
    end
  end

  defmodule Finisher do
    @moduledoc """
    Owns `:finisher`: every resource is finished as soon as it is seen, and
    is swept once, which is an action. Keeps one.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.Harness

    @impl true
    def kind, do: :finisher
    @impl true
    def condition_types, do: [:done]
    @impl true
    def retention, do: %{keep: 1, ttl_ms: :infinity}

    @impl true
    def observe(%{name: name}, context),
      do: %{swept?: Harness.fact(context, {:swept, name}) == true}

    @impl true
    def reconcile(_finisher, %{swept?: swept?}) do
      {Verdict.new([done: {true, :done}], terminal?: true),
       if(swept?, do: [], else: [{:action, :sweep, nil}])}
    end

    @impl true
    def act(:sweep, nil, %{resource: %{name: name}} = context) do
      Harness.record(context, {__MODULE__, name}, :sweep)
      Harness.put_fact(context, {:swept, name}, true)
    end
  end

  defmodule Mute do
    @moduledoc "Owns `:mute` and never reports anything."
    @behaviour Vagus.Resource.Controller

    @impl true
    def kind, do: :mute
    @impl true
    def condition_types, do: [:ready]
    @impl true
    def retention, do: %{keep: 5, ttl_ms: :infinity}
    @impl true
    def observe(_mute, _context), do: %{}
    @impl true
    def reconcile(_mute, _observed), do: {:no_verdict, []}
    @impl true
    def act(_action, _args, _context), do: :ok
  end

  defmodule Echo do
    @moduledoc """
    Attached to `:mute`, reports `:heard`. With `spec["nosy"]` its verdict
    also carries status, which is not an attached controller's to report.
    """
    @behaviour Vagus.Resource.Controller

    @impl true
    def kind, do: :mute
    @impl true
    def condition_types, do: [:heard]
    @impl true
    def owned_conditions, do: [:heard]
    @impl true
    def observe(_mute, _context), do: %{}

    @impl true
    def reconcile(%{spec: %{"nosy" => true}}, _observed),
      do: {Verdict.new([heard: {true, :loud}], status: %{instance: "mine"}), []}

    def reconcile(_mute, _observed), do: {Verdict.new(heard: {true, :loud}), []}
    @impl true
    def act(_action, _args, _context), do: :ok
  end

  defmodule Clasher do
    @moduledoc "Attached to `:kept`, and declares the condition its owner declares."
    @behaviour Vagus.Resource.Controller

    @impl true
    def kind, do: :kept
    @impl true
    def condition_types, do: [:ready]
    @impl true
    def owned_conditions, do: [:ready]
    @impl true
    def observe(_kept, _context), do: %{}
    @impl true
    def reconcile(_kept, _observed), do: {:no_verdict, []}
    @impl true
    def act(_action, _args, _context), do: :ok
  end

  defmodule Grabber do
    @moduledoc "Attached to `:kept`, and declares the finalizer its owner declares."
    @behaviour Vagus.Resource.Controller

    @impl true
    def kind, do: :kept
    @impl true
    def condition_types, do: [:grabbed]
    @impl true
    def owned_conditions, do: [:grabbed]
    @impl true
    def finalizer, do: :kept
    @impl true
    def observe(_kept, _context), do: %{}
    @impl true
    def reconcile(_kept, _observed), do: {:no_verdict, []}
    @impl true
    def act(_action, _args, _context), do: :ok
  end

  defmodule Broken do
    @moduledoc "Owns `:broken`, and raises when asked what it retains."
    @behaviour Vagus.Resource.Controller

    @impl true
    def kind, do: :broken
    @impl true
    def condition_types, do: [:ready]
    @impl true
    def retention, do: raise("no idea")
    @impl true
    def observe(_broken, _context), do: %{}
    @impl true
    def reconcile(_broken, _observed), do: {:no_verdict, []}
    @impl true
    def act(_action, _args, _context), do: :ok
  end

  defmodule Sticky do
    @moduledoc """
    Owns `:sticky`. Every pass nudges, and refers to the probe named in
    `spec["target"]`; with `spec["fail"]` the nudge fails. Notes the failed
    action each pass is told of as `{:told, name, failed_action}`.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.Harness

    @impl true
    def kind, do: :sticky
    @impl true
    def condition_types, do: [:ready]
    @impl true
    def references(%{spec: %{"target" => target}}), do: [{:probe, target}]

    @impl true
    def observe(%{name: name}, context),
      do: Harness.note(context, {:told, name, context.failed_action})

    @impl true
    def reconcile(%{spec: spec}, _observed),
      do: {:no_verdict, [{:action, :nudge, spec["fail"] == true}]}

    @impl true
    def act(:nudge, fail?, _context), do: if(fail?, do: {:error, :stuck}, else: :ok)
  end

  defmodule Shapeless do
    @moduledoc """
    Declares whatever the calling process has put under `{Shapeless,
    callback}`, and something well-formed otherwise.
    """
    @behaviour Vagus.Resource.Controller

    defp said(callback, otherwise), do: Process.get({__MODULE__, callback}, otherwise)

    @impl true
    def kind, do: said(:kind, :shapeless)
    @impl true
    def condition_types, do: said(:condition_types, [:ready])
    @impl true
    def retention, do: said(:retention, %{keep: 1, ttl_ms: :infinity})
    @impl true
    def finalizer, do: said(:finalizer, :shapeless)
    @impl true
    def writer_entries, do: said(:writer_entries, [["holds"]])
    @impl true
    def observe(_shapeless, _context), do: %{}
    @impl true
    def reconcile(_shapeless, _observed), do: {:no_verdict, []}
    @impl true
    def act(_action, _args, _context), do: :ok
  end

  defmodule Bare do
    @moduledoc "Owns `:bare`, and declares its condition type as an atom where a list is due."
    @behaviour Vagus.Resource.Controller

    @impl true
    def kind, do: :bare
    @impl true
    def condition_types, do: :ready
    @impl true
    def observe(_bare, _context), do: %{}
    @impl true
    def reconcile(_bare, _observed), do: {:no_verdict, []}
    @impl true
    def act(_action, _args, _context), do: :ok
  end

  defmodule Twisted do
    @moduledoc """
    Owns `:twisted`, and is wrong on purpose in the way `spec["twist"]`
    says. Its first pass marks its spec and does `:a`, its second does `:b`.
    A pass that finds the mark and `:a` not done can only come after an
    interruption between that commit and its action, and does not carry on
    as it should: `"missing"` skips `:a`, `"extra"` does a `:repair` first,
    `"reorder"` does `:b` before `:a`. The store ends the same every time.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.Harness

    @impl true
    def kind, do: :twisted
    @impl true
    def condition_types, do: [:ready]

    @impl true
    def observe(%{name: name}, context),
      do: Map.new([:a, :b, :repair], &{&1, Harness.fact(context, {&1, name}) == true})

    @impl true
    def reconcile(%{name: name, spec: %{"twist" => twist} = spec}, done) do
      next =
        cond do
          done.b and (done.a or twist != "reorder") -> nil
          done.b -> :a
          done.a -> :b
          spec["marked"] != true -> :a
          twist == "extra" and not done.repair -> :repair
          twist == "extra" -> :a
          twist in ["missing", "reorder"] -> :b
        end

      mark = [{:update_spec, :twisted, name, %{"marked" => true}, []}]

      {Verdict.new(ready: {next == nil, :twisting}),
       if(next, do: mark ++ [{:action, next, nil}], else: [])}
    end

    @impl true
    def act(action, nil, %{resource: %{name: name}} = context) do
      Harness.record(context, {__MODULE__, name}, action)
      Harness.put_fact(context, {action, name}, true)
    end
  end

  defmodule Forgetful do
    @moduledoc """
    Owns `:forgetful`, and is wrong on purpose: what it takes for proof
    that its action ran is kept under its runtime's pid, so a replacement
    runtime observes nothing done and does it again.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.{Harness, Runtime}

    defp done(name, context),
      do: {:done, name, Process.whereis(Runtime.name(context.instance, __MODULE__))}

    @impl true
    def kind, do: :forgetful
    @impl true
    def condition_types, do: [:ready]
    @impl true
    def observe(%{name: name}, context), do: Harness.fact(context, done(name, context)) == true

    @impl true
    def reconcile(_forgetful, done?),
      do: {Verdict.new(ready: {done?, :doing}), if(done?, do: [], else: [{:action, :do, nil}])}

    @impl true
    def act(:do, nil, %{resource: %{name: name}} = context) do
      Harness.record(context, {__MODULE__, name}, :do)
      Harness.put_fact(context, done(name, context), true)
    end
  end

  defmodule Gated do
    @moduledoc """
    Owns `:gated`. Its action is in two parts, the doing and what makes it
    observable, and for a resource with a process under the fact
    `{:gate, name}` it waits between the two until that process is gone,
    having told the test `{:inside, name}`.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.Harness

    @impl true
    def kind, do: :gated
    @impl true
    def condition_types, do: [:ready]
    @impl true
    def observe(%{name: name}, context), do: Harness.fact(context, {:done, name}) == true

    @impl true
    def reconcile(_gated, done?),
      do: {Verdict.new(ready: {done?, :doing}), if(done?, do: [], else: [{:action, :do, nil}])}

    @impl true
    def act(:do, nil, %{resource: %{name: name}} = context) do
      Harness.record(context, {__MODULE__, name}, :do)

      if gate = Harness.fact(context, {:gate, name}) do
        send(context.test, {:inside, name})
        monitor = Process.monitor(gate)

        receive do
          {:DOWN, ^monitor, :process, ^gate, _reason} -> :ok
        end
      end

      Harness.put_fact(context, {:done, name}, true)
    end
  end

  defmodule Copycat do
    @moduledoc """
    Owns `:copycat`. Copies once for every try `Fragile` has counted in the
    resource named in `spec["target"]`, so it does twice what `Fragile`
    counted twice.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.{Harness, Store}

    @impl true
    def kind, do: :copycat
    @impl true
    def condition_types, do: [:ready]
    @impl true
    def references(%{spec: %{"target" => target}}), do: [{:fragile, target}]

    @impl true
    def observe(%{name: name, spec: %{"target" => target}}, context) do
      fragile = Store.get(:fragile, target, instance: context.instance)

      %{
        tries: (fragile && fragile.spec["tries"]) || 0,
        copied: Harness.fact(context, {:copied, name}) || 0
      }
    end

    @impl true
    def reconcile(_copycat, %{tries: tries, copied: copied}) do
      {Verdict.new(ready: {copied == tries, :copying}),
       if(copied < tries, do: [{:action, :copy, copied + 1}], else: [])}
    end

    @impl true
    def act(:copy, n, %{resource: %{name: name}} = context) do
      Harness.record(context, {__MODULE__, name}, :copy)
      Harness.put_fact(context, {:copied, name}, n)
    end
  end

  defmodule Fragile do
    @moduledoc """
    Owns `:fragile`, and is wrong on purpose: the pass that acts counts
    itself in the spec, in the commit before the action. Interrupted between
    the two, the pass is made again and counts again.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.Harness

    @impl true
    def kind, do: :fragile
    @impl true
    def condition_types, do: [:ready]

    @impl true
    def observe(%{name: name}, context),
      do: %{done?: Harness.fact(context, {:done, name}) == true}

    @impl true
    def reconcile(_fragile, %{done?: true}), do: {Verdict.new(ready: {true, :done}), []}

    def reconcile(%{name: name}, %{done?: false}) do
      {Verdict.new(ready: {false, :trying}),
       [{:update_spec, :fragile, name, [{:inc, ["tries"]}], []}, {:action, :count, nil}]}
    end

    @impl true
    def act(:count, nil, %{resource: %{name: name}} = context) do
      Harness.record(context, {__MODULE__, name}, :count)
      Harness.put_fact(context, {:done, name}, true)
    end
  end
end
