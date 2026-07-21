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
      `/data/options.json`, ensures the bind-source dirs exist, then creates +
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
  """

  require Logger

  alias Vagus.Addon.Backend.Spec
  alias Vagus.Addon.{Config, OptionsSchema}
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
  """
  @spec install(Config.t(), keyword()) :: :ok | {:error, term()}
  def install(%Config{} = config, opts \\ []) do
    spec = build_spec(config, ensure_token(opts))

    with :ok <- maybe_ensure_network(config, opts),
         :ok <- backend(opts).pull(spec) do
      :ok
    end
  end

  @doc """
  Starts the add-on: fresh token → validated `/data/options.json` → bind-source
  dirs → create + start. Returns `{:ok, %{id: id, access_token: token}}`.
  """
  @spec start(Config.t(), keyword()) ::
          {:ok, %{id: String.t(), access_token: String.t()}} | {:error, term()}
  def start(%Config{} = config, opts \\ []) do
    token = generate_token()
    opts = Keyword.put(opts, :access_token, token)
    spec = build_spec(config, opts)
    data_root = data_root(opts)

    user_options = Keyword.get(opts, :user_options, %{})

    with :ok <- ensure_mount_sources(spec),
         :ok <- write_options(config, data_root, user_options),
         :ok <- maybe_ensure_network(config, opts),
         :ok <- remove_stale_container(spec, opts),
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
  """
  @spec stop(String.t(), keyword()) :: :ok | {:error, :not_found}
  def stop(slug, opts \\ []) do
    case Vagus.Addon.State.get(slug) do
      :error ->
        {:error, :not_found}

      {:ok, %{config: config}} ->
        stop_and_remove_container(config, opts)
        deregister_slug(config)
        record_state(config, :stopped)
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
    case Vagus.Addon.State.get(slug) do
      :error ->
        {:error, :not_found}

      {:ok, %{config: config, user_options: user_options}} ->
        start(config, Keyword.put_new(opts, :user_options, user_options || %{}))
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
  """
  @spec uninstall(String.t(), keyword()) :: :ok | {:error, :not_found} | {:error, term()}
  def uninstall(slug, opts \\ []) do
    case Vagus.Addon.State.get(slug) do
      :error ->
        {:error, :not_found}

      {:ok, %{config: config}} ->
        stop_and_remove_container(config, opts)
        remove_image_best_effort(config, opts)
        purge_side_state(config.slug)
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

  @doc "Builds the runtime-neutral `Backend.Spec` for `config`. Pure given `opts`."
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
      ports: if(host?, do: %{}, else: config.ports),
      pid_mode: if(not protected and config.host_pid, do: "host", else: nil),
      uts_mode: if(config.host_uts, do: "host", else: nil),
      platform: platform(arch)
    }
  end

  ## Internals

  defp backend(opts), do: Keyword.get(opts, :backend, default_backend())

  defp default_backend, do: Application.get_env(:vagus, :addon_backend, @default_backend)

  defp maybe_ensure_network(%Config{host_network: true}, _opts), do: :ok

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

    [data_mount | mapped]
  end

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

  defp ensure_mount_sources(%Spec{mounts: mounts}) do
    Enum.reduce_while(mounts, :ok, fn %{source: source}, :ok ->
      case File.mkdir_p(source) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:mkdir, source, reason}}}
      end
    end)
  end

  # Validate merged options against the add-on schema and write /data/options.json
  # (the per-add-on data dir is the /data bind source).
  defp write_options(config, data_root, user_options) do
    with {:ok, options} <- OptionsSchema.effective(config.schema, config.options, user_options) do
      path = Path.join([data_root, "addons", "data", config.slug, "options.json"])

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, Jason.encode!(options)) do
        :ok
      else
        {:error, reason} -> {:error, {:write_options, reason}}
      end
    else
      {:error, reason} -> {:error, {:invalid_options, reason}}
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
