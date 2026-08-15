# Mock modules themselves are defined in test/support/mocks.ex (compiled
# alongside lib/ for :test, see apps/vagus/mix.exs's elixirc_paths) rather
# than here, so they exist by the end of the same compile pass that
# compiles Vagus.API.Router — see that file for why.

# Global mode: any process (including a `Task.start/1`-spawned one, as
# `POST host/reboot`/`host/shutdown` use) can consume these mocks, not just
# whichever process set them up — see Vagus.API.Router's reboot/shutdown
# handlers. This is safe here specifically because only one dedicated,
# `async: false` test module (backend/handler tests) ever calls
# `Mox.expect/3`; every other test — including all pre-existing contract
# tests, unchanged — never touches Mox at all and just observes whatever
# `stub_with/2` below wired up once, for the whole suite.
Mox.set_mox_global()

Mox.stub_with(Vagus.Backend.NetworkMock, Vagus.Backend.Network.HostStub)
Mox.stub_with(Vagus.Backend.HostMock, Vagus.Backend.Host.HostStub)
Mox.stub_with(Vagus.Backend.OSMock, Vagus.Backend.OS.HostStub)

# Tests tagged `:docker` need a running Docker/balena-engine daemon on the
# host socket; they're opt-in via `mix test --include docker`.
#
# `:block_device` needs a real block node under /dev, which the dev container
# has none of (only /dev/null, /dev/zero and friends). Opt-in via
# `mix test --include block_device` on a board or any host with a disk; when
# included with no node present it flunks rather than passing vacuously.
ExUnit.start(exclude: [:docker, :block_device])
