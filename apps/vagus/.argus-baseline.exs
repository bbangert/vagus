# Reviewed argus findings: each is a validated false positive or deliberate
# design, with its reason. Checked by scripts/argus_baseline.exs (see its
# header for the workflow); prefer fixing a finding over adding it here.
[
  %{
    analysis: "startup",
    file: "lib/vagus/addon/boot_starter.ex",
    title: "handle_continue races a later sibling",
    detail:
      "Vagus.Addon.BootStarter sync-calls Vagus.DNS, a later sibling, from handle_continue under Vagus.Application. The continue runs concurrently with the supervisor's start sequence, so whether Vagus.DNS is alive when the call lands is a boot-time race — it works on the fast machine and fails in CI.",
    reason:
      "BootStarter's continue reaches Vagus.DNS/Vagus.Ingress only after its :api phase sees Vagus.API.Listener accepting, and Vagus.API.Supervisor starts after both DNS and Ingress in Vagus.Application's one_for_one child order, so they are always up by then. Before that it only pings the engine and binds the bridge anchors."
  },
  %{
    analysis: "startup",
    file: "lib/vagus/addon/boot_starter.ex",
    title: "handle_continue races a later sibling",
    detail:
      "Vagus.Addon.BootStarter sync-calls Vagus.Ingress, a later sibling, from handle_continue under Vagus.Application. The continue runs concurrently with the supervisor's start sequence, so whether Vagus.Ingress is alive when the call lands is a boot-time race — it works on the fast machine and fails in CI.",
    reason:
      "BootStarter's continue reaches Vagus.DNS/Vagus.Ingress only after its :api phase sees Vagus.API.Listener accepting, and Vagus.API.Supervisor starts after both DNS and Ingress in Vagus.Application's one_for_one child order, so they are always up by then. Before that it only pings the engine and binds the bridge anchors."
  },
  %{
    analysis: "shutdown",
    file: "lib/vagus/api/core_proxy/ws_bridge.ex",
    title: "terminate/2 does work a supervisor shutdown will skip",
    detail:
      "Vagus.API.CoreProxy.WSBridge.Upstream does not trap exits, so a GenServer shutdown from its supervisor kills it outright and terminate/2 never runs. Vagus.API.CoreProxy.WSBridge.Upstream.terminate/2 calls Mint.HTTP.close/1, which the effect model cannot classify — so this cannot say WHAT is skipped, only that terminate/2 does more than log and none of it will happen on the normal stop path. If that call releases a lease, closes a session or flushes a buffer, it is silently not happening in production.",
    reason:
      "terminate/2 only sends a courtesy WebSocket close frame (Upstream) or closes the Mint connection; the socket is owned by this process, so the VM closes it when the process is killed. Skipping it on a shutdown only drops the close frame — the peer sees the TCP close."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "Vagus.Addon.BootStarter registers with Vagus.Addon.Registry when it starts, and Vagus.Addon.Registry keeps it in its state. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Addon.Registry restarts, its init/1 starts it afresh without what Vagus.Addon.BootStarter put there, and Vagus.Addon.BootStarter, which is not restarted with it, never registers again. When Vagus.Addon.BootStarter restarts, it registers a second time beside what its old process left.",
    reason:
      "Misattributed: Vagus.Addon.Manager registers each add-on's per-start token on every start (boot reconciliation, the router, the watchdog), not this boot-time caller specifically, and the token is minted per start, so a re-register is only possible by restarting the add-on. Known design gap, tracked as a follow-up: Vagus.Addon.Registry should rebuild from Vagus.Addon.State in init/1."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "Vagus.Addon.BootStarter registers with Vagus.Addon.State when it starts, and Vagus.Addon.State keeps it in its state. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Addon.State restarts, its init/1 starts it afresh without what Vagus.Addon.BootStarter put there, and Vagus.Addon.BootStarter, which is not restarted with it, never registers again. When Vagus.Addon.BootStarter restarts, it registers a second time beside what its old process left.",
    reason:
      "Vagus.Addon.State is file-backed and reloads every entry from disk in init/1, so its restart loses nothing a caller put there."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "Vagus.Addon.BootStarter registers with Vagus.DNS when it starts, and Vagus.DNS keeps it in its state. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.DNS restarts, its init/1 starts it afresh without what Vagus.Addon.BootStarter put there, and Vagus.Addon.BootStarter, which is not restarted with it, never registers again. When Vagus.Addon.BootStarter restarts, it registers a second time beside what its old process left.",
    reason:
      "Misattributed: Vagus.Addon.Manager registers each add-on's DNS name (container bridge IP) on every start, not this boot-time caller specifically. Known design gap, tracked as a follow-up: Vagus.DNS should rebuild its dynamic names for running add-ons after a restart."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "Vagus.Addon.DefaultProvider registers with Vagus.Addon.Registry when it starts, and Vagus.Addon.Registry keeps it in its state. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Addon.Registry restarts, its init/1 starts it afresh without what Vagus.Addon.DefaultProvider put there, and Vagus.Addon.DefaultProvider, which is not restarted with it, never registers again. When Vagus.Addon.DefaultProvider restarts, it registers a second time beside what its old process left.",
    reason:
      "Misattributed: Vagus.Addon.Manager registers each add-on's per-start token on every start (boot reconciliation, the router, the watchdog), not this boot-time caller specifically, and the token is minted per start, so a re-register is only possible by restarting the add-on. Known design gap, tracked as a follow-up: Vagus.Addon.Registry should rebuild from Vagus.Addon.State in init/1."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "Vagus.Addon.DefaultProvider registers with Vagus.Addon.State when it starts, and Vagus.Addon.State keeps it in its state. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Addon.State restarts, its init/1 starts it afresh without what Vagus.Addon.DefaultProvider put there, and Vagus.Addon.DefaultProvider, which is not restarted with it, never registers again. When Vagus.Addon.DefaultProvider restarts, it registers a second time beside what its old process left.",
    reason:
      "Vagus.Addon.State is file-backed and reloads every entry from disk in init/1, so its restart loses nothing a caller put there."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "Vagus.Addon.DefaultProvider registers with Vagus.DNS when it starts, and Vagus.DNS keeps it in its state. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.DNS restarts, its init/1 starts it afresh without what Vagus.Addon.DefaultProvider put there, and Vagus.Addon.DefaultProvider, which is not restarted with it, never registers again. When Vagus.Addon.DefaultProvider restarts, it registers a second time beside what its old process left.",
    reason:
      "Misattributed: Vagus.Addon.Manager registers each add-on's DNS name (container bridge IP) on every start, not this boot-time caller specifically. Known design gap, tracked as a follow-up: Vagus.DNS should rebuild its dynamic names for running add-ons after a restart."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "Vagus.Addon.Watchdog registers with Vagus.Runtime.Events when it starts, and Vagus.Runtime.Events keeps a monitor or link for it. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Runtime.Events restarts, its init/1 starts it afresh without what Vagus.Addon.Watchdog put there, and Vagus.Addon.Watchdog, which is not restarted with it, never registers again. When Vagus.Addon.Watchdog restarts, it registers a second time beside what its old process left.",
    reason:
      "Fixed rather than accepted: the subscriber monitors the server it subscribed to and re-subscribes to the restarted, name-registered server (Vagus.Resubscribe, see its tests). argus does not model re-registering from a handler (restart_state.dl: \"a's re-registering on a schedule of its own\" is not asked), so it still reports the init/1 subscribe."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "Vagus.Core.Boot registers with Vagus.Core.HttpConfig when it starts, and Vagus.Core.HttpConfig keeps it in its state. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Core.HttpConfig restarts, its init/1 starts it afresh without what Vagus.Core.Boot put there, and Vagus.Core.Boot, which is not restarted with it, never registers again. When Vagus.Core.Boot restarts, it registers a second time beside what its old process left.",
    reason:
      "Per-use write, not a standing registration: HttpConfig caches Core's reported port/ssl, and by design (Vagus.Core.Supervisor moduledoc) a restart drops back to defaults and is re-pulled at the next Core start/healthy transition."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "Vagus.Core.Watchdog registers with Vagus.Runtime.Events when it starts, and Vagus.Runtime.Events keeps a monitor or link for it. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Runtime.Events restarts, its init/1 starts it afresh without what Vagus.Core.Watchdog put there, and Vagus.Core.Watchdog, which is not restarted with it, never registers again. When Vagus.Core.Watchdog restarts, it registers a second time beside what its old process left.",
    reason:
      "Fixed rather than accepted: the subscriber monitors the server it subscribed to and re-subscribes to the restarted, name-registered server (Vagus.Resubscribe, see its tests). argus does not model re-registering from a handler (restart_state.dl: \"a's re-registering on a schedule of its own\" is not asked), so it still reports the init/1 subscribe."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "Vagus.Core.Watchdog.Probe registers with Vagus.Core.TokenStore when it starts, and Vagus.Core.TokenStore keeps it in its state. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Core.TokenStore restarts, its init/1 starts it afresh without what Vagus.Core.Watchdog.Probe put there, and Vagus.Core.Watchdog.Probe, which is not restarted with it, never registers again. When Vagus.Core.Watchdog.Probe restarts, it registers a second time beside what its old process left.",
    reason:
      "Fixed rather than accepted: the subscriber monitors the server it subscribed to and re-subscribes to the restarted, name-registered server (Vagus.Resubscribe, see its tests). argus does not model re-registering from a handler (restart_state.dl: \"a's re-registering on a schedule of its own\" is not asked), so it still reports the init/1 subscribe."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "Vagus.OS.Updater.Checker registers with Vagus.Core.EventPusher when it starts, and Vagus.Core.EventPusher keeps it in its state. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Core.EventPusher restarts, its init/1 starts it afresh without what Vagus.OS.Updater.Checker put there, and Vagus.OS.Updater.Checker, which is not restarted with it, never registers again. When Vagus.OS.Updater.Checker restarts, it registers a second time beside what its old process left.",
    reason:
      "Per-use: the Checker pushes an update-available event per check; EventPusher queues it for Core and holds no standing registration of the Checker, so the next check simply pushes again."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "Vagus.Provisioner registers with Vagus.Core.HttpConfig when it starts, and Vagus.Core.HttpConfig keeps it in its state. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Core.HttpConfig restarts, its init/1 starts it afresh without what Vagus.Provisioner put there, and Vagus.Provisioner, which is not restarted with it, never registers again. When Vagus.Provisioner restarts, it registers a second time beside what its old process left.",
    reason:
      "Per-use write, not a standing registration: HttpConfig caches Core's reported port/ssl, and by design (Vagus.Core.Supervisor moduledoc) a restart drops back to defaults and is re-pulled at the next Core start/healthy transition."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "Vagus.Provisioner registers with Vagus.Core.Versions when it starts, and Vagus.Core.Versions keeps it in its state. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Core.Versions restarts, its init/1 starts it afresh without what Vagus.Provisioner put there, and Vagus.Provisioner, which is not restarted with it, never registers again. When Vagus.Provisioner restarts, it registers a second time beside what its old process left.",
    reason:
      "Vagus.Core.Versions persists the installed version to disk and re-reads it in init/1; its only in-memory state is a 24h latest-version cache that re-fetches on demand."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "Vagus.Provisioner registers with Vagus.Jobs when it starts, and Vagus.Jobs keeps it in its state. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Jobs restarts, its init/1 starts it afresh without what Vagus.Provisioner put there, and Vagus.Provisioner, which is not restarted with it, never registers again. When Vagus.Provisioner restarts, it registers a second time beside what its old process left.",
    reason:
      "Per-use: the Provisioner's one-shot first-boot job record. Jobs are ephemeral progress records for API polling; losing one on a Jobs restart is accepted (nothing re-reads it to drive behaviour)."
  },
  %{
    analysis: "mailbox",
    file: "lib/vagus/bounded_call.ex",
    title: "Task.yield on a linked task cannot see it crash",
    detail:
      "Vagus.BoundedCall.run/2 starts a task with Task.async (or Task.Supervisor.async), which links it to the caller, and collects it with Task.yield. yield's {:exit, reason} result is documented for a crashed task, but the link delivers the crash to this process first: unless it traps exits, the branch handling a failed task never runs — the caller is already down.",
    reason:
      "Deliberate: run/2 catches the function's raise/throw/exit inside the task (capture/1) and returns it as a value, so the task never crashes over the link; the {:exit, _} branch only covers an outside kill. The link is kept so a killed caller (the watchdog deadline failsafe) takes the inner call with it. See test/vagus/bounded_call_test.exs."
  },
  %{
    analysis: "shutdown",
    file: "lib/vagus/core/event_pusher/socket_connection.ex",
    title: "terminate/2 does work a supervisor shutdown will skip",
    detail:
      "Vagus.Core.EventPusher.SocketConnection does not trap exits, so a GenServer shutdown from its supervisor kills it outright and terminate/2 never runs. Vagus.Core.EventPusher.SocketConnection.terminate/2 calls Mint.HTTP.close/1, which the effect model cannot classify — so this cannot say WHAT is skipped, only that terminate/2 does more than log and none of it will happen on the normal stop path. If that call releases a lease, closes a session or flushes a buffer, it is silently not happening in production.",
    reason:
      "terminate/2 only sends a courtesy WebSocket close frame (Upstream) or closes the Mint connection; the socket is owned by this process, so the VM closes it when the process is killed. Skipping it on a shutdown only drops the close frame — the peer sees the TCP close."
  },
  %{
    analysis: "startup",
    file: "lib/vagus/ingress.ex",
    title: "init/1 connects with no reconnect path",
    detail:
      "Vagus.Ingress's init/1 reaches :gen_tcp.connect/4, and nothing in the module arms a timer or continues after init to try again. When the dependency is not there yet, init fails, the supervisor restarts the child at once, and after max_restarts the tree — usually the application — goes down at boot.",
    reason:
      "False positive: Vagus.Ingress.init/1 only captures &default_port_probe/2 as the :port_probe closure; the :gen_tcp.connect runs later, per port allocation, never in init/1."
  },
  %{
    analysis: "shutdown",
    file: "lib/vagus/ingress/ws_bridge.ex",
    title: "terminate/2 does work a supervisor shutdown will skip",
    detail:
      "Vagus.Ingress.WSBridge.Upstream does not trap exits, so a GenServer shutdown from its supervisor kills it outright and terminate/2 never runs. Vagus.Ingress.WSBridge.Upstream.terminate/2 calls Mint.HTTP.close/1, which the effect model cannot classify — so this cannot say WHAT is skipped, only that terminate/2 does more than log and none of it will happen on the normal stop path. If that call releases a lease, closes a session or flushes a buffer, it is silently not happening in production.",
    reason:
      "terminate/2 only sends a courtesy WebSocket close frame (Upstream) or closes the Mint connection; the socket is owned by this process, so the VM closes it when the process is killed. Skipping it on a shutdown only drops the close frame — the peer sees the TCP close."
  },
  %{
    analysis: "startup",
    file: "lib/vagus/ssh_access.ex",
    title: "Distributed operation in init/1",
    detail:
      "Vagus.SSHAccess.init/1 performs open_file during init, while the supervisor's start sequence waits. A slow or partitioned peer stalls local startup.",
    reason:
      "False positive: :dets.open_file opens a local file (the SSH key store), not a distributed table, and any open failure degrades the server (accessors answer {:error, :unavailable}) instead of failing its start."
  },
  %{
    analysis: "startup",
    file: "lib/vagus/api/core_proxy/ws_bridge.ex",
    title: "init/1 blocks on a synchronous call",
    detail:
      "Vagus.API.CoreProxy.WSBridge.init/1 makes a synchronous call to Vagus.Core.Versions (directly or transitively) on every init. init runs inside the supervisor's start sequence, so the tree's startup stalls for as long as Vagus.Core.Versions takes to answer. Argus could not establish where Vagus.Core.Versions runs relative to this init — its child spec is built at runtime — so this is a note, not a diagnosis; a proven startup deadlock is reported separately as an error.",
    reason:
      "WSBridge is a per-connection WebSock handler started by a Core proxy request, not a supervised child in a boot sequence; the Versions.installed/0 read in its init/1 delays only that one connection's upgrade."
  },
  %{
    analysis: "startup",
    file: "lib/vagus/api/listener.ex",
    title: "init/1 makes a synchronous supervisor call",
    detail:
      "Vagus.API.Listener.init/1 reaches DynamicSupervisor.start_child on a supervisor chosen at runtime. Every supervisor management call is a GenServer.call into the supervisor; start_child in particular does not return until the new child's init/1 has, so those inits now run inside this one, on the tree's startup path. A child that calls back into Vagus.API.Listener, or into anything not yet started, deadlocks the boot; terminate_child waits for the whole shutdown of the child.",
    reason:
      "Deliberate and off the start path: Listener.init/1 returns {:continue, :listen} and the Bandit start_child runs in handle_continue/2. The listener owns its Bandit child (restart: :temporary, see default_start/2 and the moduledoc) and retries the bind itself."
  },
  %{
    analysis: "startup",
    file: "lib/vagus/backup.ex",
    title: "init/1 waits on another process with no timeout",
    detail:
      "Vagus.Backup.bounded/1 has a `receive` with no `after`, and init/1 reaches it in its own process. The wait takes the exit of the process it waits on, so it ends if that process dies; while it lives and does not answer, the process is not started: its supervisor's start, and whoever called start_child, wait with it.",
    reason:
      "Backups.init/1 scans backup tars through Backup.bounded/1, which monitors a heap-capped child (max_heap_size with kill) reading a local file: the receive also takes the child's :DOWN, so it ends when the child returns, crashes or is killed for memory."
  },
  %{
    analysis: "mailbox",
    file: "lib/vagus/bounded_call.ex",
    title: "Task.async in library code links to an unknown caller",
    detail:
      "Vagus.BoundedCall.run/2 is a plain function, not a process callback, so the task it starts with Task.async is linked to whichever process called it. A caller that traps exits then receives the task's exit as an {:EXIT, pid, :normal} message that Task.await never consumes, and a crashing task takes the caller down with it.",
    reason:
      "Deliberate: its only callers are the watchdogs' own sequence/action tasks and the probe GenServers, none of which trap exits, and the link exists so a killed caller takes the inner call with it (see Vagus.BoundedCall moduledoc)."
  },
  %{
    analysis: "failure",
    file: "lib/vagus/core/event_pusher.ex",
    title: "Process.exit inside a GenServer callback",
    detail:
      "Vagus.Core.EventPusher.handle_info/2 sends an exit signal to a process it holds as a value from inside a callback. This is often deliberate — process-manager handoff, registry name-conflict resolution, an ownership watcher killing dependents — but killing a process imperatively bypasses the supervisor that started it, so it is worth confirming the target is meant to be torn down this way rather than stopped through its own protocol.",
    reason:
      "Deliberate: the :ready_timeout handler kills a connection it monitors that connected but never became ready; its :DOWN then runs the ordinary backoff and transport re-pick (see the comment at the call). The connection is not under a restarting supervisor."
  }
]
