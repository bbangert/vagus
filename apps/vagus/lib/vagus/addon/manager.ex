defmodule Vagus.Addon.Manager do
  @moduledoc """
  Ties the add-on pieces together into install + start — the Gate-1 keystone
  (`docs/contract-2026.7-m4-addendum.md` §A1). Given a parsed
  `Vagus.Addon.Config`, it:

    * builds a runtime-neutral `Vagus.Addon.Backend.Spec` (`build_spec/2`) —
      container name `addon_<slug>`, hostname `<slug-dashes>`, per-arch image,
      the `TZ`/`SUPERVISOR_TOKEN`/`HASSIO_TOKEN` env, the `hassio`-bridge
      attach with the injected `supervisor`/`hassio` `/etc/hosts` entries and
      CoreDNS resolver (§A6 / P1-T3), `map:`-derived bind mounts, ports, and
      the pinned §A1.4 invariants (via `Backend.Container`);
    * `install/2` — ensures the bridge and pulls the image;
    * `start/2` — generates a fresh per-add-on token, writes the validated
      `/data/options.json`, ensures the bind-source dirs exist, resolves a
      dynamic ingress port if the config declares one (`ingress_port: 0`,
      `docs/contract-2026.7-m4b-ingress-watchdog.md` §B3.2), then creates +
      starts the container via the backend.

  Backend is injectable (`:backend`, defaulting to `config :vagus,
  :addon_backend` — itself defaulting to `Backend.Container` — so router
  tests can swap in a fake backend for a whole request without threading an
  opt through every call site); the data root is `config :vagus,
  :addon_data_root` (default `/data`), overridable via `:data_root` (host
  tests point it at a tmp dir).

  P3-T1 adds the rest of the lifecycle on top of install/start:

    * `stop/2` — docker-stop then remove the container (the real
      Supervisor's `stop` removes the container; `start` always re-creates),
      deregister the token + DNS record, record `:stopped`;
    * `start_slug/2` — re-`start/2` a previously-installed slug using its
      `Vagus.Addon.State`-stored config + user options;
    * `restart/2` — `stop/2` (tolerating any failure but `:not_found`) then
      `start_slug/2`;
    * `uninstall/2` — stop+remove the container and image (both
      best-effort), purge the slug's discovery/service registrations, drop
      its `Registry`/`DNS`/`State` entries, and `File.rm_rf` its data dir —
      gated on the slug matching a safe directory-name charset, since the
      slug is interpolated into that rm_rf path.

  ## W6 — per-slug serialization (IW-P1-T2)

  Once `Vagus.Addon.Watchdog` can autonomously call `start_slug/2`/
  `restart/2` from its own `Task`, the previously-benign possibility of two
  lifecycle calls for the same slug running concurrently (a user's
  `POST /addons/{slug}/stop` landing mid-way through a watchdog-driven
  restart, or two watchdog attempts overlapping) becomes a real race: both
  sides issue raw create/start/stop/remove calls against the same
  `addon_<slug>` container name, and interleaving them can leave the
  container, the `State` entry, and the DNS/Registry/token side-state
  mutually inconsistent (e.g. a stop's `remove` racing a restart's
  `create`, or a `:stopped` record clobbered back to `:started` by a
  restart that started *before* the stop that should have won).

  Every public lifecycle function (`start/2`, `start_slug/2`, `stop/2`,
  `restart/2`, `uninstall/2`) therefore wraps its body in
  `:global.trans({{:addon_lifecycle, slug}, self()}, fun, [node()])` — a
  mutex keyed by slug. `:global.trans/3` blocks (rather than erroring) a
  second caller until the first releases, so callers never need to handle
  a "locked" result; passing `[node()]` scopes it to this node only (Vagus
  is single-node, there's no cluster to coordinate the lock across, so
  `:global`'s cross-node broadcast/consensus machinery would be pure
  overhead here — `:global.trans` is used purely for its **reentrant local
  mutex** behavior, not its distribution). Reentrant matters because
  `restart/2` calls `stop/2` then `start_slug/2`, and `start_slug/2` calls
  `start/2` — all from the same process, which must not deadlock against
  its own outer lock. `:global.set_lock/2` (which `:global.trans` uses
  internally) already guarantees this: a second `set_lock` call for the
  same `{LockId, RequesterId}` pair from the *same requester* (here,
  `self()`) increments a counter rather than blocking, so nested calls
  from one process compose safely while a genuinely different process
  calling with the same slug still queues behind the outer holder. No
  extra supervision is needed — `:global` is already part of the runtime
  (`:kernel`), there is nothing here for `Vagus.Application` to start or
  own.

  `stop/2` and `uninstall/2` additionally record `Vagus.Addon.State`'s
  `:stopped` state **before** touching the container (see each function's
  doc) — the watchdog's manual-stop suppression (§B6.3's `_manual_stop`
  analogue) depends on the `die` event a stop/uninstall causes finding
  `state: :stopped` already recorded, not racing to see it.
  """

  require Logger

  alias Vagus.Addon.Backend.Spec
  alias Vagus.Addon.{Config, Devices, OptionsSchema, Ports}
  alias Vagus.DSP
  alias Vagus.Ingress.Panels
  alias Vagus.Network

  @default_backend Vagus.Addon.Backend.Container
  @default_data_root "/data"

  # map: type -> {data-root subdir, container target, bind propagation}
  @map_types %{
    "ssl" => {"ssl", "/ssl", nil},
    "share" => {"share", "/share", "rslave"},
    "media" => {"media", "/media", "rslave"},
    "backup" => {"backup", "/backup", nil},
    "config" => {"homeassistant", "/config", nil},
    "homeassistant_config" => {"homeassistant", "/homeassistant", nil},
    "all_addon_configs" => {"addon_configs", "/addon_configs", nil},
    "addons" => {"addons/local", "/addons", nil}
  }

  @doc """
  Ensures the `hassio` bridge (for bridged add-ons) and pulls the add-on image.

  Refuses a slug Vagus reserves for itself (`Config.reserved_slug?/1`) with
  `{:error, {:reserved_slug, slug}}`. The check belongs here rather than only
  in `Config.parse/1` because `Vagus.API.Router`'s install handler overwrites
  the parsed config's slug with the one from the URL — this is the single
  choke point every install path (`Vagus.Addon.Update`,
  `Vagus.Addon.DefaultProvider`) goes through.
  """
  @spec install(Config.t(), keyword()) :: :ok | {:error, term()}
  def install(%Config{} = config, opts \\ []) do
    if Config.reserved_slug?(config.slug) do
      {:error, {:reserved_slug, config.slug}}
    else
      do_install(config, opts)
    end
  end

  defp do_install(%Config{} = config, opts) do
    opts = put_backend(opts, config)
    spec = build_spec(config, ensure_token(opts))

    with :ok <- maybe_ensure_network(config, opts) do
      backend(opts).pull(spec)
    end
  end

  # install/2 isn't part of W6's lock (it never touches a running
  # container — only image pull + bridge setup — so it can't race
  # start/stop/restart/uninstall the way they race each other).

  @doc """
  Starts the add-on: fresh token → validated `/data/options.json` → bind-source
  dirs → create + start. Returns `{:ok, %{id: id, access_token: token}}`.
  """
  @spec start(Config.t(), keyword()) ::
          {:ok, %{id: String.t(), access_token: String.t()}} | {:error, term()}
  def start(%Config{slug: slug} = config, opts \\ []) do
    with_slug_lock(slug, fn -> do_start(config, opts) end)
  end

  defp do_start(%Config{} = config, opts) do
    token = generate_token()

    # `protected` is resolved here rather than in `do_start_slug/2` because
    # `Vagus.Addon.Update`, `Vagus.Addon.DefaultProvider` and the router's
    # install path all reach `do_start/2` with a bare `Config` — resolving it
    # a level up would silently run those starts protected regardless of what
    # `POST /addons/{slug}/security` stored.
    opts =
      opts
      |> put_backend(config)
      |> Keyword.put(:access_token, token)
      |> Keyword.put_new(:protected, stored_protected(config.slug))

    spec = build_spec(config, opts)
    data_root = data_root(opts)

    user_options = Keyword.get(opts, :user_options, %{})

    with :ok <- ensure_mount_sources(spec),
         :ok <- ensure_dsp_store(config),
         :ok <- ensure_dsp_devices(config, opts),
         :ok <- write_options(config, data_root, user_options),
         :ok <- maybe_ensure_network(config, opts),
         :ok <- remove_stale_container(spec, opts),
         :ok <- maybe_allocate_ingress_port(config, opts),
         {:ok, id} <- backend(opts).create(spec),
         :ok <- start_or_cleanup(id, opts) do
      register_identity(config, token)
      record_state(config, :started, user_options: user_options)
      register_dns(config, id, opts)
      {:ok, %{id: id, access_token: token}}
    end
  end

  @doc """
  Stops `slug`: docker-stop then remove the container (§A1.1 — the real
  Supervisor's `stop` removes the container, and `start` always re-creates
  one), deregister its token (`Registry.unregister_slug/1`) and DNS record
  (`DNS.unregister/1`), and record `:stopped` (preserving any stored user
  options). Idempotent: a backend error stopping/removing an
  already-stopped/absent container is logged and tolerated, never surfaced
  as a failure — only an unknown (never-installed) `slug` is an error.

  W6: `record_state(config, :stopped)` runs **before**
  `stop_and_remove_container/2`, not after — the docker `die` event this
  stop causes must already find `state: :stopped` in `Vagus.Addon.State`
  when `Vagus.Addon.Watchdog` looks it up (§B6.3's `_manual_stop`
  analogue), not a stale `:started` that would make the watchdog treat a
  deliberate stop as a crash to restart.
  """
  @spec stop(String.t(), keyword()) :: :ok | {:error, :not_found}
  def stop(slug, opts \\ []) do
    with_slug_lock(slug, fn -> do_stop(slug, opts) end)
  end

  defp do_stop(slug, opts) do
    case Vagus.Addon.State.get(slug) do
      :error ->
        {:error, :not_found}

      {:ok, %{config: config}} ->
        opts = put_backend(opts, config)
        record_state(config, :stopped)
        stop_and_remove_container(config, opts)
        deregister_slug(config)
        :ok
    end
  end

  @doc """
  Re-`start/2`s a previously-installed `slug` using its
  `Vagus.Addon.State`-stored config and user options (a fresh token is
  generated, same as any `start/2`). `{:error, :not_found}` if `slug` isn't
  tracked (never installed, or already uninstalled).
  """
  @spec start_slug(String.t(), keyword()) ::
          {:ok, %{id: String.t(), access_token: String.t()}} | {:error, term()}
  def start_slug(slug, opts \\ []) do
    with_slug_lock(slug, fn -> do_start_slug(slug, opts) end)
  end

  defp do_start_slug(slug, opts) do
    case Vagus.Addon.State.get(slug) do
      :error ->
        {:error, :not_found}

      {:ok, %{config: config, user_options: user_options} = entry} ->
        # start/2 re-acquires the same slug's lock — reentrant for this
        # process (W6), so this doesn't deadlock against the lock
        # with_slug_lock/2 already holds above.
        opts =
          opts
          |> Keyword.put_new(:user_options, user_options || %{})
          |> Keyword.put_new(:ports, Map.get(entry, :ports) || %{})

        start(config, opts)
    end
  end

  @doc """
  Restarts `slug`: `stop/2` then `start_slug/2`. Any `stop/2` failure other
  than `{:error, :not_found}` is tolerated (`stop/2` itself already tolerates
  backend errors — this only guards the unknown-slug case, which must still
  short-circuit before attempting a start).
  """
  @spec restart(String.t(), keyword()) ::
          {:ok, %{id: String.t(), access_token: String.t()}} | {:error, term()}
  def restart(slug, opts \\ []) do
    with_slug_lock(slug, fn -> do_restart(slug, opts) end)
  end

  defp do_restart(slug, opts) do
    case stop(slug, opts) do
      {:error, :not_found} -> {:error, :not_found}
      _ -> start_slug(slug, opts)
    end
  end

  @doc """
  Uninstalls `slug`: stop+remove the container and remove the image (both
  best-effort — a daemon that's already gone-ahead-and-forgotten either one
  isn't a failure here), purge its discovery messages
  (`Vagus.Discovery.delete_by_slug/1`) and service registrations
  (`Vagus.Services.delete_by_slug/1`), drop its `Registry`/`DNS`/`State`
  entries, then `File.rm_rf` its data dir (`<data_root>/addons/data/<slug>`).

  The data-dir removal is gated on `Vagus.Addon.Config.valid_slug?/1` (W3) —
  `slug` is interpolated straight into that rm_rf path, so a slug that fails
  the check is skipped rather than risk deleting outside the add-on's own
  data dir; `{:error, {:invalid_slug, _}}` is returned in that case (every
  other step still runs). `valid_slug?/1` is the same charset
  `Config.parse/1` itself enforces (permissive of uppercase/dots), plus an
  explicit `.`/`..`/`/` reject — so, unlike this guard's previous
  lowercase-only regex (which any uppercase- or dot-containing, otherwise
  perfectly valid, `Config.parse/1`-produced slug would fail, silently
  orphaning that add-on's data dir on every uninstall), a real parsed config
  can only ever fail this check via one of those degenerate `.`/`..` tokens.

  W6: like `stop/2`, `record_state(config, :stopped)` runs **before**
  `stop_and_remove_container/2` — the same manual-stop-suppression
  rationale, for the brief window before `purge_side_state/1` deletes the
  `State` entry entirely.
  """
  @spec uninstall(String.t(), keyword()) :: :ok | {:error, :not_found} | {:error, term()}
  def uninstall(slug, opts \\ []) do
    with_slug_lock(slug, fn -> do_uninstall(slug, opts) end)
  end

  defp do_uninstall(slug, opts) do
    case Vagus.Addon.State.get(slug) do
      :error ->
        {:error, :not_found}

      {:ok, %{config: config}} ->
        opts = put_backend(opts, config)
        record_state(config, :stopped)
        stop_and_remove_container(config, opts)
        remove_image_best_effort(config, opts)
        purge_side_state(config.slug)
        # State entry is gone by now — `maybe_push_panel/2` resolves to a
        # DELETE push, mirroring upstream forcing `ingress_panel = false` +
        # pushing on uninstall (§B4.2). This is the only lifecycle op that
        # pushes; see `maybe_push_panel/2` for why start/stop no longer do.
        maybe_push_panel(config, opts)
        remove_data_dir(config.slug, opts)
    end
  end

  # A container named `addon_<slug>` may already exist — e.g. after a device
  # reboot or emulator restart, the previous session's container survives while
  # the in-memory add-on state does not, and `create` would 409 on the fixed
  # name. The real Supervisor's `DockerInterface.run` stops+removes any
  # existing container before creating (§A1.4 — no restart policy, the manager
  # owns the lifecycle), so do the same, tolerantly (absent/not-running is fine).
  defp remove_stale_container(spec, opts) do
    _ = backend(opts).stop(spec.name, [])
    _ = backend(opts).remove(spec.name, [])
    :ok
  end

  # Start the created container; if start fails, remove it (best-effort) so a
  # retry doesn't collide on the fixed `addon_<slug>` name with an orphaned,
  # created-but-unstarted container.
  defp start_or_cleanup(id, opts) do
    case backend(opts).start(id) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = backend(opts).remove(id)
        {:error, {:start_failed, reason}}
    end
  end

  # For a dynamic-ingress-port add-on (`ingress_port: 0`, §B3.1), resolve +
  # persist the real port (`Vagus.Ingress.dynamic_port/2`, §B3.2) BEFORE the
  # container is created — the add-on's own entrypoint reads the port back via
  # `GET /addons/self/info` (`bashio::addon.ingress_port`) right after start,
  # so it must already exist in `Vagus.Addon.State` by the time the container
  # runs (§B3.2 fact 5; this relies on the add-on's `Vagus.Addon.State` entry
  # already existing, which the install route creates before any start).
  #
  # Best-effort only when the ingress server isn't running at all (isolated
  # host unit tests, `:ingress_enabled false`) — same `Process.whereis` guard
  # style as `register_identity/2`/`record_state/3`. A *running* server that
  # fails to allocate is different: an ingress add-on without its port is
  # broken, so that case fails the start outright rather than being tolerated.
  # `opts[:ingress_server]` overrides the target (default `Vagus.Ingress`),
  # so tests can inject a private instance.
  defp maybe_allocate_ingress_port(%Config{ingress: true, ingress_port: 0, slug: slug}, opts) do
    server = ingress_server(opts)

    if Process.whereis(server) do
      case Vagus.Ingress.dynamic_port(slug, server) do
        {:ok, _port} -> :ok
        {:error, reason} -> {:error, {:ingress_port, reason}}
      end
    else
      :ok
    end
  end

  defp maybe_allocate_ingress_port(_config, _opts), do: :ok

  defp ingress_server(opts), do: Keyword.get(opts, :ingress_server, Vagus.Ingress)

  @doc """
  Builds the runtime-neutral `Backend.Spec` for `config`.

  Deterministic given `opts`, but **not** filesystem-free: resolving a
  `devices:` entry to a cgroup rule means `stat`-ing the node
  (`Vagus.Addon.Devices`), because the major:minor pair only exists on the
  device itself. The alternative — resolving in `do_start/2` and passing rules
  through `opts` — keeps purity but lets `build_spec/2` emit a spec that
  silently lacks its device rules, which is the worse failure.

  An add-on declaring neither `devices:` nor `full_access:` touches the
  filesystem not at all, so the hermetic callers (`image_ref/2`, the
  container-fingerprint gate) stay filesystem-free in practice.
  """
  @spec build_spec(Config.t(), keyword()) :: Spec.t()
  def build_spec(%Config{} = config, opts) do
    arch = Keyword.get(opts, :arch, default_arch())
    token = Keyword.get(opts, :access_token, "")
    data_root = data_root(opts)
    protected = Keyword.get(opts, :protected, true)
    host? = config.host_network

    %Spec{
      name: "addon_#{config.slug}",
      image: image_ref(config, arch),
      hostname: if(host?, do: nil, else: hostname(config.slug)),
      env: %{
        "TZ" => Keyword.get(opts, :tz, "UTC"),
        "SUPERVISOR_TOKEN" => token,
        "HASSIO_TOKEN" => token
      },
      network: if(host?, do: :host, else: :hassio),
      network_name: Network.name(),
      extra_hosts: %{"supervisor" => Network.supervisor_ip(), "hassio" => Network.supervisor_ip()},
      dns: [Network.dns_ip()],
      dns_search: ["local.hass.io"],
      dns_options: ["timeout:10"],
      init: config.init,
      cap_add: config.privileged,
      tmpfs: if(config.host_ipc, do: %{}, else: %{"/dev/shm" => ""}),
      mounts: mounts(config, data_root),
      device_cgroup_rules: Devices.cgroup_rules(config, protected),
      # The user's persisted host-port overrides, overlaid on the config's
      # declared ports (`Vagus.Addon.Ports`). A host-network add-on publishes
      # nothing — its ports are the host's already.
      ports: if(host?, do: %{}, else: Ports.effective(config, Keyword.get(opts, :ports, %{}))),
      pid_mode: if(not protected and config.host_pid, do: "host", else: nil),
      uts_mode: if(config.host_uts, do: "host", else: nil),
      platform: platform(arch)
    }
  end

  ## Internals

  # W6: per-slug reentrant mutex around each public lifecycle function's
  # body — see the moduledoc's "W6" section for why `:global.trans/3`
  # (reentrant per-process, node-local here) rather than a `GenServer`/
  # `Registry`-backed lock.
  @doc false
  # Unlocked `stop`/`start`, for a caller that ALREADY holds this slug's
  # lock — today only `Vagus.Addon.Update`.
  #
  # Nesting `:global.trans/4` on the same resource id does NOT work, even for
  # the same requester: `:global` locks are not counted, so the *inner*
  # release deletes the resource outright and the outer critical section
  # silently continues unlocked. Verified empirically — a different requester
  # can then acquire it mid-flight. `Vagus.Core.Lifecycle` sidesteps the same
  # trap by calling its own unlocked `do_*` helpers rather than its locking
  # public functions; these two exist so `Update` can do the same.
  #
  # (`start/2` re-acquiring the lock from `start_slug/2` is fine by contrast:
  # the outer function *returns into* the inner one and does nothing
  # afterwards, so losing the lock at the inner release costs nothing.)
  @spec stop_holding_lock(String.t(), keyword()) :: :ok | {:error, :not_found}
  def stop_holding_lock(slug, opts \\ []), do: do_stop(slug, opts)

  @doc false
  @spec start_holding_lock(Config.t(), keyword()) ::
          {:ok, %{id: String.t(), access_token: String.t()}} | {:error, term()}
  def start_holding_lock(%Config{} = config, opts \\ []), do: do_start(config, opts)

  defp with_slug_lock(slug, fun) do
    :global.trans({{:addon_lifecycle, slug}, self()}, fun, [node()])
  end

  defp backend(opts), do: Keyword.get(opts, :backend, default_backend())

  defp default_backend, do: Application.get_env(:vagus, :addon_backend, @default_backend)

  # Per-add-on backend selection (M5): a `backend: native` add-on (the mqttx
  # virtual add-on) routes every `backend(opts)` call site through
  # `Backend.Native` instead of the global `:addon_backend` default, while every
  # other add-on keeps the container default. `put_new` so an explicitly-injected
  # `:backend` (tests) still wins. Native `stop`/`remove` are idempotent no-ops
  # on an unstarted id, so `remove_stale_container/2` needs no native special-case.
  #
  # SECURITY: `backend:` comes from UNTRUSTED store `config.yaml`. Native add-ons
  # run un-sandboxed (no container/apparmor/caps), so `:native` is honoured ONLY
  # for a first-party allowlist (`:native_addon_slugs`, default `["core_mqtt"]`).
  # A store add-on that declares `backend: native` on any other slug silently
  # falls back to the container backend — it can't escape the sandbox or
  # impersonate the built-in broker.
  defp put_backend(opts, %Config{backend: :native, slug: slug} = config) do
    if native_allowed?(slug),
      do: Keyword.put_new(opts, :backend, Vagus.Addon.Backend.Native),
      else: put_backend(opts, %{config | backend: :container})
  end

  defp put_backend(opts, %Config{}), do: opts

  # Public (not private) because `Vagus.Host.Shutdown`'s add-on stop stage
  # needs this exact allowlist check to skip container-less native add-ons
  # (the in-BEAM mqttx broker has no `addon_<slug>` container to
  # docker-stop) — shared logic, not a new rule.
  @doc false
  @spec native_allowed?(String.t()) :: boolean()
  def native_allowed?(slug) do
    slug in Application.get_env(:vagus, :native_addon_slugs, ["core_mqtt"])
  end

  defp maybe_ensure_network(%Config{host_network: true}, _opts), do: :ok
  # Native "virtual add-ons" have no container on the hassio bridge — nothing to
  # attach, so don't stand the bridge up on their account (M5).
  defp maybe_ensure_network(%Config{backend: :native}, _opts), do: :ok

  defp maybe_ensure_network(_config, opts) do
    case Network.ensure(network_opts(opts)) do
      {:ok, _id} ->
        # Bind the supervisor anchor (.2) to the freshly-ensured bridge so the
        # host-networked emulator answers where the add-on reaches it (§A6).
        Network.ensure_supervisor_ip()
        :ok

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  # Only pass through opts the Docker client understands (e.g. :socket).
  defp network_opts(opts), do: Keyword.take(opts, [:socket])

  defp hostname(slug), do: String.replace(slug, "_", "-")

  # A native add-on has no image — `nil` is honest (the container-only fields of
  # the Spec are ignored by `Backend.Native`), and it means native survival no
  # longer depends on a placeholder `image:` in the config.
  defp image_ref(%Config{backend: :native}, _arch), do: nil

  defp image_ref(%Config{image: nil, slug: slug}, _arch),
    do: raise(ArgumentError, "add-on #{slug} has no image: (local build not supported yet)")

  defp image_ref(%Config{image: image, version: version}, arch) do
    "#{String.replace(image, "{arch}", arch)}:#{version}"
  end

  defp platform("amd64"), do: "linux/amd64"
  defp platform("aarch64"), do: "linux/arm64"
  defp platform("armv7"), do: "linux/arm/v7"
  defp platform("armhf"), do: "linux/arm/v6"
  defp platform("i386"), do: "linux/386"
  defp platform(_), do: nil

  defp default_arch do
    arch = to_string(:erlang.system_info(:system_architecture))

    cond do
      String.contains?(arch, "aarch64") -> "aarch64"
      String.contains?(arch, "x86_64") -> "amd64"
      String.contains?(arch, "arm") -> "armv7"
      true -> "amd64"
    end
  end

  defp mounts(config, data_root) do
    data_mount = %{
      source: Path.join([data_root, "addons", "data", config.slug]),
      target: "/data",
      read_only: false,
      propagation: nil
    }

    mapped =
      config.map |> Enum.map(&map_mount(&1, data_root, config.slug)) |> Enum.reject(&is_nil/1)

    [data_mount | mapped] ++ host_dbus_mount(config) ++ dsp_mount(config) ++ [dev_mount()]
  end

  # `dsp: true` — two read-only binds, because reaching the Hexagon DSP needs
  # two payloads with two different owners. Vagus only; upstream has no
  # equivalent key (see `Vagus.Addon.Config`'s moduledoc for why these are host
  # mounts rather than something baked into the add-on image).
  #
  # `/usr/lib/dsp` carries the fastrpc *shells* the system image ships;
  # `Vagus.DSP.root()` carries the operator-uploaded skel, which Qualcomm does
  # not permit redistributing and so can never be in any image. Measured on
  # dragon_q6a: skel without shells fails `0x80000600` (the session never
  # opens), shells without skel fails `0x80000406` (it opens and the skel load
  # fails). Independently required, and each failing distinctly.
  #
  # Two directories, not one: `libcdsprpc.so.1` searches a built-in path *list*
  # (`/usr/lib/dsp/cdsp;/usr/lib/dsp/adsp;/usr/lib/rfsa/adsp;/usr/lib/dsp`), so
  # nothing has to compose them. `/usr/lib/rfsa/adsp` is on that list and the
  # system image never populates it, so the two binds cannot collide — measured
  # with the skels bound only there running on the DSP, and the control of the
  # same files bound off the list failing.
  #
  # `system: true` on both, meaning something different on each: the firmware
  # owns `/usr/lib/dsp`, while Vagus owns the store and the operator may simply
  # not have filled it yet. Neither may be mkdir_p'd by
  # `ensure_mount_sources/1` — an empty bind is an add-on that starts, falls
  # back to CPU for the whole session, and reports success forever, which is
  # the silent failure this flag exists to prevent. A create-time refusal is
  # the loud alternative, and for the store half `ensure_dsp_store/1` turns it
  # into a sentence naming the panel first; the engine stays the backstop.
  #
  # A board with no DSP has no `root()` and gets no store bind, rather than one
  # with a `nil` source. `/usr/lib/dsp` is absent there too and fails on its
  # own, which is the honest answer for an add-on asking for hardware the board
  # does not have.
  defp dsp_mount(%Config{dsp: true}),
    do: [
      %{
        source: "/usr/lib/dsp",
        target: "/usr/lib/dsp",
        read_only: true,
        propagation: nil,
        system: true
      }
      | skel_mount(DSP.root())
    ]

  defp dsp_mount(_config), do: []

  defp skel_mount(nil), do: []

  defp skel_mount(root),
    do: [
      %{
        source: root,
        target: "/usr/lib/rfsa/adsp",
        read_only: true,
        propagation: nil,
        system: true
      }
    ]

  # Real-Supervisor parity (MOUNT_DEV): every add-on gets the host's whole /dev
  # bound read-only, unconditionally — upstream does not key this on `devices:`.
  #
  # The bind grants *visibility*; `Vagus.Addon.Devices`' cgroup rule grants
  # *access*. That model is only true for device numbers the engine denies by
  # default — every block device, which is the case that matters for
  # `devices:`. It is NOT true for the nodes moby's default policy already
  # allows: `c 1:3/1:5/1:7/1:8/1:9`, `c 5:0`, `c 5:1` (/dev/console), `c 5:2`,
  # and `c 136:*` (pty slaves). For those the bind alone IS access, with no
  # rule from us. Measured on BOTH boards (balenaEngine v25.0.14, cgroup v2,
  # `Tty: false` so the container owns no pty, no device rules at all):
  # `/dev/console` reads `5:1` and `/dev/pts/0` reads `136:0` — the host's
  # numbers exactly — while a container without the bind gets runc's private,
  # empty devpts and no console. Both open.
  #
  # Upstream has the same exposure: its `MOUNT_DEV` sets
  # `read_only_non_recursive`, the engine honours the field, and the result is
  # byte-identical. Docker 29.6.1 behaves the same, so this is neither a
  # balena-engine limitation nor something a different runtime would fix.
  #
  # The IEx shell is NOT reachable: `erlinit --ctty tty1` puts it on
  # `/dev/tty1`, and `c 4:*` is not in moby's default allowlist — `/dev/tty1`,
  # `/dev/tty0` and `/dev/ttyAMA0` are all denied. `/dev/pts/0` is PID 1's
  # stdio (the BEAM's nbtty pty), so the residual exposure is reading
  # keystrokes typed at the LOCAL console and spoofing its output. Writing a
  # pty slave sends output; it does not inject input.
  #
  # **The bind is not what grants any of this, and masking a path does not
  # revoke it.** A cgroup rule names a device NUMBER, not a path, and
  # `CAP_MKNOD` is in the default capability set — so a container with no
  # `/dev` bind at all can `mknod c 5 1` and read and write the host console
  # just the same. Verified on-device, including against a container with no
  # bind: the exposure predates this mount and is upstream's too. Only
  # dropping `MKNOD` closes it, which upstream does not do. See
  # docs/divergences.md — a `/dev/null` mask over `/dev/console` was tried and
  # removed because one `mknod` walks around it.
  #
  # Read-only buys node create/unlink protection on the host's /dev and nothing
  # more — it is not a security control on the nodes themselves. Writes to a
  # char/block node bypass the mount check (Linux gates it on
  # `!special_file(inode->i_mode)`), as do `connect()` to a unix socket and any
  # `ioctl` on a granted node.
  #
  # `system: true` keeps `ensure_mount_sources/1` from ever mkdir-ing into `/`.
  #
  # `read_only_non_recursive` matches upstream's `MOUNT_DEV` exactly
  # (`docker/const.py`). Measured on balenaEngine v25.0.14: the engine honours
  # the field, and it changes nothing about what is reachable — it governs
  # whether read-only is forced onto `/dev`'s submounts, not isolation. Carried
  # for parity, not for protection.
  defp dev_mount,
    do: %{
      source: "/dev",
      target: "/dev",
      read_only: true,
      propagation: nil,
      read_only_non_recursive: true,
      system: true
    }

  # Real-Supervisor parity (MOUNT_DBUS): a `host_dbus: true` add-on gets the
  # host system-bus socket dir bound read-only, same as HA Core's container.
  # `system: true` keeps `ensure_mount_sources/1` from mkdir-ing it — /run/dbus
  # is owned by Vagus.Bluetooth/Bluez.prepare_runtime/0, and on a BlueZ-less
  # firmware (Vagus.Bluetooth `:ignore`d) creating it here would hand the
  # add-on a valid-looking but daemon-less bus mount instead of a loud
  # create-time failure (the engine rejects a bind whose source is missing).
  defp host_dbus_mount(%Config{host_dbus: true}),
    do: [
      %{source: "/run/dbus", target: "/run/dbus", read_only: true, propagation: nil, system: true}
    ]

  defp host_dbus_mount(_config), do: []

  defp map_mount(%{type: "addon_config", read_only: ro}, data_root, slug) do
    %{
      source: Path.join([data_root, "addon_configs", slug]),
      target: "/config",
      read_only: ro,
      propagation: nil
    }
  end

  defp map_mount(%{type: type, read_only: ro}, data_root, _slug) do
    case Map.fetch(@map_types, type) do
      {:ok, {subdir, target, prop}} ->
        %{source: Path.join(data_root, subdir), target: target, read_only: ro, propagation: prop}

      :error ->
        Logger.warning("Vagus.Addon.Manager: unknown map type '#{type}', skipping")
        nil
    end
  end

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_mount_sources(%Spec{mounts: mounts}) do
    Enum.reduce_while(mounts, :ok, fn
      # System-owned sources (see Spec.mount/0 `:system`) are never created
      # here — if the owner (e.g. Vagus.Bluetooth for /run/dbus) hasn't stood
      # them up, container create fails loudly on the missing bind source.
      %{system: true}, :ok ->
        {:cont, :ok}

      %{source: source}, :ok ->
        case File.mkdir_p(source) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:mkdir, source, reason}}}
        end
    end)
  end

  # The store bind is `system: true`, so an unsupplied skel is already a failed
  # container create — but the engine's error for it is a missing bind source,
  # which names a path the operator has never heard of for a problem they fix
  # by uploading a file. This says that instead, and only for `dsp: true`.
  #
  # `DSP.state/0`, not `DSP.status/0`: a start must not pay the whole-file
  # version rescan, and `Vagus.Addon.Watchdog` can drive starts in a loop.
  defp ensure_dsp_store(%Config{dsp: true}) do
    case DSP.state() do
      :configured ->
        :ok

      :not_configured ->
        {:error,
         {:dsp_not_configured,
          "no DSP skeleton library has been supplied — upload one from the QAIRT SDK " <>
            "on the Vagus admin panel"}}

      :unsupported ->
        {:error, {:dsp_unsupported, "this device has no Hexagon DSP"}}
    end
  end

  defp ensure_dsp_store(_config), do: :ok

  # Ordered after `ensure_dsp_store/1` on purpose: a board with no DSP has no
  # fastrpc nodes either, and "a device node is missing" would be a true but
  # useless answer to "this device has no Hexagon DSP".
  #
  # Fail-closed for the same reason the store check is. Without a rule for
  # these the container starts, allocates nothing, and dies at `ERROR 0x68`
  # inside the add-on — a failure the operator sees as the add-on being broken.
  # `Vagus.Addon.Devices` skips a node it cannot resolve, which is right for an
  # author's `devices:` and wrong for the two `dsp: true` cannot work without.
  defp ensure_dsp_devices(%Config{dsp: true}, opts) do
    case Devices.unresolved_dsp_nodes(opts) do
      [] ->
        :ok

      missing ->
        {:error,
         {:dsp_devices_unavailable,
          "this device's DSP nodes are not available (#{Enum.join(missing, ", ")}) — " <>
            "the add-on could not use the DSP even if it started"}}
    end
  end

  defp ensure_dsp_devices(_config, _opts), do: :ok

  # Validate merged options against the add-on schema and write /data/options.json
  # (the per-add-on data dir is the /data bind source).
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp write_options(config, data_root, user_options) do
    case OptionsSchema.effective(config.schema, config.options, user_options) do
      {:ok, options} ->
        path = Path.join([data_root, "addons", "data", config.slug, "options.json"])

        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, Jason.encode!(options)) do
          :ok
        else
          {:error, reason} -> {:error, {:write_options, reason}}
        end

      {:error, reason} ->
        {:error, {:invalid_options, reason}}
    end
  end

  # Register the running add-on's token → identity/grants so the emulator's
  # add-on-facing endpoints can authorize it. Best-effort: skipped if the
  # registry isn't running (e.g. isolated unit tests).
  defp register_identity(config, token) do
    if Process.whereis(Vagus.Addon.Registry) do
      Vagus.Addon.Registry.register(token, Vagus.Addon.Registry.identity_from_config(config))
    end

    :ok
  end

  # Record the add-on's lifecycle state so `GET /addons/{slug}/info` (and the
  # lifecycle routes) can serve it. Best-effort: skipped if the store isn't
  # running (isolated unit tests). `state_opts` forwards to `State.put/3`
  # (e.g. `user_options:` on a start; omitted on a stop, so the prior
  # user options are preserved — see `Vagus.Addon.State.put/3`).
  # Defaults `true` on every uncertain path — a slug that isn't tracked yet
  # (a brand-new install starts before `record_state/3` writes its entry), the
  # isolated unit tests where `State` isn't running at all, and a stored value
  # that isn't a boolean.
  #
  # That last clause is the same fail-closed rule `State.decode_protected/1`
  # applies to a corrupt state file, restated at the *read* end because this is
  # where a bad value would do damage: `Devices.cgroup_rules/3` guards on
  # `is_boolean`, so a non-boolean here crashes the start with a
  # FunctionClauseError. Guarding `State.put_setting/4` instead would leave
  # `preserved_settings/2` free to copy a bad value forward, and would make
  # `:protected` the only one of that setter's seven keys to type-check its
  # value.
  defp stored_protected(slug) do
    with true <- is_pid(Process.whereis(Vagus.Addon.State)),
         {:ok, entry} <- Vagus.Addon.State.get(slug),
         value when is_boolean(value) <- Map.get(entry, :protected, true) do
      value
    else
      _ -> true
    end
  end

  defp record_state(config, state, state_opts \\ []) do
    if Process.whereis(Vagus.Addon.State), do: Vagus.Addon.State.put(config, state, state_opts)
    :ok
  end

  # Deregister a stopped/uninstalled add-on's token + DNS record. Best-effort,
  # same rationale as `register_identity/2`/`register_dns/3`.
  defp deregister_slug(%Config{slug: slug}) do
    if Process.whereis(Vagus.Addon.Registry), do: Vagus.Addon.Registry.unregister_slug(slug)
    if Process.whereis(Vagus.DNS), do: Vagus.DNS.unregister(String.replace(slug, "_", "-"))
    :ok
  end

  # docker-stop then remove (§A1.1's pinned `stop` semantics). Both calls are
  # tolerated: an already-stopped/absent container is idempotent success at
  # the backend, but a legitimately-failing daemon call (e.g. no daemon in a
  # host devcontainer) must not block deregistration/state bookkeeping either
  # — this is best-effort the same way DNS/registry side effects are.
  defp stop_and_remove_container(config, opts) do
    id = "addon_#{config.slug}"

    case backend(opts).stop(id, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Vagus.Addon.Manager: stop #{id} failed (tolerated): #{inspect(reason)}")
    end

    case backend(opts).remove(id, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Vagus.Addon.Manager: remove #{id} failed (tolerated): #{inspect(reason)}")
    end

    :ok
  end

  # Image removal goes straight through `Vagus.Runtime.Docker` (not the
  # injectable `:backend` — the `Backend` behaviour is container-lifecycle
  # only, and image removal isn't part of it) and is best-effort: a config
  # with no `image:` (raises building the spec) or a daemon that's already
  # forgotten the image both just log and move on.
  # Native add-ons have no image to remove (and `image_ref/2` is nil for them).
  defp remove_image_best_effort(%Config{backend: :native}, _opts), do: :ok

  defp remove_image_best_effort(config, opts) do
    case safe_image_ref(config, opts) do
      {:ok, image} ->
        case Vagus.Runtime.Docker.remove_image(image, network_opts(opts)) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Vagus.Addon.Manager: remove image #{image} failed (tolerated): #{inspect(reason)}"
            )
        end

      :error ->
        :ok
    end
  end

  defp safe_image_ref(config, opts) do
    {:ok, build_spec(config, opts).image}
  rescue
    ArgumentError -> :error
  end

  # Purge every other subsystem's record of `slug` on uninstall. Each touch
  # is best-effort/guarded the same way the rest of the manager's side
  # registrations are — an uninstall must complete even in an isolated test
  # that never started the full app.
  defp purge_side_state(slug) do
    if Process.whereis(Vagus.Discovery), do: Vagus.Discovery.delete_by_slug(slug)
    if Process.whereis(Vagus.Services), do: Vagus.Services.delete_by_slug(slug)
    if Process.whereis(Vagus.Addon.Registry), do: Vagus.Addon.Registry.unregister_slug(slug)
    if Process.whereis(Vagus.DNS), do: Vagus.DNS.unregister(String.replace(slug, "_", "-"))
    if Process.whereis(Vagus.Addon.State), do: Vagus.Addon.State.delete(slug)
    :ok
  end

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_data_dir(slug, opts) do
    if Config.valid_slug?(slug) do
      File.rm_rf(Path.join([data_root(opts), "addons", "data", slug]))
      :ok
    else
      Logger.warning(
        "Vagus.Addon.Manager: refusing to rm_rf the data dir for unsafe slug #{inspect(slug)}"
      )

      {:error, {:invalid_slug, slug}}
    end
  end

  # Register `<slug-with-dashes>` → the container's hassio-bridge IP in the DNS
  # server (§A6) so Core / other add-ons resolve the add-on by name. Best-effort:
  # only for bridged add-ons, only when the DNS server + Docker inspect are
  # available; any failure is logged and ignored (the add-on still runs).
  defp register_dns(%Config{host_network: true}, _id, _opts), do: :ok
  # A native add-on has no container/bridge IP to inspect (MQ-P3-T3). Advertise
  # the supervisor anchor IP — the in-BEAM broker listens there and it's
  # reachable from every bridged add-on + Core, same as the injected
  # `supervisor`/`hassio` host entries. Best-effort, like the container path.
  defp register_dns(%Config{backend: :native, slug: slug}, _id, _opts) do
    if is_pid(Process.whereis(Vagus.DNS)) do
      Vagus.DNS.register(String.replace(slug, "_", "-"), Network.supervisor_ip())
    end

    :ok
  end

  defp register_dns(%Config{slug: slug}, id, opts) do
    with true <- is_pid(Process.whereis(Vagus.DNS)),
         {:ok, %{"NetworkSettings" => %{"Networks" => networks}}} <-
           Vagus.Runtime.Docker.inspect_container(id, network_opts(opts)),
         %{"IPAddress" => ip} when is_binary(ip) and ip != "" <-
           Map.get(networks, Network.name()) do
      Vagus.DNS.register(String.replace(slug, "_", "-"), ip)
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("Vagus.Addon.Manager: DNS register for #{slug} failed: #{inspect(e)}")
      :ok
  end

  # Core sidebar-panel push, on uninstall only — §B4.4's set, not a superset
  # of it.
  #
  # This used to fire on start/stop as well, on the theory that "an extra push
  # is harmless, since Core re-fetches the full list rather than trusting the
  # push body". The P2-A phase 5 device gate disproved the premise: Core
  # answers `POST api/hassio_push/panel/{slug}` with **500** whenever the panel
  # is already registered, and logs `ValueError: Overwriting panel {slug}` with
  # a full traceback at ERROR. That is structural upstream, not a transient —
  # HA's `components/hassio/addon_panel.py::_register_panel` calls
  # `frontend.async_register_built_in_panel` without `update=True`, and
  # `components/frontend/__init__.py` raises on overwrite. So every start of an
  # ingress add-on wrote a traceback into the user's Core log.
  #
  # Upstream pushes from exactly three places, none of them a lifecycle
  # transition: the options handler when `ingress_panel` is toggled
  # (`supervisor/api/apps.py`), uninstall after forcing `ingress_panel = false`
  # (`supervisor/apps/app.py`), and restore when the flag actually changed
  # (`supervisor/apps/manager.py`). Vagus matches that: the options-change push
  # lives in the router, this one covers uninstall, and restore never moves
  # `ingress_panel` so it needs none. A start doesn't need one either — the
  # flag defaults to false and only the options endpoint flips it, and Core
  # registers every enabled panel itself at its own startup.
  #
  # `Panels.update_hass_panel/2` still guards for an unreachable/absent Core
  # client, so a bare call is fine here — same as `register_dns/3`'s
  # `Process.whereis` style for its own side effect.
  defp maybe_push_panel(%Config{ingress: true, slug: slug}, opts) do
    panels(opts).update_hass_panel(slug)
    :ok
  end

  defp maybe_push_panel(_config, _opts), do: :ok

  defp panels(opts), do: Keyword.get(opts, :panels, Panels)

  defp ensure_token(opts), do: Keyword.put_new(opts, :access_token, generate_token())

  defp generate_token, do: :crypto.strong_rand_bytes(56) |> Base.encode16(case: :lower)

  defp data_root(opts),
    do:
      Keyword.get(
        opts,
        :data_root,
        Application.get_env(:vagus, :addon_data_root, @default_data_root)
      )
end
