defmodule Vagus.Resource.Runtime.Step do
  @moduledoc """
  One pass over one resource: read, collect, observe, reconcile, apply.
  Everything here runs in the step's task, never in the runtime, so a
  callback that raises or an engine call that hangs costs the runtime
  nothing but that key.

  The task's result tells the runtime what to do with the key next:

    * `{:ok, next}`, a pass that ran, `next` being `:rest`, `:now` or
      `{:after, ms}`;
    * `{:unavailable, next}`, the same for a pass whose observation could
      not be made;
    * `{:action_failed, failure}`, an action returned an error;
    * `:gone`, the resource is not there, or is no longer the one read;
    * `:gated`, the host is shutting down and the pass stopped short.

  Anything else, an exit above all, is a crashed pass.
  """

  require Logger

  alias Vagus.Resource
  alias Vagus.Resource.{Clock, Collector, Controller, Lanes, Stamp, Store, Verdict}

  @type next :: :rest | :now | {:after, non_neg_integer()}

  @type result ::
          {:ok, next()}
          | {:unavailable, next()}
          | {:action_failed, Controller.failed_action()}
          | :gone
          | :gated

  @spec run(map()) :: result()
  def run(%{kind: kind, name: name} = step) do
    case Store.get(kind, name, step.i) do
      nil -> :gone
      resource -> pass(step, resource, collectable(step, resource))
    end
  end

  defp pass(step, resource, []) do
    cond do
      step.shutdown?.() -> :gated
      held_back?(step, resource) -> {:ok, :rest}
      true -> reconcile(step, resource, Clock.now(step.clock))
    end
  end

  # What was collected changed the resource this pass read, so the decision
  # is left to the next one.
  defp pass(step, resource, ops) do
    with :ok <- group(step, resource, ops), do: {:ok, :now}
  end

  defp collectable(%{owner?: true, skip_collector: false} = step, resource),
    do: Collector.ops(resource, step.i)

  defp collectable(_step, _resource), do: []

  defp held_back?(step, %Resource{deleting?: true, finalizers: finalizers}),
    do: Enum.any?(step.finalize_after, &(&1 in finalizers))

  defp held_back?(_step, _resource), do: false

  defp reconcile(step, resource, now) do
    context =
      Map.merge(step.context, %{
        instance: step.instance,
        clock: step.clock,
        now: now,
        failed_action: step.failed_action
      })

    observation = step.controller.observe(resource, context)
    {verdict, effects} = step.controller.reconcile(resource, observation)
    verdict = admitted(step, resource, verdict)
    {[first | acts], requeue} = plan(effects)

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

      if match?({:unavailable, _reason}, observation), do: {:unavailable, next}, else: {:ok, next}
    end
  end

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
    conditions = Verdict.conditions(verdict, resource.generation)

    patch =
      if step.owner? do
        verdict.status
        |> Map.merge(%{conditions: conditions, observed_generation: resource.generation})
        |> Map.merge(finished(step, resource, verdict, now))
      else
        %{conditions: conditions}
      end

    [{:patch_status, kind, name, patch, [writer: step.controller]}]
  end

  defp finished(%{retention: %{}}, resource, %Verdict{terminal?: true}, now) do
    if match?(%Stamp{}, resource.status[:finished]), do: %{}, else: %{finished: now}
  end

  defp finished(_step, _resource, _verdict, _now), do: %{}

  defp group(_step, _resource, []), do: :ok

  defp group(step, %Resource{kind: kind, name: name, uid: uid}, ops) do
    if step.shutdown?.() do
      :gated
    else
      # The uid, so that what was decided about a resource never lands on a
      # namesake created after it was deleted.
      case Store.commit([{:expect, kind, name, uid: uid} | ops], step.i) do
        {:ok, _resources} ->
          boundary(step, :commit)

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
      for name <- Collector.expired(step.kind, retention, now, step.i) do
        Store.delete(step.kind, name, step.i)
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
      if step.shutdown?.(), do: :gated, else: step.controller.act(name, args, context)
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
