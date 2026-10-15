defmodule Vagus.Runtime.Host do
  @moduledoc """
  Prepares the board for podman once per start, then hands out the permits
  every `podman` call runs under.

  ## Preparation

  Runs in `handle_continue/2`, so permit requests queue behind it and none is
  granted before it ends. In order, each step idempotent:

    1. `mount --make-rshared /`: `rslave` app binds need a shared root.
    2. The Core socket dir, mode 0700, which must exist before Core's create
       binds it.
    3. `/run/resolv.conf`, the host resolver host-network containers and
       pulls read.
    4. The profile (`frugal` below 2 GiB of RAM, else `fast`; the override
       file wins), its `containers.conf` drop-in, and the env every podman
       spawn carries.
    5. `<graphroot>/tmp`, which a pull needs to exist, emptied once per VM
       boot: a marker in `/run` keeps a Vagus restart from deleting the
       spool of a pull still running.
    6. `podman info`, the readiness probe. On failure the probe is retried
       every `:prep_retry_ms`.

  Only the probe can fail preparation; the earlier steps log and go on,
  because a board without them still runs most containers.

  ## Permits

  `:pull` (1), `:ops` (2 frugal, 4 fast) and one reserved `:shutdown` permit
  for `stop_all`. Holders and waiters are monitored, so a crashed holder
  frees its permit. Once `Vagus.Host.Shutdown.in_flight?/0` is true, new
  `:pull` permits are refused.

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

  alias Vagus.Engine.ResolvConf
  alias Vagus.Runtime.Podman.Cmd

  @frugal_below_kb 2 * 1024 * 1024
  @permits %{frugal: %{pull: 1, ops: 2, shutdown: 1}, fast: %{pull: 1, ops: 4, shutdown: 1}}
  @go_env %{
    frugal: [{"GOMAXPROCS", "1"}, {"GOMEMLIMIT", "32MiB"}, {"GOGC", "10"}],
    fast: []
  }

  @type profile :: :frugal | :fast
  @type class :: :pull | :ops | :shutdown
  @type permit :: {GenServer.server(), reference()}
  @type status :: :preparing | :ready | {:prep_failed, term()}

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
  `:meminfo`, `:profile_override`, `:socket_dir`, `:resolv_conf`,
  `:name_servers` (0-arity fun), `:run` (`fn bin, args -> {out, status}`,
  for `mount`), `:probe` (`fn opts -> :ok | {:error, reason}`),
  `:shutting_down?` (0-arity fun), `:prep_retry_ms`, `:permits`.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @spec env(atom() | nil) :: [{String.t(), String.t()}]
  def env(host), do: shared(host)[:env] || []

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

  @spec ready?(atom() | nil) :: boolean()
  def ready?(host \\ nil), do: ready(host) == :ok

  @spec profile(atom() | nil) :: profile() | nil
  def profile(host \\ nil), do: shared(host)[:profile]

  @doc """
  Empties the pull spools. Only for a holder of the pull permit, and only
  while a single one exists, so no pull can be using them.
  """
  @spec clear_spool(atom() | nil) :: :ok
  def clear_spool(host) do
    with %{spools: spools, pull_permits: 1} <- shared(host) do
      Enum.each(spools, &empty_dir/1)
    end

    :ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp empty_dir(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.each(entries, &File.rm_rf(Path.join(dir, &1)))
      {:error, _} -> :ok
    end
  end

  @doc "The previous stats sample for `name`, or nil."
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

  @doc """
  Takes a permit of `class`, waiting up to `wait_ms` behind other holders.
  `{:error, :busy}` when the wait runs out, `:shutting_down` for a `:pull`
  during shutdown, `:unavailable` when no Host runs.
  """
  @spec checkout(atom() | nil, class(), non_neg_integer()) ::
          {:ok, permit()} | {:error, :busy | :shutting_down | :unavailable}
  def checkout(host, class, wait_ms) do
    host = host || __MODULE__
    ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + wait_ms

    try do
      GenServer.call(host, {:acquire, class, ref}, max(wait_ms, 1))
    catch
      :exit, {:timeout, _} -> abandon(host, ref)
      :exit, _ -> {:error, :unavailable}
    else
      :granted ->
        {:ok, {host, ref}}

      :queued ->
        receive do
          {__MODULE__, :granted, ^ref} -> {:ok, {host, ref}}
        after
          max(deadline - System.monotonic_time(:millisecond), 0) -> abandon(host, ref)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec checkin(permit()) :: :ok
  def checkin({host, ref}), do: GenServer.cast(host, {:release, ref})

  @doc "Runs `fun` under a permit; the permit's error when none is had."
  @spec with_permit(atom() | nil, class(), non_neg_integer(), (-> result)) ::
          result | {:error, :busy | :shutting_down | :unavailable}
        when result: term()
  def with_permit(host, class, wait_ms, fun) do
    case checkout(host, class, wait_ms) do
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

  # The request may still be queued or even granted by now; the cancel
  # follows it in this caller's order, so the Host drops either.
  defp abandon(host, ref) do
    GenServer.cast(host, {:release, ref})

    receive do
      {__MODULE__, :granted, ^ref} -> :ok
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
    stats = :ets.new(__MODULE__.Stats, [:public, read_concurrency: true, write_concurrency: true])

    state = %{
      name: name,
      opts: opts,
      stats: stats,
      profile: nil,
      env: [],
      permits: Keyword.get(opts, :permits, @permits.frugal),
      free: %{},
      holders: %{},
      waiting: %{pull: :queue.new(), ops: :queue.new(), shutdown: :queue.new()}
    }

    state = publish(%{state | free: state.permits}, :preparing)
    {:ok, state, {:continue, :prepare}}
  end

  @impl true
  def handle_continue(:prepare, state) do
    make_root_shared(state.opts)
    ensure_socket_dir(state.opts)
    write_resolv_conf(state.opts)
    state = state |> apply_profile() |> publish(:preparing)
    clear_spool_once(state.opts)
    {:noreply, probe(state)}
  end

  @impl true
  def handle_call({:acquire, class, ref}, {pid, _tag}, state) do
    cond do
      class == :pull and shutting_down?(state.opts) ->
        {:reply, {:error, :shutting_down}, state}

      state.free[class] > 0 ->
        {:reply, :granted, grant(state, class, ref, pid)}

      true ->
        entry = {ref, pid, Process.monitor(pid)}
        waiting = Map.update!(state.waiting, class, &:queue.in(entry, &1))
        {:reply, :queued, %{state | waiting: waiting}}
    end
  end

  @impl true
  def handle_cast({:release, ref}, state), do: {:noreply, release(state, ref)}

  @impl true
  def handle_info({:DOWN, mon, :process, _pid, _reason}, state) do
    held = for {ref, {_class, _pid, ^mon}} <- state.holders, do: ref
    state = Enum.reduce(held, state, &release(&2, &1))

    waiting =
      Map.new(state.waiting, fn {c, q} -> {c, :queue.filter(&(elem(&1, 2) != mon), q)} end)

    {:noreply, %{state | waiting: waiting}}
  end

  def handle_info(:probe, state), do: {:noreply, probe(state)}

  defp grant(state, class, ref, pid) do
    holders = Map.put(state.holders, ref, {class, pid, Process.monitor(pid)})
    %{state | holders: holders, free: Map.update!(state.free, class, &(&1 - 1))}
  end

  defp release(state, ref) do
    case Map.pop(state.holders, ref) do
      {{class, _pid, mon}, holders} ->
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
        send(pid, {__MODULE__, :granted, ref})
        grant(%{state | waiting: Map.put(state.waiting, class, rest)}, class, ref, pid)

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

  defp publish(state, status) do
    :persistent_term.put(
      {__MODULE__, state.name},
      %{
        status: status,
        env: state.env,
        stats: state.stats,
        profile: state.profile,
        spools: [spool_dir(state.opts), Path.join(run_dir(state.opts), "spool")],
        pull_permits: state.permits[:pull]
      }
    )

    state
  end

  defp probe(state) do
    probe = Keyword.get(state.opts, :probe, &default_probe/1)

    case probe.(Keyword.put(state.opts, :host, state.name)) do
      :ok ->
        publish(state, :ready)

      {:error, reason} ->
        Logger.error("Vagus.Runtime.Host: podman probe failed: #{inspect(reason)}")
        Process.send_after(self(), :probe, Keyword.get(state.opts, :prep_retry_ms, 5_000))
        publish(state, {:prep_failed, reason})
    end
  end

  defp default_probe(opts) do
    case Cmd.run(["info", "--format", "{{.Version.Version}}"], [timeout_ms: 15_000] ++ opts) do
      {:ok, _version} -> :ok
      {:exit, status, out} -> {:error, {:failed, :info, {status, String.trim(out)}}}
      {:error, reason} -> {:error, reason}
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

  # The paths below are module defaults or a test's temp dir, never request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_socket_dir(opts) do
    dir = Keyword.get_lazy(opts, :socket_dir, &Vagus.Core.Container.socket_dir/0)

    with :ok <- File.mkdir_p(dir), :ok <- File.chmod(dir, 0o700) do
      :ok
    else
      {:error, reason} ->
        Logger.error("Vagus.Runtime.Host: #{dir} not made 0700 (#{inspect(reason)})")
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_resolv_conf(opts) do
    path = Keyword.get(opts, :resolv_conf, ResolvConf.path())
    servers = Keyword.get(opts, :name_servers, &name_servers/0).()

    case File.write(path, ResolvConf.build(servers)) do
      :ok ->
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
  `:frugal` below 2 GiB of `MemTotal`, else `:fast`; a readable override
  file holding `frugal` or `fast` wins. An unreadable meminfo is frugal,
  the profile that cannot OOM a small board.
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

  @doc "The `containers.conf` drop-in for `profile`."
  @spec containers_conf(profile(), keyword()) :: String.t()
  def containers_conf(:frugal, opts) do
    """
    [engine]
    events_logger = "file"
    image_parallel_copies = 1
    image_copy_tmp_dir = "#{spool_dir(opts)}"
    """
  end

  def containers_conf(:fast, opts) do
    """
    [engine]
    events_logger = "file"
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

  defp spool_dir(opts),
    do: Path.join(Keyword.get(opts, :graphroot, "/root/containers/storage"), "tmp")

  defp run_dir(opts), do: Keyword.get(opts, :run_dir, "/run/vagus/podman")

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
