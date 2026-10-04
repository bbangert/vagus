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
      argus: argus(),
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
      dialyzer: [
        # :ssh isn't inferred as a PLT app from any dep — Vagus.SSHAccess
        # calls straight into the OTP `:ssh`/`:public_key`/`:crypto`
        # applications (`:ssh_file.encode/2`, `:ssh.hostkey_fingerprint/2`,
        # `:crypto.generate_key/2`, the `{:ECPoint, _}`/`{:namedCurve, _}`
        # public_key records) without a Hex dep pulling their PLT info in,
        # so Dialyzer reports those as unknown/nonexistent functions unless
        # the apps are added explicitly.
        plt_add_apps: [:ssh, :public_key, :crypto],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true
      ]
    ]
  end

  # `mix argus --fail-above 0` is a CI gate (its own job, not a compiler).
  # argus can only suppress per file (`ignore: [files: ...]` drops every
  # finding reported in that file), so each file below was reviewed and
  # holds only findings judged false positives or deliberate design. When
  # touching one, drop it from this list and re-check with `mix argus`.
  defp argus do
    [
      ignore: [
        files: [
          # coupling (one_for_one siblings that "register" with each other).
          # The two standing subscriptions it names — the watchdogs on
          # Vagus.Runtime.Events, the Core probe on Vagus.Core.TokenStore —
          # monitor the server and re-subscribe after a restart
          # (Vagus.Resubscribe), which argus does not model ("a's
          # re-registering on a schedule of its own"). The rest are per-use
          # requests (EventPusher pushes, Jobs/HttpConfig/Versions writes by
          # one-shot boot flows, HttpConfig re-pulled on Core start by
          # design) or add-on records written through Vagus.Addon.Manager by
          # every add-on start, not only these boot-time callers. State is
          # file-backed and reloads; Registry tokens and DNS names live in
          # memory only, so a Registry/DNS restart loses them for running
          # add-ons until each restarts — a known gap in those two servers
          # (they should rebuild from State in init/1), not in the callers.
          "lib/vagus/application.ex",
          # One reconnect loop only: :connect is armed by a dropped or failed
          # connection, and while it is pending conn is nil, so no stream
          # message can arm a second one.
          "lib/vagus/runtime/events.ex",
          # Task.async is linked deliberately (a killed caller takes the
          # inner call with it), and the function's failures are caught
          # inside the task, so the link never carries a crash to the caller.
          "lib/vagus/bounded_call.ex",
          # terminate/2 only closes a Mint connection whose socket the process
          # owns; the VM closes it when the process dies anyway. WSBridge's
          # init/1 call to Core.Versions runs per request, not in a boot
          # sequence.
          "lib/vagus/api/core_proxy/ws_bridge.ex",
          "lib/vagus/ingress/ws_bridge.ex",
          "lib/vagus/core/event_pusher/socket_connection.ex",
          # :dets.open_file in init/1 is a local file, not a distributed
          # store (the store failing degrades the server, never its start).
          "lib/vagus/ssh_access.ex",
          # Its continue only reaches Vagus.DNS/Vagus.Ingress after the :api
          # gate (Vagus.API.Listener accepting), and the API supervisor
          # starts after both.
          "lib/vagus/addon/boot_starter.ex",
          # init/1 only captures the port-probe closure; it never connects.
          "lib/vagus/ingress.ex",
          # The listener owns its Bandit child (restart: :temporary, see
          # default_start/2) and starts it from init/1 by design.
          "lib/vagus/api/listener.ex",
          # bounded/1's receive also takes the child's :DOWN, and the child is
          # heap-capped (max_heap_size kill), so the wait always ends.
          "lib/vagus/backup.ex",
          # The :ready_timeout kill of a connection that never became ready is
          # deliberate; the monitor's :DOWN then drives the ordinary retry.
          "lib/vagus/core/event_pusher.ex"
        ]
      ]
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
      {:finch, "~> 0.24.0"},
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
      {:nerves_github_updater, "~> 0.2.0"},

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
      {:bluez, "~> 0.2.0"},

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
      {:improv, "~> 0.1.3"},

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
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false, targets: :host},
      # Whole-program OTP/supervision analysis over the compiled beams
      # (`mix argus`). Needs Souffle on PATH; run as its own CI job rather
      # than a compiler so a missing Souffle never breaks `mix compile`.
      {:argus_beam, "~> 0.20", only: [:dev, :test], runtime: false, targets: :host}
    ]
  end
end
