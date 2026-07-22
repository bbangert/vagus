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
  {"lib/vagus/core/api_socket.ex", :no_return},
  {"lib/vagus/core/api_socket.ex", :call},
  {"lib/vagus/core/api_socket.ex", :unused_fun},
  {"lib/vagus/core/api_socket.ex", :invalid_contract},
  {"lib/vagus/addon/boot_starter.ex", :no_return},
  {"lib/vagus/addon/backend/container.ex", :no_return},
  {"lib/vagus/addon/backend/container.ex", :pattern_match},
  {"lib/vagus/addon/manager.ex", :pattern_match},
  {"lib/vagus/addon/watchdog.ex", :pattern_match},
  {"lib/vagus/addon/watchdog/probe.ex", :pattern_match},
  {"lib/vagus/api/ingress_proxy.ex", :pattern_match},
  {"lib/vagus/api/router.ex", :pattern_match},
  {"lib/vagus/api/router.ex", :pattern_match_cov},
  {"lib/vagus/backups.ex", :pattern_match},
  {"lib/vagus/network.ex", :pattern_match},
  {"lib/vagus/backend/host/host_stub.ex", :pattern_match},

  # ── Root 2: intentional no-return / opaque-type nitpicks ────────────────
  # - backend/native + microvm: declared "not implemented" stubs that raise;
  #   dialyzer flags an always-raising fn as no_return vs its @spec.
  # - backend/host/nerves: reboot/poweroff genuinely never return (they halt
  #   the board) — no_return is correct; the pattern_match is downstream.
  # - ingress/ws_bridge + core/events: Mint.WebSocket / MapSet opaque-type
  #   pedantry (flush_pending IS called; the caller is only "unreachable"
  #   via the same Mint typing story). No behaviour issue.
  {"lib/vagus/addon/backend/native.ex", :no_return},
  {"lib/vagus/addon/backend/microvm.ex", :no_return},
  {"lib/vagus/backend/host/nerves.ex", :no_return},
  {"lib/vagus/backend/host/nerves.ex", :pattern_match},
  {"lib/vagus/ingress/ws_bridge.ex", :pattern_match},
  {"lib/vagus/ingress/ws_bridge.ex", :unused_fun},
  {"lib/vagus/core/events.ex", :call_without_opaque},

  # ── Root 3: benign dead defensive checks ────────────────────────────────
  # Dialyzer proved a nil/default branch unreachable given the inferred types:
  # `user_options || %{}` in manager.ex (a defaulting `||` on a value already
  # typed as a map). Correct, defensive, not worth churning. (The analogous
  # ingress_proxy `query_string` dead-nil check was fixed at the source rather
  # than ignored — `in [nil, ""]` → `== ""`, since Plug guarantees a binary.)
  {"lib/vagus/addon/manager.ex", :guard_fail}
]
