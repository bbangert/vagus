defmodule Vagus.App.Controller.Reconcile do
  @moduledoc """
  The App controller's decision: a pure function of an App resource and of
  what `Vagus.App.Controller.Observe` saw.

  `reconcile/2` is in two parts. `Vagus.App.Controller.View.view/2` works
  out every fact the decision turns on, and the bookkeeping the pass
  carries forward in status, each under a name. `decide/1` is the table:
  the first clause whose condition holds is the pass's verdict, its state,
  and at most one action. A clause's reason is the reason of all three
  conditions.

  Failed is of two kinds. Given up: a failure for good, an action that
  raised, a budget spent, a crash nothing restarts. Nothing more is done
  until the spec is written to. And not ready within its deadline
  (`readiness_timeout`): the instance runs and is still asked, at a longer
  interval, and is Ready when it answers, with no write to anything.

  The order of the clauses is the order of precedence: what is owed to a
  container the other firmware slot left, then taking an instance away,
  then judging one that ended, then the start sequence.
  """

  alias Vagus.App.Controller.View
  alias Vagus.Resource
  alias Vagus.Resource.Verdict

  @kind :app
  @finalizer :app

  @readiness_poll_ms 5_000
  # Past its deadline an app is still asked, since a slow one must come up
  # all the same, but seldom: one that is dead is not worth a question
  # every five seconds for as long as it stays so.
  @overdue_poll_ms 30_000
  @removing_poll_ms 1_000
  @api_poll_ms 2_000

  @blank View.blank()

  @spec finalizer() :: atom()
  def finalizer, do: @finalizer

  @spec reconcile(Resource.t(), map() | {:unavailable, atom()}) ::
          {Verdict.t() | :no_verdict, [Vagus.Resource.Controller.effect()]}
  def reconcile(%Resource{deleting?: true, finalizers: held} = resource, observation) do
    if @finalizer in held, do: reconciled(resource, observation), else: {:no_verdict, []}
  end

  def reconcile(%Resource{} = resource, observation), do: reconciled(resource, observation)

  # Nothing was seen, so nothing recorded is touched: only the conditions say so.
  defp reconciled(_resource, {:unavailable, reason}),
    do: {verdict({false, true, false}, reason, %{}), []}

  defp reconciled(resource, observation), do: resource |> View.view(observation) |> decide()

  # One function on purpose: the order of its clauses is the precedence,
  # and a clause moved into a helper would hide where it stands.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp decide(v) do
    cond do
      v.mismatch? and v.deleting? ->
        out(v, :idle, :deleted, :deleting, %{}, [release(v)])

      v.mismatch? ->
        out(v, :failed, :name_mismatch, :failed)

      v.raised? and v.running? and v.token in [:absent, :other] and not v.put_raised? ->
        act(v, :indexing_token, :starting, :put_token)

      v.raised? ->
        out(v, :failed, :crashed, :failed)

      v.leftover == :running ->
        act(v, :removing_leftover, :stopping, :stop_leftover)

      v.leftover == :stopped ->
        act(v, :removing_leftover, :stopping, :remove_leftover)

      v.removing? ->
        wait(v, :removing, :stopping, @removing_poll_ms)

      v.stale_pull != nil ->
        act(v, :cancelling_pull, :pulling, {:cancel_pull, %{image: v.stale_pull}})

      v.down? and v.pull_waiting? ->
        act(v, :cancelling_pull, :stopping, :cancel_pull, pull: nil)

      v.deleting? and v.token_held? ->
        act(v, :revoking_token, :stopping, :remove_token)

      v.running? and v.retire? ->
        act(v, :stopping, :stopping, stop(v), expected_exit: v.id)

      v.present? and v.dispose? ->
        act(v, :removing, :stopping, :remove, expected_exit: v.id)

      v.down? and v.token_held? ->
        act(v, :revoking_token, :stopping, :remove_token)

      v.deleting? and v.image_owed? ->
        act(v, :removing_image, :deleting, :remove_image)

      v.deleting? and v.data? ->
        act(v, :removing_data, :deleting, :remove_data)

      v.deleting? ->
        out(v, :idle, :deleted, :deleting, %{}, [release(v)])

      not v.wanted? ->
        out(v, :idle, if(v.held?, do: :held, else: :stopped), :stopped, stopped(v))

      v.running? and v.token in [:absent, :other] ->
        act(v, :indexing_token, :starting, :put_token)

      v.succeeded? ->
        out(v, :idle, :succeeded, :succeeded)

      v.failed? ->
        out(v, :failed, v.failure.cause, :failed)

      v.retry_in > 0 ->
        wait(v, v.failure.cause, :starting, v.retry_in)

      v.crash_loop? and v.loop_spent? ->
        fail(v, :run, :crash_loop)

      v.crash_loop? ->
        act(v, :crash_loop, :stopping, stop(v), recreating(v))

      v.finished? ->
        out(v, :idle, :succeeded, :succeeded, %{succeeded: v.generation})

      v.ended? and v.policy == :never ->
        fail(v, :run, :crashed, %{exit_code: v.exit_code})

      (v.ended? or v.unhealthy?) and v.spent? ->
        fail(v, :run, :restart_budget_exhausted)

      v.exited? ->
        act(v, :crashed, :restarting, :remove, restarts: v.spend, expected_exit: v.id)

      v.ended? ->
        out(v, :progressing, :crashed, :restarting, %{restarts: v.spend, instance: nil}, [
          {:requeue_after, 0}
        ])

      v.unhealthy? ->
        act(v, :unhealthy, :restarting, stop(v), restarts: v.spend, expected_exit: v.id)

      not v.running? and not v.api? ->
        wait(v, :waiting_for_api, :waiting, @api_poll_ms)

      v.absent? and v.backoff_in > 0 ->
        wait(v, :backing_off, :restarting, v.backoff_in)

      v.absent? and v.wave_wait_in > 0 ->
        wait(v, :waiting_for_wave, :waiting, v.wave_wait_in, waiting(v))

      v.absent? and not v.buildable? ->
        out(v, :failed, :no_container_builder, :failed)

      v.image_owed? and v.pull == :pulling ->
        out(v, :progressing, :pulling, :pulling)

      v.image_owed? and v.pull == :refused ->
        fail(v, :pull, v.pull_failure.cause, v.pull_failure.detail)

      v.image_owed? and v.pull_retry_in > 0 ->
        wait(v, v.pull_failure.cause, :pulling, v.pull_retry_in)

      v.image_owed? ->
        act(v, :pulling, :pulling, :request_pull, pull: v.pull_next)

      v.absent? and v.native? ->
        act(v, :starting, :starting, :start_process, launching(v))

      v.absent? ->
        act(v, :creating, :creating, :create, launching(v))

      v.token == :none_to_put and v.token_pending? ->
        wait(v, :waiting_for_token, :starting, @readiness_poll_ms)

      v.token == :none_to_put ->
        out(v, :failed, :no_token, :failed)

      v.token in [:absent, :other] ->
        act(v, :indexing_token, :starting, :put_token)

      not v.running? ->
        act(v, :starting, :starting, :start, launching(v))

      v.waiting != nil and v.past_deadline? ->
        wait(v, :readiness_timeout, :failed, @overdue_poll_ms, %{}, :failed)

      v.waiting != nil ->
        wait(v, v.waiting, :starting, v.readiness_poll)

      v.gates_closed != [] ->
        out(v, :progressing, :waiting_for_gate, :starting)

      true ->
        ready(v)
    end
  end

  defp stop(v), do: {if(v.native?, do: :stop_process, else: :stop), %{grace: v.grace}}

  defp launching(v), do: [made_for: v.target, expected_exit: nil, recreate: nil]

  defp recreating(v) do
    [
      expected_exit: v.id,
      recreate: v.id,
      engine_restarts: %{seen: [], actions: [v.now | v.loop_actions]}
    ]
  end

  defp waiting(v), do: %{wave_since: v.wave_since, waiting_on: v.waiting_on}

  defp stopped(v) do
    Map.merge(
      Map.take(@blank, [:failure, :succeeded, :restarts, :probe, :pull, :wave_since]),
      %{made_for: if(v.id, do: v.base.made_for)}
    )
  end

  defp release(v), do: {:remove_finalizer, @kind, v.name, @finalizer}

  defp ready(v) do
    held = v.base.ready_since || v.now
    reset? = v.reset_in == 0

    changes = %{
      instance: %{v.base.instance | ready?: true},
      ready_since: held,
      failure: nil,
      pull: nil,
      restarts: if(reset?, do: @blank.restarts, else: v.base.restarts)
    }

    later = for ms <- [v.probe_in, if(not reset?, do: v.reset_in)], ms != nil, do: ms

    out(
      v,
      :ready,
      :ready,
      :ready,
      changes,
      for(ms <- Enum.take(Enum.sort(later), 1), do: {:requeue_after, ms})
    )
  end

  defp fail(v, action, cause, detail \\ nil) do
    failure = %{
      action: action,
      class: :permanent,
      cause: cause,
      detail: detail,
      at: v.now,
      generation: v.generation,
      count: 1
    }

    out(v, :failed, cause, :failed, %{failure: failure})
  end

  defp wait(v, reason, state, ms, changes \\ %{}, kind \\ :progressing),
    do: out(v, kind, reason, state, changes, for(ms <- [ms], ms != nil, do: {:requeue_after, ms}))

  defp act(v, reason, state, action, changes \\ []) do
    {name, args} = if is_tuple(action), do: action, else: {action, args(action, v)}
    # The generation, for whoever reads of the action's failure later.
    args = Map.put(args, :generation, v.generation)
    out(v, :progressing, reason, state, Map.new(changes), [{:action, name, args}])
  end

  defp args(:request_pull, v), do: %{image: v.image, priority: v.wave}
  defp args(action, v) when action in [:cancel_pull, :remove_image], do: %{image: v.image}
  defp args(:put_token, v), do: %{instance: v.id}
  defp args(_action, _v), do: %{}

  defp out(v, kind, reason, state, changes \\ %{}, effects \\ []) do
    outcome =
      case kind do
        :ready -> {true, false, false}
        :progressing -> {false, true, false}
        :failed -> {false, false, true}
        :idle -> {false, false, false}
      end

    status =
      v.base
      |> Map.merge(%{ready_since: nil})
      |> Map.merge(changes)
      |> Map.put(:state, state)

    {verdict(outcome, reason, status), effects}
  end

  defp verdict({ready, progressing, failed}, reason, status) do
    Verdict.new(
      %{ready: {ready, reason}, progressing: {progressing, reason}, failed: {failed, reason}},
      status: status
    )
  end
end
