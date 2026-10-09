# Reviewed argus findings: each is a validated false positive or deliberate
# design, with its reason. Checked by scripts/argus_baseline.exs (see its
# header for the workflow); prefer fixing a finding over adding it here.
[
  %{
    analysis: "shutdown",
    file: "lib/vagus/api/core_proxy/ws_bridge.ex",
    title: "terminate/2 does work a supervisor shutdown will skip",
    at_label: "a supervisor shutdown skips this",
    detail:
      "Vagus.API.CoreProxy.WSBridge.Upstream does not trap exits, so a GenServer shutdown from its supervisor kills it outright and terminate/2 never runs. Vagus.API.CoreProxy.WSBridge.Upstream.terminate/2 calls Mint.HTTP.close/1, which the effect model cannot classify — so this cannot say WHAT is skipped, only that terminate/2 does more than log and none of it will happen on the normal stop path. If that call releases a lease, closes a session or flushes a buffer, it is silently not happening in production.",
    reason:
      "terminate/2 only sends a courtesy WebSocket close frame (Upstream) or closes the Mint connection; the socket is owned by this process, so the VM closes it when the process is killed. Skipping it on a shutdown only drops the close frame — the peer sees the TCP close."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    at_label: "supervision tree defined here",
    detail:
      "Vagus.Core.Watchdog registers with Vagus.Runtime.Events when it starts, and Vagus.Runtime.Events keeps a monitor or link for it. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Runtime.Events restarts, its init/1 starts it afresh without what Vagus.Core.Watchdog put there, and Vagus.Core.Watchdog, which is not restarted with it, never registers again. When Vagus.Core.Watchdog restarts, it registers a second time beside what its old process left.",
    reason:
      "Fixed rather than accepted: the subscriber monitors the server it subscribed to and re-subscribes to the restarted, name-registered server (Vagus.Resubscribe, see its tests). argus does not model re-registering from a handler (restart_state.dl: \"a's re-registering on a schedule of its own\" is not asked), so it still reports the init/1 subscribe."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    at_label: "supervision tree defined here",
    detail:
      "Vagus.Core.Watchdog.Probe registers with Vagus.Core.TokenStore when it starts, and Vagus.Core.TokenStore keeps it in its state. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Core.TokenStore restarts, its init/1 starts it afresh without what Vagus.Core.Watchdog.Probe put there, and Vagus.Core.Watchdog.Probe, which is not restarted with it, never registers again. When Vagus.Core.Watchdog.Probe restarts, it registers a second time beside what its old process left.",
    reason:
      "Fixed rather than accepted: the subscriber monitors the server it subscribed to and re-subscribes to the restarted, name-registered server (Vagus.Resubscribe, see its tests). argus does not model re-registering from a handler (restart_state.dl: \"a's re-registering on a schedule of its own\" is not asked), so it still reports the init/1 subscribe."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    at_label: "supervision tree defined here",
    detail:
      "Vagus.OS.Updater.Checker registers with Vagus.Core.EventPusher when it starts, and Vagus.Core.EventPusher keeps it in its state. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Core.EventPusher restarts, its init/1 starts it afresh without what Vagus.OS.Updater.Checker put there, and Vagus.OS.Updater.Checker, which is not restarted with it, never registers again. When Vagus.OS.Updater.Checker restarts, it registers a second time beside what its old process left.",
    reason:
      "Per-use: the Checker pushes an update-available event per check; EventPusher queues it for Core and holds no standing registration of the Checker, so the next check simply pushes again."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    at_label: "supervision tree defined here",
    detail:
      "Vagus.Provisioner registers with Vagus.Core.HttpConfig when it starts, and Vagus.Core.HttpConfig keeps it in its state. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Core.HttpConfig restarts, its init/1 starts it afresh without what Vagus.Provisioner put there, and Vagus.Provisioner, which is not restarted with it, never registers again. When Vagus.Provisioner restarts, it registers a second time beside what its old process left.",
    reason:
      "Per-use write, not a standing registration: HttpConfig caches Core's reported port/ssl, and by design (Vagus.Core.Supervisor moduledoc) a restart drops back to defaults and is re-pulled at the next Core start/healthy transition."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    at_label: "supervision tree defined here",
    detail:
      "Vagus.Provisioner registers with Vagus.Core.Versions when it starts, and Vagus.Core.Versions keeps it in its state. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Core.Versions restarts, its init/1 starts it afresh without what Vagus.Provisioner put there, and Vagus.Provisioner, which is not restarted with it, never registers again. When Vagus.Provisioner restarts, it registers a second time beside what its old process left.",
    reason:
      "Vagus.Core.Versions persists the installed version to disk and re-reads it in init/1; its only in-memory state is a 24h latest-version cache that re-fetches on demand."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    at_label: "supervision tree defined here",
    detail:
      "Vagus.Provisioner registers with Vagus.Jobs when it starts, and Vagus.Jobs keeps it in its state. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Jobs restarts, its init/1 starts it afresh without what Vagus.Provisioner put there, and Vagus.Provisioner, which is not restarted with it, never registers again. When Vagus.Provisioner restarts, it registers a second time beside what its old process left.",
    reason:
      "Per-use: the Provisioner's one-shot first-boot job record. Jobs are ephemeral progress records for API polling; losing one on a Jobs restart is accepted (nothing re-reads it to drive behaviour)."
  },
  %{
    analysis: "mailbox",
    file: "lib/vagus/bounded_call.ex",
    title: "Task.yield on a linked task cannot see it crash",
    at_label: "linked task started here",
    detail:
      "Vagus.BoundedCall.run/2 starts a task with Task.async (or Task.Supervisor.async), which links it to the caller, and collects it with Task.yield. yield's {:exit, reason} result is documented for a crashed task, but the link delivers the crash to this process first: unless it traps exits, the branch handling a failed task never runs — the caller is already down.",
    reason:
      "Deliberate: run/2 catches the function's raise/throw/exit inside the task (capture/1) and returns it as a value, so the task never crashes over the link; the {:exit, _} branch only covers an outside kill. The link is kept so a killed caller (the watchdog deadline failsafe) takes the inner call with it. See test/vagus/bounded_call_test.exs."
  },
  %{
    analysis: "shutdown",
    file: "lib/vagus/core/event_pusher/socket_connection.ex",
    title: "terminate/2 does work a supervisor shutdown will skip",
    at_label: "a supervisor shutdown skips this",
    detail:
      "Vagus.Core.EventPusher.SocketConnection does not trap exits, so a GenServer shutdown from its supervisor kills it outright and terminate/2 never runs. Vagus.Core.EventPusher.SocketConnection.terminate/2 calls Mint.HTTP.close/1, which the effect model cannot classify — so this cannot say WHAT is skipped, only that terminate/2 does more than log and none of it will happen on the normal stop path. If that call releases a lease, closes a session or flushes a buffer, it is silently not happening in production.",
    reason:
      "terminate/2 only sends a courtesy WebSocket close frame (Upstream) or closes the Mint connection; the socket is owned by this process, so the VM closes it when the process is killed. Skipping it on a shutdown only drops the close frame — the peer sees the TCP close."
  },
  %{
    analysis: "shutdown",
    file: "lib/vagus/ingress/ws_bridge.ex",
    title: "terminate/2 does work a supervisor shutdown will skip",
    at_label: "a supervisor shutdown skips this",
    detail:
      "Vagus.Ingress.WSBridge.Upstream does not trap exits, so a GenServer shutdown from its supervisor kills it outright and terminate/2 never runs. Vagus.Ingress.WSBridge.Upstream.terminate/2 calls Mint.HTTP.close/1, which the effect model cannot classify — so this cannot say WHAT is skipped, only that terminate/2 does more than log and none of it will happen on the normal stop path. If that call releases a lease, closes a session or flushes a buffer, it is silently not happening in production.",
    reason:
      "terminate/2 only sends a courtesy WebSocket close frame (Upstream) or closes the Mint connection; the socket is owned by this process, so the VM closes it when the process is killed. Skipping it on a shutdown only drops the close frame — the peer sees the TCP close."
  },
  %{
    analysis: "startup",
    file: "lib/vagus/ssh_access.ex",
    title: "Distributed operation in init/1",
    at_label: "remote operation during init/1",
    detail:
      "Vagus.SSHAccess.init/1 performs open_file during init, while the supervisor's start sequence waits. A slow or partitioned peer stalls local startup.",
    reason:
      "False positive: :dets.open_file opens a local file (the SSH key store), not a distributed table, and any open failure degrades the server (accessors answer {:error, :unavailable}) instead of failing its start."
  },
  %{
    analysis: "startup",
    file: "lib/vagus/api/core_proxy/ws_bridge.ex",
    title: "init/1 blocks on a synchronous call",
    at_label: "this init blocks the start sequence",
    detail:
      "Vagus.API.CoreProxy.WSBridge.init/1 makes a synchronous call to Vagus.Core.Versions (directly or transitively) on every init. init runs inside the supervisor's start sequence, so the tree's startup stalls for as long as Vagus.Core.Versions takes to answer. Argus could not establish where Vagus.Core.Versions runs relative to this init — its child spec is built at runtime — so this is a note, not a diagnosis; a proven startup deadlock is reported separately as an error.",
    reason:
      "WSBridge is a per-connection WebSock handler started by a Core proxy request, not a supervised child in a boot sequence; the Versions.installed/0 read in its init/1 delays only that one connection's upgrade."
  },
  %{
    analysis: "startup",
    file: "lib/vagus/api/listener.ex",
    title: "init/1 makes a synchronous supervisor call",
    at_label: "this call blocks init until the supervisor answers",
    detail:
      "Vagus.API.Listener.init/1 reaches DynamicSupervisor.start_child on a supervisor chosen at runtime. Every supervisor management call is a GenServer.call into the supervisor; start_child in particular does not return until the new child's init/1 has, so those inits now run inside this one, on the tree's startup path. A child that calls back into Vagus.API.Listener, or into anything not yet started, deadlocks the boot; terminate_child waits for the whole shutdown of the child.",
    reason:
      "Deliberate and off the start path: Listener.init/1 returns {:continue, :listen} and the Bandit start_child runs in handle_continue/2. The listener owns its Bandit child (restart: :temporary, see default_start/2 and the moduledoc) and retries the bind itself."
  },
  %{
    analysis: "mailbox",
    file: "lib/vagus/bounded_call.ex",
    title: "Task.async in library code links to an unknown caller",
    at_label: "linked task started in library code",
    detail:
      "Vagus.BoundedCall.run/2 is a plain function, not a process callback, so the task it starts with Task.async is linked to whichever process called it. A caller that traps exits then receives the task's exit as an {:EXIT, pid, :normal} message that Task.await never consumes, and a crashing task takes the caller down with it.",
    reason:
      "Deliberate: its only callers are the watchdogs' own sequence/action tasks and the probe GenServers, none of which trap exits, and the link exists so a killed caller takes the inner call with it (see Vagus.BoundedCall moduledoc)."
  },
  %{
    analysis: "failure",
    file: "lib/vagus/core/event_pusher.ex",
    title: "Process.exit inside a GenServer callback",
    at_label: "sends an exit signal from a callback",
    detail:
      "Vagus.Core.EventPusher.handle_info/2 sends an exit signal to a process it holds as a value from inside a callback. This is often deliberate — process-manager handoff, registry name-conflict resolution, an ownership watcher killing dependents — but killing a process imperatively bypasses the supervisor that started it, so it is worth confirming the target is meant to be torn down this way rather than stopped through its own protocol.",
    reason:
      "Deliberate: the :ready_timeout handler kills a connection it monitors that connected but never became ready; its :DOWN then runs the ordinary backoff and transport re-pick (see the comment at the call). The connection is not under a restarting supervisor."
  },
  %{
    analysis: "coupling",
    file: "lib/vagus/application.ex",
    title: "Coupled children under one_for_one",
    at_label: "supervision tree defined here",
    detail:
      "Vagus.App.Orchestrator registers with Vagus.Core.EventPusher when it starts, and Vagus.Core.EventPusher keeps it in its state. Both are children of the one_for_one supervisor Vagus.Application, which restarts either alone. When Vagus.Core.EventPusher restarts, its init/1 starts it afresh without what Vagus.App.Orchestrator put there, and Vagus.App.Orchestrator, which is not restarted with it, never registers again. When Vagus.App.Orchestrator restarts, it registers a second time beside what its old process left.",
    reason:
      "A one-shot push, not a registration: boot pushes supervisor_update startup: complete once into Vagus.Core.EventPusher's bounded, drop-oldest queue, which is lossy by design; a restart losing it is a dropped event like any other, and Core's hassio coordinator still refreshes on its own schedule."
  },
  %{
    analysis: "failure",
    file: "lib/vagus/app/server.ex",
    title: "Call made bare where other call sites catch its error",
    at_label: "called outside any try",
    detail:
      "Vagus.App.Server.port_free/2 calls Registry.lookup/2 with no try around it, in its own body or on some way into it; 4 of the 5 call sites in this program catch its error. No rule says the callee's failure must be taken; the program's own sites say so, and this one disagrees — the shape of a site written without the convention in mind, or one the convention grew around.",
    reason:
      "Deliberate: the other sites (Vagus.App, Vagus.DNS, Vagus.Ingress, Vagus.Runtime.Events) are outside the app tree and must outlive a restarting directory. An app process is under the directory's :rest_for_one supervisor and linked to its partition, so a lookup that raises there means the directory is gone and this process is about to be restarted with it; crashing is the intended outcome, and catching would only start a step against a directory that no longer exists."
  }
]
