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

# `:podman` runs Engine.Podman against a real podman (on PATH, or the one
# VAGUS_PODMAN_BIN names); opt-in via `mix test --include podman`.
#
# `:block_device` needs a real block node under /dev, which the dev container
# has none of (only /dev/null, /dev/zero and friends). Opt-in via
# `mix test --include block_device` on a board or any host with a disk; when
# included with no node present it flunks rather than passing vacuously.
#
# `:known_failing` tests pin the intended behaviour of defects the per-app
# lifecycle fixes; run them with `mix test --include known_failing`.
#
# `:pty` runs serial capture against a socat pty pair; opt-in via
# `mix test --include pty`, skipped when socat is not on PATH.
#
# `:db` runs the memory store against the Postgres + pgvector that
# VAGUS_MEMORY_TEST_DSN names (postgres://agent@127.0.0.1:5432/memory);
# excluded when it is unset.
db_excluded =
  if System.get_env("VAGUS_MEMORY_TEST_DSN") in [nil, ""] do
    IO.puts("Excluding :db tests: set VAGUS_MEMORY_TEST_DSN to run them")
    [:db]
  else
    []
  end

ExUnit.start(exclude: [:podman, :block_device, :known_failing, :pty] ++ db_excluded)

# Read by test/support/podman_docker_exec.sh, which gives each run its own
# podman store: two suites at once would otherwise share container names.
System.put_env(
  "VAGUS_PODMAN_RUN",
  "r#{System.pid()}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
)

# At VM exit rather than `ExUnit.after_suite/1`: that runs after every pass of
# `--repeat-until-failure`, and the app processes started at boot read from it.
System.at_exit(fn _status ->
  if dir = Application.get_env(:vagus, :app_files_dir), do: File.rm_rf(dir)
end)
