defmodule Vagus.Resource.Controller do
  @moduledoc """
  What a controller supplies to `Vagus.Resource.Runtime`. See
  `docs/app-lifecycle.md`.

  One pass over a resource is `observe/2`, then `reconcile/2`, then the
  effects `reconcile/2` returned. `reconcile/2` is the only place a decision
  is made and must be pure: everything it needs is in the resource and in
  what `observe/2` returned, the time included (`context.now`).

  ## Effects

  `reconcile/2` returns, as data:

    * store ops (`t:Vagus.Resource.Store.op/0`), any number, each written
      with whatever `:writer` it names;
    * at most one `{:action, name, args}`, performed by `act/3`, after every
      op;
    * `{:requeue_after, ms}`, which looks at the resource again after that
      long. The shortest one wins.

  A pass makes one commit, of the verdict and all the ops, then performs
  the action, and ends: the resource is observed again before anything else
  is decided. A second action would rest on facts the first has changed,
  and each one adds a place a crash can fall. So create and start, stop and
  remove, and each hook of a sequence are separate passes, each decided
  from what the pass before left to observe.

  A pass can be cut anywhere: a commit whose call exits may have been
  applied, and a step that dies with its runtime dies inside `act/3`. So
  **an action must be idempotent against observation**: the pass after
  observes whatever the action did and carries on from there. Nothing but
  `observe/2` tells a pass that an action ran. The commit is made before
  it, and a pass cut between the two has the one without the other.

  There is no status effect. Status is written by the runtime, from the
  `Vagus.Resource.Verdict`, and by nothing else.

  What `reconcile/2` returns is checked whole before any of it is applied.
  A verdict that does not match the declaration, a term that is no effect,
  a second action or an op after the action fails the pass with nothing
  written and nothing done.

  A failed pass is retried with back-off: one whose commit the store
  refuses, and anything a callback raises. `act/3` returning
  `{:error, reason}` ends the pass. The next pass runs at once and finds
  the failure in `context.failed_action`, because a failed action usually
  leaves nothing behind for `observe/2` to see; counting it and spacing the
  retries is the controller's to do, with `{:requeue_after, ms}`. Passes
  that keep ending in a failed action are spaced like crashed ones, and so
  is a pass that performs the action the pass before performed, compared by
  name: an action must change what `observe/2` sees.

  ## Where a controller's code runs

  Nowhere in the runtime. The callbacks that take no argument (`kind/0`,
  `condition_types/0`, `owned_conditions/0`, `retention/0`, `finalizer/0`,
  `writer_entries/0`) are evaluated once, by `declare/1`, while
  `Vagus.Resource.Supervisor` starts: one that raises fails that start,
  with its name. `observe/2`, `reconcile/2`, `act/3`, `references/1`,
  `action_class/1` run in the pass's task, where one that
  raises or exits costs its resource that pass and nothing beyond it. One
  that never returns also keeps one of the passes its runtime may have in
  flight, so every call a callback makes needs a timeout. `validate/1` and
  the codec hooks run in the store, on each write to the kind: what they
  raise refuses the write, and they must not block, since every write
  waits behind them.

  ## What `observe/2` cannot reach

  `observe/2` returns `{:unavailable, reason}` when what it reads cannot be
  reached, the container engine above all (`{:unavailable,
  :engine_unavailable}`). `reconcile/2` is given that in place of an
  observation and returns the verdict for it: progressing, with that reason.
  Its store ops and its verdict are written; an action it returns is not
  performed. The runtime counts no failure and looks again shortly, whatever
  the effects ask for.

  ## Owning and attaching

  One controller owns a kind: it supplies the kind's admission and codec, and
  its verdict covers `condition_types/0`. A controller that exports
  `owned_conditions/0` is attached to a kind another owns: its verdict covers
  exactly those types and carries no other status. Who owns a kind and who
  writes which condition type is fixed by the list of controllers, before
  the store starts (`kinds/1`).

  A controller that must clean up after another reads the resource's
  `finalizers` and waits while the other's is there: its removal is a
  change, which brings the next pass.
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
  For a kind whose resources finish: how many finished ones to keep, and for
  how long. The count is the bound that always holds; an age is only known
  within one incarnation.
  """
  @callback retention() :: %{keep: non_neg_integer(), ttl_ms: non_neg_integer() | :infinity}

  @callback owned_conditions() :: [atom()]

  @doc "Held by every resource of the kind from its creation until this controller removes it."
  @callback finalizer() :: atom()

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
                      retention: 0,
                      owned_conditions: 0,
                      finalizer: 0,
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

  @typedoc """
  What a controller declares about itself, as data. Every callback that
  takes no resource is evaluated into one of these, once, before anything
  starts, so that no process has to call the controller to know it.
  """
  @type declaration :: %{
          controller: module(),
          kind: Resource.kind(),
          owner?: boolean(),
          conditions: [atom()],
          retention: %{keep: non_neg_integer(), ttl_ms: non_neg_integer() | :infinity} | nil,
          finalizer: atom() | nil,
          writer_entries: [Resource.path()]
        }

  @doc """
  Evaluates the controller's declarations. Raises, naming the controller
  and the callback, if one of them raises or returns anything but what it
  is declared to: an atom for `kind/0` and `finalizer/0`, a list of atoms
  for `condition_types/0` and `owned_conditions/0`, a list of paths for
  `writer_entries/0`, and a map of a `keep` count and a `ttl_ms` for
  `retention/0`. A value of the wrong shape would otherwise surface later
  and elsewhere, as a status write the store refuses or a step that fails
  on every resource.
  """
  @spec declare(module()) :: declaration()
  def declare(controller) do
    Code.ensure_loaded!(controller)
    owner? = owner?(controller)
    conditions = if owner?, do: :condition_types, else: :owned_conditions
    atoms = {"a list of atoms", &list_of?(&1, fn atom -> is_atom(atom) end)}
    name = {"an atom other than nil", &(is_atom(&1) and &1 != nil)}

    %{
      controller: controller,
      kind: declared(controller, :kind, :required, name),
      owner?: owner?,
      conditions: declared(controller, conditions, :required, atoms),
      retention:
        declared(
          controller,
          :retention,
          nil,
          {"%{keep: count, ttl_ms: ms | :infinity}", &retention?/1}
        ),
      finalizer: declared(controller, :finalizer, nil, name),
      writer_entries:
        declared(
          controller,
          :writer_entries,
          [],
          {"a list of spec paths", &list_of?(&1, fn path -> Resource.path?(path) end)}
        )
    }
  end

  defp declared(controller, callback, default, {expected, valid?}) do
    if default == :required or exports?(controller, callback, 0) do
      value = returned(controller, callback)

      if not valid?.(value) do
        raise ArgumentError,
              "#{inspect(controller)}.#{callback}/0 returned #{inspect(value)}, not #{expected}"
      end

      value
    else
      default
    end
  end

  defp returned(controller, callback) do
    apply(controller, callback, [])
  catch
    kind, reason ->
      raise ArgumentError,
            "#{inspect(controller)}.#{callback}/0 failed: " <>
              Exception.format_banner(kind, reason, __STACKTRACE__)
  end

  # Not `Enum`: it raises on what is not a proper list, without a name.
  defp list_of?([], _valid?), do: true
  defp list_of?([head | tail], valid?), do: valid?.(head) and list_of?(tail, valid?)
  defp list_of?(_not_a_list, _valid?), do: false

  defp retention?(%{keep: keep, ttl_ms: ttl} = retention) do
    map_size(retention) == 2 and is_integer(keep) and keep >= 0 and
      (ttl == :infinity or (is_integer(ttl) and ttl >= 0))
  end

  defp retention?(_other), do: false

  @doc """
  The kinds the store is started with, one per owning controller, each with
  its owner, the writer of every condition type and the finalizers of every
  controller on it. Takes controllers or their declarations.

  Raises, naming the controllers, on a list that cannot run: two owners of
  one kind, a controller attached to a kind nobody owns, or one condition
  type or one finalizer declared by two controllers of a kind.
  """
  @spec kinds([module() | declaration()]) :: %{Resource.kind() => Kind.t()}
  def kinds(controllers) do
    {owners, attached} =
      controllers
      |> Enum.uniq()
      |> Enum.map(&if(is_atom(&1), do: declare(&1), else: &1))
      |> Enum.split_with(& &1.owner?)

    owned =
      Enum.reduce(owners, %{}, fn owner, owned ->
        Map.update(owned, owner.kind, owner, fn rival ->
          raise ArgumentError,
                "#{inspect(rival.controller)} and #{inspect(owner.controller)} both own kind " <>
                  inspect(owner.kind)
        end)
      end)

    for %{controller: controller, kind: kind} <- attached, not is_map_key(owned, kind) do
      raise ArgumentError,
            "#{inspect(controller)} attaches to #{inspect(kind)}, which no controller owns"
    end

    Map.new(owned, fn {kind, %{controller: owner} = declaration} ->
      on_kind = [declaration | Enum.filter(attached, &(&1.kind == kind))]
      conditions = distinct_conditions!(kind, on_kind)
      finalizers = distinct_finalizers!(kind, on_kind)

      # The validator and the hooks are the controller's code, run by the
      # store on each write. It takes what they raise as a refusal.
      {kind,
       Kind.new(
         [
           validators: if(exports?(owner, :validate, 1), do: [&owner.validate/1], else: []),
           finalizers: finalizers,
           writer_entries: declaration.writer_entries,
           owner: owner,
           conditions: conditions
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
  defp distinct_finalizers!(kind, declarations) do
    held =
      for %{finalizer: finalizer, controller: c} <- declarations,
          finalizer != nil,
          do: {finalizer, c}

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

  defp distinct_conditions!(kind, declarations) do
    Enum.reduce(declarations, %{}, fn %{controller: controller, conditions: types}, declared ->
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
