import Config

# Contract tests exercise Vagus.API.Router directly via Plug.Test, so
# Bandit never needs to bind a port — this keeps `mix test` from leaving
# dangling listeners or racing port conflicts across runs (P2-T1).
config :vagus, :api_server_enabled, false

# Don't bind the DNS server (:53 / the .3 anchor) during `mix test` — the DNS
# unit tests start their own instance on a loopback high port. Mirrors
# :api_server_enabled.
config :vagus, :dns_enabled, false

# Strict-mode Vagus.API.Model: an undeclared/missing key raises instead of
# just being logged, so a drifted field list fails the test suite loudly.
config :vagus, :model_strict, true

# A token path isolated from the real host dev-loop token
# (.dev/supervisor_token) — tests read/write here instead, regardless of
# which directory `mix test` is invoked from.
config :vagus, :token_path, Path.join(System.tmp_dir!(), "vagus_test_supervisor_token")

# Isolated from the real host dev-loop core token file, same rationale as
# :token_path above — and from the real host :core_token_path so the
# globally-supervised Vagus.Core.TokenStore never accidentally picks up a
# real refresh token left over on the dev machine (which would make
# Vagus.Core.EventPusher attempt a real connection during `mix test`).
config :vagus, :core_token_path, Path.join(System.tmp_dir!(), "vagus_test_core_token.json")

# Host-management backends (P4-T1): Mox mocks, not the host stubs directly
# — `test/test_helper.exs` defines each mock and, via `Mox.stub_with/2`,
# defaults it to delegate to the matching `Vagus.Backend.*.HostStub` (so
# existing contract tests that never touch Mox themselves keep observing
# host-stub-shaped data), while dedicated backend/handler tests use
# `Mox.expect/3` to prove the router calls the configured backend.
config :vagus, :backends, %{
  network: Vagus.Backend.NetworkMock,
  host: Vagus.Backend.HostMock,
  os: Vagus.Backend.OSMock
}

# Add-on state stays in-memory (nil disables `Vagus.Addon.State` file
# persistence) and boot reconciliation stays off (`Vagus.Addon.BootStarter`
# `:ignore`s) — `mix test` has no real engine socket to poll and no
# device-reboot scenario to reconcile (M4-P8-T1).
config :vagus, :addon_state_path, nil
config :vagus, :addon_boot_start, false
