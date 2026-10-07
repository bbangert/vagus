defmodule Vagus.Resource.Runtime.Step do
  @moduledoc """
  One pass over one resource: read, collect, observe, reconcile, commit,
  act. Everything here runs in the step's task, never in the runtime, so a
  callback that raises costs the runtime nothing but that pass, and an
  engine call that hangs costs it that key and one of its steps in flight.

  A pass makes one commit of its own, the verdict's status with every op
  `reconcile/2` returned, and then performs at most one action. What it
  collects is apart from that. A release or a delete owed to a resource
  that is gone is the whole pass. The finished resources the kind no longer
  retains are deleted last, after the action, each in a commit of its own
  since each is another resource with its own uid to expect: that is
  housekeeping for others, and this resource's action does not wait on it.

  The task's result says what the resource it was given refers to, the
  action the pass performed, and its outcome:

    * `{:ok, next}`, a pass that ran, `next` being `:rest`, `:now` or
      `{:after, ms}`;
    * `{:unavailable, next}`, the same for a pass whose observation could
      not be made;
    * `{:action_failed, failure}`, the action returned an error;
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

  @typedoc "`refs` is what the resource refers to, `action` what the pass performed."
  @type result :: %{
          refs: [Resource.key()],
          action: {atom(), term()} | nil,
          outcome: outcome()
        }

  # `step.resource` is the row the runtime read when it started this, which
  # is how the runtime knows whose pass it is even if the pass crashes.
  @spec run(map()) :: result()
  def run(%{resource: %Resource{} = resource} = step) do
    result = %{refs: references(step, resource), action: nil, outcome: nil}

    case if(collects?(step), do: Collector.ops(resource, step.i), else: []) do
      [] ->
        if step.shutdown?.(),
          do: %{result | outcome: :gated},
          else: reconcile(step, resource, Clock.now(step.clock), result)

      # What was collected changed the resource this pass read, so the
      # decision is left to the next one.
      ops ->
        %{result | outcome: with(:ok <- commit(step, resource, ops), do: {:ok, :now})}
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

    {verdict, ops, action, requeue} =
      decided(step, resource, step.controller.reconcile(resource, observation))

    action = performable(step, resource, action, unavailable?)
    requeue = sooner(requeue, expiry(step, resource, verdict, now))

    outcome =
      with :ok <- commit(step, resource, status_ops(step, resource, verdict, now) ++ ops),
           acted = act(step, action, Map.put(context, :resource, resource)),
           # Whatever the action came to: a failing one would otherwise
           # keep the kind's finished resources for as long as it fails.
           :ok <- retain(step, verdict, now),
           :ok <- acted do
        next =
          cond do
            # An action changed the world and no event is promised for it.
            action != nil -> :now
            requeue != nil -> {:after, requeue}
            true -> :rest
          end

        if unavailable?, do: {:unavailable, next}, else: {:ok, next}
      end

    %{result | outcome: outcome, action: if(match?({:ok, _next}, outcome), do: action)}
  end

  # Checked whole, before any of it is applied: a return that is wrong in
  # one part must not have another part of it written or performed.
  defp decided(step, resource, {verdict, effects}) when is_list(effects) do
    {verdict, problems} =
      if verdict == :no_verdict,
        do: {nil, []},
        else: {verdict, Verdict.problems(verdict, step.types, step.owner?)}

    bad = Enum.reject(effects, &Controller.effect?/1)
    {requeues, rest} = Enum.split_with(effects, &match?({:requeue_after, _ms}, &1))
    {ops, acts} = Enum.split_while(rest, &(not match?({:action, _name, _args}, &1)))

    refused =
      cond do
        problems != [] ->
          "verdict on #{resource.kind}/#{resource.name} refused: #{inspect(problems)}"

        bad != [] ->
          "not effects: #{inspect(bad)}"

        match?([_action, _more | _], acts) ->
          "more than one action in a pass, or an op after the action: #{inspect(acts)}"

        true ->
          nil
      end

    if refused, do: raise(ArgumentError, "#{inspect(step.controller)}: #{refused}")

    action =
      case acts do
        [{:action, name, args}] -> {name, args}
        [] -> nil
      end

    {verdict, ops, action, Enum.min(for({:requeue_after, ms} <- requeues, do: ms), fn -> nil end)}
  end

  defp decided(step, _resource, other),
    do: raise(ArgumentError, "#{inspect(step.controller)}.reconcile/2 returned #{inspect(other)}")

  # With nothing observed there is nothing an action could rightly be
  # decided from, and one that failed against an absent engine would be
  # counted against the resource. The ops and the verdict are still written.
  defp performable(step, resource, {name, _args}, true) do
    Logger.warning(
      "#{inspect(step.controller)}: #{resource.kind}/#{resource.name} could not be observed; " <>
        "not performing #{inspect(name)}"
    )

    nil
  end

  defp performable(_step, _resource, action, _unavailable?), do: action

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

  defp commit(_step, _target, []), do: :ok

  # Every write of a step: not during a shutdown, only to the resource that
  # was read, and failing the step on anything else the store refuses.
  # `:gone` when `target` is no longer that resource.
  defp commit(step, %{kind: kind, name: name, uid: uid}, ops) do
    if step.shutdown?.() do
      :gated
    else
      # The uid, so that what was decided about a resource never lands on a
      # namesake created after it was deleted.
      case Store.commit_changed([{:expect, kind, name, uid: uid} | ops], step.i) do
        # A commit that changed nothing is told apart for whoever watches
        # the boundaries: the store is as it was before the pass.
        {:ok, _resources, changed?} ->
          boundary(step, if(changed?, do: :commit, else: :idle_commit))

        # A new resource under the name, or none. Any other expectation
        # that fails was the controller's own, about a resource that is
        # still the one read, and is a commit refused like any other.
        {:error, {:precondition, {^kind, ^name}, field}} when field in [:uid, :not_found] ->
          :gone

        {:error, reason} ->
          exit({:commit_refused, {kind, name}, reason})
      end
    end
  end

  # After the pass's own commit, which is what stamps this resource as
  # finished and so puts it in the listing, and after its action.
  defp retain(
         %{retention: %{} = retention, skip_collector: false} = step,
         %Verdict{terminal?: true},
         now
       ) do
    step.kind
    |> Collector.expired(retention, now, step.i)
    |> Enum.reduce_while(:ok, fn expired, :ok ->
      case commit(step, expired, [{:delete, expired.kind, expired.name}]) do
        # Deleted, or replaced under its name since it was listed, which
        # leaves nothing of it to delete.
        done when done in [:ok, :gone] -> {:cont, :ok}
        :gated -> {:halt, :gated}
      end
    end)
  end

  defp retain(_step, _verdict, _now), do: :ok

  defp act(_step, nil, _context), do: :ok

  defp act(step, {name, args}, context) do
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
        class -> Lanes.run(class, [instance: step.instance], run)
      end

    case result do
      :ok ->
        boundary(step, :action)

      :gated ->
        :gated

      {:error, reason} ->
        {:action_failed, %{name: name, args: args, reason: reason, at: context.now}}

      other ->
        raise ArgumentError, "#{inspect(step.controller)}.act/3 returned #{inspect(other)}"
    end
  end

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
