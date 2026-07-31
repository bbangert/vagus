defmodule Vagus.API.CoreProxy.WSBridge do
  @moduledoc """
  The Core-API proxy's WebSocket leg — caller side
  (`.claude/plans/vagus-core-api-proxy/plan.md`, fact 8). Reached only via
  `Vagus.API.CoreProxy`'s `call_websocket/1`, after method + upgrade-header
  checks already ran — this module never sees a non-GET or non-upgrade
  request. Mirrors `Vagus.Ingress.WSBridge`'s two-linked-process shape (this
  module = the `WebSock` process Bandit already created for the caller leg,
  `#{inspect(__MODULE__)}.Upstream` = a linked `GenServer` owning the raw
  `Mint.WebSocket` connection to Core) as closely as the different handshake
  allows — see that module's moduledoc for the shared design rationale
  (why two processes, why raw `Mint.WebSocket` and not `fresh`, why
  `trap_exit`).

  ## The one thing that's fundamentally different: THIS module runs the auth

  Every other route family resolves a caller's identity from a header
  before any handler code runs (`Vagus.API.Auth`). Fact 1 puts
  `/core/websocket` et al in `no_security_check` — there is no header check
  at all before the upgrade. Fact 8 is explicit that the proxy runs Core's
  OWN auth handshake against the caller itself, over the socket, after the
  upgrade has already completed:

  1. `init/1` pushes `{"type":"auth_required","ha_version":V}` (`V` =
     `Vagus.Core.Versions.installed/0`, `nil` → JSON `null` — this only
     happens pre-first-boot; a real device always has an installed Core by
     the time anything calls this route) and arms a deadline
     (`Vagus.API.CoreProxy.ws_auth_timeout_ms/0`, shared with `Upstream`'s
     own Core-side deadline per fact 8's "10s for both").
  2. The caller's first frame is expected to be a JSON object carrying
     `access_token` **or** `api_password` (`decode_caller_message/1`) —
     fact 8's exact wording is `msg.get("access_token") or
     msg.get("api_password")`, with **no check on a `"type"` field at all**,
     so this deliberately does not require `"type":"auth"` the way the
     moduledoc example message happens to have one.
  3. The token is checked exactly like the REST leg's `_check_access`
     (`Vagus.API.CoreProxy.check_access/1` — same resolve-in-`Registry`-and-
     require-`homeassistant_api` predicate, reused rather than
     reimplemented so the two legs can't drift on what "authorized" means).
     Success → `auth_ok` is pushed immediately and `Upstream` is started
     **only now** — an unauthenticated or wrongly-scoped caller never causes
     a dial to Core at all. Failure (bad token, no token field, non-JSON,
     a binary frame, or the deadline firing first) → `auth_invalid` then a
     normal close, no per-attempt logging (same RingLogger-ring discipline
     `Vagus.API.CoreProxy`'s own moduledoc documents for the REST leg — an
     unauthenticated caller can repeat this at will).

  ## `auth_ok` is sent before Core is known to be reachable at all

  Fact 8's wording is "on success `auth_ok`... **then** open a connection to
  Core's WS API" — literally in that order. So if `Upstream.start_link/1`
  itself fails (Core refuses the TCP connect outright), or if `Upstream`
  later can't complete ITS OWN handshake with Core (timeout, `auth_invalid`
  from Core), the caller has already been told `auth_ok` — the tunnel then
  simply closes with 1011, the same "can't relay any further, not
  necessarily the caller's fault" code `Vagus.Ingress.WSBridge` uses for its
  own abnormal-loss paths. This mirrors what any authenticate-then-tunnel
  proxy does: authentication and tunnel-availability are different
  questions, and upstream conflates them in exactly this order, not the
  other way round.

  ## Once past `:awaiting_auth`, relaying is unconditional cast-and-forget

  `handle_in/2` in the `:relaying` phase casts every frame to `Upstream`
  regardless of whether CORE's own handshake has completed yet —
  `Upstream` is the one that queues (see its moduledoc's "ready = WS-upgraded
  AND Core-auth'd" section, the literal extension of
  `Vagus.Ingress.WSBridge.Upstream`'s own pending-buffer shape the plan
  calls for). This module has no separate "connecting" state of its own to
  track: from the caller's point of view, once its own `auth_ok` has been
  sent, every frame it sends just goes to `Upstream`, on the same terms as
  `Vagus.Ingress.WSBridge.handle_in/2`.

  ## Heartbeat (fact 8's `heartbeat=30`)

  A 30s repeating `Process.send_after/3` timer, armed in `init/1`, pushes a
  `:ping` control frame to the caller on every tick — unlike
  `Vagus.Ingress.WSBridge`'s deliberate "pings never cross the bridge"
  design (that bridge relies on `WebSock`/Bandit auto-answering, since
  upstream's OWN heartbeat there is answered by the add-on, not synthesized
  by the bridge), fact 8 explicitly documents `heartbeat=30` as this proxy's
  own keepalive obligation to the caller — so it's synthesized here, one
  independent timer per leg (this module pings the caller; `Upstream` pings
  Core on its own connection), not relayed either direction.

  ## Close-code propagation

  Identical shape to `Vagus.Ingress.WSBridge`: `Upstream` sends this process
  `{:relay, op, data}` for data frames and `{:upstream_close, code, reason}`
  for any terminal event (Core's own close frame, a transport error, a
  failed Core-side handshake — all mapped to 1011 by `Upstream` the same way
  `Vagus.Ingress.WSBridge.Upstream` maps its own abnormal losses), which this
  module's `handle_info/2` turns into `{:stop, :normal, {code, reason},
  state}` so Bandit sends that exact code to the caller. `terminate/2` tears
  `Upstream` down the same way (`GenServer.stop/3`, not a raw exit, so its
  own `terminate/2` — a best-effort close frame to Core — actually runs).
  """

  @behaviour WebSock

  alias Vagus.API.CoreProxy
  alias Vagus.API.CoreProxy.WSBridge.Upstream
  alias Vagus.Core.Versions

  @heartbeat_interval_ms 30_000

  @typedoc "State carried across every `WebSock` callback for the caller leg."
  @type state :: %{
          phase: :awaiting_auth | :relaying,
          upstream: pid() | nil,
          ha_version: String.t() | nil,
          closing?: boolean()
        }

  @impl WebSock
  @doc """
  Starts in `:awaiting_auth`: pushes `auth_required` immediately, arms the
  shared handshake deadline (`CoreProxy.ws_auth_timeout_ms/0`) and the 30s
  heartbeat. `Process.flag(:trap_exit, true)` runs even though `Upstream`
  doesn't exist yet — it will, by the time `:awaiting_auth` ends, and
  arming it up front (same as `Vagus.Ingress.WSBridge.init/1`) means there is
  never a window where a link to `Upstream` could kill this process
  uncleanly.
  """
  def init(_args) do
    Process.flag(:trap_exit, true)

    ha_version = Versions.installed()
    Process.send_after(self(), :auth_deadline, CoreProxy.ws_auth_timeout_ms())
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)

    state = %{phase: :awaiting_auth, upstream: nil, ha_version: ha_version, closing?: false}

    {:push, {:text, encode(%{"type" => "auth_required", "ha_version" => ha_version})}, state}
  end

  @impl WebSock
  @doc """
  `:awaiting_auth`: a text frame is parsed as JSON and checked for
  `access_token`/`api_password` (fact 8 — no `"type"` requirement, see
  moduledoc); anything else (a binary frame, non-JSON, a JSON non-object, no
  token field at all) takes the same `auth_invalid` + close path as a bad
  token. `:relaying`: every frame — text or binary — is cast to `Upstream`
  unconditionally; see moduledoc for why this module doesn't itself track
  whether Core's side of the handshake has completed yet.
  """
  def handle_in({data, opcode: :text}, %{phase: :awaiting_auth} = state) do
    case decode_caller_token(data) do
      {:ok, token} -> authenticate(token, state)
      :error -> auth_invalid_and_close(state)
    end
  end

  def handle_in({_data, opcode: :binary}, %{phase: :awaiting_auth} = state) do
    auth_invalid_and_close(state)
  end

  def handle_in({data, opcode: op}, %{phase: :relaying, upstream: pid} = state) do
    GenServer.cast(pid, {:frame, op, data})
    {:ok, state}
  end

  @impl WebSock
  @doc "Ping/pong from the caller: no-op, same reasoning as `Vagus.Ingress.WSBridge.handle_control/2` — `WebSock`/Bandit already auto-answered before this callback ran."
  def handle_control(_frame, state), do: {:ok, state}

  @impl WebSock
  @doc """
  `:auth_deadline` fires once, 10s (default) after `init/1` — a no-op if
  the caller already authenticated by then. `:heartbeat` repeats every 30s
  (fact 8) for the life of the connection, pushing a `:ping` control frame;
  `closing?` guards the tick after this process has already told Bandit to
  stop (same defensive no-op `Vagus.Ingress.WSBridge`'s own `closing?` guard
  serves — Bandit still delivers messages for a short window after a
  `:stop` return). `{:relay, ...}`/`{:upstream_close, ...}`/`{:EXIT, ...}`
  are byte-for-byte `Vagus.Ingress.WSBridge`'s own clauses — see that
  module's moduledoc for the full close-code-propagation argument, which
  applies here unchanged since `Upstream` produces the identical message
  shapes.
  """
  def handle_info(:auth_deadline, %{phase: :awaiting_auth} = state) do
    auth_invalid_and_close(state)
  end

  def handle_info(:auth_deadline, state), do: {:ok, state}

  def handle_info(:heartbeat, %{closing?: true} = state), do: {:ok, state}

  def handle_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
    {:push, {:ping, ""}, state}
  end

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
  Fires for every termination path. Identical mechanism to
  `Vagus.Ingress.WSBridge.terminate/2`: `GenServer.stop/3` (not a raw exit)
  so `Upstream.terminate/2`'s own best-effort close-frame-to-Core actually
  runs; the `try/catch` guards the TOCTOU race against `Upstream` having
  already exited on its own (e.g. after already sending
  `{:upstream_close, ...}`).
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

  ## Internals

  # Fact 8: `msg.get("access_token") or msg.get("api_password")` — no
  # `"type"` field is ever checked. `{:ok, %{} = msg}` requires the decoded
  # JSON to be an object (a JSON array/string/number has no field to read at
  # all); a non-binary value for either key (a stray number/bool in a
  # malformed message) is treated the same as absent, since `check_access/1`
  # below expects a string to look up.
  defp decode_caller_token(data) do
    with {:ok, %{} = msg} <- Jason.decode(data),
         token when is_binary(token) <-
           Map.get(msg, "access_token") || Map.get(msg, "api_password") do
      {:ok, token}
    else
      _not_a_usable_token -> :error
    end
  end

  defp authenticate(token, state) do
    case CoreProxy.check_access(token) do
      :ok -> start_relaying(state)
      {:error, :unauthorized} -> auth_invalid_and_close(state)
    end
  end

  # `auth_ok` is pushed regardless of whether `Upstream.start_link/1`
  # succeeds — see moduledoc's "`auth_ok` is sent before Core is known to be
  # reachable at all". A synchronous dial failure (Core's TCP connect
  # refused outright) uses the 5-tuple `{:stop, reason, close_detail,
  # messages, state}` shape so the `auth_ok` frame is still sent before the
  # close, exactly like the success path's caller-visible behavior up to
  # that point — the difference only becomes visible once Core proves
  # unreachable.
  defp start_relaying(state) do
    auth_ok = {:text, encode(%{"type" => "auth_ok", "ha_version" => state.ha_version})}

    case Upstream.start_link(%{parent: self()}) do
      {:ok, pid} ->
        {:push, auth_ok, %{state | phase: :relaying, upstream: pid}}

      {:error, _reason} ->
        {:stop, {:error, :upstream_connect_failed}, {1011, ""}, [auth_ok],
         %{state | phase: :relaying, closing?: true}}
    end
  end

  # Fact 8: on any auth failure, `{"type":"auth_invalid","message":"Invalid
  # access"}` then a close — no per-attempt logging (same RingLogger
  # discipline `Vagus.API.CoreProxy`'s own moduledoc documents: an
  # unauthenticated caller can repeat this at will, so nothing here logs per
  # attempt). 1000 (normal closure): an auth rejection is this proxy
  # behaving exactly as designed, not an error condition to flag with a
  # non-1000 code.
  defp auth_invalid_and_close(state) do
    message = {:text, encode(%{"type" => "auth_invalid", "message" => "Invalid access"})}
    {:stop, :normal, {1000, ""}, [message], %{state | closing?: true}}
  end

  defp encode(map), do: Jason.encode!(map)
end

defmodule Vagus.API.CoreProxy.WSBridge.Upstream do
  @moduledoc """
  The Core-API proxy's WebSocket leg — Core side ("B" in
  `Vagus.API.CoreProxy.WSBridge`'s moduledoc). A `GenServer` owning a raw
  `Mint.WebSocket` connection to Core's `/api/websocket`, started and linked
  from `WSBridge.start_relaying/1` **only after** the caller's own auth has
  already succeeded — an unauthenticated or wrongly-scoped caller never
  causes this module to exist at all, let alone dial Core.

  Structurally this is `Vagus.Ingress.WSBridge.Upstream` with one extra
  phase inserted between "WS-upgraded" and "ready to relay": Core runs its
  OWN auth handshake (fact 8's `_websocket_client`) as ordinary WS text
  frames sent AFTER the WebSocket upgrade itself completes, not as HTTP
  headers on the upgrade request — so `Mint.WebSocket.upgrade/5` here is
  called with an empty header list, and the credential is a JSON message
  exchanged post-upgrade instead.

  ## The three states, tracked as two booleans

    * `upgraded?` — Core's 101 response has arrived and
      `Mint.WebSocket.new/4` has run; frames can now be decoded. Mirrors
      `Vagus.Ingress.WSBridge.Upstream`'s own field exactly.
    * `auth_sent?` — this process has replied to Core's `auth_required`
      with `{"type":"auth","access_token":T}` (`T` from the existing
      `:core_proxy_access_token_fun` seam,
      `Vagus.API.CoreProxy.default_access_token/0` by default — the same
      credential the REST leg's `core_access_token/0` resolves, reused
      rather than re-derived) and is now waiting for Core's `auth_ok`.
    * `ha_ready?` — Core replied `auth_ok`. This is the actual "ready to
      relay" gate: `upgraded?` alone isn't enough, because Core's own
      handshake frames must be consumed here and never relayed to the
      caller (fact 8) — only once `ha_ready?` flips does `handle_frames/2`
      start turning Core's text/binary frames into `{:relay, op, data}`
      messages to `WSBridge`, and only then does `flush_pending/1` release
      whatever the caller already sent.

  A single deadline (`Vagus.API.CoreProxy.ws_auth_timeout_ms/0`, the same
  config value `WSBridge` uses for the caller-side wait — fact 8: "10s for
  both") covers connect-through-`ha_ready?` as one window; if `ha_ready?`
  is still `false` when it fires, this is treated exactly like any other
  Core-side handshake failure — the caller has typically already seen
  `auth_ok` by then (see `WSBridge`'s moduledoc), so from here on the only
  correct action is closing both legs, same as a transport error would.

  ## Pending caller frames

  `WSBridge.handle_in/2` casts every caller frame here unconditionally once
  the caller itself is past `:awaiting_auth` (see that module's moduledoc) —
  including frames that arrive before `ha_ready?`. `handle_cast/2` buffers
  those in `pending` (newest-first, flushed in order once `ha_ready?`
  flips) — the literal extension of `Vagus.Ingress.WSBridge.Upstream`'s own
  pending-buffer idiom the plan calls for, just gated on `ha_ready?` instead
  of `upgraded?` alone. Unlike that module's own W3 hardening, this buffer
  has no size/count cap. This is a DEFERRED FOLLOW-UP, not a permanent
  design decision — `Vagus.Ingress.WSBridge.Upstream` only gained its W3
  cap (`:pending_max_bytes`/`:pending_max_frames`) as a post-day-one review
  finding, not at first ship, and this leg's caller is already an
  authenticated add-on with `homeassistant_api: true` rather than an
  anonymous browser, which narrows but does not eliminate the exposure (an
  authorized-but-compromised or misbehaving add-on can still flood the
  pre-`ha_ready?` window, bounded only by the shared ~10s auth deadline). A
  future hardening pass should add the same size/frame cap here; no cap
  code exists yet.

  ## Heartbeat (fact 8's `heartbeat=30`)

  A 30s repeating timer sends Core a `:ping` WS frame directly on this
  connection (once `upgraded?`) — the independent-per-leg keepalive
  `WSBridge`'s own moduledoc describes; Core's replies (`:pong`) are
  consumed here and never forwarded, same as `Vagus.Ingress.WSBridge.
  Upstream`'s own ping/pong handling.

  ## Close-code propagation

  Every terminal path — Core's own close frame, a transport error, a failed
  Core-side handshake (bad JSON, an unexpected message where `auth_ok` was
  expected, the shared deadline firing) — sends `WSBridge`
  `{:upstream_close, 1011, ""}` (or, for Core's own explicit close frame,
  that frame's real code/reason) and stops `:normal`, exactly mirroring
  `Vagus.Ingress.WSBridge.Upstream`'s own "1006 is never sent on the wire,
  map abnormal loss to 1011" convention. `terminate/2` is `Vagus.Ingress.
  WSBridge.Upstream.terminate/2` unchanged: a best-effort `{:close, 1000,
  ""}` frame to Core before closing the Mint connection, for the paths
  where the CALLER side went away first (`WSBridge.terminate/2` stopping
  this `GenServer`).
  """

  use GenServer

  alias Vagus.API.CoreProxy

  @heartbeat_interval_ms 30_000
  @core_ws_path "/api/websocket"

  @typedoc "State for the Core-side Mint.WebSocket connection GenServer."
  @type state :: %{
          parent: pid(),
          conn: Mint.HTTP.t(),
          ref: reference(),
          status: Mint.Types.status() | nil,
          resp_headers: Mint.Types.headers(),
          websocket: Mint.WebSocket.t() | nil,
          upgraded?: boolean(),
          auth_sent?: boolean(),
          ha_ready?: boolean(),
          # Newest-first (prepended on cast, reversed on flush) — same
          # convention as `Vagus.Ingress.WSBridge.Upstream`'s own `pending`.
          pending: [{WebSock.data_opcode(), binary()}]
        }

  @spec start_link(%{required(:parent) => pid()}) :: {:ok, pid()} | {:error, term()}
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl GenServer
  @doc """
  Connects to Core (`config :vagus, :core_base_url`, the same key the REST
  leg reads — Core is always local, never the `hassio` bridge, so unlike
  `Vagus.Ingress.WSBridge.Upstream` there is no `Vagus.Network.
  source_bind_opts/1` split to make here), then sends (but does not await)
  the WS upgrade request to `/api/websocket` — same "connect + send happen
  in `init/1`, the 101 itself arrives asynchronously" structure as
  `Vagus.Ingress.WSBridge.Upstream.init/1`, and the same reason: blocking
  `init/1` on Core's 101 would block `WSBridge.init/1` in turn (a
  `GenServer.start_link/3` caller blocks until `init/1` returns), stalling
  the caller's own Bandit connection process while dialing.

  Either failure point (`Mint.HTTP.connect/4`, or `Mint.WebSocket.upgrade/5`
  after a successful connect) stops this `GenServer` immediately, which
  `WSBridge.start_relaying/1` sees as `Upstream.start_link/1` returning
  `{:error, reason}` — see that function's doc for how it maps to a 1011
  close after `auth_ok` has already gone to the caller.
  """
  def init(%{parent: parent}) do
    case connect_and_upgrade() do
      {:ok, conn, ref} ->
        Process.send_after(self(), :handshake_deadline, CoreProxy.ws_auth_timeout_ms())
        Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)

        {:ok,
         %{
           parent: parent,
           conn: conn,
           ref: ref,
           status: nil,
           resp_headers: [],
           websocket: nil,
           upgraded?: false,
           auth_sent?: false,
           ha_ready?: false,
           pending: []
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp connect_and_upgrade do
    uri = URI.parse(core_base_url())
    http_scheme = if uri.scheme == "https", do: :https, else: :http
    ws_scheme = if http_scheme == :https, do: :wss, else: :ws

    case Mint.HTTP.connect(http_scheme, uri.host, uri.port, mode: :active, protocols: [:http1]) do
      {:ok, conn} ->
        case Mint.WebSocket.upgrade(ws_scheme, conn, @core_ws_path, []) do
          {:ok, conn, ref} ->
            {:ok, conn, ref}

          {:error, conn, reason} ->
            Mint.HTTP.close(conn)
            {:error, {:upgrade_request_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:connect_failed, reason}}
    end
  end

  defp core_base_url, do: Application.get_env(:vagus, :core_base_url, "http://localhost:8123")

  ## Caller frames (cast from `WSBridge.handle_in/2`)

  @impl GenServer
  @doc """
  Buffered (see moduledoc's "Pending caller frames") until `ha_ready?`;
  sent immediately otherwise. A send failure is treated exactly like a
  decoded transport error from Core: notify `WSBridge` with the 1011-mapped
  abnormal-loss message and stop.
  """
  def handle_cast({:frame, op, data}, %{ha_ready?: false} = state) do
    {:noreply, %{state | pending: [{op, data} | state.pending]}}
  end

  def handle_cast({:frame, op, data}, %{ha_ready?: true} = state) do
    case do_send_frame(op, data, state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, state} ->
        send(state.parent, {:upstream_close, 1011, ""})
        {:stop, :normal, state}
    end
  end

  ## Timers

  @impl GenServer
  @doc """
  Covers every `handle_info/2` clause in this module (a single `@doc` is
  all a multi-clause function gets — see each clause's own inline comment
  for specifics beyond this summary):

    * `:handshake_deadline` — the shared deadline
      (`Vagus.API.CoreProxy.ws_auth_timeout_ms/0`); a no-op once
      `ha_ready?`, otherwise this connect-through-auth attempt is stalling
      (or Core will never answer) and gets the same 1011 close as any other
      abnormal-loss path.
    * `:heartbeat` — fact 8's `heartbeat=30`, Core-facing half: sends a
      `:ping` WS frame directly on this connection every 30s, once
      `upgraded?` (nothing to send a WS frame over before then — a no-op
      re-arm instead of an error).
    * Any other message — Mint's active-mode transport messages; one clause
      covers pre- and post-upgrade alike, same as
      `Vagus.Ingress.WSBridge.Upstream.handle_info/2`.
  """
  def handle_info(:handshake_deadline, %{ha_ready?: true} = state), do: {:noreply, state}

  def handle_info(:handshake_deadline, %{ha_ready?: false} = state) do
    send(state.parent, {:upstream_close, 1011, ""})
    {:stop, :normal, state}
  end

  def handle_info(:heartbeat, %{upgraded?: false} = state) do
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
    {:noreply, state}
  end

  def handle_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)

    case do_send_frame(:ping, "", state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, state} ->
        send(state.parent, {:upstream_close, 1011, ""})
        {:stop, :normal, state}
    end
  end

  ## Mint active-mode messages — one clause covers pre- and post-upgrade
  ## alike, same as `Vagus.Ingress.WSBridge.Upstream.handle_info/2`.

  def handle_info(msg, state) do
    case Mint.WebSocket.stream(state.conn, msg) do
      {:ok, conn, responses} ->
        process_responses(responses, %{state | conn: conn})

      {:error, conn, _reason, responses} ->
        case process_responses(responses, %{state | conn: conn}) do
          {:noreply, state} ->
            # No close frame among `responses` — a bare transport-level
            # loss, mapped to 1011 same as `Vagus.Ingress.WSBridge.
            # Upstream`'s identical comment explains (1006 is never sent on
            # the wire by any real implementation).
            send(state.parent, {:upstream_close, 1011, ""})
            {:stop, :normal, state}

          {:stop, :normal, state} ->
            # `process_responses/2` already sent its own `{:upstream_close,
            # ...}` (a close frame, or a handshake failure) — don't send a
            # second, contradictory one.
            {:stop, :normal, state}
        end

      :unknown ->
        {:noreply, state}
    end
  end

  defp process_responses([], state), do: {:noreply, state}

  defp process_responses([response | rest], state) do
    case process_response(response, state) do
      {:continue, state} -> process_responses(rest, state)
      {:stop, state} -> {:stop, :normal, state}
    end
  end

  defp process_response({:status, ref, status}, %{ref: ref} = state) do
    {:continue, %{state | status: status}}
  end

  defp process_response({:headers, ref, headers}, %{ref: ref} = state) do
    {:continue, %{state | resp_headers: headers}}
  end

  defp process_response({:done, ref}, %{ref: ref, upgraded?: false} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.resp_headers) do
      {:ok, conn, websocket} ->
        # Deliberately NOT flushed yet, unlike `Vagus.Ingress.WSBridge.
        # Upstream`'s own `:done` clause — `ha_ready?` (Core's own
        # `auth_ok`), not `upgraded?` alone, is the real "ready" gate here.
        # See moduledoc's "three states" section.
        {:continue, %{state | conn: conn, websocket: websocket, upgraded?: true}}

      {:error, conn, _reason} ->
        send(state.parent, {:upstream_close, 1011, ""})
        {:stop, %{state | conn: conn}}
    end
  end

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

  ## Decoded Core frames

  defp handle_frames([], state), do: {:continue, state}

  # Core's handshake, step 1: expect `{"type":"auth_required",...}`, reply
  # with the credential from the same `:core_proxy_access_token_fun` seam
  # the REST leg uses.
  defp handle_frames(
         [{:text, data} | rest],
         %{ha_ready?: false, auth_sent?: false} = state
       ) do
    case Jason.decode(data) do
      {:ok, %{"type" => "auth_required"}} ->
        case send_core_auth(state) do
          {:ok, state} ->
            handle_frames(rest, state)

          {:error, state} ->
            # Consistency/defense-in-depth with every other failure clause
            # in this module (otp review Medium finding): the exit link to
            # `WSBridge` would otherwise mask this send's absence (its
            # `trap_exit` + catch-all `{:EXIT, pid, _reason}` clause maps
            # any exit reason, including this one's `:normal`, to the same
            # 1011 close) — sending it explicitly stops this path depending
            # on that plumbing.
            send(state.parent, {:upstream_close, 1011, ""})
            {:stop, state}
        end

      _unexpected ->
        send(state.parent, {:upstream_close, 1011, ""})
        {:stop, state}
    end
  end

  # Core's handshake, step 2: expect `{"type":"auth_ok",...}` — anything
  # else (including a well-formed `auth_invalid`) fails the handshake the
  # same way. Flushes whatever the caller already sent before any further
  # frame in this same batch is processed.
  defp handle_frames(
         [{:text, data} | rest],
         %{ha_ready?: false, auth_sent?: true} = state
       ) do
    case Jason.decode(data) do
      {:ok, %{"type" => "auth_ok"}} ->
        case flush_pending(%{state | ha_ready?: true}) do
          {:continue, state} -> handle_frames(rest, state)
          {:stop, state} -> {:stop, state}
        end

      _not_auth_ok ->
        send(state.parent, {:upstream_close, 1011, ""})
        {:stop, state}
    end
  end

  defp handle_frames([{:text, data} | rest], %{ha_ready?: true} = state) do
    send(state.parent, {:relay, :text, data})
    handle_frames(rest, state)
  end

  defp handle_frames([{:binary, data} | rest], %{ha_ready?: true} = state) do
    send(state.parent, {:relay, :binary, data})
    handle_frames(rest, state)
  end

  # Core's handshake is text-only JSON (fact 8) — a binary frame before
  # `ha_ready?` is a protocol violation, treated like any other handshake
  # failure rather than silently ignored.
  defp handle_frames([{:binary, _data} | _rest], %{ha_ready?: false} = state) do
    send(state.parent, {:upstream_close, 1011, ""})
    {:stop, state}
  end

  defp handle_frames([{:ping, data} | rest], state) do
    case do_send_frame(:pong, data, state) do
      {:ok, state} -> handle_frames(rest, state)
      {:error, state} -> {:stop, state}
    end
  end

  defp handle_frames([{:pong, _data} | rest], state), do: handle_frames(rest, state)

  defp handle_frames([{:close, code, reason} | _rest], state) do
    send(state.parent, {:upstream_close, code || 1000, reason || ""})
    # RFC6455§7.1.5: echo a close frame back before closing the transport —
    # best-effort, same as `Vagus.Ingress.WSBridge.Upstream.ack_close/2`.
    state = ack_close(state, code || 1000)
    Mint.HTTP.close(state.conn)
    {:stop, state}
  end

  defp send_core_auth(state) do
    fun =
      Application.get_env(
        :vagus,
        :core_proxy_access_token_fun,
        &CoreProxy.default_access_token/0
      )

    case fun.() do
      {:ok, token} ->
        payload = Jason.encode!(%{"type" => "auth", "access_token" => token})

        case do_send_frame(:text, payload, state) do
          {:ok, state} -> {:ok, %{state | auth_sent?: true}}
          {:error, state} -> {:error, state}
        end

      {:error, _reason} ->
        {:error, state}
    end
  end

  defp ack_close(state, code) do
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

  # Flushes frames buffered while `ha_ready?` was still false, in send
  # order (`pending` is newest-first — see moduledoc). Reuses the same
  # `{:continue, state} | {:stop, state}` protocol as `process_response/2`.
  defp flush_pending(%{pending: pending} = state) do
    fresh_state = %{state | pending: []}

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
  Called when `WSBridge.terminate/2` stops this `GenServer` (the caller
  side going away first). Best-effort `{:close, 1000, ""}` to Core before
  closing the Mint connection — byte-for-byte `Vagus.Ingress.WSBridge.
  Upstream.terminate/2`.
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
