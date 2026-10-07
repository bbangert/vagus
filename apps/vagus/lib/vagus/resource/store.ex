defmodule Vagus.Resource.Store do
  @moduledoc """
  The single writer of every resource, and of the resource file.

  Reads (`get/3`, `fetch/3`, `list/2`, `owned_by/2`, `claimant/3`) are ETS
  lookups in the caller. They never enter this process's mailbox, so they do
  not wait behind a flash write, and since `Vagus.Resource.Tables` holds the
  tables they keep answering while this process is restarting. Writes are
  calls: **with the store absent, reads work and writes exit.**

  Every write is `commit/2` of a list of ops, applied all or none. In order:
  the file is rewritten if a durable field changed, then ETS is written, then
  `Vagus.Resource.Watch` subscribers are told.

  What this process keeps in its own memory, and so loses when it restarts,
  is who registered for which kind. Everyone who registers is a later child
  of `Vagus.Resource.Supervisor`, which restarts them with the store.

  All functions take `instance: name` to address a store other than the
  application's.
  """

  use GenServer

  require Logger

  alias Vagus.Resource
  alias Vagus.Resource.{Kind, Persistence, Tables, Watch}

  @type instance :: atom()

  @typedoc """
  A change to one spec path. `:release` gives up the writer's ownership of
  the path and leaves the value.
  """
  @type spec_op ::
          {:put, Resource.path(), term()}
          | {:inc, Resource.path()}
          | {:delete, Resource.path()}
          | {:release, Resource.path()}

  @type op ::
          {:create, Resource.kind(), Resource.name(), map(), keyword()}
          | {:update_spec, Resource.kind(), Resource.name(), [spec_op()] | map(), keyword()}
          | {:patch_status, Resource.kind(), Resource.name(), map(), keyword()}
          | {:put_progress, Resource.kind(), Resource.name(), map(), keyword()}
          | {:add_finalizer, Resource.kind(), Resource.name(), atom()}
          | {:remove_finalizer, Resource.kind(), Resource.name(), atom()}
          | {:delete, Resource.kind(), Resource.name()}

  @type result :: {:ok, Resource.t()} | {:error, term()}

  @typedoc "`(path, data)`; replaced in tests to count or fail flash writes."
  @type persist :: (Path.t(), iodata() -> :ok | {:error, term()})

  @doc """
  Options: `:instance`, `:kinds` (`%{kind => Vagus.Resource.Kind}` fields),
  `:path` (the resource file; `nil` keeps everything in memory) and
  `:persist`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: name(instance(opts)))
  end

  @spec name(instance()) :: atom()
  def name(instance), do: Module.concat(instance, Store)

  @spec get(Resource.kind(), Resource.name(), keyword()) :: Resource.t() | nil
  def get(kind, name, opts \\ []) do
    case :ets.lookup(table(opts), {kind, name}) do
      [{_key, resource}] -> resource
      [] -> nil
    end
  end

  @spec fetch(Resource.kind(), Resource.name(), keyword()) ::
          {:ok, Resource.t()} | {:error, :not_found}
  def fetch(kind, name, opts \\ []) do
    case get(kind, name, opts) do
      nil -> {:error, :not_found}
      resource -> {:ok, resource}
    end
  end

  @doc "Not a snapshot: a concurrent commit may be half visible."
  @spec list(Resource.kind(), keyword()) :: [Resource.t()]
  def list(kind, opts \\ []) do
    opts
    |> table()
    |> :ets.select([{{{kind, :_}, :"$1"}, [], [:"$1"]}])
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Every resource that names `owner` in its `owner_refs`. A scan: there are
  tens of resources, and an index would be a second thing to keep right.
  """
  @spec owned_by(Resource.ref(), keyword()) :: [Resource.t()]
  def owned_by(%{kind: _, name: _, uid: _} = owner, opts \\ []) do
    opts
    |> table()
    |> all()
    |> Enum.filter(&(owner in &1.owner_refs))
    |> Enum.sort_by(&{&1.kind, &1.name})
  end

  @doc """
  The process holding the operation claim, as of the read: it may have died
  since. Use `claim/3` to decide anything.
  """
  @spec claimant(Resource.kind(), Resource.name(), keyword()) :: pid() | nil
  def claimant(kind, name, opts \\ []) do
    case :ets.lookup(Tables.claims(instance(opts)), {kind, name}) do
      [{_key, pid, _monitor}] -> pid
      [] -> nil
    end
  end

  @doc """
  Makes `owner` the owner of `kind`: the only writer of its `progress` and of
  status outside conditions. Options: `:validators`, run after the kind's
  own, and `:conditions`, the condition types `owner` writes.

  The same owner may register again (its runtime restarted); a different one
  is refused.
  """
  @spec register_kind(Resource.kind(), Resource.writer(), keyword()) ::
          :ok
          | {:error, {:unknown_kind, Resource.kind()}}
          | {:error, {:kind_owned, Resource.writer()}}
          | {:error, {:condition_owned, atom(), Resource.writer()}}
  def register_kind(kind, owner, opts \\ []) do
    call(opts, {:register, kind, owner, Keyword.take(opts, [:validators, :conditions]), true})
  end

  @doc "Declares the condition types (`:conditions`) an attached writer owns on `kind`."
  @spec register_writer(Resource.kind(), Resource.writer(), keyword()) ::
          :ok
          | {:error, {:unknown_kind, Resource.kind()}}
          | {:error, {:condition_owned, atom(), Resource.writer()}}
  def register_writer(kind, writer, opts \\ []) do
    call(opts, {:register, kind, writer, Keyword.take(opts, [:conditions]), false})
  end

  @doc """
  Applies `ops` in order, all or none, and returns each op's resource as that
  op left it. One rejected op rejects the commit and nothing changes.
  """
  @spec commit([op()], keyword()) :: {:ok, [Resource.t()]} | {:error, term()}
  def commit(ops, opts \\ []) when is_list(ops), do: call(opts, {:commit, ops})

  @doc """
  Options: `:owner_refs`, `:finalizers`, and `:writer` to own the spec keys
  given here.
  """
  @spec create(Resource.kind(), Resource.name(), map(), keyword()) :: result()
  def create(kind, name, spec, opts \\ []), do: one({:create, kind, name, spec, opts}, opts)

  @doc """
  `ops` is a list of `t:spec_op/0`, or a map of top-level puts.

  A write made with `:writer` owns the paths it writes. A write to a path, or
  to anything above or below a path, that another writer owns is
  `{:error, {:conflict, path, owner}}` unless `force: true` takes it over. A
  write without `:writer` owns nothing, so a user cannot block a controller
  but a controller can block a user. The generation moves only when the spec
  does.
  """
  @spec update_spec(Resource.kind(), Resource.name(), [spec_op()] | map(), keyword()) :: result()
  def update_spec(kind, name, ops, opts \\ []),
    do: one({:update_spec, kind, name, ops, opts}, opts)

  @doc """
  Merges `patch` into status; `:conditions` (a list) merges by type. `:writer`
  must have registered each condition type it writes, and must be the kind's
  owner to write anything else.
  """
  @spec patch_status(Resource.kind(), Resource.name(), map(), keyword()) :: result()
  def patch_status(kind, name, patch, opts),
    do: one({:patch_status, kind, name, patch, opts}, opts)

  @doc "Replaces `progress`. Only the kind's owner (`:writer`) may."
  @spec put_progress(Resource.kind(), Resource.name(), map(), keyword()) :: result()
  def put_progress(kind, name, progress, opts),
    do: one({:put_progress, kind, name, progress, opts}, opts)

  @spec add_finalizer(Resource.kind(), Resource.name(), atom(), keyword()) :: result()
  def add_finalizer(kind, name, finalizer, opts \\ []),
    do: one({:add_finalizer, kind, name, finalizer}, opts)

  @spec remove_finalizer(Resource.kind(), Resource.name(), atom(), keyword()) :: result()
  def remove_finalizer(kind, name, finalizer, opts \\ []),
    do: one({:remove_finalizer, kind, name, finalizer}, opts)

  @doc """
  Marks the resource `deleting?`. It is removed once it has no finalizers,
  which is at once if it has none now. The generation moves, because what is
  wanted changed and every status written before is about something else.
  """
  @spec delete(Resource.kind(), Resource.name(), keyword()) :: result()
  def delete(kind, name, opts \\ []), do: one({:delete, kind, name}, opts)

  @doc """
  Takes the operation claim on `{kind, name}` for the calling process, which
  holds it until `release_claim/3` or its own death. The resource need not
  exist: an install claims the name it is about to create. Never persisted.
  """
  @spec claim(Resource.kind(), Resource.name(), keyword()) :: :ok | {:error, :busy}
  def claim(kind, name, opts \\ []), do: call(opts, {:claim, {kind, name}})

  @spec release_claim(Resource.kind(), Resource.name(), keyword()) ::
          :ok | {:error, :not_holder}
  def release_claim(kind, name, opts \\ []), do: call(opts, {:release_claim, {kind, name}})

  defp instance(opts), do: Keyword.get(opts, :instance, Resource)
  defp table(opts), do: Tables.resources(instance(opts))
  defp call(opts, request), do: GenServer.call(name(instance(opts)), request)

  defp one(op, opts) do
    with {:ok, [resource]} <- commit([op], opts), do: {:ok, resource}
  end

  defp all(table), do: :ets.select(table, [{{{:_, :_}, :"$1"}, [], [:"$1"]}])

  # Loading is the start result, not a continue: a later child must never
  # start against a half-loaded store, and a file that cannot be read has to
  # fail the start rather than look like "nothing installed".
  @impl true
  def init(opts) do
    instance = instance(opts)

    kinds =
      Map.new(Keyword.get(opts, :kinds, %{}), fn {kind, fields} -> {kind, Kind.new(fields)} end)

    state = %{
      instance: instance,
      table: Tables.resources(instance),
      claims: Tables.claims(instance),
      path: Keyword.get(opts, :path),
      persist: Keyword.get(opts, :persist, &Persistence.write/2),
      kinds: kinds,
      registrations:
        Map.new(kinds, fn {kind, _fields} ->
          {kind, %{owner: nil, validators: [], conditions: %{}}}
        end)
    }

    with :ok <- Tables.take(instance),
         {:ok, contents} <- load(state) do
      restore(state, contents)
      remonitor(state.claims)
      {:ok, state}
    else
      {:error, reason} ->
        Logger.error("resource store #{inspect(state.path)} cannot start: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:commit, ops}, _from, state) do
    txn = %{state: state, rows: %{}, removed: [], next_uid: next_uid(state.table)}

    with {:ok, results, txn} <- run_all(ops, txn),
         changes = changes(state.table, txn),
         :ok <- persist(state, txn, changes) do
      apply_changes(state, txn, changes)
      {:reply, {:ok, results}, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:register, kind, writer, opts, owner?}, _from, state) do
    with {:ok, registration} <- registration(state, kind),
         :ok <- free_for(registration, writer, owner?),
         {:ok, conditions} <-
           declare(registration.conditions, writer, Keyword.get(opts, :conditions, [])) do
      registration = %{registration | conditions: conditions}

      registration =
        if owner?,
          do: %{registration | owner: writer, validators: Keyword.get(opts, :validators, [])},
          else: registration

      {:reply, :ok, put_in(state.registrations[kind], registration)}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:claim, key}, {pid, _tag}, state) do
    if :ets.member(state.claims, key) do
      {:reply, {:error, :busy}, state}
    else
      # The monitor lives in the row so a replacement store can find every
      # claim and watch its holder again.
      :ets.insert(state.claims, {key, pid, Process.monitor(pid)})
      {:reply, :ok, state}
    end
  end

  def handle_call({:release_claim, key}, {pid, _tag}, state) do
    case :ets.lookup(state.claims, key) do
      [{^key, ^pid, monitor}] ->
        Process.demonitor(monitor, [:flush])
        :ets.delete(state.claims, key)
        {:reply, :ok, state}

      _other ->
        {:reply, {:error, :not_holder}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    :ets.match_delete(state.claims, {:_, pid, monitor})
    {:noreply, state}
  end

  # `Tables.take/1` hands the tables over in `init/1`; the transfer notices
  # arrive here afterwards.
  def handle_info({:"ETS-TRANSFER", _table, _from, _data}, state), do: {:noreply, state}

  defp load(%{path: nil}), do: {:ok, nil}
  defp load(%{path: path, kinds: kinds}), do: Persistence.read(path, kinds)

  # Without a file the rows that survived in ETS are all there is.
  defp restore(%{table: table}, nil) do
    :ets.insert_new(table, {:next_uid, 1})
    :ok
  end

  # The file wins over the rows a previous store left in ETS. They differ
  # only when that store died between its flash write and its ETS write, and
  # then nobody was told about the change either, so it is announced now.
  # Status is not in the file; it stays with the same resource.
  defp restore(%{table: table} = state, %{resources: resources, next_uid: next_uid}) do
    stale = Map.new(all(table), &{key(&1), &1})

    rows =
      for resource <- resources do
        case stale[key(resource)] do
          %Resource{uid: uid, status: status} when uid == resource.uid ->
            %{resource | status: status}

          _other ->
            resource
        end
      end

    changed = Enum.reject(rows, &(stale[key(&1)] == &1))
    gone = stale |> Map.drop(Enum.map(rows, &key/1)) |> Map.values()

    next_uid =
      Enum.max([next_uid, next_uid(table) | Enum.map(resources, &(&1.uid + 1))])

    :ets.insert(table, [{:next_uid, next_uid} | Enum.map(changed, &{key(&1), &1})])
    for resource <- gone, do: :ets.delete(table, key(resource))

    for resource <- gone, do: Watch.notify(state.instance, :removed, resource)
    for resource <- changed, do: Watch.notify(state.instance, :changed, resource)
    :ok
  end

  defp remonitor(claims) do
    for {key, pid, _dead_monitor} <- :ets.tab2list(claims) do
      :ets.insert(claims, {key, pid, Process.monitor(pid)})
    end
  end

  # The counter sits beside the rows it numbered so that it survives with
  # them: a uid handed out twice would let a new resource inherit an old
  # one's children.
  defp next_uid(table) do
    case :ets.lookup(table, :next_uid) do
      [{:next_uid, next_uid}] -> next_uid
      [] -> 1
    end
  end

  defp key(%Resource{kind: kind, name: name}), do: {kind, name}

  defp run_all(ops, txn) do
    Enum.reduce_while(ops, {:ok, [], txn}, fn op, {:ok, results, txn} ->
      case run(op, txn) do
        {:ok, resource, txn} -> {:cont, {:ok, [resource | results], txn}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results, txn} -> {:ok, Enum.reverse(results), txn}
      {:error, _reason} = error -> error
    end
  end

  defp changes(table, txn) do
    Enum.flat_map(txn.rows, fn {key, new} ->
      case row(table, key) do
        ^new -> []
        old -> [{key, old, new}]
      end
    end)
  end

  defp persist(state, txn, changes) do
    if Enum.any?(changes, fn {_key, old, new} -> durable(old) != durable(new) end) do
      resources =
        state.table
        |> all()
        |> Map.new(&{key(&1), &1})
        |> Map.merge(txn.rows)
        |> Enum.reject(fn {_key, resource} -> resource == nil end)
        |> Enum.sort()
        |> Enum.map(&elem(&1, 1))

      # Encoded even with no file to write, so a spec that flash would refuse
      # is refused on the host and in tests too.
      with {:ok, data} <-
             Persistence.encode(%{resources: resources, next_uid: txn.next_uid}, state.kinds) do
        write(state, data)
      end
    else
      :ok
    end
  end

  defp write(%{path: nil}, _data), do: :ok

  defp write(%{path: path, persist: persist}, data) do
    with {:error, reason} <- persist.(path, data) do
      Logger.error("resource store #{path} not written: #{inspect(reason)}")
      {:error, {:persist_failed, reason}}
    end
  end

  defp durable(nil), do: nil
  defp durable(%Resource{} = resource), do: %{resource | status: %{}}

  # Flash, then ETS, then subscribers.
  #
  # Flash before ETS: a failed or interrupted flash write leaves ETS alone,
  # so no reader ever acts on desired state a reboot would take back. The
  # failure this order tolerates is the store dying after the file is renamed
  # and before the insert: readers then see less than flash holds until the
  # next store reads the file (`restore/2`), and the caller, whose call
  # exited, cannot know which way it went.
  #
  # ETS before subscribers: a subscriber that reads when woken finds a row at
  # least as new as the change that woke it.
  defp apply_changes(state, txn, changes) do
    if changes != [] do
      :ets.insert(state.table, [
        {:next_uid, txn.next_uid} | for({key, _old, %Resource{} = new} <- changes, do: {key, new})
      ])

      for {key, _old, nil} <- changes, do: :ets.delete(state.table, key)
    end

    for resource <- Enum.reverse(txn.removed),
        do: Watch.notify(state.instance, :removed, resource)

    for {_key, _old, %Resource{} = new} <- changes,
        do: Watch.notify(state.instance, :changed, new)

    :ok
  end

  defp run({:create, kind, name, spec, opts}, txn) when is_binary(name) and is_map(spec) do
    owner_refs = Keyword.get(opts, :owner_refs, [])

    with {:ok, _registration} <- registration(txn.state, kind),
         :ok <- absent(txn, {kind, name}),
         :ok <- known_refs(txn.state, owner_refs),
         {:ok, admitted} <- admit(txn.state, kind, spec) do
      writer = opts[:writer]

      resource = %Resource{
        kind: kind,
        name: name,
        uid: txn.next_uid,
        spec: admitted,
        finalizers: Keyword.get(opts, :finalizers, []),
        owner_refs: owner_refs,
        managed_fields:
          if(writer, do: Map.new(spec, fn {key, _} -> {[key], writer} end), else: %{})
      }

      put(%{txn | next_uid: txn.next_uid + 1}, resource)
    end
  end

  defp run({:update_spec, kind, name, ops, opts}, txn) do
    with {:ok, resource} <- lookup(txn, {kind, name}),
         ops = spec_ops(ops),
         :ok <- writable(resource, ops),
         {:ok, spec, managed} <-
           apply_spec_ops(ops, resource, opts[:writer], opts[:force] == true),
         {:ok, spec} <- readmit(txn.state, resource, spec) do
      generation =
        if spec == resource.spec, do: resource.generation, else: resource.generation + 1

      put(txn, %{resource | spec: spec, managed_fields: managed, generation: generation})
    end
  end

  defp run({:patch_status, kind, name, patch, opts}, txn) when is_map(patch) do
    {conditions, rest} = Map.pop(patch, :conditions, [])

    with {:ok, resource} <- lookup(txn, {kind, name}),
         {:ok, registration} <- registration(txn.state, kind),
         :ok <- owns_status(registration, conditions, rest, opts[:writer]) do
      resource = %{resource | status: Map.merge(resource.status, rest)}
      put(txn, Enum.reduce(conditions, resource, &Resource.put_condition(&2, &1)))
    end
  end

  defp run({:put_progress, kind, name, progress, opts}, txn) when is_map(progress) do
    with {:ok, resource} <- lookup(txn, {kind, name}),
         {:ok, registration} <- registration(txn.state, kind),
         :ok <- owner(registration, :progress, opts[:writer]) do
      put(txn, %{resource | progress: progress})
    end
  end

  defp run({:add_finalizer, kind, name, finalizer}, txn) do
    case lookup(txn, {kind, name}) do
      # Cleanup that was not owed when deletion began cannot be added to it.
      {:ok, %Resource{deleting?: true}} ->
        {:error, :deleting}

      {:ok, resource} ->
        put(txn, %{resource | finalizers: Enum.uniq(resource.finalizers ++ [finalizer])})

      {:error, _reason} = error ->
        error
    end
  end

  defp run({:remove_finalizer, kind, name, finalizer}, txn) do
    with {:ok, resource} <- lookup(txn, {kind, name}) do
      put(txn, %{resource | finalizers: resource.finalizers -- [finalizer]})
    end
  end

  defp run({:delete, kind, name}, txn) do
    case lookup(txn, {kind, name}) do
      {:ok, %Resource{deleting?: true} = resource} ->
        {:ok, resource, txn}

      {:ok, resource} ->
        put(txn, %{resource | deleting?: true, generation: resource.generation + 1})

      {:error, _reason} = error ->
        error
    end
  end

  defp run(op, _txn), do: {:error, {:bad_op, op}}

  defp put(txn, %Resource{deleting?: true, finalizers: []} = resource) do
    {:ok, resource,
     %{txn | rows: Map.put(txn.rows, key(resource), nil), removed: [resource | txn.removed]}}
  end

  defp put(txn, %Resource{} = resource),
    do: {:ok, resource, %{txn | rows: Map.put(txn.rows, key(resource), resource)}}

  defp row(table, key) do
    case :ets.lookup(table, key) do
      [{^key, resource}] -> resource
      [] -> nil
    end
  end

  defp current(txn, key) do
    case txn.rows do
      %{^key => resource} -> resource
      _untouched -> row(txn.state.table, key)
    end
  end

  defp lookup(txn, key) do
    case current(txn, key) do
      nil -> {:error, :not_found}
      resource -> {:ok, resource}
    end
  end

  defp absent(txn, key),
    do: if(current(txn, key) == nil, do: :ok, else: {:error, :already_exists})

  # A kind the store was not started with could be written but never read
  # back, which would fail the next start.
  defp registration(state, kind) do
    case state.registrations do
      %{^kind => registration} -> {:ok, registration}
      _unknown -> {:error, {:unknown_kind, kind}}
    end
  end

  defp known_refs(state, refs) do
    case Enum.reject(
           refs,
           &match?(%{kind: kind, name: _, uid: _} when is_map_key(state.kinds, kind), &1)
         ) do
      [] -> :ok
      [ref | _] -> {:error, {:bad_owner_ref, ref}}
    end
  end

  defp free_for(%{owner: owner}, writer, true) when owner not in [nil, writer],
    do: {:error, {:kind_owned, owner}}

  defp free_for(_registration, _writer, _owner?), do: :ok

  defp declare(conditions, writer, types) do
    others = Map.reject(conditions, fn {_type, owner} -> owner == writer end)

    case Enum.find(types, &is_map_key(others, &1)) do
      nil -> {:ok, Map.merge(others, Map.new(types, &{&1, writer}))}
      type -> {:error, {:condition_owned, type, others[type]}}
    end
  end

  defp owns_status(registration, conditions, rest, writer) do
    foreign =
      Enum.find(conditions, &(writer == nil or registration.conditions[&1.type] != writer))

    cond do
      foreign -> {:error, {:not_owner, foreign.type, writer}}
      rest == %{} -> :ok
      true -> owner(registration, rest |> Map.keys() |> hd(), writer)
    end
  end

  defp owner(%{owner: owner}, _field, writer) when writer != nil and writer == owner, do: :ok
  defp owner(_registration, field, writer), do: {:error, {:not_owner, field, writer}}

  defp admit(state, kind, spec) do
    validators = state.kinds[kind].validators ++ state.registrations[kind].validators

    Enum.reduce_while(validators, {:ok, spec}, fn validator, {:ok, spec} ->
      case validator.(spec) do
        {:ok, %{} = spec} -> {:cont, {:ok, spec}}
        {:error, reason} -> {:halt, {:error, {:invalid, reason}}}
      end
    end)
  end

  # Giving up a path must work on a spec that would no longer be admitted.
  defp readmit(_state, %Resource{spec: spec}, spec), do: {:ok, spec}
  defp readmit(state, %Resource{kind: kind}, spec), do: admit(state, kind, spec)

  defp spec_ops(%{} = puts), do: Enum.map(puts, fn {key, value} -> {:put, [key], value} end)
  defp spec_ops(ops) when is_list(ops), do: ops

  # Nothing new may be asked of a resource on its way out, but a writer can
  # still let go of what it holds there.
  defp writable(%Resource{deleting?: false}, _ops), do: :ok

  defp writable(%Resource{}, ops) do
    if Enum.all?(ops, &match?({op, _path} when op in [:delete, :release], &1)),
      do: :ok,
      else: {:error, :deleting}
  end

  defp apply_spec_ops(ops, resource, writer, force?) do
    Enum.reduce_while(ops, {:ok, resource.spec, resource.managed_fields}, fn
      op, {:ok, spec, managed} ->
        case apply_spec_op(op, spec, managed, writer, force?) do
          {:ok, _spec, _managed} = ok -> {:cont, ok}
          {:error, _reason} = error -> {:halt, error}
        end
    end)
  end

  defp apply_spec_op({:release, path}, spec, managed, writer, _force?) do
    if managed[path] == writer,
      do: {:ok, spec, Map.delete(managed, path)},
      else: {:ok, spec, managed}
  end

  defp apply_spec_op({:delete, [_ | _] = path}, spec, managed, writer, force?) do
    with {:ok, managed} <- own(managed, path, writer, force?) do
      {:ok, delete_path(spec, path), Map.delete(managed, path)}
    end
  end

  defp apply_spec_op({:inc, path}, spec, managed, writer, force?) do
    value = (get_path(spec, path) || 0) + 1
    apply_spec_op({:put, path, value}, spec, managed, writer, force?)
  end

  defp apply_spec_op({:put, [_ | _] = path, value}, spec, managed, writer, force?) do
    with {:ok, managed} <- own(managed, path, writer, force?) do
      {:ok, put_path(spec, path, value), managed}
    end
  end

  defp apply_spec_op(op, _spec, _managed, _writer, _force?), do: {:error, {:bad_op, op}}

  # Ownership is of a subtree: owning `[:a]` and writing `[:a, :b]` collide
  # either way round.
  defp own(managed, path, writer, force?) do
    rivals =
      for {owned, owner} <- managed,
          owner != writer,
          List.starts_with?(owned, path) or List.starts_with?(path, owned),
          do: {owned, owner}

    case Enum.sort(rivals) do
      [{owned, owner} | _] when not force? ->
        {:error, {:conflict, owned, owner}}

      rivals ->
        managed = Map.drop(managed, Enum.map(rivals, &elem(&1, 0)))
        {:ok, if(writer, do: Map.put(managed, path, writer), else: managed)}
    end
  end

  defp get_path(spec, path) do
    Enum.reduce_while(path, spec, fn
      key, %{} = map -> {:cont, Map.get(map, key)}
      _key, _leaf -> {:halt, nil}
    end)
  end

  defp put_path(map, [key], value), do: Map.put(map, key, value)

  defp put_path(map, [key | rest], value) do
    inner =
      case map do
        %{^key => %{} = inner} -> inner
        _absent_or_leaf -> %{}
      end

    Map.put(map, key, put_path(inner, rest, value))
  end

  defp delete_path(map, [key]), do: Map.delete(map, key)

  defp delete_path(map, [key | rest]) do
    case map do
      %{^key => %{} = inner} -> Map.put(map, key, delete_path(inner, rest))
      _absent_or_leaf -> map
    end
  end
end
