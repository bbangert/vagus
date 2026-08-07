defmodule Vagus.MixProject do
  use Mix.Project

  @all_targets [:rpi3_64, :dragon_q6a, :rubik_pi3]

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
      # NOTE on PLT staleness: dialyxir NEVER checks/updates the PLT from an
      # umbrella child (`no_check?/1` hard-returns true — `check_plt: true`
      # and a custom `plt_file:` are both defeated; a missing PLT triggers a
      # parent-context build, an existing one is used as-is). A PLT restored
      # from CI's _build cache is therefore frozen at its build-time app set
      # — new deps dialyze as unknown_function forever, and vendored path
      # deps (not in mix.lock) never enter it, which is what originally
      # spawned the since-removed mqttx ignore filters. The fix lives in
      # .github/workflows/ci.yml: PLTs are deleted on any cache-key miss so
      # dialyxir rebuilds them against the current deps. Locally: delete
      # _build/*/dialyxir_* after changing deps.
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
      extra_applications: [:logger, :runtime_tools, :ssh],
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

      # Native MQTT broker (M5, vagus-mqtt): pure-Elixir MQTT 5.0
      # client/server/codec, embedded as a BEAM-subtree "virtual add-on"
      # behind the `Vagus.Addon.Backend.Native` seam — replaces the
      # containerized Mosquitto add-on as the default MQTT provider.
      # All targets (runs on-device).
      #
      # Vendored (not Hex): upstream mqttx 0.10.0 (cignosystems/mqttx, v0.10.0
      # tag) carries a one-line, backward-compatible patch that threads
      # ThousandIsland's `read_timeout` through the transport opts. The broker
      # sets `read_timeout: :infinity` so MQTT keepalive — not ThousandIsland's
      # 60s socket idle timeout — governs liveness; otherwise a healthy but idle
      # HA connection (keep-alive 60s) is dropped every ~130s. Only that one file
      # differs from the tag; see vendor/mqttx/lib/mqttx/transport/thousand_island.ex
      # (`read_timeout_opts/1`). Upstream PR: cignosystems/mqttx#5 — once merged
      # + released, replace this with the Hex dep. Vendored (vs a git pin) to keep
      # the broker's transport fully in-repo + auditable, matching `fresh`.
      {:mqttx, path: "../../vendor/mqttx"},

      # Parses add-on `config.yaml` in the store (P2-T3). yamerl-backed;
      # pulled into all targets since the store runs on-device.
      {:yaml_elixir, "~> 2.11"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.12"},

      # Vagus.Diagnostics.ring_grep/2 reads the RingLogger buffer directly
      # (RingLogger.get/2), not just via vagus_platform's backend config.
      # Same version constraint as vagus_platform's declaration so the
      # umbrella resolves one shared version.
      {:ring_logger, "~> 0.11.0"},

      # GitHub-releases OTA firmware updates (`Vagus.OS.Updater` wraps its
      # Supervisor + check/install API behind the daily-cadence timer and
      # the /os/update route). Deliberately NOT targets-scoped: it must
      # compile on :host for the router/updater tests — its fwup/reboot
      # side effects all sit behind injectable seams (:devpath_fn,
      # :reboot_fn, ...), so nothing hardware touches the host build.
      {:nerves_github_updater, "~> 0.1.1"},

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

      # BlueZ stack bring-up (dbus-daemon + bluetoothd under MuonTrap).
      # Vagus starts only the daemon slice of its tree — HA Core is the BLE
      # consumer via the /run/dbus bind (see Vagus.Bluetooth).
      {:bluez, "~> 0.1.0"},

      # Improv-over-BLE Wi-Fi provisioning (bluetooth phase 2): on an
      # offline boot the Pi advertises the Improv service so the HA
      # companion app can provision wlan0 before HA Core exists (the
      # engine — and with it Core — is already gated on :internet by
      # Vagus.Engine.Manager). Untargeted like :bluez: the host build
      # needs it for the pure child-spec/gate tests; nothing starts it
      # off-target. See Vagus.Improv.
      #
      # >= 0.1.2 is required, not incidental: earlier versions hardcoded
      # `key_mgmt: :wpa_psk`, so a WPA3 (SAE-only) network could never be
      # provisioned — it associated and then failed the 4-way handshake,
      # surfacing as a misleading "wrong password". 0.1.2 infers SAE vs PSK
      # from the target SSID's live scan flags. Found on the Dragon Q6A
      # (bbangert/improv#2).
      {:improv, "~> 0.1.2"},

      # bluez's compile-time macro dep, overridden as a git checkout pinned
      # to its release tag: the hex package's mix.exs derives its version
      # from `git describe --always --tags` at compile time, and a hex dep
      # dir isn't a git repo — describe walks up into THIS repo, which has
      # no tags, yielding a bare sha that Mix rejects as a Version. A git
      # checkout at the tag makes describe answer "0.5.4" deterministically
      # (locally and in CI).
      {:typedstruct, github: "saleyn/typedstruct", tag: "0.5.4", override: true, runtime: false},

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
