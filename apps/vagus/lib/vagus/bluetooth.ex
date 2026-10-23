defmodule Vagus.Bluetooth do
  @moduledoc """
  Daemons-only slice of the `Bluez` stack: `dbus-daemon --system` and
  `bluetoothd -E` as `MuonTrap`-supervised OS processes, plus the vendored
  rebus runtime and the `Bluez.BusReady` gate they ride on — everything in
  `Bluez.children/1` up to and including the `:bluetoothd` child, nothing
  after it.

  HA Core is the BLE consumer on this system: its container gets `/run/dbus`
  bound read-only (real-Supervisor parity, `MOUNT_DBUS`) and habluetooth
  drives the adapter over BlueZ's D-Bus API. Vagus deliberately does not
  start the bluez library's scanning/GATT/audio clients — a second scanner
  would compete with Core for the radio and burn CPU D-Bus-decoding adverts
  nobody consumes. Slicing by child id (not position) keeps the cut robust
  to upstream reordering while inheriting the library's hardware-proven
  daemon specs (socket cleanup, machine-id, restart budget rationale).

  Started from `target_children/0` only. `start_link/1` returns `:ignore`
  when either daemon binary is absent (e.g. a system built without
  `BR2_PACKAGE_BLUEZ5_UTILS`) so a misbuilt firmware degrades to "no
  Bluetooth" instead of an app-toppling supervision crash loop.

  The tree is this `:one_for_one` supervisor holding a single child,
  `Vagus.Bluetooth.Stack` (`:rest_for_one`), which holds the daemon slice
  and then the Improv-over-BLE Wi-Fi provisioning group + its reaper (see
  `Vagus.Improv` / `Vagus.Improv.Reaper`), mounted per improv's contract:
  appended last, so a `bluetoothd` restart rebuilds the group while an
  Improv fault never disturbs the daemons. The group idles disarmed on an
  online boot and is reaped once the network is up; disable entirely with
  `improv: false` in opts.

  `stop/1` / `start/1` / `status/1` let the agent-dev-board orchestrator
  release the host stack over distribution so a worker container can own
  `hci0` with its own `bluetoothd`, then take it back. Stopping takes the
  whole stack down, `dbus-daemon` included, and removes its
  `/run/dbus/system_bus_socket` (dbus-daemon leaves the file behind on
  SIGTERM): every `/run/dbus` bind — HA Core's and each `host_dbus: true`
  app's — then holds no bus until `start/1`, which is why `stop/1` refuses
  while such an app is started. `start/1` brings the Improv tail back with
  the daemons; it cannot arm again this boot and the Reaper removes it once
  the network is up. The stopped state lives in this supervisor only — a
  restart of `Vagus.Bluetooth` itself (or a reboot) brings the stack back.
  This is a consistency API for a root agent, not a guard against it.
  """

  use Supervisor

  require Logger

  alias Vagus.Bluetooth.Stack

  @default_dbus_daemon "/usr/bin/dbus-daemon"
  @default_bluetoothd "/usr/libexec/bluetooth/bluetoothd"

  # `:unknown` is an app whose process did not answer the listing: its
  # container may well be up, so it blocks like a started one. Any other
  # state blocks only while the container still runs (`alive?`): an `:error`
  # app whose URL probe failed is not stopped when the watchdog cannot act.
  @in_use_states [:startup, :started, :unknown]

  # Past muontrap's SIGTERM -> 500 ms -> SIGKILL -> reap sequence, so only a
  # wedged wrapper runs into it.
  @os_exit_timeout_ms 3_000
  @os_exit_poll_ms 50

  # `:global` sleeps a random up-to 250, 500 and 1000 ms between these
  # retries, so a caller that cannot get the lock gives up within 1.75 s.
  @lock_retries 3

  @daemon_comms %{"dbus-daemon" => :dbus_daemon, "bluetoothd" => :bluetoothd}

  def start_link(opts \\ []) do
    # Normalize the daemon paths INTO opts before anything reads them, so the
    # existence check here and the child specs `Bluez.children/1` builds can
    # never disagree — Bluez applies its own defaults for these keys, which
    # happen to match @default_* today but aren't contractually tied to them.
    opts =
      opts
      |> Keyword.put_new(:dbus_daemon_path, @default_dbus_daemon)
      |> Keyword.put_new(:bluetoothd_path, @default_bluetoothd)

    dbus_daemon = Keyword.fetch!(opts, :dbus_daemon_path)
    bluetoothd = Keyword.fetch!(opts, :bluetoothd_path)

    if File.exists?(dbus_daemon) and File.exists?(bluetoothd) do
      Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      Logger.warning(
        "Vagus.Bluetooth: #{dbus_daemon} or #{bluetoothd} missing; Bluetooth daemons not started"
      )

      :ignore
    end
  end

  # A string segment: aliasing `Stack` here would nest the full module name
  # under `name` and no longer match the Reaper's default target.
  @spec stack_name(module()) :: module()
  def stack_name(name), do: Module.concat(name, "Stack")

  @impl Supervisor
  def init(opts) do
    stack_name = stack_name(Keyword.get(opts, :name, __MODULE__))

    # The crash-loop budget is the Stack's own (10 in 60 s). Zero here keeps
    # escalation as it was before the split: a Stack that gives up takes
    # this supervisor down at once, so Vagus.Supervisor sees one exit and
    # spends one restart of its own. `terminate_child`/`restart_child` from
    # stop/start count against neither.
    Supervisor.init([{Stack, Keyword.put(opts, :stack_name, stack_name)}],
      strategy: :one_for_one,
      max_restarts: 0,
      max_seconds: 1
    )
  end

  @doc """
  The Stack's full child list: the daemon slice plus (unless `improv: false`)
  the Improv provisioning tail. Public for child-order tests.
  """
  @spec children(keyword()) :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children(opts \\ []) do
    daemon_children(opts) ++ improv_children(opts)
  end

  # Explicit `false` match (not truthiness) so a future config-driven
  # value like `nil`/`"false"` fails loudly instead of silently toggling.
  defp improv_children(opts) do
    case Keyword.get(opts, :improv, true) do
      false -> []
      true -> [Vagus.Improv.supervisor_child(), Vagus.Improv.Reaper]
    end
  end

  @doc """
  The daemon prefix of `Bluez.children/1`: every child up to and including
  the `:bluetoothd` spec. Public for child-order tests (mirrors upstream's
  exposed `children/1`).
  """
  @spec daemon_children(keyword()) :: [Supervisor.child_spec() | {module(), term()} | module()]
  def daemon_children(opts \\ []) do
    case Enum.split_while(Bluez.children(opts), &(child_id(&1) != :bluetoothd)) do
      {prefix, [bluetoothd | _clients]} ->
        prefix ++ [bluetoothd]

      {_all, []} ->
        # Upstream contract change — fail loud at startup, not with a
        # silently client-inclusive tree.
        raise "Bluez.children/1 has no :bluetoothd child; bluez #{Application.spec(:bluez, :vsn)} incompatible"
    end
  end

  defp child_id(%{id: id}), do: id
  defp child_id(_), do: nil

  @doc """
  Stops the whole stack (see the moduledoc) and returns once both daemons'
  OS processes have exited, so the caller can hand `hci0` on immediately.
  `:ok` when already stopped, whatever apps run, once no daemon this VM
  started is left (a retry after `:still_running` waits again); otherwise
  `{:error, {:in_use, slugs}}` while an app other than the orchestrator
  has `host_dbus: true` and is starting, started, unanswering, or in any
  other state with its container still up — the orchestrator must stop those
  (upstream's Matter Server and Terminal & SSH both set it) before taking
  Bluetooth. The orchestrator itself is exempt: its bind is a convenience,
  it does not need the host bluetoothd. The refusal is not mirrored on app
  start. `{:error, {:still_running, id}}` when a daemon outlives the wait.

  Opts: `:server`, `:apps_fun` (default `Vagus.App.list/0`),
  `:socket_path` (default `Bluez.socket_path/0`), `:os_pid_fun` (default
  `MuonTrap.Daemon.os_pid/1`), `:proc_alive_fun`, `:live_daemons_fun`
  (default: this VM's descendant `dbus-daemon`/`bluetoothd` processes),
  `:os_exit_timeout_ms`, `:lock_retries`. `{:error, :busy}` while another
  `stop/1` or `start/1` holds the transition.
  """
  @spec stop(keyword()) ::
          :ok
          | {:error,
             :absent
             | :busy
             | {:in_use, [String.t()]}
             | {:apps, term()}
             | {:still_running, atom()}}
  def stop(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    transition(server, opts, fn ->
      case stack(server) do
        # A stop whose wait timed out has already terminated the Stack, so
        # its retry lands here with the daemon possibly still up.
        {:ok, :undefined} -> settle(opts)
        {:ok, state} -> stop_running(server, state, opts)
        error -> error
      end
    end)
  end

  # The parent supervisor serialises terminate_child and restart_child, not
  # the OS-exit wait and socket removal around them: unlocked, a start/1
  # landing in that wait brings up a new dbus-daemon whose socket the stop
  # then unlinks.
  defp transition(server, opts, fun) do
    lock = {{__MODULE__, server}, self()}

    case :global.trans(lock, fun, [node()], Keyword.get(opts, :lock_retries, @lock_retries)) do
      :aborted -> {:error, :busy}
      result -> result
    end
  end

  defp stop_running(server, state, opts) do
    with :ok <- refuse_in_use(Keyword.get(opts, :apps_fun, &Vagus.App.list/0)) do
      # Read before terminating: once the Daemon GenServers are gone nothing
      # on the BEAM side still knows the OS pids.
      os_pids = os_pids(state, Keyword.get(opts, :os_pid_fun, &MuonTrap.Daemon.os_pid/1))

      with :ok <- terminate(server),
           :ok <- await_exit(os_pids, opts) do
        remove_socket(opts)
      end
    end
  end

  defp settle(opts) do
    live = Keyword.get(opts, :live_daemons_fun, &live_daemons/0)

    with :ok <- await(live, deadline(opts)), do: remove_socket(opts)
  end

  # The socket path is Bluez's constant unless a test injects one; nothing
  # request-derived reaches it.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_socket(opts) do
    _ = File.rm(Keyword.get(opts, :socket_path, Bluez.socket_path()))
    :ok
  end

  defp terminate(server) do
    case Supervisor.terminate_child(server, Stack) do
      :ok -> :ok
      {:error, :not_found} -> {:error, :absent}
    end
  catch
    :exit, _ -> {:error, :absent}
  end

  defp os_pids(stack, os_pid_fun) when is_pid(stack) do
    for {id, pid, _type, _mods} <- which_children(stack),
        id in [:dbus_daemon, :bluetoothd] and is_pid(pid),
        os_pid = safe_os_pid(os_pid_fun, pid),
        is_integer(os_pid),
        do: {id, os_pid}
  end

  defp os_pids(_restarting, _os_pid_fun), do: []

  defp which_children(sup) do
    Supervisor.which_children(sup)
  catch
    :exit, _ -> []
  end

  # A daemon exiting between which_children and the call has no OS pid
  # left to wait for.
  defp safe_os_pid(fun, pid) do
    fun.(pid)
  catch
    :exit, _ -> nil
  end

  # The pid is the muontrap wrapper's, which exits only after reaping its
  # daemon, so its /proc entry vanishing means the daemon is gone too.
  defp await_exit(os_pids, opts) do
    alive? = Keyword.get(opts, :proc_alive_fun, &proc_alive?/1)
    await(fn -> for {id, os_pid} <- os_pids, alive?.(os_pid), do: id end, deadline(opts))
  end

  defp deadline(opts),
    do:
      System.monotonic_time(:millisecond) +
        Keyword.get(opts, :os_exit_timeout_ms, @os_exit_timeout_ms)

  defp await(live_fun, deadline) do
    case live_fun.() do
      [] ->
        :ok

      [id | _] ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, {:still_running, id}}
        else
          Process.sleep(@os_exit_poll_ms)
          await(live_fun, deadline)
        end
    end
  end

  # An OS pid read from the port, never request-derived.
  # sobelow_skip ["Traversal.FileModule"]
  defp proc_alive?(os_pid), do: File.exists?("/proc/#{os_pid}")

  # Once the Stack is gone nothing on the BEAM side holds the daemons' pids,
  # so the retry looks in /proc. Ancestry, not the name alone: a worker's
  # bluetoothd in a rootful podman container is just as visible here, and
  # is exactly the one that must keep running.
  defp live_daemons do
    beam = String.to_integer(System.pid())

    for entry <- ls_proc(),
        {os_pid, ""} <- [Integer.parse(entry)],
        id = Map.get(@daemon_comms, read_comm(os_pid)),
        id != nil and descends_from?(os_pid, beam, 16),
        do: id
  end

  defp ls_proc do
    case File.ls("/proc") do
      {:ok, entries} -> entries
      {:error, _} -> []
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_comm(os_pid) do
    case File.read("/proc/#{os_pid}/comm") do
      {:ok, comm} -> String.trim_trailing(comm)
      {:error, _} -> nil
    end
  end

  # The depth bound only stops a walk the /proc snapshot made cyclic; the
  # real chain is daemon -> muontrap -> erl_child_setup -> beam.
  defp descends_from?(_os_pid, _beam, 0), do: false

  defp descends_from?(os_pid, beam, depth) do
    case ppid(os_pid) do
      ^beam -> true
      ppid when is_integer(ppid) and ppid > 1 -> descends_from?(ppid, beam, depth - 1)
      _init_or_gone -> false
    end
  end

  # comm may itself hold spaces or parentheses, so fields count from the last ")".
  # sobelow_skip ["Traversal.FileModule"]
  defp ppid(os_pid) do
    with {:ok, stat} <- File.read("/proc/#{os_pid}/stat"),
         [_state, ppid | _] <- stat |> String.split(")") |> List.last() |> String.split(),
         {ppid, ""} <- Integer.parse(ppid) do
      ppid
    else
      _ -> nil
    end
  end

  @doc """
  Starts the stack again in boot order, the Improv tail included. `:ok`
  when already running; `{:error, :busy}` while the supervisor is retrying
  a failed restart of it or while a `stop/1` holds the transition.

  Opts: `:server`, `:lock_retries`.
  """
  @spec start(keyword()) :: :ok | {:error, :absent | :busy | term()}
  def start(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    transition(server, opts, fn -> restart(server) end)
  end

  defp restart(server) do
    case Supervisor.restart_child(server, Stack) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, :restarting} -> {:error, :busy}
      {:error, :not_found} -> {:error, :absent}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _ -> {:error, :absent}
  end

  @doc """
  `:running` also while the supervisor is retrying a failed restart;
  `:absent` when `start_link/1` returned `:ignore` (or the tree is down).
  """
  @spec status(keyword()) :: :running | :stopped | :absent
  def status(opts \\ []) do
    case stack(Keyword.get(opts, :server, __MODULE__)) do
      {:ok, :undefined} -> :stopped
      {:ok, _pid_or_restarting} -> :running
      {:error, :absent} -> :absent
    end
  end

  defp stack(server) do
    case List.keyfind(Supervisor.which_children(server), Stack, 0) do
      {Stack, state, _type, _mods} -> {:ok, state}
      nil -> {:error, :absent}
    end
  catch
    :exit, _ -> {:error, :absent}
  end

  defp refuse_in_use(apps_fun) do
    with {:ok, apps} <- list_apps(apps_fun) do
      slugs =
        for %{config: %{slug: slug, host_dbus: true}, state: state} = app <- apps,
            state in @in_use_states or Map.get(app, :alive?, false),
            not Vagus.App.orchestrator?(slug),
            do: slug

      if slugs == [], do: :ok, else: {:error, {:in_use, Enum.sort(slugs)}}
    end
  end

  # The listing calls every app's process; a failure there is the caller's
  # answer, not a crash in the erpc handler.
  defp list_apps(apps_fun) do
    {:ok, apps_fun.()}
  rescue
    error -> {:error, {:apps, error}}
  catch
    :exit, reason -> {:error, {:apps, reason}}
  end
end
