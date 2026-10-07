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

  **A write whose call exits may have been applied.** That is a timeout as
  much as the store dying: the store may still be inside the flash write, or
  have died after it. When the store cannot tell whether a flash write will
  survive a power cut, it stops rather than answer, and its replacement
  takes whatever the file holds. The caller reads to find out.

  What this process keeps in its own memory, and so loses when it restarts,
  is who registered for which kind. Everyone who registers is a later child
  of `Vagus.Resource.Supervisor`, which restarts them with the store. Until
  an owner has registered again, status and progress writes for its kind are
  refused, since nobody owns them; spec writes are admitted as always,
  because the validators are part of the kind the store was started with and
  not of any registration.

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
          | {:release_writer, Resource.kind(), Resource.name(), Resource.writer()}
          | {:expect, Resource.kind(), Resource.name(),
             [uid: pos_integer(), generation: pos_integer()]}

  @type result :: {:ok, Resource.t()} | {:error, term()}

  @typedoc """
  `(path, data)`, with `Vagus.Resource.Persistence.write/2`'s results;
  replaced in tests to count or fail flash writes.
  """
  @type persist :: (Path.t(), iodata() -> :ok | {:error, term()} | {:unknown, term()})

  # A commit is two fsyncs on flash that image pulls are writing to at the
  # same time, and it queues behind every commit ahead of it. The default 5 s
  # would turn a busy disk into callers that gave up on writes that then
  # happened.
  @write_timeout 30_000

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
  status outside conditions. `:conditions` are the condition types `owner`
  writes.

  The same owner may register again (its runtime restarted); a different one
  is refused.
  """
  @spec register_kind(Resource.kind(), Resource.writer(), keyword()) ::
          :ok
          | {:error, {:unknown_kind, Resource.kind()}}
          | {:error, {:kind_owned, Resource.writer()}}
          | {:error, {:condition_owned, atom(), Resource.writer()}}
          | {:error, {:bad_conditions, term()}}
          | {:error, {:bad_writer, nil}}
  def register_kind(kind, owner, opts \\ []) do
    call(opts, {:register, kind, owner, Keyword.get(opts, :conditions, []), true})
  end

  @doc "Declares the condition types (`:conditions`) an attached writer owns on `kind`."
  @spec register_writer(Resource.kind(), Resource.writer(), keyword()) ::
          :ok
          | {:error, {:unknown_kind, Resource.kind()}}
          | {:error, {:condition_owned, atom(), Resource.writer()}}
          | {:error, {:bad_conditions, term()}}
          | {:error, {:bad_writer, nil}}
  def register_writer(kind, writer, opts \\ []) do
    call(opts, {:register, kind, writer, Keyword.get(opts, :conditions, []), false})
  end

  @doc """
  Applies `ops` in order, all or none, and returns each op's resource as that
  op left it. One rejected op rejects the commit and nothing changes.
  """
  @spec commit([op()], keyword()) :: {:ok, [Resource.t()]} | {:error, term()}
  def commit(ops, opts \\ []) when is_list(ops) do
    with {:ok, resources, _changed?} <- commit_changed(ops, opts), do: {:ok, resources}
  end

  @doc """
  As `commit/2`, and also whether the commit changed anything: a resource,
  or the uid counter, which a create and delete of one resource moves
  without leaving a row. A commit that changed nothing wrote nothing and
  told nobody.
  """
  @spec commit_changed([op()], keyword()) ::
          {:ok, [Resource.t()], changed? :: boolean()} | {:error, term()}
  def commit_changed(ops, opts \\ []) when is_list(ops), do: call(opts, {:commit, ops})

  @doc """
  Options: `:owner_refs`, `:finalizers`, and `:writer` to own the spec keys
  given here. The kind's own finalizers are added to the ones given.
  """
  @spec create(Resource.kind(), Resource.name(), map(), keyword()) :: result()
  def create(kind, name, spec, opts \\ []), do: one({:create, kind, name, spec, opts}, opts)

  @doc """
  `ops` is a list of `t:spec_op/0`, or a map of top-level puts.

  A write made with `:writer` owns the paths it writes. A write to a path, or
  to anything above or below a path, that another writer owns is
  `{:error, {:conflict, path, owner}}` unless `force: true` takes it over. A
  write without `:writer` owns nothing, so a user cannot block a controller
  but a controller can block a user. Deleting a path also gives up everything
  the writer owned beneath it. The generation moves only when the spec does.
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
  Gives up every spec path `writer` owns on the resource. A path under one of
  the kind's `writer_entries` is deleted with its value; any other keeps its
  value and becomes unowned. For a writer that no longer exists to release
  its paths itself.
  """
  @spec release_writer(Resource.kind(), Resource.name(), Resource.writer(), keyword()) ::
          result()
  def release_writer(kind, name, writer, opts \\ []),
    do: one({:release_writer, kind, name, writer}, opts)

  @doc """
  Rejects the commit it is part of unless the resource has this `:uid` and
  `:generation` (either may be left out), with
  `{:error, {:precondition, {kind, name}, :uid | :generation | :not_found}}`.

  A writer that decided from a read uses the uid: a resource deleted and
  created again under the same name is a different one, and what was decided
  about its predecessor must not land on it.
  """
  @spec expect(Resource.kind(), Resource.name(), keyword(), keyword()) :: result()
  def expect(kind, name, expected, opts \\ []), do: one({:expect, kind, name, expected}, opts)

  @doc """
  Has the store send `message` to each of `pids`. The store is also the
  sender of every change notification, so a subscriber receives `message`
  after the notifications of every commit that returned before this call:
  what it does on receipt, it does having heard of all of them.
  """
  @spec relay([pid()], term(), keyword()) :: :ok
  def relay(pids, message, opts \\ []) when is_list(pids), do: call(opts, {:relay, pids, message})

  @typedoc "Sees the resource, or `nil` when there is none."
  @type await_fun :: (Resource.t() | nil -> {:halt, term()} | :cont)

  @doc """
  Blocks the caller until `fun` halts on the resource, and returns what it
  halted with; `{:error, {:timeout, last_seen}}` after `:timeout` (5 s).

  The caller subscribes to the object before the first read, so no change
  falls between the two, and reads again on every notification. It also
  reads every `:poll` (1 s), for the notification that never comes: one the
  store did not live to send, or a wait for something that is not a change
  to the resource at all. A store that restarts during the wait costs
  nothing else: the subscription is in `Vagus.Resource.Watch`, which
  outlives it.

  **The wait does not outlive `Watch`.** When the registry goes, with the
  whole subtree, the caller goes with it as every subscriber does: by its
  link to the registry, with the registry's reason, or by an exit from here
  with `{:watch_down, reason}`, whichever comes first. A caller that traps
  exits gets the second. The reason is the registry's, or `:noproc` for one
  that was already gone, or went, as the wait began. A wait that went on without a subscription would
  end as a timeout that says nothing of why.

  The caller must hold no subscription of its own to the same object; the
  notifications left in its mailbox when this returns are dropped. To be
  sure of that it asks the store once before returning, so it returns behind
  whatever the store is then writing.
  """
  @spec await(Resource.kind(), Resource.name(), await_fun(), keyword()) ::
          {:ok, term()} | {:error, {:timeout, Resource.t() | nil}}
  def await(kind, name, fun, opts \\ []) when is_function(fun, 1) do
    watch = Keyword.take(opts, [:instance])
    key = {:object, kind, name}
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 5_000)
    # For the caller that traps exits, whom the link to the registry only
    # sends a message.
    registry = Process.monitor(Watch.name(instance(opts)))
    subscribe(key, watch, registry)

    try do
      await_loop({kind, name}, fun, {deadline, Keyword.get(opts, :poll, 1_000), registry}, opts)
    after
      Process.demonitor(registry, [:flush])
      withdraw(key, watch)
      behind_dispatch(opts)
      drop_notifications(kind, name)
    end
  end

  # With no registry there is nothing to subscribe to and nothing to wait
  # for: the same end as for one that goes during the wait.
  defp subscribe(key, watch, registry) do
    Watch.subscribe(key, watch)
  rescue
    ArgumentError ->
      Process.demonitor(registry, [:flush])
      exit({:watch_down, :noproc})
  end

  # With the registry gone there is nothing to withdraw, and raising here
  # would replace the exit that says so.
  defp withdraw(key, watch) do
    Watch.unsubscribe(key, watch)
  rescue
    ArgumentError -> :ok
  end

  # The store may have read the subscription, for a notification it is about
  # to send, just before it was withdrawn. It answers this after that send,
  # so the notification is in the mailbox to be dropped.
  #
  # With the store gone or not answering the wait still returns what it
  # found: its answer came from the tables, not from the store, and a
  # command that got its condition must not fail on tidying up. A store that
  # died while asked had sent whatever it was going to before the exit that
  # says so arrived. One that is merely slow may still send, and that one
  # notification is left for the caller; it says "look again", which no
  # caller is harmed by doing.
  defp behind_dispatch(opts) do
    relay([], nil, opts)
  catch
    :exit, _reason -> :ok
  end

  defp await_loop({kind, name} = key, fun, {deadline, poll, registry} = timing, opts) do
    resource = get(kind, name, opts)

    case fun.(resource) do
      {:halt, result} ->
        {:ok, result}

      :cont ->
        case deadline - System.monotonic_time(:millisecond) do
          remaining when remaining <= 0 ->
            {:error, {:timeout, resource}}

          remaining ->
            receive do
              {Watch, _event, %{kind: ^kind, name: ^name}} -> :ok
              {:DOWN, ^registry, :process, _pid, reason} -> exit({:watch_down, reason})
            after
              min(remaining, poll) -> :ok
            end

            await_loop(key, fun, timing, opts)
        end
    end
  end

  defp drop_notifications(kind, name) do
    receive do
      {Watch, _event, %{kind: ^kind, name: ^name}} -> drop_notifications(kind, name)
    after
      0 -> :ok
    end
  end

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
  defp call(opts, request), do: GenServer.call(name(instance(opts)), request, @write_timeout)

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
        Map.new(kinds, fn {kind, _fields} -> {kind, %{owner: nil, conditions: %{}}} end)
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
    next_uid = next_uid(state.table)
    txn = %{state: state, rows: %{}, removed: [], next_uid: next_uid}

    with {:ok, results, txn} <- run_all(ops, [], txn),
         changes = changes(state.table, txn),
         :ok <- persist(state, txn, changes) do
      apply_changes(state, txn, changes)
      {:reply, {:ok, results, changes != [] or txn.next_uid != next_uid}, state}
    else
      {:error, _reason} = error ->
        {:reply, error, state}

      # The file holds the commit and ETS does not. Answering either way
      # would be a guess, so the call exits and the next store reads the file.
      {:unknown, reason} ->
        {:stop, {:persist_outcome_unknown, reason}, state}
    end
  end

  def handle_call({:relay, pids, message}, _from, state) do
    for pid <- pids, is_pid(pid), do: send(pid, message)
    {:reply, :ok, state}
  end

  def handle_call({:register, kind, writer, types, owner?}, _from, state) do
    with {:ok, registration} <- registration(state, kind),
         # `nil` is how "no writer" is spelled everywhere else.
         :ok <- if(writer == nil, do: {:error, {:bad_writer, nil}}, else: :ok),
         :ok <- free_for(registration, writer, owner?),
         {:ok, conditions} <- declare(registration.conditions, writer, types) do
      registration = %{registration | conditions: conditions}
      registration = if owner?, do: %{registration | owner: writer}, else: registration
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

  def handle_info(_other, state), do: {:noreply, state}

  defp load(%{path: nil}), do: {:ok, nil}
  defp load(%{path: path, kinds: kinds}), do: Persistence.read(path, kinds)

  # Without a file the rows that survived in ETS are all there is.
  defp restore(%{table: table}, nil) do
    :ets.insert_new(table, {:next_uid, 1})
    :ok
  end

  # The file wins over the rows a previous store left in ETS. That store
  # wrote flash first, so wherever the two differ it stopped or died before
  # its ETS write, and nobody was told about the change either: it is
  # announced now. Status is not in the file; it stays with the same resource.
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

  defp run_all([], results, txn), do: {:ok, Enum.reverse(results), txn}

  defp run_all([op | ops], results, txn) do
    case if(options?(op), do: run(op, txn), else: {:error, {:bad_op, op}}) do
      {:ok, resource, txn} -> run_all(ops, [resource | results], txn)
      {:error, _reason} = error -> error
    end
  end

  defp run_all(not_a_list, _results, _txn), do: {:error, {:bad_op, not_a_list}}

  # Options are read with `Keyword`, which raises on anything but pairs.
  defp options?({_op, _kind, _name, _arg, opts}),
    do: every?(opts, &match?({key, _value} when is_atom(key), &1))

  defp options?(_op), do: true

  defp changes(table, txn) do
    Enum.flat_map(txn.rows, fn {key, new} ->
      case row(table, key) do
        ^new -> []
        old -> [{key, old, new}]
      end
    end)
  end

  # The counter is durable too: a create and delete of one resource in one
  # commit changes no row, and its uid must still never be given out again.
  defp persist(state, txn, changes) do
    if txn.next_uid != next_uid(state.table) or
         Enum.any?(changes, fn {_key, old, new} -> durable(old) != durable(new) end) do
      resources =
        state.table
        |> all()
        |> Map.new(&{key(&1), &1})
        |> Map.merge(txn.rows)
        |> Enum.reject(fn {_key, resource} -> resource == nil end)
        |> Enum.sort()
        |> Enum.map(&elem(&1, 1))

      # Encoded, and read back, even with no file to write, so what flash
      # would refuse or return changed is refused on the host and in tests too.
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
    case persist.(path, data) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("resource store #{path} not written: #{inspect(reason)}")
        {:error, {:persist_failed, reason}}

      {:unknown, reason} ->
        Logger.error("resource store #{path} written but not synced: #{inspect(reason)}")
        {:unknown, reason}
    end
  end

  defp durable(nil), do: nil
  defp durable(%Resource{} = resource), do: %{resource | status: %{}}

  # Flash, then ETS, then subscribers.
  #
  # Flash before ETS: ETS is written only once flash holds the commit, so no
  # reader ever acts on desired state a reboot would take back. The failure
  # this order tolerates is the file holding a commit ETS never got: the
  # store died between the two, or stopped because the write failed after
  # its rename. Readers then see less than flash holds until the next store
  # reads the file (`restore/2`), and the caller, whose call exited, cannot
  # know which way it went.
  #
  # ETS before subscribers: a subscriber that reads when woken finds a row at
  # least as new as the change that woke it.
  defp apply_changes(state, txn, changes) do
    # Only what a reader could have seen is announced as gone; a resource
    # created and deleted inside this commit never was.
    removed =
      for %Resource{uid: uid} = resource <- Enum.reverse(txn.removed),
          match?(%Resource{uid: ^uid}, row(state.table, key(resource))),
          do: resource

    :ets.insert(state.table, [
      {:next_uid, txn.next_uid} | for({key, _old, %Resource{} = new} <- changes, do: {key, new})
    ])

    for {key, _old, nil} <- changes, do: :ets.delete(state.table, key)

    for resource <- removed, do: Watch.notify(state.instance, :removed, resource)

    for {_key, _old, %Resource{} = new} <- changes,
        do: Watch.notify(state.instance, :changed, new)

    :ok
  end

  defp run({:create, kind, name, spec, opts} = op, txn)
       when is_binary(name) and is_map(spec) and is_list(opts) do
    owner_refs = Keyword.get(opts, :owner_refs, [])
    finalizers = Keyword.get(opts, :finalizers, [])

    with {:ok, _registration} <- registration(txn.state, kind),
         :ok <- absent(txn, {kind, name}),
         writer = opts[:writer],
         :ok <- creatable(op, finalizers, writer),
         :ok <- known_refs(txn.state, owner_refs),
         {:ok, admitted} <- admit(txn.state, kind, spec) do
      resource = %Resource{
        kind: kind,
        name: name,
        uid: txn.next_uid,
        spec: admitted,
        # One release per name has to be enough to let the resource go.
        finalizers: Enum.uniq(txn.state.kinds[kind].finalizers ++ finalizers),
        owner_refs: owner_refs,
        managed_fields:
          if(writer != nil, do: Map.new(spec, fn {key, _} -> {[key], writer} end), else: %{})
      }

      put(%{txn | next_uid: txn.next_uid + 1}, resource)
    end
  end

  defp run({:update_spec, kind, name, ops, opts}, txn) when is_list(opts) do
    with {:ok, resource} <- lookup(txn, {kind, name}),
         {:ok, ops} <- spec_ops(ops),
         :ok <- writable(resource, ops),
         {:ok, spec, managed} <-
           apply_spec_ops(ops, resource, opts[:writer], opts[:force] == true),
         {:ok, spec} <- readmit(txn.state, resource, spec) do
      generation =
        if spec == resource.spec, do: resource.generation, else: resource.generation + 1

      put(txn, %{resource | spec: spec, managed_fields: managed, generation: generation})
    end
  end

  defp run({:patch_status, kind, name, patch, opts} = op, txn)
       when is_map(patch) and is_list(opts) do
    {conditions, rest} = Map.pop(patch, :conditions, [])

    with {:ok, resource} <- lookup(txn, {kind, name}),
         {:ok, registration} <- registration(txn.state, kind),
         :ok <- if(every?(conditions, &condition?/1), do: :ok, else: {:error, {:bad_op, op}}),
         :ok <- owns_status(registration, conditions, rest, opts[:writer]) do
      resource = %{resource | status: Map.merge(resource.status, rest)}
      put(txn, Enum.reduce(conditions, resource, &Resource.put_condition(&2, &1)))
    end
  end

  defp run({:put_progress, kind, name, progress, opts}, txn)
       when is_map(progress) and is_list(opts) do
    with {:ok, resource} <- lookup(txn, {kind, name}),
         {:ok, registration} <- registration(txn.state, kind),
         :ok <- owner(registration, :progress, opts[:writer]) do
      put(txn, %{resource | progress: progress})
    end
  end

  defp run({:add_finalizer, kind, name, finalizer}, txn) when is_atom(finalizer) do
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

  defp run({:remove_finalizer, kind, name, finalizer}, txn) when is_atom(finalizer) do
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

  # Also for a resource on its way out: letting go is always allowed.
  defp run({:release_writer, kind, name, writer}, txn) when writer != nil do
    with {:ok, resource} <- lookup(txn, {kind, name}),
         owned = for({path, ^writer} <- resource.managed_fields, do: path),
         entries = txn.state.kinds[kind].writer_entries,
         spec =
           owned
           |> Enum.filter(&entry?(&1, entries))
           |> Enum.reduce(resource.spec, &delete_path(&2, &1)),
         {:ok, spec} <- readmit(txn.state, resource, spec) do
      generation =
        if spec == resource.spec, do: resource.generation, else: resource.generation + 1

      put(txn, %{
        resource
        | spec: spec,
          managed_fields: Map.drop(resource.managed_fields, owned),
          generation: generation
      })
    end
  end

  defp run({:expect, kind, name, expected} = op, txn) do
    known? = &match?({field, value} when field in [:uid, :generation] and is_integer(value), &1)

    with :ok <- if(every?(expected, known?), do: :ok, else: {:error, {:bad_op, op}}),
         %Resource{} = resource <- current(txn, {kind, name}),
         nil <- Enum.find(expected, fn {field, value} -> Map.fetch!(resource, field) != value end) do
      {:ok, resource, txn}
    else
      {:error, _reason} = error -> error
      nil -> {:error, {:precondition, {kind, name}, :not_found}}
      {field, _value} -> {:error, {:precondition, {kind, name}, field}}
    end
  end

  defp run(op, _txn), do: {:error, {:bad_op, op}}

  defp entry?(path, entries) do
    Enum.any?(entries, &(List.starts_with?(path, &1) and length(path) > length(&1)))
  end

  # With a writer the given keys become owned paths, which the file has to
  # be able to hold.
  defp creatable({:create, _kind, _name, spec, _opts} = op, finalizers, writer) do
    if every?(finalizers, &is_atom/1) and
         (writer == nil or Enum.all?(Map.keys(spec), &Resource.path?([&1]))),
       do: :ok,
       else: {:error, {:bad_op, op}}
  end

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

  # A reference that is not exactly this shape would be written and then
  # fail the next load.
  defp known_refs(state, refs) do
    known? = fn ref ->
      match?(
        %{kind: kind, name: name, uid: uid}
        when map_size(ref) == 3 and is_map_key(state.kinds, kind) and is_binary(name) and
               is_integer(uid) and uid > 0,
        ref
      )
    end

    case first_bad(refs, known?) do
      :none -> :ok
      {:bad, ref} -> {:error, {:bad_owner_ref, ref}}
    end
  end

  # Not `Enum`: that raises on what is not a proper list, and this is asked
  # of whatever a caller sent.
  defp first_bad([], _ok?), do: :none

  defp first_bad([head | tail], ok?),
    do: if(ok?.(head), do: first_bad(tail, ok?), else: {:bad, head})

  defp first_bad(not_a_list, _ok?), do: {:bad, not_a_list}

  defp every?(list, ok?), do: first_bad(list, ok?) == :none

  defp condition?(condition) do
    match?(
      %{type: type, status: status, reason: reason, observed_generation: generation}
      when is_atom(type) and is_boolean(status) and is_atom(reason) and is_integer(generation),
      condition
    )
  end

  defp free_for(%{owner: owner}, writer, true) when owner not in [nil, writer],
    do: {:error, {:kind_owned, owner}}

  defp free_for(_registration, _writer, _owner?), do: :ok

  defp declare(conditions, writer, types) do
    others = Map.reject(conditions, fn {_type, owner} -> owner == writer end)

    if every?(types, &is_atom/1) do
      case Enum.find(types, &is_map_key(others, &1)) do
        nil -> {:ok, Map.merge(others, Map.new(types, &{&1, writer}))}
        type -> {:error, {:condition_owned, type, others[type]}}
      end
    else
      {:error, {:bad_conditions, types}}
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
    Enum.reduce_while(state.kinds[kind].validators, {:ok, spec}, fn validator, {:ok, spec} ->
      case validate(validator, spec) do
        {:ok, %{} = spec} -> {:cont, {:ok, spec}}
        {:error, reason} -> {:halt, {:error, {:invalid, reason}}}
        other -> {:halt, {:error, {:bad_validator, other}}}
      end
    end)
  end

  # A validator is the kind's code run on a caller's spec, inside the one
  # process every write goes through: what it raises rejects the commit.
  defp validate(validator, spec) do
    validator.(spec)
  rescue
    exception -> {:raised, Exception.message(exception)}
  end

  # Giving up a path must work on a spec that would no longer be admitted.
  defp readmit(_state, %Resource{spec: spec}, spec), do: {:ok, spec}
  defp readmit(state, %Resource{kind: kind}, spec), do: admit(state, kind, spec)

  defp spec_ops(%{} = puts),
    do: spec_ops(Enum.map(puts, fn {key, value} -> {:put, [key], value} end))

  defp spec_ops(ops) do
    case first_bad(ops, &spec_op?/1) do
      :none -> {:ok, ops}
      {:bad, op} -> {:error, {:bad_op, op}}
    end
  end

  defp spec_op?({name, path}) when name in [:inc, :delete, :release], do: Resource.path?(path)
  defp spec_op?({:put, path, _value}), do: Resource.path?(path)
  defp spec_op?(_other), do: false

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

  # Whatever was owned under the path went with it. After `own/4` those
  # entries are all this writer's: a rival's is a conflict or was forced out.
  defp apply_spec_op({:delete, path}, spec, managed, writer, force?) do
    with {:ok, managed} <- own(managed, path, writer, force?) do
      {:ok, delete_path(spec, path),
       Map.reject(managed, fn {owned, _owner} -> List.starts_with?(owned, path) end)}
    end
  end

  defp apply_spec_op({:inc, path} = op, spec, managed, writer, force?) do
    case fetch_path(spec, path) do
      :error ->
        apply_spec_op({:put, path, 1}, spec, managed, writer, force?)

      {:ok, n} when is_integer(n) ->
        apply_spec_op({:put, path, n + 1}, spec, managed, writer, force?)

      {:ok, _not_a_counter} ->
        {:error, {:bad_op, op}}
    end
  end

  defp apply_spec_op({:put, path, value}, spec, managed, writer, force?) do
    with {:ok, managed} <- own(managed, path, writer, force?) do
      {:ok, put_path(spec, path, value), managed}
    end
  end

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
        {:ok, if(writer != nil, do: Map.put(managed, path, writer), else: managed)}
    end
  end

  # `:error` only for a path that is not there: a counter starts from
  # absence, and a `nil` someone put is a value like any other.
  defp fetch_path(%{} = map, [key]), do: Map.fetch(map, key)

  defp fetch_path(%{} = map, [key | rest]) do
    with {:ok, inner} <- Map.fetch(map, key), do: fetch_path(inner, rest)
  end

  defp fetch_path(leaf, _beneath), do: {:ok, {:not_a_map, leaf}}

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
