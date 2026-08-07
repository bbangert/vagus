defmodule Vagus.Engine.Manager do
  @moduledoc """
  Gates balena-engine daemon startup on real internet connectivity, then
  supervises the daemon as an OS process.

  Subscribes to `vintage_net`'s **aggregate** `["connection"]` property (via
  `VintageNet.subscribe/1`) rather than polling `VintageNet.get/1` in a sleep
  loop — the nerves-containers prior art
  (`research/balena-packaging-scan.md`) does the latter; a subscription gets
  the same "wait for `:internet`" behavior as an event instead of a busy
  loop. `["connection"]` is vintage_net's own best-of-all-interfaces status
  (`VintageNet.Route.Properties.update_best_connection/1`), not a
  per-interface `["interface", ifname, "connection"]` value, so this reacts
  correctly regardless of which interface (eth0/wlan0/usb0) ends up
  providing internet.

  On the **first** transition into `:internet` this GenServer:

    0. Creates `Vagus.Core.Container.socket_dir/0` (`/run/supervisor`), the
       bind-mount source for the socket Core opens as
       `SUPERVISOR_CORE_API_SOCKET`. `/run` is tmpfs, so the directory is
       gone after every boot and must be back *before* the daemon starts:
       the daemon immediately revives Core's `unless-stopped` container, and
       a bind mount whose source is missing fails the container start
       outright. Idempotent + best-effort (logged, non-blocking) like
       `/run/resolv.conf` below.
    1. Writes `/run/resolv.conf` (`Vagus.Engine.ResolvConf`) from
       vintage_net's `["name_servers"]` property, with a static fallback —
       *before* starting the daemon, because balena-engine and the
       containers it launches read resolver config at daemon-start time;
       starting too early leaves them with broken DNS for the entire boot
       (the exact failure mode the prior art's sleep-poll was working
       around). A write failure (e.g. `/run` not mounted yet) is logged and
       does **not** block daemon start — an earlier boot may have left a
       valid file in place, and refusing to start the engine over a resolver
       write failure is worse than starting it with stale DNS.
    2. Starts `balena-engine-daemon` as a `MuonTrap.Daemon`, added
       dynamically to `Vagus.Engine.DaemonSupervisor` so a later daemon
       crash gets restarted (via the supervisor's normal `:permanent`
       restart) without needing to observe `:internet` again.

  The daemon's pid is monitored (`Process.monitor/1`) once started, and
  `DynamicSupervisor.start_child/2`'s result is never trusted to be `{:ok,
  _}` — a fixed child `name:` means `{:error, {:already_started, pid}}` is a
  real, non-fatal outcome (treated as "already running", the returned pid is
  monitored same as a fresh start). Any other `{:error, reason}` is logged
  and schedules a `:retry_daemon_start` message (`@retry_ms`) instead of
  crashing the `GenServer` — a crash here would replay the exact same
  failing call on restart, with no backoff, risking exhaustion of
  `Vagus.Supervisor`'s restart intensity (device reboot on this target). If
  the monitored daemon later goes `:DOWN` (e.g. `DaemonSupervisor` exhausted
  its own restart budget and gave up), the same retry is scheduled so the
  engine doesn't limp along dead with no signal — the retry's
  `:already_started` branch just re-monitors if something else already
  restarted it, otherwise it starts the daemon fresh.

  Spike scope: this only ever starts the daemon once per boot (plus
  retries). There is no reconciliation/adoption logic here (see plan.md task
  4.2, explicitly observation-only for this milestone).
  """

  use GenServer

  require Logger

  alias Vagus.Core.Container
  alias Vagus.Engine.ResolvConf

  @connection_property ["connection"]

  # How long to wait before re-attempting a failed/lost daemon start.
  @retry_ms 5_000

  # Use the real mount path, NOT the `/data` symlink (→ `/root`): runc rejects a
  # container rootfs whose path contains a symlink component ("invalid rootfs:
  # not an absolute path, or a symlink"), which blocked every container from
  # starting on-device. `/root/balena-engine` is the same physical directory,
  # just without the symlink. (On-device P0-T1 finding, 2026-07-21.)
  @data_root "/root/balena-engine"
  @exec_root "/run/balena-engine"
  @pidfile "/run/balena-engine.pid"
  @socket "unix:///run/balena-engine.sock"

  @daemon_args [
    "--data-root=#{@data_root}",
    "--exec-root=#{@exec_root}",
    "--pidfile=#{@pidfile}",
    "--host=#{@socket}",
    "--storage-driver=overlay2",
    "--exec-opt",
    "native.cgroupdriver=cgroupfs",
    "--iptables=true",
    # Containers survive daemon restarts (MuonTrap respawns kill the daemon
    # process; without this every respawn also bounced all containers —
    # restart-matrix finding, plan task 4.2).
    "--live-restore"
  ]

  @doc """
  Starts the manager.

  Options:

    * `:daemon_supervisor` - the `DynamicSupervisor` (name or pid) to start
      the `MuonTrap.Daemon` child under. Defaults to
      `Vagus.Engine.DaemonSupervisor`.
    * `:name` - GenServer name, defaults to `__MODULE__`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The daemon's command-line arguments (exposed for inspection/testing)."
  @spec daemon_args() :: [String.t()]
  def daemon_args, do: @daemon_args

  @doc "The engine's --data-root (volumes live under `<data_root>/volumes`)."
  @spec data_root() :: String.t()
  def data_root, do: @data_root

  @impl GenServer
  def init(opts) do
    daemon_supervisor =
      Keyword.get(opts, :daemon_supervisor, Vagus.Engine.DaemonSupervisor)

    subscribe_to_connection()

    state = %{daemon_supervisor: daemon_supervisor, daemon_pid: nil, daemon_monitor_ref: nil}

    # Handle the case where :internet was already reached before we
    # subscribed (e.g. this GenServer restarted after a crash).
    {:ok, start_daemon_if_already_connected(state)}
  end

  @impl GenServer
  def handle_info(
        {VintageNet, @connection_property, _previous, :internet, _meta},
        %{daemon_pid: nil} = state
      ) do
    {:noreply, start_daemon(state)}
  end

  def handle_info({VintageNet, @connection_property, _previous, _new, _meta}, state) do
    {:noreply, state}
  end

  # The daemon we're monitoring went down (crashed past DaemonSupervisor's
  # own restart budget, or was killed outright). Clear our started-state and
  # retry — otherwise the engine limps along dead with no signal until (if
  # ever) the connection property happens to flap.
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{daemon_monitor_ref: ref} = state
      ) do
    Logger.warning(
      "Vagus.Engine.Manager: balena-engine-daemon is down (#{inspect(reason)}), " <>
        "retrying in #{@retry_ms}ms"
    )

    Process.send_after(self(), :retry_daemon_start, @retry_ms)

    {:noreply, %{state | daemon_pid: nil, daemon_monitor_ref: nil}}
  end

  def handle_info(:retry_daemon_start, %{daemon_pid: nil} = state) do
    {:noreply, maybe_retry_start(state)}
  end

  # Already started (or not our retry to act on) - no-op. Covers both the
  # "already started" no-double-start guard and stray retry messages.
  def handle_info(:retry_daemon_start, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  defp start_daemon(state) do
    Logger.info("Vagus.Engine.Manager: internet reached, starting balena-engine-daemon")

    make_root_shared()
    ensure_core_socket_dir()

    case current_name_servers() |> ResolvConf.write() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Vagus.Engine.Manager: failed to write #{ResolvConf.path()} " <>
            "(#{inspect(reason)}), proceeding with daemon start anyway"
        )
    end

    case DynamicSupervisor.start_child(state.daemon_supervisor, daemon_child_spec()) do
      {:ok, pid} ->
        monitor_daemon(state, pid)

      {:error, {:already_started, pid}} ->
        monitor_daemon(state, pid)

      {:error, reason} ->
        Logger.error(
          "Vagus.Engine.Manager: failed to start balena-engine-daemon " <>
            "(#{inspect(reason)}), retrying in #{@retry_ms}ms"
        )

        Process.send_after(self(), :retry_daemon_start, @retry_ms)
        state
    end
  end

  # Add-ons bind-mount share/media with `rslave` propagation, which the daemon
  # rejects unless the source's mount is shared/slave ("not a shared or slave
  # mount"). HAOS makes the rootfs shared; replicate that once here, before any
  # add-on container starts. Idempotent + best-effort. (On-device Gate-1
  # finding, 2026-07-21.)
  defp make_root_shared do
    case System.cmd("/bin/mount", ["--make-rshared", "/"], stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Logger.warning("Vagus.Engine.Manager: make-rshared / failed (#{code}): #{out}")
    end
  rescue
    e -> Logger.warning("Vagus.Engine.Manager: make-rshared / errored: #{Exception.message(e)}")
  end

  # Core's container bind-mounts this directory to hand Vagus the socket it
  # opens as SUPERVISOR_CORE_API_SOCKET (see `Vagus.Core.Container`). Best-
  # effort like `make_root_shared/0`: a failure here breaks Core's start, but
  # refusing to start the engine over it would break everything else too.
  #
  # The path is a module constant (`Vagus.Core.Container.socket_dir/0`), not
  # request input — no caller can influence it.
  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_core_socket_dir do
    case File.mkdir_p(Container.socket_dir()) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Vagus.Engine.Manager: failed to create #{Container.socket_dir()} " <>
            "(#{inspect(reason)}), Core's Supervisor socket mount will fail"
        )
    end
  end

  defp monitor_daemon(state, pid) do
    %{state | daemon_pid: pid, daemon_monitor_ref: Process.monitor(pid)}
  end

  defp daemon_child_spec do
    {MuonTrap.Daemon,
     [
       "balena-engine-daemon",
       @daemon_args,
       [
         name: Vagus.Engine.Daemon,
         log_output: :info,
         log_prefix: "balena-engine-daemon: "
       ]
     ]}
  end

  # `vintage_net` (pulled in via `nerves_pack`, scoped to real targets) isn't
  # compiled at all under MIX_TARGET=host. These are the only places that
  # reference `VintageNet` directly, so the module still compiles cleanly
  # (and its pure parts, like `daemon_args/0`, stay unit-testable) on :host.
  # This mirrors the `target_children/0` split already used in
  # `Vagus.Application` — the host branch is never exercised in practice
  # since `Vagus.Application` doesn't start this GenServer on :host at all.
  #
  # `start_daemon_if_already_connected/1`'s `case` (not just its
  # `VintageNet.get/1` call) is entirely inside the target branch so the
  # compiler's type checker never sees a version of this function whose
  # only implementation returns a single literal atom — that would make it
  # (wrongly, for the real target build) flag the `:internet` clause as
  # unreachable.
  if Mix.target() == :host do
    defp subscribe_to_connection, do: :ok
    defp start_daemon_if_already_connected(state), do: state
    defp current_name_servers, do: []

    # `Manager` is never started on :host (see `Vagus.Application`), so this
    # stub is never exercised by the running app. It's also deliberately a
    # no-op (not a real connectivity check) so that if a test invokes
    # `handle_info(:retry_daemon_start, ...)` directly on :host, it can
    # never fall through to `start_daemon/1` and its real
    # `ResolvConf.write/1` call against `/run/resolv.conf` by accident. Kept
    # as its own target-only clause (rather than a shared `if` on a host
    # stub returning a literal `false`) so the compiler's type checker
    # doesn't flag the real target branch's `:internet` check as dead code —
    # same reasoning as `start_daemon_if_already_connected/1` above.
    defp maybe_retry_start(state), do: state
  else
    @name_servers_property ["name_servers"]

    defp subscribe_to_connection, do: VintageNet.subscribe(@connection_property)

    defp start_daemon_if_already_connected(state) do
      case VintageNet.get(@connection_property) do
        :internet -> start_daemon(state)
        _not_yet -> state
      end
    end

    defp current_name_servers, do: VintageNet.get(@name_servers_property, [])

    defp maybe_retry_start(state) do
      case VintageNet.get(@connection_property) do
        :internet -> start_daemon(state)
        _not_connected -> state
      end
    end
  end
end
