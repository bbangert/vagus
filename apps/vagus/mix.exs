defmodule Vagus.MixProject do
  use Mix.Project

  @all_targets [:rpi3_64]

  def project do
    [
      app: :vagus,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: [ignore_warnings: ".dialyzer_ignore.exs", list_unused_filters: true]
    ]
  end

  # `test/support` (currently just `test/support/mocks.ex`, defining the
  # `Mox.defmock/2` calls behind `config :vagus, :backends` in
  # `config/test.exs`) is compiled ALONGSIDE `lib` for :test — not required
  # via `test_helper.exs` at test-run time — so the mock modules exist by
  # the end of the same `mix compile`/`mix test` pass that compiles
  # `Vagus.API.Router`. Requiring them only from `test_helper.exs` would
  # still work at runtime (Mox mocks are ordinary modules once created),
  # but the compiler would see `Vagus.Backend.NetworkMock` etc. as
  # "undefined" while type-checking the router (they don't exist yet at
  # that point in a plain compile), which is needless noise under
  # `--warnings-as-errors`.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {Vagus.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Web/API surface (P2+ — supervisor API endpoints and outbound
      # WebSocket client to Core).
      {:plug, "~> 1.20"},
      {:bandit, "~> 1.12"},
      {:finch, "~> 0.23.0"},
      # Ingress reverse proxy (M4b): websock_adapter provides the
      # Plug-side WebSocket upgrade (`WebSockAdapter.upgrade/4`) for the
      # browser leg of the ingress WS bridge; mint_web_socket (previously
      # only transitive via vendored fresh) is hand-rolled directly for the
      # add-on leg — see .claude/plans/vagus-m4-ingress-watchdog.
      {:websock_adapter, "~> 0.5"},
      {:mint_web_socket, "~> 1.0"},
      # Vendored, not Hex: fresh 0.4.4's own mix.exs is incompatible with
      # Elixir ~> 1.20 (hard Mix.raise on charlist elixirc_paths) and
      # upstream is unmaintained since 2024. See vendor/fresh/mix.exs for
      # the one-line patch (charlists -> strings) applied to an otherwise
      # byte-identical copy of the 0.4.4 release.
      {:fresh, path: "../../vendor/fresh"},
      {:jason, "~> 1.4"},

      # Parses add-on `config.yaml` in the store (P2-T3). yamerl-backed;
      # pulled into all targets since the store runs on-device.
      {:yaml_elixir, "~> 2.11"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.12"},

      # Build-time only (`runtime: false`), never in a release: the globally
      # installed nerves_bootstrap archive (needed by vagus_platform's
      # firmware builds) injects a `nerves.bootstrap` step into
      # `deps.get`/`deps.precompile` for the top-level project EVEN on
      # MIX_TARGET=host, and that task hard-raises when the project doesn't
      # declare :nerves. Same pattern as vagus_platform's own declaration.
      {:nerves, "~> 1.13", runtime: false},

      # Supervises the balena-engine daemon as an OS process (engine
      # supervision, see Vagus.Engine.Manager).
      {:muontrap, "~> 1.8"},

      # Vagus.Engine.Manager subscribes to vintage_net's aggregate
      # ["connection"] property directly (compile-time `Mix.target()`
      # branching keeps this reference out of the :host build — vintage_net
      # itself is only ever pulled into the build for real targets, via
      # vagus_platform's nerves_pack dependency).
      {:vintage_net, "~> 0.13.12", targets: @all_targets},

      # Test-only: Vagus.Backend.{Network,Host,OS} behaviours are mocked in
      # config/test.exs so handler tests can assert the router calls the
      # configured backend without exercising real hardware.
      {:mox, "~> 1.2", only: :test, targets: :host},

      # Static analysis / linting tooling. dev+test only, never in a release
      # (runtime: false). sobelow is Phoenix-oriented; kept for parity even
      # though this app is Plug/Bandit, not Phoenix.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false, targets: :host},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false, targets: :host},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false, targets: :host}
    ]
  end
end
