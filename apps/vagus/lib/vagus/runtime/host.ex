defmodule Vagus.Runtime.Host do
  @moduledoc """
  Prepares the board for podman once per start, then hands out the permits
  every `podman` call runs under.

  ## Preparation

  Runs in `handle_continue/2`, so no permit is granted before the board is
  set up. Every step is idempotent, and only the readiness probe
  (`podman info`, run in a task and retried every `:prep_retry_ms`) can
  fail preparation: a board missing an earlier step still runs most
  containers, so those log and go on.

  The pull spool is emptied once per VM boot: a marker in `/run` keeps a
  Vagus restart from deleting the spool of a pull still running.

  On a board coming from balena-engine, `Vagus.Runtime.Migration.prepare/1`
  runs here too, so Core's config is moved, when it is due, before Core can
  be created. Only the first preparation of a boot may move it: a Host
  restarted later would move it from under a running Core.

  ## Migration

  While `Vagus.Runtime.Migration.pending?/1`, a task under
  `Vagus.TaskSupervisor`, at low priority, runs `Migration.check/2` once
  podman answers and then every `:migration_check_ms` (5 min), backing off
  up to an hour while the deletion keeps failing, until the migration is
  complete. The task polls what it needs (the slot's validation, podman's
  images, Core's health, free space), so nothing has to report to it. The
  Host keeps only what one check hands the next: whether Home Assistant
  was told the board lacks space. A condition the migration still waits on
  is logged when it changes, and hourly while it does not.

  Each pull checks its own image's room against the migration
  (`Migration.pull_space/2`, inside the pull permit) through the options
  this Host publishes (`migration/1`).

  ## Permits

  `:pull` (1), `:ops` (2 frugal, 4 fast) and one reserved `:shutdown` permit
  for `stop_all`. Holders and waiters are monitored, so a crashed holder
  frees its permit. Once `Vagus.Host.Shutdown.in_flight?/0` is true, new
  and queued `:pull` requests are refused. A request made with
  `priority: true` (Core's pulls) waits at the head of its queue.

  A `:health` request takes an `:ops` permit but never queues, and never
  the last one free: a scheduled check that would wait behind real work is
  better skipped, and the next tick comes anyway, while health checks
  alone must not hold every `:ops` permit of a frugal board. It is refused
  during a shutdown, like a pull.

  ## Shared state

  The env, the readiness status and the stats table id live in
  `:persistent_term`, so a spawn or `ready/1` needs no message. The stats
  table holds each container's previous CPU sample for
  `Vagus.Runtime.Engine.Podman.stats/2`; it is ETS so callers read and
  update it without a round trip, and it dies with the Host, which only
  costs one averaged sample per container.
  """

  use GenServer

  require Logger

  alias Vagus.Runtime.Migration
  alias Vagus.Runtime.Mountinfo
  alias Vagus.Runtime.Podman.Cmd
  alias Vagus.Runtime.ResolvConf

  @frugal_below_kb 2 * 1024 * 1024
  # How long a checkout waits for the Host's answer, apart from any wait for
  # a permit: the Host answers at once, but a loaded scheduler can take more
  # than the millisecond a zero wait would otherwise allow, and a missed
  # answer reads as a busy class.
  @reply_ms 5_000
  @permits %{frugal: %{pull: 1, ops: 2, shutdown: 1}, fast: %{pull: 1, ops: 4, shutdown: 1}}
  # Per container; conmon starts the file over once it would pass this.
  @log_max_bytes %{frugal: 2 * 1_048_576, fast: 8 * 1_048_576}
  # Container logs live on tmpfs, so they never write the SD card, and lose
  # nothing by it: the transient store forgets every container at reboot,
  # so each, Core included, is recreated with the current options and its
  # previous boot's log is gone either way. Their own tmpfs, so they can
  # never fill /run, where podman keeps its runroot: a 1 GB board's /run is
  # only 5% of RAM.
  @log_dir "/run/vagus/logs"
  @log_tmpfs_bytes %{frugal: 16 * 1_048_576, fast: 64 * 1_048_576}
  # podman reads a bare number of bytes; it rotates the file past this.
  @events_max_bytes 4 * 1_048_576
  @go_env %{
    frugal: [{"GOMAXPROCS", "1"}, {"GOMEMLIMIT", "32MiB"}, {"GOGC", "10"}],
    fast: []
  }

  @type profile :: :frugal | :fast
  @type class :: :pull | :ops | :shutdown | :health
  @type permit :: {GenServer.server(), reference()}
  @type status :: :preparing | :ready | {:prep_failed, term()}

  @doc """
  Whether this is a board this Host prepares (`config :vagus, :runtime_host`,
  set only in `target.exs`). Never inferred from the engine: host dev runs
  `Engine.Podman` too, and must not have its mounts, sysctls or interfaces
  changed.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:vagus, :runtime_host, false)

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      shutdown: 2_000
    }
  end

  @doc """
  Options (all defaulted for the device): `:name`, `:podman_bin`,
  `:graphroot`, `:run_dir` (drop-in, fast spool and the spool marker),
  `:meminfo`, `:profile_override`, `:socket_dir`, `:resolv_conf`, `:dev_root`,
  `:name_servers` (0-arity fun), `:run` (`fn bin, args -> {out, status}`,
  for `mount`), `:probe` (`fn opts -> :ok | {:error, reason}`),
  `:shutting_down?` (0-arity fun), `:prep_retry_ms`, `:permits`,
  `:spool_quiet_ms`, `:log_dir`, `:mountinfo`, `:migration` (options for
  `Vagus.Runtime.Migration`), `:migration_check_ms`, `:task_supervisor`,
  `:on_migration_checked` (1-arity, each check's result; tests).
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @spec env(atom() | nil) :: [{String.t(), String.t()}]
  def env(host), do: shared(host)[:env] || []

  @doc """
  Where split podman calls (`Runtime.Podman.Cmd`'s `:stderr_apart`) write
  their stdout: `{:ok, dir}` once this Host has its own bounded tmpfs
  there, `:unbounded` while it has none (preparing, or the mount failed),
  `:unavailable` with no Host.
  """
  @spec out_dir(atom() | nil) :: {:ok, String.t()} | :unbounded | :unavailable
  # The published snapshot outlives a stopped Host, which could then no
  # longer remove a dead caller's file.
  def out_dir(host) do
    host = host || __MODULE__

    case {Process.whereis(host), shared(host)} do
      {nil, _} -> :unavailable
      {_pid, %{out_dir: dir}} when is_binary(dir) -> {:ok, dir}
      {_pid, %{status: _}} -> :unbounded
      {_pid, _none} -> :unavailable
    end
  end

  @doc """
  Records `path` as the calling permit holder's stdout file, removed should
  the holder die before it can. `{:error, :unavailable}` when this Host
  holds no permit of the caller's: a permit from a Host since replaced
  leaves nobody to remove the file.
  """
  @spec track_out(atom() | nil, String.t()) :: :ok | {:error, :unavailable}
  def track_out(host, path) do
    GenServer.call(host || __MODULE__, {:out_file, path}, @reply_ms)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec ready(atom() | nil) :: :ok | {:error, :preparing | :unavailable | {:prep_failed, term()}}
  def ready(host \\ nil) do
    host = host || __MODULE__

    case {Process.whereis(host), shared(host)[:status]} do
      {nil, _} -> {:error, :unavailable}
      {_pid, :ready} -> :ok
      {_pid, nil} -> {:error, :preparing}
      {_pid, status} -> {:error, status}
    end
  end

  @doc """
  The options a pull checks its room with while a migration is pending,
  else `nil`.
  """
  @spec migration(atom() | nil) :: keyword() | nil
  def migration(host \\ nil), do: shared(host)[:migration]

  @spec profile(atom() | nil) :: profile() | nil
  def profile(host \\ nil), do: shared(host)[:profile]

  @doc """
  Where containers write their k8s-file logs and how large each may grow;
  the device defaults (frugal) when no Host has published them.
  """
  @spec log_config(atom() | nil) :: %{dir: String.t(), max_bytes: pos_integer()}
  def log_config(host \\ nil) do
    shared = shared(host)

    %{
      dir: shared[:log_dir] || @log_dir,
      max_bytes: shared[:log_max_bytes] || @log_max_bytes.frugal
    }
  end

  @doc """
  Removes the pull spools' stale entries: those with nothing written
  anywhere inside for `:spool_quiet_ms` (default 2 min). Permits alone
  cannot prove no pull is writing: a restarted Host forgets its holders,
  and a holder's podman can outlive the holder by its SIGKILL delay. A
  live pull writes continuously, so its entry is never stale; one an
  interrupted pull leaked is. Only while a single pull permit exists.
  """
  @spec clear_spool(atom() | nil) :: :ok
  def clear_spool(host) do
    with %{spools: spools, pull_permits: 1, spool_quiet_ms: quiet_ms} <- shared(host) do
      cutoff = System.os_time(:second) - div(quiet_ms, 1000)
      Enum.each(spools, &remove_stale(&1, cutoff))
    end

    :ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_stale(dir, cutoff) do
    case File.ls(dir) do
      {:ok, entries} ->
        for entry <- entries,
            path = Path.join(dir, entry),
            newest_mtime(path) < cutoff,
            do: File.rm_rf(path)

      {:error, _} ->
        :ok
    end
  end

  # lstat, so a symlink counts by its own time and is never followed.
  # sobelow_skip ["Traversal.FileModule"]
  defp newest_mtime(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory, mtime: mtime}} ->
        case File.ls(path) do
          {:ok, entries} ->
            entries
            |> Enum.map(&newest_mtime(Path.join(path, &1)))
            |> Enum.max(fn -> mtime end)
            |> max(mtime)

          {:error, _} ->
            mtime
        end

      {:ok, %File.Stat{mtime: mtime}} ->
        mtime

      # Gone already, or unreadable: never stale enough to remove.
      {:error, _} ->
        :infinity
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp empty_dir(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.each(entries, &File.rm_rf(Path.join(dir, &1)))
      {:error, _} -> :ok
    end
  end

  @spec last_sample(atom() | nil, String.t()) :: term()
  def last_sample(host, name) do
    with tid when tid != nil <- shared(host)[:stats],
         [{^name, sample}] <- :ets.lookup(tid, name) do
      sample
    else
      _ -> nil
    end
  rescue
    # The table died with a Host restarted since the lookup of its id.
    ArgumentError -> nil
  end

  @spec put_sample(atom() | nil, String.t(), term()) :: :ok
  def put_sample(host, name, sample) do
    if tid = shared(host)[:stats], do: :ets.insert(tid, {name, sample})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec forget_sample(atom() | nil, String.t()) :: :ok
  def forget_sample(host, name) do
    if tid = shared(host)[:stats], do: :ets.delete(tid, name)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Takes a permit of `class`, waiting up to `wait_ms` behind other holders,
  or ahead of them with `priority: true`. `{:error, :busy}` when the wait
  runs out (at once for `:health`), `:shutting_down` for a `:pull` or
  `:health` during shutdown, `:unavailable` when no Host runs.
  """
  @spec checkout(atom() | nil, class(), non_neg_integer(), keyword()) ::
          {:ok, permit()}
          | {:error, :busy | :shutting_down | :unavailable | :badarg}
  def checkout(host, class, wait_ms, opts \\ []) do
    case GenServer.whereis(host || __MODULE__) do
      nil -> {:error, :unavailable}
      pid -> checkout_from(pid, class, wait_ms, Keyword.get(opts, :priority, false))
    end
  end

  # Everything goes to this one Host: a restarted Host knows nothing of a
  # request made to the one before, so its death ends the wait.
  defp checkout_from(pid, class, wait_ms, priority?) do
    ref = make_ref()
    mon = Process.monitor(pid)
    deadline = System.monotonic_time(:millisecond) + wait_ms

    try do
      GenServer.call(pid, {:acquire, class, ref, priority?}, max(wait_ms, @reply_ms))
    catch
      :exit, {:timeout, _} -> abandon(pid, ref)
      :exit, _ -> {:error, :unavailable}
    else
      :granted ->
        {:ok, {pid, ref}}

      :queued ->
        receive do
          {__MODULE__, :granted, ^ref} -> {:ok, {pid, ref}}
          {__MODULE__, :refused, ^ref, reason} -> {:error, reason}
          {:DOWN, ^mon, :process, _, _} -> {:error, :unavailable}
        after
          max(deadline - System.monotonic_time(:millisecond), 0) -> abandon(pid, ref)
        end

      {:error, reason} ->
        {:error, reason}
    after
      Process.demonitor(mon, [:flush])
    end
  end

  @spec checkin(permit()) :: :ok
  def checkin({host, ref}), do: GenServer.cast(host, {:release, ref})

  @spec with_permit(atom() | nil, class(), non_neg_integer(), (-> result), keyword()) ::
          result | {:error, :busy | :shutting_down | :unavailable}
        when result: term()
  def with_permit(host, class, wait_ms, fun, opts \\ []) do
    case checkout(host, class, wait_ms, opts) do
      {:ok, permit} ->
        try do
          fun.()
        after
          checkin(permit)
        end

      {:error, _} = error ->
        error
    end
  end

  # The request may still be queued or even granted by now. Once the Host
  # has answered the cancel, any grant or refusal it sent is already here.
  defp abandon(host, ref) do
    try do
      GenServer.call(host, {:cancel, ref})
    catch
      :exit, _ -> :ok
    end

    receive do
      {__MODULE__, :granted, ^ref} -> :ok
      {__MODULE__, :refused, ^ref, _reason} -> :ok
    after
      0 -> :ok
    end

    {:error, :busy}
  end

  defp shared(nil), do: shared(__MODULE__)
  defp shared(host), do: :persistent_term.get({__MODULE__, host}, %{})

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    stats = :ets.new(__MODULE__.Stats, [:public])

    state = %{
      name: name,
      opts: opts,
      stats: stats,
      profile: nil,
      env: [],
      published: nil,
      probe: nil,
      permits: Keyword.get(opts, :permits, @permits.frugal),
      free: %{},
      holders: %{},
      out_dir: nil,
      migration: nil,
      migration_task: nil,
      migration_timer: nil,
      check_failures: 0,
      dismissals: 0,
      notice: nil,
      waiting_logged: nil,
      waiting: %{pull: :queue.new(), ops: :queue.new(), shutdown: :queue.new()}
    }

    state = publish(%{state | free: state.permits}, :preparing)
    {:ok, state, {:continue, :prepare}}
  end

  @impl true
  def handle_continue(:prepare, state) do
    make_root_shared(state.opts)
    # /run/vagus holds files only Vagus may read, the nft ruleset among them.
    ensure_private_dir(Path.dirname(run_dir(state.opts)))

    ensure_private_dir(
      Keyword.get_lazy(state.opts, :socket_dir, &Vagus.Core.Container.socket_dir/0)
    )

    ensure_private_dir(log_dir(state.opts))
    ensure_private_dir(out_dir_of(state.opts))
    write_resolv_conf(state.opts)
    ensure_dev_links(Keyword.get(state.opts, :dev_root, "/dev"))
    state = state |> apply_profile() |> publish(:preparing)
    mount_logs(state.opts, @log_tmpfs_bytes[state.profile])
    state = prepare_out_dir(state)
    clear_spool_once(state.opts)
    state = state |> prepare_migration() |> publish(:preparing)
    {:noreply, start_probe(state)}
  end

  @impl true
  def handle_call({:acquire, :health, ref, _priority?}, {pid, _tag}, state) do
    cond do
      shutting_down?(state.opts) -> {:reply, {:error, :shutting_down}, state}
      state.free[:ops] > 1 -> {:reply, :granted, grant(state, :ops, ref, pid)}
      true -> {:reply, {:error, :busy}, state}
    end
  end

  def handle_call({:acquire, class, _ref, _priority?}, _from, state)
      when not is_map_key(state.free, class),
      do: {:reply, {:error, :badarg}, state}

  def handle_call({:acquire, class, ref, priority?}, {pid, _tag}, state) do
    cond do
      class == :pull and shutting_down?(state.opts) ->
        {:reply, {:error, :shutting_down}, state}

      state.free[class] > 0 ->
        {:reply, :granted, grant(state, class, ref, pid)}

      true ->
        entry = {ref, pid, Process.monitor(pid)}
        enqueue = if priority?, do: &:queue.in_r/2, else: &:queue.in/2
        waiting = Map.update!(state.waiting, class, &enqueue.(entry, &1))
        {:reply, :queued, %{state | waiting: waiting}}
    end
  end

  def handle_call({:cancel, ref}, _from, state), do: {:reply, :ok, release(state, ref)}

  def handle_call({:out_file, path}, {pid, _tag}, state) do
    if Enum.any?(state.holders, &match?({_ref, {_class, ^pid, _mon, _out}}, &1)) do
      holders =
        Map.new(state.holders, fn
          {ref, {class, ^pid, mon, _out}} -> {ref, {class, pid, mon, path}}
          held -> held
        end)

      {:reply, :ok, %{state | holders: holders}}
    else
      {:reply, {:error, :unavailable}, state}
    end
  end

  @impl true
  def handle_cast({:release, ref}, state), do: {:noreply, release(state, ref)}

  @impl true
  def handle_info({ref, result}, %{probe: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, probed(%{state | probe: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{probe: ref} = state)
      when is_reference(ref),
      do: {:noreply, probed(%{state | probe: nil}, {:error, {:probe_crashed, reason}})}

  def handle_info({ref, result}, %{migration_task: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, migration_checked(%{state | migration_task: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{migration_task: ref} = state)
      when is_reference(ref) do
    crashed = %{cleanup: {:error, {:crashed, reason}}, notice: state.notice}
    {:noreply, migration_checked(%{state | migration_task: nil}, crashed)}
  end

  # A cancelled timer's message may already be queued: only the one armed
  # last, named by its tag, runs a check.
  def handle_info({:migration_check, tag}, %{migration_timer: {_timer, tag}} = state),
    do: {:noreply, start_migration_check(%{state | migration_timer: nil})}

  def handle_info({:migration_check, _stale}, state), do: {:noreply, state}

  def handle_info({:DOWN, mon, :process, _pid, _reason}, state) do
    held = for {ref, {_class, _pid, ^mon, out}} <- state.holders, do: {ref, out}
    Enum.each(held, fn {_ref, out} -> drop_out_file(out) end)

    # The caller's death does not end its podman, which may yet open `--out`
    # and so create the file again; once muontrap's kill budget has passed
    # it is gone, and that second removal is final. The path is unique to
    # its call, so it never takes a later call's file.
    for {_ref, out} <- held, out != nil do
      Process.send_after(self(), {:drop_out, make_ref(), out}, Cmd.kill_budget_ms())
    end

    state = Enum.reduce(held, state, fn {ref, _out}, state -> release(state, ref) end)

    waiting =
      Map.new(state.waiting, fn {c, q} -> {c, :queue.filter(&(elem(&1, 2) != mon), q)} end)

    {:noreply, %{state | waiting: waiting}}
  end

  def handle_info({:drop_out, ref, path}, state) when is_reference(ref) do
    drop_out_file(path)
    {:noreply, state}
  end

  def handle_info(:probe, state), do: {:noreply, start_probe(state)}

  def handle_info(msg, state) do
    Logger.debug("Vagus.Runtime.Host: ignored #{inspect(msg)}")
    {:noreply, state}
  end

  defp grant(state, class, ref, pid) do
    holders = Map.put(state.holders, ref, {class, pid, Process.monitor(pid), nil})
    %{state | holders: holders, free: Map.update!(state.free, class, &(&1 - 1))}
  end

  defp release(state, ref) do
    case Map.pop(state.holders, ref) do
      {{class, _pid, mon, _out}, holders} ->
        Process.demonitor(mon, [:flush])

        hand_over(
          %{state | holders: holders, free: Map.update!(state.free, class, &(&1 + 1))},
          class
        )

      {nil, _} ->
        drop_waiter(state, ref)
    end
  end

  defp hand_over(state, class) do
    case :queue.out(state.waiting[class]) do
      {{:value, {ref, pid, mon}}, rest} ->
        Process.demonitor(mon, [:flush])
        state = %{state | waiting: Map.put(state.waiting, class, rest)}

        if class == :pull and shutting_down?(state.opts) do
          send(pid, {__MODULE__, :refused, ref, :shutting_down})
          hand_over(state, class)
        else
          send(pid, {__MODULE__, :granted, ref})
          grant(state, class, ref, pid)
        end

      {:empty, _} ->
        state
    end
  end

  defp drop_waiter(state, ref) do
    waiting =
      Map.new(state.waiting, fn {class, q} ->
        {gone, kept} = q |> :queue.to_list() |> Enum.split_with(&(elem(&1, 0) == ref))
        Enum.each(gone, fn {_ref, _pid, mon} -> Process.demonitor(mon, [:flush]) end)
        {class, :queue.from_list(kept)}
      end)

    %{state | waiting: waiting}
  end

  # Each put of a changed term costs a global GC pass, so only changes go out.
  defp publish(state, status) do
    shared = %{
      status: status,
      env: state.env,
      stats: state.stats,
      profile: state.profile,
      spools: [spool_dir(state.opts), Path.join(run_dir(state.opts), "spool")],
      pull_permits: state.permits[:pull],
      spool_quiet_ms: Keyword.get(state.opts, :spool_quiet_ms, 120_000),
      log_dir: log_dir(state.opts),
      out_dir: state.out_dir,
      log_max_bytes: state.profile && @log_max_bytes[state.profile],
      log_tmpfs_bytes: state.profile && @log_tmpfs_bytes[state.profile],
      migration: state.migration
    }

    if shared != state.published, do: :persistent_term.put({__MODULE__, state.name}, shared)
    %{state | published: shared}
  end

  # Off the Host's own process, so permits keep flowing while podman info
  # takes its time.
  defp start_probe(state) do
    probe = Keyword.get(state.opts, :probe, &default_probe/1)
    opts = Keyword.put(state.opts, :host, state.name)
    supervisor = Keyword.get(state.opts, :task_supervisor, Vagus.TaskSupervisor)
    %{state | probe: Task.Supervisor.async_nolink(supervisor, fn -> probe.(opts) end).ref}
  end

  defp probed(state, :ok), do: state |> publish(:ready) |> start_migration_check()

  defp probed(state, {:error, reason}) do
    Logger.error("Vagus.Runtime.Host: podman probe failed: #{inspect(reason)}")
    Process.send_after(self(), :probe, Keyword.get(state.opts, :prep_retry_ms, 5_000))
    publish(state, {:prep_failed, reason})
  end

  defp default_probe(opts) do
    case Cmd.run(["info", "--format", "{{.Version.Version}}"], [timeout_ms: 15_000] ++ opts) do
      {:ok, _version} -> :ok
      {:exit, status, out} -> {:error, {:failed, :info, {status, String.trim(out)}}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The run marker is written once a preparation has done what was due:
  # a later preparation in this boot must not move the config under a Core
  # created since. A failed one leaves no marker, so the move is tried again.
  # sobelow_skip ["Traversal.FileModule"]
  defp prepare_migration(state) do
    opts = migration_opts(state)
    marker = Path.join(run_dir(state.opts), "migration-prepared")

    case Migration.prepare(Keyword.put(opts, :rename?, not File.exists?(marker))) do
      {:error, _} -> :ok
      _done -> File.write(marker, "")
    end

    # A warning raised before a restart may still be up, and the Host that
    # knew is gone: the first check raises or dismisses it either way. A
    # dismissal of a notification Home Assistant does not have changes
    # nothing. Not pending, that check is a dismissal and the end of it.
    %{state | migration: opts, notice: :unknown}
  end

  defp migration_opts(state) do
    Keyword.merge(
      [host: state.name, graphroot: graphroot(state.opts)],
      Keyword.get(state.opts, :migration, [])
    )
  end

  defp start_migration_check(%{migration: opts, migration_task: nil} = state)
       when is_list(opts) do
    notice = state.notice
    supervisor = Keyword.get(state.opts, :task_supervisor, Vagus.TaskSupervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        # Deleting balena's store walks a large tree; nothing waits on it.
        Process.flag(:priority, :low)
        Migration.check(opts, notice: notice)
      end)

    %{state | migration_task: task.ref}
  end

  defp start_migration_check(state), do: state

  # An hour at most between checks while the deletion keeps failing.
  @max_check_ms 3_600_000
  @waiting_log_ms 3_600_000
  # Spread by the backoff over about six hours: long enough for Core to come
  # up after a boot.
  @dismiss_attempts 8

  defp migration_checked(state, %{cleanup: cleanup, notice: notice} = result) do
    if observe = Keyword.get(state.opts, :on_migration_checked), do: observe.(result)
    state = %{state | notice: notice}

    case cleanup do
      :done when notice == nil ->
        finish_migration(state)

      :done when state.dismissals + 1 >= @dismiss_attempts ->
        Logger.warning(
          "Vagus.Runtime.Host: Home Assistant did not take the dismissal of the " <>
            "migration's space warning after #{@dismiss_attempts} tries; giving up"
        )

        finish_migration(%{state | notice: nil})

      # Checked on until Home Assistant has dismissed the warning too. The
      # cleanup errors before it neither use up the tries nor stretch their
      # backoff.
      :done ->
        dismissals = state.dismissals + 1
        schedule_check(%{state | dismissals: dismissals, check_failures: dismissals})

      {:waiting, condition} ->
        %{log_waiting(state, condition) | check_failures: 0} |> schedule_check()

      {:error, reason} ->
        Logger.error("Vagus.Runtime.Host: migration check failed: #{inspect(reason)}")
        schedule_check(%{state | check_failures: state.check_failures + 1})
    end
  end

  defp finish_migration(state) do
    if state.migration_timer, do: Process.cancel_timer(elem(state.migration_timer, 0))
    state = %{state | migration: nil, migration_timer: nil, check_failures: 0, dismissals: 0}
    publish(state, state.published.status)
  end

  defp schedule_check(state) do
    base = Keyword.get(state.opts, :migration_check_ms, 300_000)
    delay = min(base * Integer.pow(2, min(state.check_failures, 4)), max(base, @max_check_ms))
    tag = make_ref()
    timer = Process.send_after(self(), {:migration_check, tag}, delay)
    %{state | migration_timer: {timer, tag}}
  end

  defp log_waiting(state, condition) do
    now = System.monotonic_time(:millisecond)

    case state.waiting_logged do
      {^condition, at} when now - at < @waiting_log_ms ->
        state

      _changed_or_due ->
        Logger.info("Vagus.Runtime.Host: the balena migration waits on #{condition}")
        %{state | waiting_logged: {condition, now}}
    end
  end

  defp make_root_shared(opts) do
    run = Keyword.get(opts, :run, &Vagus.Host.Cmd.run/2)

    case run.("mount", ["--make-rshared", "/"]) do
      {_out, 0} ->
        :ok

      {out, status} ->
        Logger.warning("Vagus.Runtime.Host: make-rshared / failed (#{status}): #{out}")
    end
  end

  # A Vagus restart within one boot finds the tmpfs already there. A board
  # that cannot mount it, or whose directory already holds something,
  # keeps the plain directory on /run: mounting over files would hide logs
  # conmon is still writing.
  defp mount_tmpfs(dir, bytes, opts) do
    case mount_at(dir, Keyword.get(opts, :mountinfo, "/proc/self/mountinfo")) do
      {:ok, "tmpfs"} -> :ok
      {:ok, fstype} -> {:plain, "#{fstype} is mounted there"}
      {:error, reason} -> {:plain, "mountinfo unreadable (#{inspect(reason)})"}
      :none -> mount_if_empty(dir, bytes, opts)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp mount_if_empty(dir, bytes, opts) do
    case File.ls(dir) do
      {:ok, []} ->
        run = Keyword.get(opts, :run, &Vagus.Host.Cmd.run/2)
        options = "size=#{bytes},mode=0700,nosuid,nodev,noexec"

        case run.("mount", ["-t", "tmpfs", "-o", options, "tmpfs", dir]) do
          {_out, 0} -> :ok
          {out, status} -> {:plain, "mount failed (#{status}): #{String.trim(out)}"}
        end

      {:ok, _entries} ->
        {:plain, "it already holds files"}

      {:error, reason} ->
        {:plain, inspect(reason)}
    end
  end

  defp mount_logs(opts, bytes) do
    dir = log_dir(opts)

    with {:plain, why} <- mount_tmpfs(dir, bytes, opts),
         do: Logger.warning("Vagus.Runtime.Host: no tmpfs for #{dir}: #{why}; logs stay on /run")
  end

  # Split podman calls write stdout here with no pipe to hold them back, so
  # a burst past the cap could fill /run, where podman keeps its runroot,
  # before Cmd's poll stops it. Their own tmpfs bounds that: room for every
  # permit's call at the cap at once (a health check holds an ops permit),
  # and one more for a burst the poll has not caught yet. A fresh Host has
  # no holders, so anything already there is an orphan of a Host that died
  # with removals still due. Without that bound the dir is never published,
  # and split calls keep stderr merged as before, where the pipe holds podman
  # back; failing them instead would stop every inspect, list and create.
  # sobelow_skip ["Traversal.FileModule"]
  defp prepare_out_dir(state) do
    dir = out_dir_of(state.opts)

    with {:ok, entries} <- File.ls(dir),
         do: Enum.each(entries, &File.rm_rf(Path.join(dir, &1)))

    calls = state.permits |> Map.values() |> Enum.sum()

    case mount_tmpfs(dir, (calls + 1) * Cmd.default_cap(), state.opts) do
      :ok ->
        %{state | out_dir: dir}

      {:plain, why} ->
        Logger.warning(
          "Vagus.Runtime.Host: no tmpfs for #{dir}: #{why}; " <>
            "podman's stderr stays merged with the stdout Vagus parses"
        )

        %{state | out_dir: nil}
    end
  end

  # The fstype of the last mount at `dir`, the one in view.
  defp mount_at(dir, mountinfo) do
    with {:ok, mounts} <- Mountinfo.read(mountinfo) do
      case for({^dir, fstype} <- mounts, do: fstype) |> List.last() do
        nil -> :none
        fstype -> {:ok, fstype}
      end
    end
  end

  # The paths below are module defaults or a test's temp dir, never request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_private_dir(dir) do
    with :ok <- File.mkdir_p(dir), :ok <- File.chmod(dir, 0o700) do
      :ok
    else
      {:error, reason} ->
        Logger.error("Vagus.Runtime.Host: #{dir} not made 0700 (#{inspect(reason)})")
    end
  end

  # Apps get the host's `/dev` bound in, and the Nerves host has none of
  # these, so bash process substitution (`<(…)`, `/dev/fd/63`) and
  # `/dev/stdin` fail in every app. Made before any container can start;
  # one already there, of whatever kind, is left alone.
  @dev_links [
    {"fd", "/proc/self/fd"},
    {"stdin", "/proc/self/fd/0"},
    {"stdout", "/proc/self/fd/1"},
    {"stderr", "/proc/self/fd/2"}
  ]

  @doc false
  # sobelow_skip ["Traversal.FileModule"]
  @spec ensure_dev_links(Path.t()) :: :ok
  def ensure_dev_links(dev_root) do
    for {name, target} <- @dev_links do
      link = Path.join(dev_root, name)

      case File.ln_s(target, link) do
        result when result in [:ok, {:error, :eexist}] ->
          :ok

        {:error, reason} ->
          Logger.error("Vagus.Runtime.Host: #{link} not linked (#{inspect(reason)})")
      end
    end

    :ok
  end

  # Only a missing file: once vintage_net has written it (search domain
  # included), a Host restarted within the boot must not replace it.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_resolv_conf(opts) do
    path = Keyword.get(opts, :resolv_conf, ResolvConf.path())
    servers = Keyword.get(opts, :name_servers, &name_servers/0).()

    case File.write(path, ResolvConf.build(servers), [:exclusive]) do
      result when result in [:ok, {:error, :eexist}] ->
        :ok

      {:error, reason} ->
        Logger.error("Vagus.Runtime.Host: #{path} not written (#{inspect(reason)})")
    end
  end

  defp apply_profile(state) do
    opts = state.opts
    profile = pick_profile(opts)
    conf = Path.join(run_dir(opts), "containers.conf")

    override =
      case write_conf(conf, containers_conf(profile, opts)) do
        :ok ->
          [{"CONTAINERS_CONF_OVERRIDE", conf}]

        {:error, reason} ->
          # The baked config already defaults to frugal values.
          Logger.error("Vagus.Runtime.Host: #{conf} not written (#{inspect(reason)})")
          []
      end

    # No permit is out yet: requests queue behind preparation.
    permits = Keyword.get(opts, :permits, @permits[profile])

    Logger.info("Vagus.Runtime.Host: podman profile #{profile}")

    %{
      state
      | profile: profile,
        env: @go_env[profile] ++ override,
        permits: permits,
        free: permits
    }
  end

  @doc """
  The override file wins, else 2 GiB of `MemTotal` divides `:frugal` from
  `:fast`. An unreadable meminfo is frugal, the profile that cannot OOM a
  small board.
  """
  @spec pick_profile(keyword()) :: profile()
  def pick_profile(opts) do
    case read(Keyword.get(opts, :profile_override, "/root/vagus/podman-profile")) do
      "frugal" -> :frugal
      "fast" -> :fast
      _ -> profile_by_ram(read(Keyword.get(opts, :meminfo, "/proc/meminfo")))
    end
  end

  defp profile_by_ram(nil), do: :frugal

  defp profile_by_ram(meminfo) do
    case Regex.run(~r/^MemTotal:\s+(\d+)\s+kB/m, meminfo) do
      [_, kb] -> if String.to_integer(kb) < @frugal_below_kb, do: :frugal, else: :fast
      nil -> :frugal
    end
  end

  @spec containers_conf(profile(), keyword()) :: String.t()
  def containers_conf(:frugal, opts) do
    """
    [engine]
    events_logger = "file"
    events_logfile_max_size = #{@events_max_bytes}
    image_parallel_copies = 1
    image_copy_tmp_dir = "#{spool_dir(opts)}"
    """
  end

  def containers_conf(:fast, opts) do
    """
    [engine]
    events_logger = "file"
    events_logfile_max_size = #{@events_max_bytes}
    image_copy_tmp_dir = "#{Path.join(run_dir(opts), "spool")}"
    """
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_conf(path, content) do
    with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, content)
  end

  # Both spools are made: the fast one may hold a pull's layers, and
  # podman stats `<graphroot>/tmp` even when it spools elsewhere.
  # sobelow_skip ["Traversal.FileModule"]
  defp clear_spool_once(opts) do
    spool = spool_dir(opts)
    marker = Path.join(run_dir(opts), "spool-cleared")
    _ = File.mkdir_p(Path.join(run_dir(opts), "spool"))

    with :ok <- File.mkdir_p(spool),
         false <- File.exists?(marker) do
      empty_dir(spool)
      File.write(marker, "")
    else
      true -> :ok
      {:error, reason} -> Logger.error("Vagus.Runtime.Host: spool #{spool}: #{inspect(reason)}")
    end
  end

  defp spool_dir(opts), do: Path.join(graphroot(opts), "tmp")

  defp graphroot(opts), do: Keyword.get(opts, :graphroot, "/root/containers/storage")

  defp run_dir(opts), do: Keyword.get(opts, :run_dir, "/run/vagus/podman")
  defp out_dir_of(opts), do: Path.join(run_dir(opts), "out")

  # A holder killed mid-call never reaches Cmd's own cleanup. A file its
  # podman already holds open keeps its space until podman exits. The path
  # is one Cmd made in this Host's out dir.
  defp drop_out_file(nil), do: :ok
  # sobelow_skip ["Traversal.FileModule"]
  defp drop_out_file(path), do: _ = File.rm(path)

  defp log_dir(opts), do: Keyword.get(opts, :log_dir, @log_dir)

  defp shutting_down?(opts),
    do: Keyword.get(opts, :shutting_down?, &Vagus.Host.Shutdown.in_flight?/0).()

  # sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    case File.read(path) do
      {:ok, content} -> String.trim(content)
      {:error, _} -> nil
    end
  end

  if Mix.target() == :host do
    defp name_servers, do: []
  else
    defp name_servers, do: VintageNet.get(["name_servers"], [])
  end
end
