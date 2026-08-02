defmodule Vagus.Ingress.WSBridge do
  @moduledoc """
  The ingress WebSocket bridge — browser leg
  (`docs/contract-2026.7-m4b-ingress-watchdog.md` §B2.3, pinned design in
  `.claude/plans/vagus-m4-ingress-watchdog/research/proxy-approach.md` §2).
  Reached only via `Vagus.API.IngressProxy`'s `WebSockAdapter.upgrade/4`
  call, after the session cookie and target `{ip, port}` are already
  resolved — this module never touches auth or token resolution itself.

  ## Two linked processes, not one (research §2)

  Real Supervisor terminates the incoming WS and opens an independent
  *outgoing* WS client connection to the add-on, pumping both directions
  concurrently (§B2.3) — not a raw byte-for-byte tunnel. Emulating that
  with a single process is impossible: the browser leg is Bandit's own
  `WebSock` connection process (must implement the `WebSock` behaviour to
  exist at all), while the upstream leg needs an **active-mode** `Mint`
  connection continuously receiving container frames as messages — a
  fundamentally different control-flow shape. So, per research §2:

    * **A** = this module — the `WebSock` process Bandit already created for
      the browser leg (this *is* the per-connection process; there is no
      separate "start A" step, `init/1` below just runs inside it).
    * **B** = `#{inspect(__MODULE__)}.Upstream`, a plain `GenServer`
      **started and linked from `A`'s `init/1`**, owning the `Mint.WebSocket`
      connection to the add-on.

  `fresh` (vendored, used by `Vagus.Core.*`) was considered and rejected for
  **B**: its `gen_statem` auto-reconnects by default, which is wrong for a
  proxy leg (an orphaned upstream reconnecting silently, instead of the
  browser also seeing the drop, would violate close-code faithfulness) — see
  research §2's "Upstream" section for the full reasoning. Raw
  `Mint.WebSocket`, hand-rolled in the same style as `Vagus.Runtime.Docker`/
  `Vagus.Core.ApiSocket`, is used instead.

  ## Linking + trapping exits (why, not just how)

  `A` calls `Process.flag(:trap_exit, true)` before linking `B` so that an
  upstream crash arrives as an ordinary `{:EXIT, pid, reason}` **message** to
  `handle_info/2` instead of killing `A` (and, transitively, the whole
  Bandit connection) uncleanly. This is the only mechanism that lets a
  crashed upstream become a *clean, faithfully-coded* browser-side close
  (1011) rather than the browser just seeing the TCP connection vanish.

  ## Close-code propagation — all four paths

  1. **Upstream clean close** (add-on sends a real `{:close, code, reason}`
     frame): `B` decodes it, `send`s `A` `{:upstream_close, code, reason}`,
     closes its own Mint connection, stops `:normal`. `A`'s `handle_info/2`
     turns that into `{:stop, :normal, {code, reason}, state}` — Bandit
     (`deps/bandit/lib/bandit/websocket/connection.ex`'s
     `{:stop, :normal, code, websock_state} -> do_stop(code, :normal, ...)`
     clause) sends **that exact code** to the browser instead of a default.
  2. **Upstream crash** (Mint transport error, or `B` dying outright before
     it could even send a message): `B`'s own transport-error handling
     reuses the *same* `{:upstream_close, 1011, ""}` message (§B2.3's
     "1006 is never sent on the wire" — an abnormal loss is mapped to 1011,
     not relayed as-is), so it flows through the identical path-1 code in
     `handle_info/2`. If `B` dies without ever sending anything (e.g. an
     unhandled raise), `A`'s trapped `{:EXIT, pid, reason}` catches it and
     returns `{:stop, {:error, :upstream_down}, {1011, ""}, state}` directly.
  3. **Browser closes**: Bandit's own `Connection.handle_frame/3` intercepts
     the browser's close frame *before* it ever reaches `handle_in/2` or
     `handle_control/2` — it calls `terminate(:remote, state)` directly.
     `terminate/2` (below) stops `B`, whose own `terminate/2` best-effort
     sends a `{:close, 1000, ""}` frame upstream before closing its socket —
     this is the propagation direction *opposite* paths 1/2 (browser → add-on).
  4. **Idle timeout**: the `:timeout` opt passed to `WebSockAdapter.upgrade/4`
     (see `Vagus.API.IngressProxy`) expires; Bandit's
     `Connection.handle_timeout/2` calls `terminate(:timeout, state)`
     directly (again bypassing `handle_in`/`handle_info`) and closes the
     browser socket itself (code `1002`, Bandit's own hardcoded choice for
     this case). `terminate/2` still stops `B` the same way as path 3.

  Paths 3 and 4 share one `terminate/2` implementation because *from this
  module's perspective* "the browser side is going away, tear down upstream"
  is the same action regardless of why Bandit decided to call it.

  ## Pings never cross the bridge — a deliberate §B2.3 deviation

  Upstream's real relay (`_websocket_forward`, §B2.3) forwards `PING`/`PONG`
  frames through like any other frame. This emulator does **not**: `WebSock`
  itself guarantees the web server auto-answers the browser's pings
  ("implementations SHOULD NOT send a pong … this MUST be automatically done
  by the web server", `deps/websock/lib/websock.ex`), so `handle_control/2`
  below is a no-op; separately, `B` answers the add-on's pings on its own
  Mint connection (`{:pong, data}` sent right back over the same socket,
  never forwarded to `A`). Each leg keepalives independently — simpler than
  relaying, and equivalent for liveness (the only thing a ping/pong loop is
  *for*): neither side can distinguish "the peer answered my ping itself"
  from "the peer's ping was relayed and something on the far end answered
  it". Research §2 states this explicitly: "the two ping/pong loops never
  cross the bridge, only data/close frames do."

  ## Memory discipline

  Every data frame is relayed one at a time — `handle_in/2` hands a single
  frame to `B` via a bounded `GenServer.call/3` (`:ingress_ws_handoff_timeout`,
  issue #37 — see below); `B` decodes/encodes a single frame at a time from
  `Mint`'s active-mode messages. Nothing is ever rebuffered beyond the frame
  currently in flight (except the small pre-upgrade `pending` list in `B`,
  bounded only by how much the browser sends before the add-on's 101
  arrives — a local network hop, expected to be at most a few frames).
  The 16 MiB cap (§B2.3's `max_msg_size`) is enforced independently by
  `websock`/Bandit on the browser leg (`max_frame_size` in
  `Vagus.API.IngressProxy`'s `WebSockAdapter.upgrade/4` call) and by
  `mint_web_socket`'s own frame assembly on the upstream leg.

  ## Steady-state backpressure (issue #37)

  `B`'s send path (`do_send_frame/3` → `Mint.WebSocket.stream_request_body/3`
  → `:gen_tcp.send`) blocks if the add-on's own socket buffer is full. A
  `cast` would let `A` keep accepting browser frames into `B`'s mailbox
  without bound while `B` sits blocked — the steady-state vector the W3
  pending cap doesn't cover (that cap only bounds the pre-upgrade window).
  `handle_in/2` calls instead: `B`'s `handle_call/3` replies only once the
  send returns, so `A`'s blocked call is what stops Bandit from reading the
  browser's socket for as long as the send is wedged — TCP backpressure to
  the browser instead of an unbounded mailbox. `B`'s own Mint socket
  `send_timeout` (default 5s, `send_timeout_ms` — see `Upstream`'s
  moduledoc) is what actually resolves a wedged send in the normal case,
  well before `A`'s own (larger, 10s default, `:ingress_ws_handoff_timeout`)
  call timeout would need to act as a backstop. Reverse-direction
  `{:relay, ...}` frames queue in `A`'s mailbox for at most one call's
  duration (normally µs; bounded by whichever timeout fires) — the bounded
  head-of-line tradeoff the issue explicitly accepts in exchange for a
  bounded mailbox.
  """

  @behaviour WebSock

  alias Vagus.Ingress.WSBridge.Upstream

  @typedoc "State carried across every `WebSock` callback for the browser leg."
  @type state :: %{upstream: pid() | nil, closing?: boolean()}

  @impl WebSock
  @doc """
  `state` here is the map `Vagus.API.IngressProxy` passed to
  `WebSockAdapter.upgrade/4`: `%{target: {ip, port}, path: path, protocols:
  protocols, headers: headers}`. `headers` (audit F1/B1) is
  `IngressProxy.build_request_headers/1`'s output — the same filtered
  header set (hop-by-hop stripped, auth/identity stripped, `X-Forwarded-For`
  appended) the plain-HTTP leg forwards, required here rather than optional
  because there is no other source for it: this module never sees the
  browser's original `conn`.

  Starts **and links** `B` (`Upstream`). `Process.flag(:trap_exit, true)`
  runs first so that link is a *message*-delivering link from the start —
  see the moduledoc's "Linking + trapping exits" section for why this
  matters (an upstream crash must not kill this process outright).

  If `Upstream.start_link/1` itself returns `{:error, _}` (the add-on's TCP
  connect or the initial upgrade-request send failed outright, before any
  linked process existed to crash later), this returns
  `{:stop, reason, close_detail, state}` directly from `init/1` — a valid
  `WebSock.handle_result` per its typespec (the same shape `handle_in/2` and
  `handle_info/2` may return), closing the browser side with 1011 without
  ever completing the upgrade to an *open* bridge.
  """
  def init(%{target: {ip, port}, path: path, protocols: protocols, headers: headers}) do
    Process.flag(:trap_exit, true)

    upstream_args = %{
      parent: self(),
      ip: ip,
      port: port,
      path: path,
      protocols: protocols,
      headers: headers
    }

    case Upstream.start_link(upstream_args) do
      {:ok, pid} ->
        {:ok, %{upstream: pid, closing?: false}}

      {:error, _reason} ->
        {:stop, {:error, :upstream_connect_failed}, {1011, "upstream connection failed"},
         %{upstream: nil, closing?: true}}
    end
  end

  @impl WebSock
  @doc """
  Every browser data frame is handed to `B` via a bounded `GenServer.call/3`
  (`handoff_timeout_ms/0`) — see moduledoc's "Steady-state backpressure"
  section for why this deliberately DOES block `handle_in/2` on the upstream
  send completing, rather than firing a fully async `cast`. A timeout closes
  with 1011 directly (`B` never got the chance to notify anyone); any other
  exit (`B` already stopped, normally or via a crash) is a no-op — the
  faithful close code is already on its way through the existing
  `{:upstream_close, ...}`/`{:EXIT, ...}` clauses in `handle_info/2` below,
  and stamping 1011 here would race it.
  """
  def handle_in({data, opcode: op}, %{upstream: pid} = state) do
    :ok = GenServer.call(pid, {:frame, op, data}, handoff_timeout_ms())
    {:ok, state}
  catch
    :exit, {:timeout, _} ->
      {:stop, :normal, {1011, ""}, %{state | closing?: true}}

    :exit, _upstream_died_mid_call ->
      {:ok, state}
  end

  @impl WebSock
  @doc """
  Ping/pong control frames from the browser: **no-op**. Per `WebSock`'s own
  contract the server (Bandit) has *already* auto-answered the ping before
  this callback ever runs — see the moduledoc's ping/pong section for why
  this deliberately never touches `B`.
  """
  def handle_control(_frame, state), do: {:ok, state}

  @impl WebSock
  @doc """
  `{:relay, op, data}` — a data frame `B` decoded from the add-on — becomes
  a `{:push, {op, data}, state}`, the `WebSock` shape for "send this frame
  to the browser, no state change beyond what's given".

  `{:upstream_close, code, reason}` is the *faithful* close-code path
  (upstream paths 1 and 2 in the moduledoc): `{:stop, :normal, {code,
  reason}, state}` tells Bandit's `Connection.handle_continutation/3` to
  hit its `{:stop, :normal, code, websock_state} -> do_stop(code, :normal,
  ...)` clause, which sends *that* code to the browser rather than the
  default 1000. `closing?` guards against acting twice: `B` always sends
  its own `{:upstream_close, ...}` message before it stops (`:normal`),
  which also produces a linked `{:EXIT, pid, :normal}` message shortly
  after — once `closing?` is `true` we've already told Bandit to stop, so
  any further message about the same upstream is a no-op (Bandit still
  routes messages to this process for a short window after a `:stop` return
  while the connection finishes closing — see `deps/bandit/lib/bandit/
  websocket/connection.ex`'s `do_stop/4`, which sets `state: :closing`
  rather than tearing the process down synchronously).

  `{:EXIT, pid, _reason}` for `B`'s own pid, when we *haven't* already seen
  an `{:upstream_close, ...}` (i.e. `B` died without a chance to notify us —
  an unhandled crash, not a graceful stop) is upstream-crash path 2: close
  the browser with 1011.
  """
  def handle_info({:relay, op, data}, state) do
    {:push, {op, data}, state}
  end

  def handle_info({:upstream_close, _code, _reason}, %{closing?: true} = state) do
    {:ok, state}
  end

  def handle_info({:upstream_close, code, reason}, %{closing?: false} = state) do
    {:stop, :normal, {code, reason}, %{state | closing?: true}}
  end

  def handle_info({:EXIT, pid, _reason}, %{upstream: pid, closing?: false} = state) do
    {:stop, {:error, :upstream_down}, {1011, ""}, %{state | closing?: true}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:ok, state}

  def handle_info(_other, state), do: {:ok, state}

  @impl WebSock
  @doc """
  Fires for **every** termination path (browser close, idle timeout, an
  upstream-driven `{:stop, ...}` we returned ourselves, or a Bandit-level
  error) — `reason` distinguishes them (`:remote` = browser closed,
  `:timeout` = idle timeout, `:normal`/`{:error, _}` = one of our own
  `handle_info/2` stops), but the cleanup is identical in every case: make
  sure `B` is not left running. `GenServer.stop/3` (not a raw
  `Process.exit/2`) is used deliberately so `B`'s own `terminate/2` callback
  — which best-effort sends a `{:close, 1000, ""}` frame upstream before
  closing the Mint socket — actually runs; a bare exit signal to a
  non-trapping GenServer would kill it without ever calling that callback.

  The `try/catch` guards the unavoidable TOCTOU race between the
  `Process.alive?/1` check and the `GenServer.stop/3` call (`B` may have
  already exited on its own, e.g. after already sending
  `{:upstream_close, ...}` for path 1/2) — `GenServer.stop/3` against an
  already-dead pid exits `:noproc`, which would otherwise crash this
  `terminate/2` itself.
  """
  def terminate(_reason, %{upstream: pid}) when is_pid(pid) do
    try do
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # issue #37: bound on the `GenServer.call/3` `handle_in/2` makes to `B` for
  # every relayed frame — see moduledoc's "Steady-state backpressure". No
  # args seam on this module (unlike `Upstream`'s `start_link/1` map), so an
  # app env, same precedent as `:ingress_target_fun`.
  defp handoff_timeout_ms, do: Application.get_env(:vagus, :ingress_ws_handoff_timeout, 10_000)
end

defmodule Vagus.Ingress.WSBridge.Upstream do
  @moduledoc """
  The ingress WebSocket bridge — upstream leg ("B" in
  `Vagus.Ingress.WSBridge`'s moduledoc). A `GenServer` owning a
  `Mint.WebSocket` connection to the add-on, started and linked from `A`'s
  (`WSBridge`'s) `init/1`. Runs the Mint connection in `:active` mode
  (`Mint.HTTP.connect(..., mode: :active)`) so container frames arrive as
  ordinary process messages rather than requiring an explicit `recv` loop.

  ## Connect + upgrade-request happen in `init/1`; the 101 response doesn't

  `Mint.HTTP.connect/4` (a real TCP connect, but to a container on the same
  docker bridge network — fast) and `Mint.WebSocket.upgrade/5` (which only
  *sends* the upgrade request, `Mint.HTTP.request/5` under the hood) both
  run synchronously inside `init/1`: both either succeed immediately or
  return an error tuple immediately, and `init/1` failing outright (`{:stop,
  reason}`) is exactly how `WSBridge.init/1` detects "the upstream never
  came up" and closes the browser with 1011 before ever reaching an *open*
  bridge state.

  What does **not** happen in `init/1` is waiting for the add-on's 101
  response — that depends on a network round-trip to a container that might
  be slow to accept (or never upgrade at all), and blocking `init/1` on it
  would block `WSBridge.init/1` in turn (a `GenServer.start_link/3` caller
  blocks until `init/1` returns), which would block the Bandit `WebSock`
  connection process from doing anything else — including timing out —
  while dialing. Instead `init/1` returns as soon as the request is *sent*,
  and the 101 (or any other server reply) arrives later as an ordinary
  active-mode message, handled in `handle_info/2` exactly like every other
  post-upgrade frame — `Mint.WebSocket.stream/2` is deliberately used for
  *all* messages (pre- and post-upgrade alike): its own moduledoc documents
  this exact "drop-in replacement for `Mint.HTTP.stream/2`" usage, and in
  practice it degrades to plain `Mint.HTTP.stream/2` automatically before
  `Mint.WebSocket.new/4` has run (that function is what first records this
  request ref as a websocket in the connection's private data), so a single
  `handle_info/2` clause serves both phases.

  ## Header forwarding (audit F1/B1)

  The upgrade request sent in `init/1` carries the exact same filtered
  header set the plain-HTTP leg forwards
  (`Vagus.API.IngressProxy.build_request_headers/1` — hop-by-hop strip,
  auth/identity strip, `X-Forwarded-For` append) plus
  `sec-websocket-protocol` appended separately (`protocol_headers/1`,
  driven by `protocols`, not `headers`). Before this fix the upgrade
  request carried *only* `sec-websocket-protocol` — no `Cookie`, no `Host`,
  nothing — which silently broke any add-on gating its own WS endpoint on
  the session cookie. `IngressProxy` builds `headers` from the browser's
  `conn` and hands it in via `WSBridge.init/1`'s state map; this module has
  no access to that `conn` and could not build the list itself.

  ## Buffering before the upgrade completes

  A browser frame can arrive (via `WSBridge.handle_in/2`'s call) before the
  add-on's 101 response does — the browser doesn't wait for our upstream
  handshake. Frames received while `upgraded?` is `false` are prepended to
  `pending` (a stalling browser flooding frames must not force an O(n²)
  `pending ++ [frame]` append on every call) and flushed, in reverse (i.e.
  back into send order), the moment `Mint.WebSocket.new/4` succeeds
  (`flush_pending/1`). This is the *only* rebuffering this module does;
  every other frame is relayed one at a time.

  ## `send_timeout` on the Mint socket (issue #37)

  `Mint.HTTP.connect/4`'s `transport_opts` carry `send_timeout` (default 5s,
  `send_timeout_ms`) and `send_timeout_close: true`. Without it, a wedged
  `:gen_tcp.send` (the add-on's socket buffer full) blocks forever — after
  `WSBridge`'s own handoff timeout gives up and closes the browser leg,
  `terminate/2`'s `GenServer.stop/3` can't be processed by a process stuck
  inside `handle_call/3`, so this `GenServer` would leak (blocked, holding a
  socket) indefinitely (a `:normal` exit signal doesn't kill a
  non-trapping process). A timed-out send instead surfaces as
  `stream_request_body`'s ordinary `{:error, conn, reason}` tuple, flowing
  through the same 1011-close path as any other transport error — this is
  the normal way a wedged send resolves, expected to fire well before
  `WSBridge`'s own (larger) call timeout would need to act as a backstop.

  ## Pending cap + upgrade deadline (review W3)

  Nothing otherwise bounds how long the add-on can take to complete its own
  WS handshake, nor how much the browser sends meanwhile — a stalling/
  malicious add-on that accepts TCP but never upgrades, paired with a
  flooding browser, would let `pending` grow without limit and OOM a 1GB
  device well before any idle timeout notices. Two independent guards:

    * `:pending_max_bytes` (default 4 MiB) / `:pending_max_frames` (default
      `256`) cap `pending`'s total size; a call that would exceed either
      closes the browser side with 1011 (`{:upstream_close, 1011, ""}` to
      the parent) and stops, same as any other abnormal-loss path.
    * `:upgrade_deadline_ms` (default `10_000`), armed once in `init/1`: if
      the 101 still hasn't arrived by the time it fires, same 1011 close —
      a no-op if the upgrade already completed.

  Both are injectable via `start_link/1`'s args map for tests; on-device
  they always run at their defaults.
  """

  use GenServer

  # review W3 defaults — see moduledoc's "Pending cap + upgrade deadline".
  @default_pending_max_bytes 4 * 1024 * 1024
  @default_pending_max_frames 256
  @default_upgrade_deadline_ms 10_000
  # issue #37 default — see moduledoc's "`send_timeout` on the Mint socket".
  @default_send_timeout_ms 5_000

  @typedoc "State for the upstream Mint.WebSocket connection GenServer."
  @type state :: %{
          parent: pid(),
          conn: Mint.HTTP.t(),
          ref: reference(),
          status: Mint.Types.status() | nil,
          resp_headers: Mint.Types.headers(),
          websocket: Mint.WebSocket.t() | nil,
          upgraded?: boolean(),
          # Newest-first (prepended on each call, reversed on flush) — see
          # moduledoc.
          pending: [{WebSock.data_opcode(), binary()}],
          pending_frames: non_neg_integer(),
          pending_bytes: non_neg_integer(),
          pending_max_bytes: pos_integer(),
          pending_max_frames: pos_integer()
        }

  @spec start_link(%{
          required(:parent) => pid(),
          required(:ip) => :inet.hostname() | :inet.ip_address(),
          required(:port) => :inet.port_number(),
          required(:path) => String.t(),
          required(:protocols) => [String.t()],
          required(:headers) => Mint.Types.headers(),
          optional(:pending_max_bytes) => pos_integer(),
          optional(:pending_max_frames) => pos_integer(),
          optional(:upgrade_deadline_ms) => pos_integer(),
          optional(:send_timeout_ms) => pos_integer()
        }) :: {:ok, pid()} | {:error, term()}
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl GenServer
  @doc """
  Connects, then sends (but does not await) the WebSocket upgrade request.
  See the moduledoc's "Connect + upgrade-request happen in `init/1`" section
  for why the 101 itself is awaited asynchronously instead.

  Either failure point (`Mint.HTTP.connect/4` erroring, or
  `Mint.WebSocket.upgrade/5` erroring after a successful connect) stops this
  `GenServer` immediately (`{:stop, reason}`) — `WSBridge.start_link/1`'s
  caller sees that as `Upstream.start_link/1` returning `{:error, reason}`
  and maps it to a 1011 browser close (see `WSBridge.init/1`). A connection
  opened but then abandoned because the upgrade request itself failed to
  send is explicitly closed here (`Mint.HTTP.close/1`) before stopping —
  since `init/1` failing means this GenServer never really started,
  `terminate/2` below is *not* called for either of these two paths (OTP
  only calls a `GenServer`'s `terminate/2` once its `init/1` has already
  succeeded), so this is the only chance to release that socket.

  Arms `:upgrade_deadline_ms` (review W3) here, on the success path only —
  a connection that never got this far has nothing to time out.
  """
  def init(
        %{parent: parent, ip: ip, port: port, path: path, protocols: protocols, headers: headers} =
          args
      ) do
    send_timeout_ms = Map.get(args, :send_timeout_ms, @default_send_timeout_ms)

    connect_opts = [
      mode: :active,
      protocols: [:http1],
      # Same source-address rule as the plain-HTTP leg: a bridge add-on that
      # filters on client IP expects the supervisor anchor .2, not the bridge
      # gateway .1 — but a `host_network: true` add-on is reached on loopback,
      # where binding .2 makes it see a non-local peer and refuse. Keyed on
      # the destination, so both hold (`Vagus.Network.source_bind_opts/1`).
      # `send_timeout`/`send_timeout_close` (issue #37) are appended rather
      # than folded into that helper — they're unconditional, not
      # destination-dependent.
      transport_opts:
        Vagus.Network.source_bind_opts(ip) ++
          [send_timeout: send_timeout_ms, send_timeout_close: true]
    ]

    case Mint.HTTP.connect(:http, ip, port, connect_opts) do
      {:error, reason} ->
        {:stop, {:connect_failed, reason}}

      {:ok, conn} ->
        # audit F1/B1: forward the browser's own filtered headers (cookie,
        # host, x-ingress-path, x-forwarded-*, authorization, ...) verbatim
        # on the upgrade request, same as the plain-HTTP leg — plus
        # `sec-websocket-protocol`, which `headers` never carries (excluded
        # by `IngressProxy.strip_request_headers/1`'s `sec-websocket-`
        # prefix strip) since it's negotiated separately via `protocols`.
        # Order doesn't matter to Mint/HTTP1, but appending keeps the
        # general set first and the protocol negotiation header visually
        # distinct.
        upgrade_headers = headers ++ protocol_headers(protocols)

        case Mint.WebSocket.upgrade(:ws, conn, path, upgrade_headers) do
          {:ok, conn, ref} ->
            upgrade_deadline_ms =
              Map.get(args, :upgrade_deadline_ms, @default_upgrade_deadline_ms)

            Process.send_after(self(), :upgrade_deadline, upgrade_deadline_ms)

            {:ok,
             %{
               parent: parent,
               conn: conn,
               ref: ref,
               status: nil,
               resp_headers: [],
               websocket: nil,
               upgraded?: false,
               pending: [],
               pending_frames: 0,
               pending_bytes: 0,
               pending_max_bytes: Map.get(args, :pending_max_bytes, @default_pending_max_bytes),
               pending_max_frames: Map.get(args, :pending_max_frames, @default_pending_max_frames)
             }}

          {:error, conn, reason} ->
            Mint.HTTP.close(conn)
            {:stop, {:upgrade_request_failed, reason}}
        end
    end
  end

  defp protocol_headers([]), do: []

  defp protocol_headers(protocols),
    do: [{"sec-websocket-protocol", Enum.join(protocols, ", ")}]

  @impl GenServer
  @doc """
  A frame called in from `A` (`WSBridge.handle_in/2`, issue #37 — see
  `Vagus.Ingress.WSBridge`'s moduledoc for why a bounded call replaced the
  original cast). Buffered, in order, until the upgrade completes; sent
  immediately otherwise. A send failure (`do_send_frame/3` returning
  `{:error, state}`) is treated exactly like a decoded transport error from
  the add-on: notify the parent with the 1011-mapped abnormal-loss message
  and stop — see the moduledoc's `Vagus.Ingress.WSBridge` "close-code
  propagation" path 2. Every clause replies `:ok` before stopping on the
  error/overflow paths too: the frame was genuinely accepted here, so `A`
  must not see a spurious `:exit` for it — the real close still arrives via
  `{:upstream_close, ...}`, same as it always has.

  Overflowing `:pending_max_bytes`/`:pending_max_frames` (review W3) is
  folded into the same 1011-close path — from the browser's perspective a
  buffer-overflow disconnect and a transport-error disconnect are
  indistinguishable, and shouldn't need to be.
  """
  def handle_call({:frame, op, data}, _from, %{upgraded?: false} = state) do
    case buffer_frame(op, data, state) do
      {:ok, state} ->
        {:reply, :ok, state}

      :overflow ->
        send(state.parent, {:upstream_close, 1011, ""})
        {:stop, :normal, :ok, state}
    end
  end

  def handle_call({:frame, op, data}, _from, %{upgraded?: true} = state) do
    case do_send_frame(op, data, state) do
      {:ok, state} ->
        {:reply, :ok, state}

      {:error, state} ->
        send(state.parent, {:upstream_close, 1011, ""})
        {:stop, :normal, :ok, state}
    end
  end

  # review W3: fires `:upgrade_deadline_ms` after `init/1` sent the upgrade
  # request. If the add-on's 101 still hasn't arrived (`upgraded?` still
  # `false`), its WS handshake is stalling (or will never complete) — closed
  # exactly like any other abnormal-loss path. A no-op once already
  # upgraded: a legitimately slow-but-eventually-successful handshake has
  # nothing further to fear from this timer having been armed.
  @impl GenServer
  def handle_info(:upgrade_deadline, %{upgraded?: true} = state), do: {:noreply, state}

  def handle_info(:upgrade_deadline, %{upgraded?: false} = state) do
    send(state.parent, {:upstream_close, 1011, ""})
    {:stop, :normal, state}
  end

  @impl GenServer
  @doc """
  Every active-mode message (the add-on's TCP data, and its `tcp_closed`/
  `tcp_error` notifications alike) is handed to `Mint.WebSocket.stream/2` —
  see the moduledoc for why this single clause covers both the pre- and
  post-upgrade phases. `:unknown` means the message wasn't ours at all (not
  expected in practice, since this process owns exactly one socket, but
  `Mint.WebSocket.stream/2`'s documented return includes it) and is ignored.
  """
  def handle_info(msg, state) do
    case Mint.WebSocket.stream(state.conn, msg) do
      {:ok, conn, responses} ->
        process_responses(responses, %{state | conn: conn})

      {:error, conn, _reason, responses} ->
        case process_responses(responses, %{state | conn: conn}) do
          {:noreply, state} ->
            # No close frame was among `responses` — this is a bare
            # transport-level loss (the add-on's TCP connection dropped
            # without a WS close handshake). §B2.3: 1006 (the code that
            # means exactly this) is never actually sent on the wire by
            # any real WebSocket implementation, so — like `do_send_frame/3`
            # failures above — this is mapped to 1011 rather than relayed
            # as a literal (nonexistent-on-the-wire) 1006.
            send(state.parent, {:upstream_close, 1011, ""})
            {:stop, :normal, state}

          {:stop, :normal, state} ->
            # `responses` already contained a `{:close, ...}` frame (or a
            # decode error), which `process_responses/2` already turned
            # into its own `{:upstream_close, ...}` message — don't send a
            # second, contradictory one.
            {:stop, :normal, state}
        end

      :unknown ->
        {:noreply, state}
    end
  end

  # `process_responses/2` and the `handle_frames/2` it calls into share one
  # tiny internal protocol: `{:continue, state}` (keep going / stay open)
  # or `{:stop, state}` (something terminal happened — a close frame, a
  # decode error, a send failure while flushing pending frames). The
  # `handle_info/2` clauses above and `flush_pending/1` below both fold
  # that into the real `GenServer` return shape.
  defp process_responses([], state), do: {:noreply, state}

  defp process_responses([response | rest], state) do
    case process_response(response, state) do
      {:continue, state} -> process_responses(rest, state)
      {:stop, state} -> {:stop, :normal, state}
    end
  end

  # Pre-upgrade HTTP/1 handshake responses (`Mint.WebSocket.stream/2`
  # degrades to plain `Mint.HTTP.stream/2` until `Mint.WebSocket.new/4` has
  # run once) — accumulate status/headers, then attempt the actual upgrade
  # on `:done`.
  defp process_response({:status, ref, status}, %{ref: ref} = state) do
    {:continue, %{state | status: status}}
  end

  defp process_response({:headers, ref, headers}, %{ref: ref} = state) do
    {:continue, %{state | resp_headers: headers}}
  end

  defp process_response({:done, ref}, %{ref: ref, upgraded?: false} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.resp_headers) do
      {:ok, conn, websocket} ->
        flush_pending(%{state | conn: conn, websocket: websocket, upgraded?: true})

      {:error, conn, _reason} ->
        send(state.parent, {:upstream_close, 1011, ""})
        {:stop, %{state | conn: conn}}
    end
  end

  # Post-upgrade: raw bytes needing WS frame decoding.
  defp process_response({:data, ref, data}, %{ref: ref, upgraded?: true} = state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        handle_frames(frames, %{state | websocket: websocket})

      {:error, websocket, _reason} ->
        send(state.parent, {:upstream_close, 1011, ""})
        {:stop, %{state | websocket: websocket}}
    end
  end

  defp process_response(_other, state), do: {:continue, state}

  # Decoded WS frames from the add-on, applied one at a time (in order) —
  # see `Vagus.Ingress.WSBridge`'s moduledoc for the text/binary → `:relay`,
  # ping/pong (never crosses), and close-code-propagation semantics of each
  # clause.
  defp handle_frames([], state), do: {:continue, state}

  defp handle_frames([{:text, data} | rest], state) do
    send(state.parent, {:relay, :text, data})
    handle_frames(rest, state)
  end

  defp handle_frames([{:binary, data} | rest], state) do
    send(state.parent, {:relay, :binary, data})
    handle_frames(rest, state)
  end

  # This leg's own keepalive: answer the add-on's ping on the same Mint
  # connection, never forwarded to `A`.
  defp handle_frames([{:ping, data} | rest], state) do
    case do_send_frame(:pong, data, state) do
      {:ok, state} ->
        handle_frames(rest, state)

      {:error, state} ->
        send(state.parent, {:upstream_close, 1011, ""})
        {:stop, state}
    end
  end

  defp handle_frames([{:pong, _data} | rest], state), do: handle_frames(rest, state)

  defp handle_frames([{:close, code, reason} | _rest], state) do
    send(state.parent, {:upstream_close, code || 1000, reason || ""})
    # RFC6455§7.1.5: the receiving end of a close handshake should echo a
    # close frame back before closing the transport if it hasn't already
    # sent one — best-effort only, `ack_close/2` swallows any failure since
    # the parent has already been notified either way.
    state = ack_close(state, code || 1000)
    Mint.HTTP.close(state.conn)
    {:stop, state}
  end

  defp ack_close(state, code) do
    # `Mint.WebSocket.Frame`'s `is_friendly_frame/1` guard requires a
    # `{:close, code, reason}` triple's `reason` to be a binary — `nil` (our
    # `frame` type's own documented "no reason" value, per
    # `Mint.WebSocket.frame/0`'s typespec) fails that guard with a
    # `FunctionClauseError`, so `""` is used here instead.
    case Mint.WebSocket.encode(state.websocket, {:close, code, ""}) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} -> %{state | conn: conn, websocket: websocket}
          {:error, conn, _reason} -> %{state | conn: conn, websocket: websocket}
        end

      {:error, websocket, _reason} ->
        %{state | websocket: websocket}
    end
  end

  # Flushes frames buffered while the upgrade was still pending, in send
  # order — `pending` is stored newest-first (`buffer_frame/3` prepends), so
  # this reverses once here rather than paying an O(n²) append per call.
  # Reuses the same `{:continue, state} | {:stop, state}` protocol as
  # `process_response/2` so `process_responses/2`'s `:done` clause can
  # return its result directly.
  defp flush_pending(%{pending: pending} = state) do
    fresh_state = %{state | pending: [], pending_frames: 0, pending_bytes: 0}

    result =
      pending
      |> Enum.reverse()
      |> Enum.reduce_while({:ok, fresh_state}, fn {op, data}, {:ok, state} ->
        case do_send_frame(op, data, state) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, state} -> {:halt, {:error, state}}
        end
      end)

    case result do
      {:ok, state} ->
        {:continue, state}

      {:error, state} ->
        send(state.parent, {:upstream_close, 1011, ""})
        {:stop, state}
    end
  end

  # review W3: caps the pre-upgrade `pending` buffer by both frame count and
  # total byte size — an unbounded buffer here would let a stalling/
  # malicious add-on (accepts TCP, never completes its WS handshake) paired
  # with a flooding browser OOM a 1GB device well before any idle timeout
  # notices (see moduledoc). Checked against the cumulative total *including*
  # the frame being buffered, so the cap is a hard ceiling, not a
  # one-frame-late one.
  defp buffer_frame(op, data, state) do
    frames = state.pending_frames + 1
    bytes = state.pending_bytes + byte_size(data)

    if frames > state.pending_max_frames or bytes > state.pending_max_bytes do
      :overflow
    else
      {:ok,
       %{
         state
         | pending: [{op, data} | state.pending],
           pending_frames: frames,
           pending_bytes: bytes
       }}
    end
  end

  # `Mint.WebSocket.encode/2` failures return `{:error, websocket, reason}`
  # (no `conn`); `Mint.WebSocket.stream_request_body/3` failures return
  # `{:error, conn, reason}` (no `websocket`) — the two error shapes aren't
  # interchangeable, hence the nested (rather than `with`-chained) case.
  defp do_send_frame(op, data, state) do
    case Mint.WebSocket.encode(state.websocket, {op, data}) do
      {:ok, websocket, encoded} ->
        state = %{state | websocket: websocket}

        case Mint.WebSocket.stream_request_body(state.conn, state.ref, encoded) do
          {:ok, conn} -> {:ok, %{state | conn: conn}}
          {:error, conn, _reason} -> {:error, %{state | conn: conn}}
        end

      {:error, websocket, _reason} ->
        {:error, %{state | websocket: websocket}}
    end
  end

  @impl GenServer
  @doc """
  Called when `A` (`WSBridge.terminate/2`) stops this `GenServer` — i.e.
  close-code-propagation paths 3 (browser closed) and 4 (idle timeout), the
  two directions where the *browser* side going away must be relayed
  *upstream*. Best-effort sends a `{:close, 1000, ""}` frame to the add-on
  before closing the Mint connection; `1000` (normal closure) is correct
  here regardless of *why* the browser side closed, since from the add-on's
  perspective this always looks like "the ingress client hung up cleanly" —
  none of Bandit's own close-reason nuance (`:remote` vs `:timeout`) has a
  meaningful add-on-facing equivalent worth threading through.

  Not called for either of `init/1`'s own failure paths (see that
  function's doc) or for the two paths where this process stops *itself*
  (`handle_call`/`handle_info` stopping `:normal` after already notifying the
  parent and closing the Mint connection directly) —
  in the latter two cases `terminate/2` *would* still run (its `init/1` did
  succeed), but the connection is already closed by then, so the encode/
  send below simply fails harmlessly against a dead socket.
  """
  def terminate(_reason, %{upgraded?: true, conn: conn, ref: ref, websocket: websocket}) do
    case Mint.WebSocket.encode(websocket, {:close, 1000, ""}) do
      {:ok, _websocket, data} -> Mint.WebSocket.stream_request_body(conn, ref, data)
      _error -> :ok
    end

    Mint.HTTP.close(conn)
    :ok
  end

  def terminate(_reason, %{conn: conn}) do
    Mint.HTTP.close(conn)
    :ok
  end
end
