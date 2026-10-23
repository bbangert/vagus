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

  Phase 2 (vagus-improv): the tree's tail carries the Improv-over-BLE
  Wi-Fi provisioning group + its reaper (see `Vagus.Improv` /
  `Vagus.Improv.Reaper`), mounted per improv's contract — appended last
  under `:rest_for_one`, so a `bluetoothd` restart rebuilds the group
  while an Improv fault never disturbs the daemons. The group idles
  disarmed on an online boot and is reaped once the network is up;
  disable entirely with `improv: false` in opts.

  `stop/1` / `start/1` / `status/1` let the agent-dev-board orchestrator
  release the host stack over distribution so a worker container can own
  `hci0` with its own `bluetoothd`, then take it back. Stopping takes the
  whole daemon slice down, `dbus-daemon` included, and removes its
  `/run/dbus/system_bus_socket` (dbus-daemon leaves the file behind on
  SIGTERM): every `/run/dbus` bind — HA Core's and each `host_dbus: true`
  app's — then holds no bus until `start/1`, which is why `stop/1` refuses
  while such an app is started. The Improv tail is stopped AND deleted with
  the daemons, not kept: it registers its GATT service through bluetoothd
  so it cannot outlive it, and a board reached over distribution is online,
  the state in which `Vagus.Improv.Reaper` would have removed it anyway.
  The stopped state lives in this supervisor only — a restart of
  `Vagus.Bluetooth` itself (or a reboot) brings the daemons back. This is a
  consistency API for a root agent, not a guard against it.
  """

  use Supervisor

  require Logger

  @default_dbus_daemon "/usr/bin/dbus-daemon"
  @default_bluetoothd "/usr/libexec/bluetooth/bluetoothd"

  # `:unknown` is an app whose process did not answer the listing: its
  # container may well be up, so it blocks like a started one.
  @in_use_states [:startup, :started, :unknown]

  def start_link(opts \\ []) do
    # Normalize the daemon paths INTO opts before anything reads them, so the
    # existence check here and the child specs `Bluez.children/1` builds in
    # `init/1` can never disagree — Bluez applies its own defaults for these
    # keys, which happen to match @default_* today but aren't contractually
    # tied to them (Copilot review, PR #4).
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

  @impl Supervisor
  def init(opts) do
    # Creates /run/dbus (+ machine-id, stale-socket cleanup) and
    # /data/bluetooth before the daemons launch; idempotent per restart.
    Keyword.get(opts, :prepare_runtime, &Bluez.prepare_runtime/0).()

    # Same explicit budget as the upstream tree: a daemon crash-loop
    # escalates to Vagus.Supervisor within a minute instead of cycling
    # silently forever.
    Supervisor.init(Keyword.get_lazy(opts, :children, fn -> children(opts) end),
      strategy: :rest_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  @doc """
  The full child list: the daemon slice plus (unless `improv: false`) the
  Improv provisioning tail. Public for child-order tests.
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
  Stops the daemon slice and drops the Improv tail (see the moduledoc).
  `:ok` when already stopped; `{:error, {:in_use, slugs}}` while a started
  app other than the orchestrator has `host_dbus: true` — the orchestrator
  must stop those (upstream's Matter Server and Terminal & SSH both set
  it) before taking Bluetooth. The orchestrator itself is
  exempt: its bind is a convenience, it does not need the host bluetoothd.

  Opts: `:server`, `:apps_fun` (default `Vagus.App.list/0`),
  `:socket_path` (default `Bluez.socket_path/0`).
  """
  @spec stop(keyword()) :: :ok | {:error, :absent | {:in_use, [String.t()]} | term()}
  # The socket path is Bluez's constant unless a test injects one; nothing
  # request-derived reaches it.
  # sobelow_skip ["Traversal.FileModule"]
  def stop(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    serialized(server, fn ->
      with {:ok, children} <- children_of(server),
           :ok <- refuse_in_use(Keyword.get(opts, :apps_fun, &Vagus.App.list/0)) do
        {tail, daemons} = split(children)

        with :ok <- each(tail, &drop(server, &1)),
             :ok <- each(ids(daemons), &Supervisor.terminate_child(server, &1)) do
          _ = File.rm(Keyword.get(opts, :socket_path, Bluez.socket_path()))
          :ok
        end
      end
    end)
  end

  @doc """
  Restarts the stopped daemon children in their original order and
  positions, so `:rest_for_one` semantics are as at boot (minus Improv,
  which `stop/1` dropped for good). `:ok` when already running.

  Opts: `:server`, `:prepare_runtime` (default `Bluez.prepare_runtime/0`).
  """
  @spec start(keyword()) :: :ok | {:error, :absent | {term(), term()}}
  def start(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    serialized(server, fn ->
      with {:ok, children} <- children_of(server) do
        {_tail, daemons} = split(children)
        stopped = for {id, :undefined, _type, _mods} <- daemons, do: id

        # A worker's own dbus-daemon on a shared /run/dbus may have left its
        # socket; a stale file waves BusReady through to ECONNREFUSED. Only
        # when dbus itself restarts — never unlink a live daemon's socket.
        if :dbus_daemon in stopped,
          do: Keyword.get(opts, :prepare_runtime, &Bluez.prepare_runtime/0).()

        stopped |> Enum.reverse() |> each(&restart(server, &1))
      end
    end)
  end

  @doc "`:absent` when `start_link/1` returned `:ignore` (or the tree is down)."
  @spec status(keyword()) :: :running | :stopped | :absent
  def status(opts \\ []) do
    case children_of(Keyword.get(opts, :server, __MODULE__)) do
      {:ok, children} ->
        if Enum.any?(children, &match?({:bluetoothd, pid, _, _} when is_pid(pid), &1)),
          do: :running,
          else: :stopped

      {:error, :absent} ->
        :absent
    end
  end

  # Concurrent stop/start over distribution would interleave their
  # per-child calls and leave a half-torn tree.
  defp serialized(server, fun), do: :global.trans({{__MODULE__, server}, self()}, fun, [node()])

  defp children_of(server) do
    if GenServer.whereis(server),
      do: {:ok, Supervisor.which_children(server)},
      else: {:error, :absent}
  catch
    :exit, _ -> {:error, :absent}
  end

  # which_children lists newest-first, so everything before :bluetoothd is
  # the tail started after it, and the rest is the daemon slice in reverse
  # start order — the order to stop it in (bluetoothd before dbus).
  defp split(children) do
    {tail, daemons} = Enum.split_while(children, &(elem(&1, 0) != :bluetoothd))
    {ids(tail), daemons}
  end

  defp ids(children), do: Enum.map(children, &elem(&1, 0))

  defp refuse_in_use(apps_fun) do
    slugs =
      for %{config: %{slug: slug, host_dbus: true}, state: state} <- apps_fun.(),
          state in @in_use_states,
          not Vagus.App.orchestrator?(slug),
          do: slug

    if slugs == [], do: :ok, else: {:error, {:in_use, Enum.sort(slugs)}}
  end

  # Deleted, not just terminated: a kept spec would come back on the next
  # bluetoothd cascade. `:not_found` is the Reaper having got there first.
  defp drop(server, id) do
    case Supervisor.terminate_child(server, id) do
      :ok -> delete(server, id)
      {:error, :not_found} -> :ok
    end
  end

  defp delete(server, id) do
    case Supervisor.delete_child(server, id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, {id, reason}}
    end
  end

  defp restart(server, id) do
    case Supervisor.restart_child(server, id) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, reason} -> {:error, {id, reason}}
    end
  end

  defp each(ids, fun) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case fun.(id) do
        :ok -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
