defmodule Vagus.Resource.Runtime.Step do
  @moduledoc """
  One pass over one resource: read, collect, observe, reconcile, apply.
  Everything here runs in the step's task, never in the runtime, so a
  callback that raises or an engine call that hangs costs the runtime
  nothing but that key.

  The task's result is `:gone` when there is no such resource, and
  otherwise says which resource the pass read, what that resource refers
  to, which actions the pass performed, and its outcome:

    * `{:ok, next}`, a pass that ran, `next` being `:rest`, `:now` or
      `{:after, ms}`;
    * `{:unavailable, next}`, the same for a pass whose observation could
      not be made;
    * `{:action_failed, failure}`, an action returned an error;
    * `:gone`, the resource is no longer the one read;
    * `:gated`, the host is shutting down and the pass stopped short.

  Anything else, an exit above all, is a crashed pass.
  """

  require Logger

  alias Vagus.Resource
  alias Vagus.Resource.{Clock, Collector, Controller, Lanes, Stamp, Store, Verdict}

  @type next :: :rest | :now | {:after, non_neg_integer()}

  @type outcome ::
          {:ok, next()}
          | {:unavailable, next()}
          | {:action_failed, Controller.failed_action()}
          | :gone
          | :gated

  @typedoc """
  `uid` is the resource the pass was about: the runtime keys its queue by
  name, and what this pass found out must not be believed of a later
  resource of that name. `refs` is what the resource refers to, `actions`
  what the pass performed.
  """
  @type result ::
          :gone
          | %{
              uid: pos_integer(),
              refs: [Resource.key()],
              actions: [{atom(), term()}],
              outcome: outcome()
            }

  @spec run(map()) :: result()
  def run(%{kind: kind, name: name} = step) do
    case Store.get(kind, name, step.i) do
      nil ->
        :gone

      resource ->
        # The controller's own code, here and not in the runtime: one that
        # raises, exits or never returns costs this key and nothing else.
        step = %{step | priority: priority(step, resource)}
        result = %{uid: resource.uid, refs: references(step, resource), actions: [], outcome: nil}
        pass(step, resource, collectable(step, resource), result)
    end
  end

  defp priority(step, resource) do
    case Controller.optional(step.controller, :priority, [resource], 0) do
      priority when is_integer(priority) ->
        priority

      other ->
        raise ArgumentError, "#{inspect(step.controller)}.priority/1 returned #{inspect(other)}"
    end
  end

  # An owner or a field's writer is referred to as well: its removal is what
  # the collector acts on.
  defp references(step, resource) do
    declared = Controller.optional(step.controller, :references, [resource], [])

    if not (is_list(declared) and
              Enum.all?(
                declared,
                &match?({kind, name} when is_atom(kind) and is_binary(name), &1)
              )) do
      raise ArgumentError,
            "#{inspect(step.controller)}.references/1 returned #{inspect(declared)}"
    end

    owed = if collects?(step), do: Collector.dependencies(resource), else: []
    Enum.uniq(declared ++ owed) -- [{resource.kind, resource.name}]
  end

  defp collects?(step), do: step.owner? and not step.skip_collector

  defp pass(step, resource, [], result) do
    cond do
      step.shutdown?.() -> %{result | outcome: :gated}
      held_back?(step, resource) -> %{result | outcome: {:ok, :rest}}
      true -> reconcile(step, resource, Clock.now(step.clock), result)
    end
  end

  # What was collected changed the resource this pass read, so the decision
  # is left to the next one.
  defp pass(step, resource, ops, result) do
    outcome = with :ok <- group(step, resource, ops), do: {:ok, :now}
    %{result | outcome: outcome}
  end

  defp collectable(step, resource),
    do: if(collects?(step), do: Collector.ops(resource, step.i), else: [])

  defp held_back?(step, %Resource{deleting?: true, finalizers: finalizers}),
    do: Enum.any?(step.finalize_after, &(&1 in finalizers))

  defp held_back?(_step, _resource), do: false

  defp reconcile(step, resource, now, result) do
    context =
      Map.merge(step.context, %{
        instance: step.instance,
        clock: step.clock,
        now: now,
        failed_action: step.failed_action
      })

    observation = step.controller.observe(resource, context)
    unavailable? = match?({:unavailable, _reason}, observation)
    {verdict, effects} = step.controller.reconcile(resource, observation)
    verdict = admitted(step, resource, verdict)
    {[first | acts], requeue} = plan(effects)
    acts = performable(step, resource, acts, unavailable?)
    requeue = sooner(requeue, expiry(step, resource, verdict, now))

    outcome =
      with :ok <- group(step, resource, status_ops(step, resource, verdict, now) ++ first),
           :ok <- retain(step, verdict, now),
           :ok <- actions(step, resource, acts, Map.put(context, :resource, resource)) do
        next =
          cond do
            # An action changed the world and no event is promised for it.
            acts != [] -> :now
            requeue != nil -> {:after, requeue}
            true -> :rest
          end

        if unavailable?, do: {:unavailable, next}, else: {:ok, next}
      end

    performed = if match?({:ok, _next}, outcome), do: Enum.map(acts, &elem(&1, 0)), else: []
    %{result | outcome: outcome, actions: performed}
  end

  # With nothing observed there is nothing an action could rightly be
  # decided from, and one that failed against an absent engine would be
  # counted against the resource.
  defp performable(_step, _resource, acts, false), do: acts
  defp performable(_step, _resource, [], true), do: []

  defp performable(step, resource, acts, true) do
    Logger.warning(
      "#{inspect(step.controller)}: #{resource.kind}/#{resource.name} could not be observed; " <>
        "not performing #{inspect(Enum.map(acts, &elem(&1, 0)))}"
    )

    []
  end

  defp sooner(nil, ms), do: ms
  defp sooner(ms, nil), do: ms
  defp sooner(one, other), do: min(one, other)

  # A finished resource is looked at again when its time is up, so that its
  # expiry does not wait for a resync.
  defp expiry(%{retention: %{ttl_ms: ttl}} = step, resource, %Verdict{terminal?: true}, now)
       when is_integer(ttl) do
    finished = Map.merge(resource.status, finished(step, resource, now)).finished
    if step.skip_collector, do: nil, else: max(ttl - Stamp.age(finished, now), 0) + 1
  end

  defp expiry(_step, _resource, _verdict, _now), do: nil

  defp admitted(_step, _resource, :no_verdict), do: nil

  defp admitted(step, resource, verdict) do
    case Verdict.problems(verdict, step.types, step.owner?) do
      [] ->
        verdict

      problems ->
        message =
          "#{inspect(step.controller)}: verdict on #{resource.kind}/#{resource.name} refused: " <>
            inspect(problems)

        if step.strict, do: raise(ArgumentError, message)
        Logger.error(message)
        nil
    end
  end

  # The ops before the first action, then each action with the ops up to the
  # next one.
  defp plan(effects) do
    with [_ | _] = bad <- Enum.reject(effects, &Controller.effect?/1) do
      raise ArgumentError, "not effects: #{inspect(bad)}"
    end

    {requeues, effects} = Enum.split_with(effects, &match?({:requeue_after, _ms}, &1))
    {first, rest} = Enum.split_while(effects, &(not action?(&1)))

    {[first | chunk(rest)],
     Enum.min(for({:requeue_after, ms} <- requeues, do: ms), fn -> nil end)}
  end

  defp chunk([]), do: []

  defp chunk([{:action, name, args} | rest]) do
    {ops, rest} = Enum.split_while(rest, &(not action?(&1)))
    [{{name, args}, ops} | chunk(rest)]
  end

  defp action?(effect), do: match?({:action, _name, _args}, effect)

  defp status_ops(_step, _resource, nil, _now), do: []

  defp status_ops(step, %Resource{kind: kind, name: name} = resource, verdict, now) do
    conditions = Verdict.conditions(verdict, observed_generation(step, resource))

    patch =
      if step.owner? do
        verdict.status
        |> Map.merge(%{conditions: conditions, observed_generation: resource.generation})
        |> Map.merge(if(verdict.terminal?, do: finished(step, resource, now), else: %{}))
      else
        %{conditions: conditions}
      end

    [{:patch_status, kind, name, patch, [writer: step.controller]}]
  end

  # The generation the pass read, which is the one it decided about. The
  # switch stamps the one current at the commit instead, to prove that a
  # test suite notices a verdict passed off as newer than it is.
  defp observed_generation(%{stamp_current_generation: true} = step, resource) do
    case Store.get(resource.kind, resource.name, step.i) do
      nil -> resource.generation
      current -> current.generation
    end
  end

  defp observed_generation(_step, resource), do: resource.generation

  defp finished(%{retention: %{}}, resource, now) do
    if match?(%Stamp{}, resource.status[:finished]), do: %{}, else: %{finished: now}
  end

  defp finished(_step, _resource, _now), do: %{}

  defp group(_step, _resource, []), do: :ok

  defp group(step, %Resource{kind: kind, name: name, uid: uid} = resource, ops) do
    if step.shutdown?.() do
      :gated
    else
      # The uid, so that what was decided about a resource never lands on a
      # namesake created after it was deleted.
      case Store.commit([{:expect, kind, name, uid: uid} | ops], step.i) do
        {:ok, _resources} ->
          boundary(step, if(idle?(resource, ops), do: :idle_commit, else: :commit))

        {:error, {:precondition, {^kind, ^name}, _field}} ->
          :gone

        {:error, reason} ->
          exit({:commit_refused, {kind, name}, reason})
      end
    end
  end

  defp retain(
         %{retention: %{} = retention, skip_collector: false} = step,
         %Verdict{terminal?: true},
         now
       ) do
    if step.shutdown?.() do
      :gated
    else
      for ops <- Collector.expired(step.kind, retention, now, step.i) do
        Store.commit(ops, step.i)
      end

      :ok
    end
  end

  defp retain(_step, _verdict, _now), do: :ok

  defp actions(_step, _resource, [], _context), do: :ok

  defp actions(step, resource, [{{name, args}, ops} | rest], context) do
    case act(step, name, args, context) do
      :ok ->
        boundary(step, :action)
        with :ok <- group(step, resource, ops), do: actions(step, resource, rest, context)

      {:error, reason} ->
        {:action_failed, %{name: name, args: args, reason: reason, at: context.now}}

      :gated ->
        :gated
    end
  end

  defp act(step, name, args, context) do
    # Asked with the lane held: the wait for it may have been long enough
    # for a shutdown to begin.
    run = fn ->
      cond do
        step.shutdown?.() ->
          :gated

        step.repeat_action ->
          with :ok <- step.controller.act(name, args, context),
               do: step.controller.act(name, args, context)

        true ->
          step.controller.act(name, args, context)
      end
    end

    result =
      case Controller.optional(step.controller, :action_class, [name], nil) do
        nil -> run.()
        class -> Lanes.run(class, [instance: step.instance, priority: step.priority], run)
      end

    case result do
      :ok -> :ok
      :gated -> :gated
      {:error, _reason} = error -> error
      other -> raise ArgumentError, "#{inspect(step.controller)}.act/3 returned #{inspect(other)}"
    end
  end

  # Whether a commit could not have changed anything: it wrote only the
  # status the pass had already read. Judged from the pass's own read, so
  # that it does not depend on who else wrote meanwhile.
  defp idle?(%Resource{kind: kind, name: name, status: status}, [
         {:patch_status, kind, name, patch, _opts}
       ]) do
    {conditions, rest} = Map.pop(patch, :conditions, [])
    held = Map.get(status, :conditions, %{})

    Map.take(status, Map.keys(rest)) == rest and Enum.all?(conditions, &(held[&1.type] == &1))
  end

  defp idle?(_resource, _ops), do: false

  defp boundary(%{boundary: nil}, _kind), do: :ok

  defp boundary(step, kind) do
    step.boundary.(%{
      runtime: step.runtime,
      controller: step.controller,
      kind: step.kind,
      name: step.name,
      after: kind
    })

    :ok
  end
end
