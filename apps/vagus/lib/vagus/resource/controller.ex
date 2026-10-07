defmodule Vagus.Resource.Controller do
  @moduledoc """
  What a controller supplies to `Vagus.Resource.Runtime`. See
  `docs/app-lifecycle.md`.

  One pass over a resource is `observe/2`, then `reconcile/2`, then the
  effects `reconcile/2` returned. `reconcile/2` is the only place a decision
  is made and must be pure: everything it needs is in the resource and in
  what `observe/2` returned, the time included (`context.now`).

  ## Effects

  Effects are data, applied in order:

    * a store op (`t:Vagus.Resource.Store.op/0`), written with whatever
      `:writer` the op names;
    * `{:action, name, args}`, performed by `act/3`;
    * `{:requeue_after, ms}`, which looks at the resource again after that
      long. The shortest one wins.

  The ops between two actions are one commit, and the verdict is written in
  the first. A crash therefore falls between a commit and an action, never
  inside a group, and **an action must be idempotent against observation**:
  the pass after a crash observes what the action already did and carries on
  from there, so the action may run twice and must not depend on the commit
  after it having happened.

  There is no status effect. Status is written by the runtime, from the
  `Vagus.Resource.Verdict`, and by nothing else.

  A commit the store refuses crashes the pass, which is retried with
  back-off; so does anything a callback raises. `act/3` returning
  `{:error, reason}` ends the pass without the effects after it. The next
  pass runs at once and finds the failure in `context.failed_action`,
  because a failed action usually leaves nothing behind for `observe/2` to
  see; counting it and spacing the retries is the controller's to do, with
  `{:requeue_after, ms}`. Passes that keep ending in a failed action are
  spaced like crashed ones, and so are passes that perform the same actions
  as the pass before: an action must change what `observe/2` sees.

  Every callback runs in the pass's task, `references/1` and `priority/1`
  included. One that raises, exits or never returns costs its resource that
  pass and nothing beyond it.

  ## What `observe/2` cannot reach

  `observe/2` returns `{:unavailable, reason}` when what it reads cannot be
  reached, the container engine above all (`{:unavailable,
  :engine_unavailable}`). `reconcile/2` is given that in place of an
  observation and returns the verdict for it: progressing, with that reason.
  Its store ops are applied; any action it returns is not performed. The
  runtime counts no failure and looks again shortly, whatever the effects
  ask for.

  ## Owning and attaching

  One controller owns a kind: it supplies the kind's admission and codec, and
  its verdict covers `condition_types/0`. A controller that exports
  `owned_conditions/0` is attached to a kind another owns: its verdict covers
  exactly those types and carries no other status.
  """

  alias Vagus.Resource
  alias Vagus.Resource.{Clock, Kind, Lanes, Stamp, Store, Verdict}

  @typedoc """
  `failed_action` is the action of this resource's previous pass that
  returned an error, if one did.
  """
  @type context :: %{
          required(:instance) => atom(),
          required(:clock) => Clock.t(),
          required(:now) => Stamp.t(),
          required(:failed_action) => failed_action() | nil,
          optional(atom()) => term()
        }

  @type failed_action :: %{name: atom(), args: term(), reason: term(), at: Stamp.t()}

  @type observation :: term()
  @type unavailable :: {:unavailable, reason :: atom()}

  @type effect ::
          Store.op()
          | {:action, name :: atom(), args :: term()}
          | {:requeue_after, non_neg_integer()}

  @callback kind() :: Resource.kind()

  @doc "For an attached controller, the same list as `owned_conditions/0`."
  @callback condition_types() :: [atom()]

  @doc "Reads the outside world and writes nothing."
  @callback observe(Resource.t(), context()) :: observation() | unavailable()

  @callback reconcile(Resource.t(), observation() | unavailable()) ::
              {Verdict.t() | :no_verdict, [effect()]}

  @doc "`context.resource` is the resource as the pass read it."
  @callback act(name :: atom(), args :: term(), context()) :: :ok | {:error, term()}

  @doc "Admission, as `t:Vagus.Resource.Kind.validator/0`. The kind's owner only."
  @callback validate(spec :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Other resources whose changes concern this one. A change to one of them
  runs a pass for this resource, and for no other.
  """
  @callback references(Resource.t()) :: [Resource.key()]

  @doc """
  The resource's place among the actions waiting for a lane: lower is served
  first. Default 0. It orders nothing else; steps all start at once.
  """
  @callback priority(Resource.t()) :: integer()

  @doc """
  For a kind whose resources finish: how many finished ones to keep, and for
  how long. The count is the bound that always holds; an age is only known
  within one incarnation.
  """
  @callback retention() :: %{keep: non_neg_integer(), ttl_ms: non_neg_integer() | :infinity}

  @callback owned_conditions() :: [atom()]

  @doc "Held by every resource of the kind from its creation until this controller removes it."
  @callback finalizer() :: atom()

  @doc """
  Finalizers that must be gone before this controller is shown a resource
  that is being deleted.
  """
  @callback finalize_after() :: [atom()]

  @doc "The lane an action runs in (`Vagus.Resource.Lanes`), or `nil` for none."
  @callback action_class(name :: atom()) :: Lanes.class() | nil

  @doc "As `Vagus.Resource.Kind.writer_entries`. The kind's owner only."
  @callback writer_entries() :: [Resource.path()]

  @doc """
  The four codec hooks of `Vagus.Resource.Kind`, for the kind's owner. A spec
  or progress with atoms in it needs them: JSON returns none, and the store
  refuses what would not read back the same.
  """
  @callback encode_spec(map()) :: term()
  @callback decode_spec(term()) :: map()
  @callback encode_progress(map()) :: term()
  @callback decode_progress(term()) :: map()

  @optional_callbacks validate: 1,
                      references: 1,
                      priority: 1,
                      retention: 0,
                      owned_conditions: 0,
                      finalizer: 0,
                      finalize_after: 0,
                      action_class: 1,
                      writer_entries: 0,
                      encode_spec: 1,
                      decode_spec: 1,
                      encode_progress: 1,
                      decode_progress: 1

  @hooks [:encode_spec, :decode_spec, :encode_progress, :decode_progress]

  @spec owner?(module()) :: boolean()
  def owner?(controller), do: not exports?(controller, :owned_conditions, 0)

  @doc "The condition types the controller's verdict must cover."
  @spec conditions(module()) :: [atom()]
  def conditions(controller) do
    if owner?(controller), do: controller.condition_types(), else: controller.owned_conditions()
  end

  @doc "An optional callback's result, or `default` when the controller has none."
  @spec optional(module(), atom(), [term()], term()) :: term()
  def optional(controller, callback, args, default) do
    if exports?(controller, callback, length(args)),
      do: apply(controller, callback, args),
      else: default
  end

  @doc """
  The kinds the store is started with, one per owning controller, each with
  the finalizers of every controller on it.

  Raises on a list the store would later refuse a registration from: two
  owners of one kind, a controller attached to a kind nobody owns, condition
  types that are not atoms, or one condition type or one finalizer declared
  by two controllers of a kind. None of these can run, and found here they fail the
  start with a name instead of a runtime that can never register.
  """
  @spec kinds([module()]) :: %{Resource.kind() => Kind.t()}
  def kinds(controllers) do
    {owners, attached} = controllers |> Enum.uniq() |> Enum.split_with(&owner?/1)

    owned =
      Enum.reduce(owners, %{}, fn owner, owned ->
        Map.update(owned, owner.kind(), owner, fn rival ->
          raise ArgumentError,
                "#{inspect(rival)} and #{inspect(owner)} both own kind #{inspect(owner.kind())}"
        end)
      end)

    for controller <- attached, not is_map_key(owned, controller.kind()) do
      raise ArgumentError,
            "#{inspect(controller)} attaches to #{inspect(controller.kind())}, " <>
              "which no controller owns"
    end

    Map.new(owned, fn {kind, owner} ->
      on_kind = [owner | Enum.filter(attached, &(&1.kind() == kind))]
      distinct_conditions!(kind, on_kind)
      finalizers = distinct_finalizers!(kind, on_kind)

      {kind,
       Kind.new(
         [
           validators: if(exports?(owner, :validate, 1), do: [&owner.validate/1], else: []),
           finalizers: finalizers,
           writer_entries: optional(owner, :writer_entries, [], [])
         ] ++
           for(
             hook <- @hooks,
             exports?(owner, hook, 1),
             do: {hook, Function.capture(owner, hook, 1)}
           )
       )}
    end)
  end

  # A resource holds a finalizer once. Shared, the first controller to finish
  # would release it for both, and the resource could go before the other
  # had cleaned up.
  defp distinct_finalizers!(kind, controllers) do
    held = for c <- controllers, exports?(c, :finalizer, 0), do: {c.finalizer(), c}

    held
    |> Enum.reduce([], fn {finalizer, controller}, seen ->
      case List.keyfind(seen, finalizer, 0) do
        nil ->
          seen ++ [{finalizer, controller}]

        {^finalizer, rival} ->
          raise ArgumentError,
                "#{inspect(rival)} and #{inspect(controller)} both declare finalizer " <>
                  "#{inspect(finalizer)} on kind #{inspect(kind)}"
      end
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp distinct_conditions!(kind, controllers) do
    Enum.reduce(controllers, %{}, fn controller, declared ->
      types = conditions(controller)

      with [_ | _] <- Enum.reject(List.wrap(types), &is_atom/1) do
        raise ArgumentError,
              "#{inspect(controller)} declares condition types #{inspect(types)}, not a list of atoms"
      end

      Enum.reduce(types, declared, fn type, declared ->
        Map.update(declared, type, controller, fn rival ->
          raise ArgumentError,
                "#{inspect(rival)} and #{inspect(controller)} both declare condition " <>
                  "#{inspect(type)} on kind #{inspect(kind)}"
        end)
      end)
    end)
  end

  @doc """
  Whether `term` is an effect the runtime can apply: an action, a timed
  re-queue, or a store op of a known shape. A status write is none: status
  comes from the verdict alone.
  """
  @spec effect?(term()) :: boolean()
  def effect?({:action, name, _args}), do: is_atom(name)
  def effect?({:requeue_after, ms}), do: is_integer(ms) and ms >= 0

  def effect?({op, kind, name, arg, opts}) when op in [:create, :put_progress],
    do: key?(kind, name) and is_map(arg) and is_list(opts)

  def effect?({:update_spec, kind, name, ops, opts}),
    do: key?(kind, name) and (is_map(ops) or is_list(ops)) and is_list(opts)

  def effect?({op, kind, name, finalizer}) when op in [:add_finalizer, :remove_finalizer],
    do: key?(kind, name) and is_atom(finalizer)

  def effect?({:release_writer, kind, name, _writer}), do: key?(kind, name)
  def effect?({:expect, kind, name, expected}), do: key?(kind, name) and is_list(expected)
  def effect?({:delete, kind, name}), do: key?(kind, name)
  def effect?(_other), do: false

  defp key?(kind, name), do: is_atom(kind) and is_binary(name)

  defp exports?(controller, callback, arity) do
    Code.ensure_loaded?(controller) and function_exported?(controller, callback, arity)
  end
end
