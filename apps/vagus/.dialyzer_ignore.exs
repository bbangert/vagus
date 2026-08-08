# Dialyzer baseline for the first run on this codebase, scoped by
# {file, warning_type} with the root cause documented. `list_unused_filters:
# true` (in mix.exs) makes a stale entry fail the build, so this list can't
# silently rot. NO real defects were found — every entry traces to one of two
# roots below. Curate downward over time.
#
# ── Root 1: Mint's `{:local, path}` unix-socket typespec gap ──────────────
# Mint.HTTP.connect/4 types `address` as String.t()|:inet.ip_address() and
# omits the `{:local, path}` unix-domain form that Mint supports at runtime.
# Vagus talks to the balena-engine control socket and Core's api socket that
# way (Vagus.Runtime.{Docker,Events}, Vagus.Core.ApiSocket). Dialyzer decides
# those connect calls "never succeed", infers the whole request chain as
# no_return, and cascades pattern_match/unused_fun through every consumer of a
# Docker/socket result. All device-proven; not defects.
[
  # invalid_contract: the @specs are correct, but since Dialyzer infers these
  # fns as no_return (connect "never succeeds"), it deems every returns-a-value
  # contract invalid. Same cascade root.
  {"lib/vagus/runtime/docker.ex", :no_return},
  {"lib/vagus/runtime/docker.ex", :call},
  {"lib/vagus/runtime/docker.ex", :unused_fun},
  {"lib/vagus/runtime/docker.ex", :invalid_contract},
  {"lib/vagus/runtime/events.ex", :no_return},
  {"lib/vagus/runtime/events.ex", :call},
  # (Vagus.Core.ApiSocket needs no entries: its connect address now comes
  # from `Vagus.Core.Transport.connect_args/1`, whose return type is the
  # general `Mint.Types.address()` rather than a literal `{:local, path}`, so
  # the cascade below never starts there.)
  # Runtime.Logs.Follow speaks to the engine socket the same {:local, path}
  # way (vagus-follow-logs): connect deemed "never succeeds" → the with-else
  # branches and request_logs read as dead → same cascade as events.ex.
  {"lib/vagus/runtime/logs/follow.ex", :call},
  {"lib/vagus/runtime/logs/follow.ex", :pattern_match},
  {"lib/vagus/runtime/logs/follow.ex", :unused_fun},
  # router.ex maybe_verbose_body/3 is only called from container_logs'
  # {:ok, raw} branch, which the same Mint story marks dead.
  {"lib/vagus/api/router.ex", :unused_fun},
  # Core.Lifecycle drives every op through Vagus.Runtime.Docker's unix-socket
  # client, so the same "connect never succeeds" inference marks all its
  # success branches dead (unused_fun for every helper past the first Docker
  # call, pattern_match on the ok-tuples, no_return on the op entrypoints).
  # Hermetic fake-engine tests + the device gate prove the behavior.
  {"lib/vagus/core/lifecycle.ex", :no_return},
  {"lib/vagus/core/lifecycle.ex", :pattern_match},
  {"lib/vagus/core/lifecycle.ex", :unused_fun},
  # Core.Boot's default_ping/0 wraps Docker.ping/0 — same cascade as
  # boot_starter.ex below.
  {"lib/vagus/core/boot.ex", :no_return},
  # Provisioner's default_ping/0 wraps Docker.ping/0 — same cascade as
  # boot.ex above (vagus-first-boot-provisioning, issue #40).
  {"lib/vagus/provisioner.ex", :no_return},
  {"lib/vagus/addon/boot_starter.ex", :no_return},
  # default_ensure_network's `{:ok, _id} <- Network.ensure()` — same cascade as
  # manager.ex:pattern_match below: the stubbed socket makes dialyzer infer the
  # success branch dead on host. Device-proven; not a defect.
  {"lib/vagus/addon/boot_starter.ex", :pattern_match},
  # ...and ensure_nat/0 (the supervisor-DNAT assert) is only called from inside
  # that same branch, so it inherits the cascade as unused_fun.
  {"lib/vagus/addon/boot_starter.ex", :unused_fun},
  {"lib/vagus/addon/backend/container.ex", :no_return},
  {"lib/vagus/addon/backend/container.ex", :pattern_match},
  {"lib/vagus/addon/manager.ex", :pattern_match},
  {"lib/vagus/addon/watchdog.ex", :pattern_match},
  {"lib/vagus/addon/watchdog/probe.ex", :pattern_match},
  # Core.Watchdog.Probe's default_running_check inspects the Core container
  # through the same unix-socket Docker client — its {:ok, %{"State" => ...}}
  # branch reads as dead under the Mint story (vagus-core-watchdog CW-P3-T1).
  {"lib/vagus/core/watchdog/probe.ex", :pattern_match},
  # Core.ConfigCheck (audit G3, phase 6) drives inspect_container +
  # exec_capture through the same unix-socket Docker client — its {:ok, _}
  # branches read as dead and every helper past the first Docker call as
  # unused, the identical cascade as lifecycle.ex above. Hermetic
  # fake-engine tests cover the behavior; real-daemon exec is a device-gate
  # item.
  {"lib/vagus/core/config_check.ex", :pattern_match},
  {"lib/vagus/core/config_check.ex", :unused_fun},
  {"lib/vagus/api/ingress_proxy.ex", :pattern_match},
  {"lib/vagus/api/router.ex", :pattern_match},
  {"lib/vagus/api/router.ex", :pattern_match_cov},
  {"lib/vagus/backups.ex", :pattern_match},
  {"lib/vagus/network.ex", :pattern_match},
  {"lib/vagus/backend/host/host_stub.ex", :pattern_match},

  # ── Root 2: intentional no-return / opaque-type nitpicks ────────────────
  # - backend/native + microvm: declared "not implemented" stubs that raise;
  #   dialyzer flags an always-raising fn as no_return vs its @spec.
  # - backend/host/nerves: reboot/poweroff route through Vagus.Host.Shutdown
  #   (returns :ok) since issue #39, so the old :no_return entry is gone;
  #   the pattern_match on the trailing `:ok` after the runtime call stays.
  # - ingress/ws_bridge + core/events: Mint.WebSocket / MapSet opaque-type
  #   pedantry (flush_pending IS called; the caller is only "unreachable"
  #   via the same Mint typing story). No behaviour issue.
  # - mint_http1_leftover/1 (all three WS bridges): drains Mint.HTTP1's
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
  {"lib/vagus/addon/manager.ex", :guard_fail}

  # ── (removed) Root 4: mqttx type/callback info gaps ─────────────────────
  # The three mqttx-related filters (handler.ex :callback_info_missing,
  # subscriptions.ex :unknown_type/:unknown_function) became UNUSED once the
  # bluetooth work (vagus-bluetooth) added the bluez/typedstruct deps and the
  # PLT was rebuilt fresh — `list_unused_filters: true` then fails the build
  # on the stale entries, exactly as designed. Re-baseline here if a future
  # dep change resurfaces them.
]
