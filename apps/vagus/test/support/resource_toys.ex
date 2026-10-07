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

  @spec wait() :: :ok
  def wait do
    receive do
      :go -> :ok
    end
  end

  defmodule Probe do
    @moduledoc """
    Owns `:probe`. Wants the world to have seen `spec["n"]`, and visits to
    make it so; with `spec["lane"]` the visit is a `:fetch` in the `:pull`
    lane.

    Facts: `{:observe, name}` is `:block` (parks `observe/2` after telling
    the test `{:observing, name, pid}`) or `:raise`; `:engine` set to `:down`
    makes it unavailable; `{:act, name}` is `:block` (parks after `{:acting, name, n,
    pid}`, which every attempt sends), `:raise` or `{:error, reason}`;
    `{:requeue, name}` is a delay to ask for once seen.
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
    def priority(%{spec: spec}), do: Map.get(spec, "priority", 0)
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
        {:unavailable, :engine_unavailable}
      else
        %{
          seen: Harness.fact(context, {:seen, name}),
          failed: context.failed_action,
          requeue: Harness.fact(context, {:requeue, name})
        }
      end
    end

    @impl true
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
          if order == :block, do: Toys.wait()
          Harness.record(context, {:probe, name}, {action, n})
          Harness.put_fact(context, {:seen, name}, n)
      end
    end
  end

  defmodule Kept do
    @moduledoc """
    Owns `:kept`, with a finalizer: makes something in the world for each
    resource and unmakes it before letting the resource go, after `Tagger`
    has let go. Entries under `spec["holds"]` belong to their writers. The
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
    def finalize_after, do: [:tagged]
    @impl true
    def writer_entries, do: [["holds"]]

    @impl true
    def observe(%{name: name}, context),
      do: %{made?: Harness.fact(context, {:made, name}) == true}

    @impl true
    def reconcile(%{deleting?: true, name: name}, %{made?: made?}) do
      {:no_verdict,
       if(made?, do: [{:action, :unmake, nil}], else: [{:remove_finalizer, :kept, name, :kept}])}
    end

    def reconcile(_kept, %{made?: made?}) do
      {Verdict.new(ready: {made?, if(made?, do: :made, else: :making)}),
       if(made?, do: [], else: [{:action, :make, nil}])}
    end

    @impl true
    def act(action, nil, %{resource: %{name: name}} = context) when action in [:make, :unmake] do
      if action == :unmake and Harness.fact(context, {:unmake, name}) == :block,
        do: Toys.parked(context, {:unmaking, name, self()})

      Harness.record(context, {:kept, name}, action)
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
    def reconcile(%{deleting?: true, name: name}, %{tagged?: tagged?}) do
      {:no_verdict,
       if(tagged?,
         do: [{:action, :untag, nil}],
         else: [{:remove_finalizer, :kept, name, :tagged}]
       )}
    end

    def reconcile(_kept, %{tagged?: tagged?}) do
      {Verdict.new(tagged: {tagged?, if(tagged?, do: :tagged, else: :tagging)}),
       if(tagged?, do: [], else: [{:action, :tag, nil}])}
    end

    @impl true
    def act(action, nil, %{resource: %{name: name}} = context) when action in [:tag, :untag] do
      if action == :untag and Harness.fact(context, {:untag, name}) == :block,
        do: Toys.parked(context, {:untagging, name, self()})

      Harness.record(context, {:tagger, name}, action)
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

      case Store.get(:probe, target, instance: context.instance) do
        nil -> %{sees: nil}
        probe -> %{sees: probe.spec["n"]}
      end
    end

    @impl true
    def reconcile(_link, %{sees: sees}),
      do: {Verdict.new([ready: {sees != nil, :looked}], status: %{sees: sees}), []}

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
    def retention, do: %{keep: 2, ttl_ms: 1_000}
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
      Harness.record(context, {:sloppy, name}, :poke)
      Harness.put_fact(context, {:poked, name}, true)
    end
  end

  defmodule Batch do
    @moduledoc """
    Owns `:batch`. One pass writes its own spec and progress in three groups
    with a mark in the world between them; once marked twice it is ready.
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
    def reconcile(_batch, %{mark: 2}), do: {Verdict.new(ready: {true, :marked}), []}

    def reconcile(%{name: name}, _observed) do
      put = &{:update_spec, :batch, name, %{&1 => true}, []}

      {Verdict.new(ready: {false, :marking}),
       [
         put.("a"),
         {:put_progress, :batch, name, %{"phase" => "one"}, [writer: __MODULE__]},
         {:action, :mark, 1},
         put.("b"),
         put.("c"),
         {:action, :mark, 2},
         put.("d")
       ]}
    end

    @impl true
    def act(:mark, n, %{resource: %{name: name}} = context) do
      Harness.record(context, {:batch, name}, {:mark, n})
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

  defmodule Fragile do
    @moduledoc """
    Owns `:fragile`, and is wrong on purpose: its action counts instead of
    setting, and it only learns that the action ran from the commit after
    it. Interrupted between the two it counts twice.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.Harness

    @impl true
    def kind, do: :fragile
    @impl true
    def condition_types, do: [:ready]
    @impl true
    def observe(%{name: name}, context), do: %{count: Harness.fact(context, {:count, name}) || 0}

    @impl true
    def reconcile(%{spec: %{"counted" => true}}, %{count: count}),
      do: {Verdict.new([ready: {true, :counted}], status: %{count: count}), []}

    def reconcile(%{name: name}, _observed) do
      {Verdict.new(ready: {false, :counting}),
       [{:action, :count, nil}, {:update_spec, :fragile, name, %{"counted" => true}, []}]}
    end

    @impl true
    def act(:count, nil, %{resource: %{name: name}} = context) do
      Harness.record(context, {:fragile, name}, :count)
      Harness.put_fact(context, {:count, name}, (Harness.fact(context, {:count, name}) || 0) + 1)
    end
  end
end
