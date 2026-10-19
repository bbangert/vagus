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
    file: "lib/vagus/api/core_proxy/ws_bridge.ex",
    title: "init/1 blocks on a synchronous call",
    at_label: "this init blocks the start sequence",
    detail:
      "Vagus.API.CoreProxy.WSBridge.init/1 makes a synchronous call to Vagus.Core.Versions (directly or transitively) on every init. init runs inside the supervisor's start sequence, so the tree's startup stalls for as long as Vagus.Core.Versions takes to answer. Argus could not establish where Vagus.Core.Versions runs relative to this init — its child spec is built at runtime — so this is a note, not a diagnosis; a proven startup deadlock is reported separately as an error.",
    reason:
      "WSBridge is a per-connection WebSock handler started by a Core proxy request, not a supervised child in a boot sequence; the Versions.installed/0 read in its init/1 delays only that one connection's upgrade."
  },
  %{
    analysis: "mailbox",
    file: "lib/vagus/bounded_call.ex",
    title: "Task.async in library code links to an unknown caller",
    at_label: "linked task started in library code",
    detail:
      "Vagus.BoundedCall.run/2 is a plain function, not a process callback, so the task it starts with Task.async is linked to whichever process called it. A caller that traps exits then receives the task's exit as an {:EXIT, pid, :normal} message that collecting the task (Task.await, Task.yield) never consumes, and a crashing task takes the caller down with it.",
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
    analysis: "shutdown",
    file: "lib/vagus/api/core_proxy/ws_bridge.ex",
    title: "Children started under another tree outlive their owner",
    at_label: "start_child onto a supervisor in another tree",
    detail:
      "Vagus.API.CoreProxy.WSBridge.start_task/1 starts children under Vagus.API.CoreProxy.TaskSupervisor, a supervisor Vagus.API.CoreProxy.WSBridge does not sit under. Their lifetime follows Vagus.API.CoreProxy.TaskSupervisor's tree, not Vagus.API.CoreProxy.WSBridge's: when Vagus.API.CoreProxy.WSBridge's tree shuts down they keep running — reconnecting, logging, calling into applications that have already stopped — and Vagus.API.CoreProxy.WSBridge's terminate/2 does not stop them.",
    reason:
      "Deliberate: a supervisor/api call's task must outlive its socket, because its handler may be mid-backup when the caller times out or goes (WSBridge moduledoc; test \"a socket closed with calls pending leaves their tasks to finish\"). It does not outlive the application: Vagus.API.CoreProxy.TaskSupervisor is the child of Vagus.Supervisor started immediately before Vagus.API.Supervisor (Supervisor.which_children/1 on a host build: 15th and 16th), so at stop it is terminated right after the listener and before everything started ahead of it (the app tree, Jobs, Backups, the store). The tasks are :temporary and do not trap exits, so they die at that :shutdown. What stops before them is Vagus.Core.Supervisor and the children after it, exactly as for the listener's own HTTP handler processes; a call into one of those then exits and is caught in WSDispatch.run/4. max_children bounds how many can be left running."
  },
  %{
    analysis: "shutdown",
    file: "lib/vagus/api/router.ex",
    title: "Children started under another tree outlive their owner",
    at_label: "start_child onto a supervisor in another tree",
    detail:
      "Vagus.API.Router.start_job_task/2 starts children under Vagus.Jobs.TaskSupervisor, a supervisor Vagus.API.CoreProxy.WSBridge does not sit under. Their lifetime follows Vagus.Jobs.TaskSupervisor's tree, not Vagus.API.CoreProxy.WSBridge's: when Vagus.API.CoreProxy.WSBridge's tree shuts down they keep running — reconnecting, logging, calling into applications that have already stopped — and Vagus.API.CoreProxy.WSBridge's terminate/2 does not stop them.",
    reason:
      "Deliberate and unchanged: a `background: true` job has always been started under Vagus.Jobs.TaskSupervisor so that it outlives the request that asked for it, which has already been answered with the job id (comment above start_job_task/2). argus attributes it to WSBridge only because a supervisor/api call now reaches the router from the bridge's task; an HTTP request reaches the same line from a Bandit connection process, which argus does not model as an owner. The job's lifetime is the same either way: it ends when its work does, or when Vagus.Jobs.TaskSupervisor stops, which is after the listener and after the bridge's own task supervisor (it is started 6th, they 16th and 15th). max_children: 8 bounds it."
  },
  %{
    analysis: "shutdown",
    file: "lib/vagus/api/core_proxy/ws_bridge.ex",
    title: "Server terminates a process it still monitors",
    at_label: "the monitored process is terminated here",
    detail:
      "Vagus.API.CoreProxy.WSBridge monitors processes from its callbacks and also terminates them on purpose, without demonitoring first. The {:DOWN, ...} for a death this server caused is delivered like any other — into the clause written for crashes, which may restart, reconnect or log what was a deliberate stop.",
    reason:
      "False positive: the two are different processes. The only Process.monitor/1 in the bridge is on a dispatch task (dispatch/3), and the bridge never stops, exits or kills a task. The only process it terminates is Upstream (GenServer.stop/3 in terminate/2), which it links and does not monitor, and after terminate/2 no message is handled. The {:DOWN, ...} clause looks the monitor reference up among its dispatches, so any other DOWN falls through to {:ok, state} (test \"a result for a call this socket never made is dropped\")."
  }
]
