# Dialyzer baseline for the first run on this codebase, scoped by
# {file, warning_type} with the root cause documented. `list_unused_filters:
# true` (in mix.exs) makes a stale entry fail the build, so this list can't
# silently rot. NO real defects were found — every entry traces to one of the
# roots below. Curate downward over time.
#
# ── (removed) Root 1: Mint's `{:local, path}` unix-socket typespec gap ────
# Mint < 1.11 typed `Mint.HTTP.connect/4`'s address as
# String.t()|:inet.ip_address(), omitting the `{:local, path}` unix-domain
# form Vagus uses for the balena-engine and Core api sockets. Dialyzer then
# decided those connect calls "never succeed" and cascaded
# no_return/pattern_match/unused_fun/call/invalid_contract through every
# consumer of a Docker/socket result (~30 {file, type} filters). Mint 1.11
# types `Mint.Types.address()` as `:inet.socket_address() | String.t()`,
# which includes `{:local, path}`, so the whole cascade is gone and its
# filters were removed. Re-baseline here only if a future dep change
# resurfaces it.
[

  # ── Root 2: intentional no-return / opaque-type nitpicks ────────────────
  # - backend/native + microvm: declared "not implemented" stubs that raise;
  #   dialyzer flags an always-raising fn as no_return vs its @spec.
  # - backend/host/nerves: reboot/poweroff route through Vagus.Host.Shutdown
  #   (returns :ok) since issue #39, so the old :no_return entry is gone;
  #   the pattern_match on the trailing `:ok` after the runtime call stays.
  # - ingress/ws_bridge + core/events: Mint.WebSocket / MapSet opaque-type
  #   pedantry (flush_pending IS called; the caller is only "unreachable"
  #   via the same Mint typing story). No behaviour issue.
  # - take_mint_http1_leftover/1 (all three WS bridges): drains Mint.HTTP1's
  #   stranded parse buffer after Mint.WebSocket.new/4, since mint_web_socket
  #   takes over the transport post-upgrade and never revisits it — bytes
  #   bundled with the 101 response would otherwise be lost. Dialyzer marks it
  #   unused_fun because it already deems the new/4 success branch dead, same
  #   cascade as the pattern_match entries below.
  {"lib/vagus/addon/backend/microvm.ex", :no_return},
  {"lib/vagus/backend/host/nerves.ex", :pattern_match},
  {"lib/vagus/ingress/ws_bridge.ex", :pattern_match},
  {"lib/vagus/ingress/ws_bridge.ex", :unused_fun},
  # core_proxy/ws_bridge.ex:589 is the SAME Mint.WebSocket.new opaque-type
  # nitpick as ingress/ws_bridge.ex above — its `{:error, conn, _reason}`
  # branch reads as unreachable because Mint types `new/4` as only ever
  # succeeding. The Core-side WS leg (vagus-core-api-proxy) mirrors the
  # ingress bridge's Upstream shape; same typing story, same non-defect. The
  # REST module (`lib/vagus/api/core_proxy.ex`) is clean and needs no entry.
  {"lib/vagus/api/core_proxy/ws_bridge.ex", :pattern_match},
  {"lib/vagus/api/core_proxy/ws_bridge.ex", :unused_fun},
  # Same `Mint.WebSocket.new/4` story again in the EventPusher's socket-transport
  # WS client (core-socket-port80 A2), which mirrors that Upstream shape.
  {"lib/vagus/core/event_pusher/socket_connection.ex", :pattern_match},
  {"lib/vagus/core/event_pusher/socket_connection.ex", :unused_fun},
  {"lib/vagus/core/events.ex", :call_without_opaque},

  # ── Root 3: benign dead defensive checks ────────────────────────────────
  # Dialyzer proved a nil/default branch unreachable given the inferred types:
  # `user_options || %{}` in manager.ex (a defaulting `||` on a value already
  # typed as a map). Correct, defensive, not worth churning. (The analogous
  # ingress_proxy `query_string` dead-nil check was fixed at the source rather
  # than ignored — `in [nil, ""]` → `== ""`, since Plug guarantees a binary.)
  {"lib/vagus/addon/manager.ex", :guard_fail},
  # Two more of the same kind, formerly listed under the (removed) Mint root
  # but independent of it: router.ex's `first_upload(_params)` fallback
  # clause (Plug always hands a map), and host_stub.ex's `{:error, _}` arm on
  # `:inet.gethostname/0` (typed as only ever returning `{:ok, name}`).
  {"lib/vagus/api/router.ex", :pattern_match_cov},
  {"lib/vagus/backend/host/host_stub.ex", :pattern_match},

  # ── Root 5: Mix is absent from the PLT, so Mix tasks look nonexistent ───
  # `Mix.Task.run/1`, `Mix.raise/1`, `Mix.shell/0` and `Mix.Project.apps_paths/0`
  # all resolve at task-run time, but :mix is not an application dependency of
  # :vagus (and must not become one — it would ship in firmware), so the PLT
  # carries no info about it and every call reads as unknown_function.
  #
  # `plt_add_apps: [:mix]` does NOT fix this, verified rather than assumed:
  # dialyxir's `plt_add_apps/0` is `config[:plt_add_apps] || [] |> load_apps()`,
  # and `|>` binds tighter than `||`, so when the key IS set the apps are never
  # `Application.load/1`ed and never reach the PLT. (:ssh/:public_key/:crypto
  # are in the PLT only because deps load them anyway — that entry is inert.)
  # Confirmed with `:dialyzer.plt_info/1`: 0 mix beams, 43 ssh beams.
  {"lib/mix/tasks/vagus.probe.diff.ex", :callback_info_missing},
  {"lib/mix/tasks/vagus.probe.diff.ex", :unknown_function}

  # ── (removed) Root 4: mqttx type/callback info gaps ─────────────────────
  # The three mqttx-related filters (handler.ex :callback_info_missing,
  # subscriptions.ex :unknown_type/:unknown_function) became UNUSED once the
  # bluetooth work (vagus-bluetooth) added the bluez/typedstruct deps and the
  # PLT was rebuilt fresh — `list_unused_filters: true` then fails the build
  # on the stale entries, exactly as designed. Re-baseline here if a future
  # dep change resurfaces them.
]
