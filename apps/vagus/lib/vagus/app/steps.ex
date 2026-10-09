defmodule Vagus.App.Steps do
  @moduledoc """
  The actions an app process runs in its tasks, one function per step:
  `run(name, input)` returns `{:ok, fact}` or `{:error, reason}`, where the
  fact is the one thing the step produced. The input is everything the step
  needs (`Vagus.App.Policy.task_input/2`), so nothing here reads app state.

  The container spec (`build_spec/2`, mounts, DSP, ports, image ref,
  platform) and backend selection are carried from the module the app
  process replaced.
  `input[:backend]`, `input[:data_root]` and `input[:socket]` override the
  configured backend, data root and engine socket.
  """

  require Logger

  alias Vagus.Addon.Backend.{Native, Spec}
  alias Vagus.Addon.{Config, Devices, OptionsSchema, Ports, Store}
  alias Vagus.DSP
  alias Vagus.Ingress.Panels
  alias Vagus.Network

  @default_backend Vagus.Addon.Backend.Container
  @default_data_root "/data"
  @halt_timeout_s 30
  @port_min 62_000
  @port_max 65_500
  @port_tries 100

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

  @spec run(atom(), map()) :: {:ok, term()} | {:error, term()}
  def run(name, input) do
    report_stage(input)
    step(name, input)
  end

  defp report_stage(%{job: job, stage: {stage, progress}} = input) when job != nil,
    do:
      Vagus.Jobs.update(
        job,
        [stage: stage, progress: progress],
        input[:jobs_server] || Vagus.Jobs
      )

  defp report_stage(_input), do: :ok

  defp step(:pull, %{config: config} = input) do
    opts = opts(input)
    spec = build_spec(config, Keyword.put(opts, :access_token, ""))

    with :ok <- maybe_ensure_network(config, opts),
         :ok <- backend(opts).pull(spec) do
      {:ok, spec.image}
    end
  end

  defp step(:start, %{config: config} = input) do
    opts =
      opts(input)
      |> Keyword.put(:access_token, input[:token] || "")
      |> Keyword.put(:ports, input[:ports] || %{})
      # Fail closed: `Devices.cgroup_rules/3` crashes on a non-boolean, and
      # this gates `full_access`/`host_pid`.
      |> Keyword.put(:protected, input[:protected] != false)

    spec = build_spec(config, opts)

    with :ok <- ensure_mount_sources(spec),
         :ok <- ensure_dsp_store(config),
         :ok <- ensure_dsp_devices(config, opts),
         :ok <- write_options(config, data_root(opts), input[:user_options] || %{}),
         :ok <- maybe_ensure_network(config, opts),
         :ok <- remove_stale_container(spec, opts),
         {:ok, id} <- backend(opts).create(spec),
         :ok <- start_or_cleanup(id, opts) do
      {:ok, started(config, id, opts)}
    end
  end

  defp step(:stop, %{config: config} = input) do
    opts = opts(input)
    id = container_name(config.slug)
    was_running = match?({:ok, state} when state in [:running, :paused], backend(opts).state(id))

    with :ok <- stop_and_remove_container(id, opts, input[:strict] == true),
         do: {:ok, %{was_running: was_running}}
  end

  # Shutdown: stop by name and leave the container for the next boot to
  # replace, inside the budget `Vagus.Host.Shutdown` has.
  defp step(:halt_stop, %{config: config} = input) do
    opts = opts(input)
    id = container_name(config.slug)

    case stop_thawed(id, Keyword.put(opts, :timeout, @halt_timeout_s)) do
      :ok -> {:ok, :stopped}
      {:error, reason} -> {:error, reason}
    end
  end

  defp step(:port, input) do
    directory = input[:directory] || Vagus.App.Directory
    probe = input[:port_probe] || (&listening?/2)
    rand = input[:rand] || fn -> Enum.random(@port_min..@port_max) end
    pick_port(directory, probe, rand, @port_tries)
  end

  # Planned for an app wanted started, whose container may not exist: with
  # none, nothing is writing, so there is nothing for the hook to quiesce.
  defp step(:exec_hook, %{config: config, cmd: cmd} = input) do
    docker = input[:docker] || Vagus.Runtime.Docker
    id = container_name(config.slug)

    case docker.exec(id, cmd, Keyword.take(opts(input), [:socket])) do
      :ok ->
        {:ok, :ok}

      {:error, {:exec_create_failed, 404, _message}} ->
        Logger.info("Vagus.App.Steps: no container #{id}; backup hook skipped")
        {:ok, :skipped}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp step(:snapshot, %{config: config, staging_dir: dir} = input) do
    opts = opts(input)

    addon = %{
      slug: config.slug,
      name: config.name,
      version: config.version,
      data_dir: data_dir(data_root(opts), config.slug),
      user: %{"options" => input[:user_options] || %{}, "version" => config.version},
      system: system_map(config),
      state: input[:state] || "stopped"
    }

    path = Path.join(dir, "#{config.slug}.tar.gz")
    tar = fn -> Vagus.Backup.addon_tar(addon) end

    {tarred, thawed} = if input[:pause], do: frozen(config, opts, tar), else: {tar.(), :ok}

    with {:ok, gz, _size} <- tarred,
         :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, gz) do
      if match?({:error, _reason}, thawed), do: {:ok, {:still_paused, path}}, else: {:ok, path}
    end
  end

  defp step(:unpause, %{config: config} = input) do
    case thaw(container_name(config.slug), opts(input)) do
      {:error, reason} -> {:error, reason}
      thawed -> {:ok, thawed}
    end
  end

  # The old data is set aside, not removed, until the new is in place, so a
  # failed rename leaves the app's data as it was. The staging dir is a
  # sibling of the data dir, so each rename stays on one filesystem. A failed
  # swap removes the staged data itself, as its caller may be gone; the aside
  # of one that succeeded goes in `drop_aside`, outside this deadline.
  # The staging path comes from the op's args and is renamed and removed as
  # root, so anything but this app's own restore sibling is refused.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp step(:swap_data, %{config: config, staging_dir: staging} = input) do
    data_dir = data_dir(data_root(opts(input)), config.slug)
    aside = staging <> ".old"

    with :ok <- restore_sibling(staging, data_dir, config.slug),
         :ok <- set_aside(data_dir, aside),
         :ok <- swap_in(staging, data_dir, aside) do
      {:ok, data_dir}
    else
      {:error, :bad_staging} = error ->
        error

      error ->
        File.rm_rf(staging)
        error
    end
  end

  # The op's last step, so the aside is gone before the app is free for an
  # uninstall: one left behind a removed data dir is what the boot sweep
  # moves back. The data is already restored, so this never fails the op.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp step(:drop_aside, %{config: config, staging_dir: staging} = input) do
    data_dir = data_dir(data_root(opts(input)), config.slug)

    with :ok <- restore_sibling(staging, data_dir, config.slug),
         {:ok, _removed} <- File.rm_rf(staging <> ".old") do
      {:ok, :ok}
    else
      error ->
        Logger.warning(
          "Vagus.App.Steps: #{config.slug}'s pre-restore data at #{staging}.old was not " <>
            "removed (#{inspect(error)}); the boot sweep removes it"
        )

        {:ok, :kept}
    end
  end

  # The backup's options are validated against the config current in this
  # op, as a save to `POST /addons/{slug}/options` is: a `hassio_role:
  # backup` app can upload a tar and restore it onto another app, so the tar
  # is the less trusted input. This bounds the options only, and only as far
  # as the schema is narrow: an app without one accepts anything, as
  # upstream's does, and the tar's data is swapped in as it is. Options that
  # do not validate are dropped and the current ones kept, rather than
  # failing the restore: a schema that tightened since the backup must not
  # cost the user the data they restored. The raw map is kept, as a save
  # keeps it.
  defp step(:set_options, %{config: config, options: options}) do
    with true <- is_map(options) || {:error, "not a map"},
         {:ok, _validated} <- OptionsSchema.effective(config.schema, config.options, options) do
      {:ok, options}
    else
      {:error, reason} ->
        Logger.warning(
          "Vagus.App.Steps: #{config.slug}'s backed-up options do not validate against its " <>
            "installed schema (#{reason}) — keeping the current options, restore continuing"
        )

        {:ok, nil}
    end
  end

  # Never fails the op: the update has already succeeded, and the likely
  # failure is the engine refusing an image another container still uses.
  defp step(:reclaim_image, %{old: old, config: new} = input) do
    opts = opts(input)
    old_ref = build_spec(old, opts).image

    if old_ref && old_ref != build_spec(new, opts).image do
      case backend(opts).remove_image(old_ref, []) do
        :ok -> Logger.info("Vagus.App.Steps: removed superseded image #{old_ref}")
        {:error, reason} -> Logger.info("Vagus.App.Steps: kept #{old_ref} (#{inspect(reason)})")
      end
    end

    {:ok, :ok}
  rescue
    error ->
      Logger.warning("Vagus.App.Steps: image reclaim skipped: #{inspect(error)}")
      {:ok, :ok}
  end

  # The container is already stopped (the step before). The panel push is
  # detached: Core may be slow or down, and the uninstall does not wait on it.
  # Discovery DELETEs are the app process's, queued before the stop.
  defp step(:remove_app, %{config: config} = input) do
    opts = opts(input)
    remove_image_best_effort(config, opts)
    maybe_push_panel(config, opts)

    case remove_data_dir(config.slug, opts) do
      :ok -> {:ok, :ok}
      {:error, reason} -> {:error, reason}
    end
  end

  # The walk lstats each entry and then reads it; frozen, nothing in the
  # container can swap a file for a symlink in between. A failed unpause does
  # not fail the snapshot: the tar is whole. It is returned beside the tar's
  # result, so the operation can thaw the app again before it ends.
  defp frozen(config, opts, tar) do
    id = container_name(config.slug)

    case backend(opts).pause(id, opts) do
      :ok ->
        tar_thawed(id, opts, tar)

      # An app wanted started but not yet adopted may have no container.
      {:error, {:http, 404}} ->
        {tar.(), :ok}

      # The engine's 409 is either "not running" or "already paused": a
      # paused one is frozen all the same, and must still be thawed. Only a
      # state that rules out a pause tars unthawed; anything else fails the
      # snapshot, so the operation thaws whatever may be paused.
      {:error, {:http, 409}} ->
        case backend(opts).state(id) do
          {:ok, :paused} -> tar_thawed(id, opts, tar)
          {:ok, state} when state in [:stopped, :unknown] -> {tar.(), :ok}
          {:ok, state} -> {{:error, {:pause, {:conflict, state}}}, :ok}
          {:error, reason} -> {{:error, {:pause, reason}}, :ok}
        end

      {:error, reason} ->
        {{:error, {:pause, reason}}, :ok}
    end
  end

  defp tar_thawed(id, opts, tar) do
    tar.()
  catch
    kind, reason ->
      thaw(id, opts)
      :erlang.raise(kind, reason, __STACKTRACE__)
  else
    tarred -> {tarred, thaw(id, opts)}
  end

  # A 409 is a container that is not paused, and a 404 one that is gone:
  # either way nothing is frozen, which is what was asked.
  defp thaw(id, opts) do
    case backend(opts).unpause(id, opts) do
      :ok ->
        :ok

      {:error, {:http, status}} when status in [404, 409] ->
        :not_paused

      {:error, reason} = error ->
        Logger.error("Vagus.App.Steps: unpause #{id} failed: #{inspect(reason)}")
        error
    end
  end

  # The engine refuses to stop a paused container with a 409: a snapshot task
  # killed by its deadline, a halt or its process dying leaves one paused, so
  # it is thawed and stopped once more.

  defp stop_thawed(id, opts) do
    with {:error, {:http, 409}} <- backend(opts).stop(id, opts) do
      Logger.warning("Vagus.App.Steps: #{id} refused to stop; unpausing it and stopping again")
      thaw(id, opts)
      backend(opts).stop(id, opts)
    end
  end

  # `addon.json`'s `system` block. A restoring HAOS validates it against
  # `SCHEMA_APP_SYSTEM` (the app config schema plus a required `repository`)
  # and uses it to find the image of an app the target lacks. Only keys whose
  # parsed shape is the wire shape are emitted: upstream defaults an absent
  # optional key, where a wrong shape fails the schema.
  defp system_map(config) do
    system = %{
      "name" => config.name,
      "version" => config.version,
      "slug" => config.slug,
      "description" => config.description,
      "arch" => config.arch,
      "startup" => config.startup,
      "boot" => config.boot,
      "init" => config.init,
      "repository" => repository_of(config.slug)
    }

    if config.image, do: Map.put(system, "image", config.image), else: system
  end

  # An app no longer in any repository falls back to `"core"`, which the info
  # payload already claims for every installed app.
  defp repository_of(slug) do
    case Store.get(slug) do
      {:ok, %{repository: repository}} when is_binary(repository) -> repository
      _absent_or_unshaped -> "core"
    end
  end

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp set_aside(data_dir, aside) do
    case File.rename(data_dir, aside) do
      {:error, :enoent} -> :ok
      result -> result
    end
  end

  defp restore_sibling(staging, data_dir, slug) do
    sibling? =
      Path.dirname(staging) == Path.dirname(data_dir) and
        Regex.match?(~r/\A\.restore-#{Regex.escape(slug)}-\d+\z/, Path.basename(staging))

    if sibling?, do: :ok, else: {:error, :bad_staging}
  end

  # An `:enoent` rename back is an app that had no data dir to set aside.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp swap_in(staging, data_dir, aside) do
    with {:error, _reason} = error <- File.rename(staging, data_dir) do
      case File.rename(aside, data_dir) do
        {:error, reason} when reason != :enoent ->
          Logger.error(
            "Vagus.App.Steps: #{data_dir} was not moved back after a failed swap " <>
              "(#{inspect(reason)}); its data is at #{aside}"
          )

        _restored ->
          :ok
      end

      error
    end
  end

  defp opts(input),
    do:
      input
      |> Map.take([:backend, :data_root, :socket, :panels, :required_dsp_nodes, :arch])
      |> Keyword.new()
      |> put_backend(input.config)

  # A native app's address is the supervisor anchor its broker listens on.
  # A container's is read once here; a failed inspect leaves no DNS record
  # and no ingress target, and the app still runs.
  defp started(%Config{} = config, id, opts) do
    if native?(config) do
      %{
        container_id: id,
        ip: Network.supervisor_ip(),
        pid: Process.whereis(Native.broker_name(id))
      }
    else
      inspect_started(config, id, opts)
    end
  end

  defp inspect_started(config, id, opts) do
    case Vagus.Runtime.Docker.inspect_container(id, network_opts(opts)) do
      {:ok, info} ->
        %{container_id: id, ip: bridge_ip(config, info), healthcheck: healthcheck?(info)}

      {:error, _reason} ->
        %{container_id: id, ip: nil, healthcheck: false}
    end
  rescue
    e ->
      Logger.warning("Vagus.App.Steps: inspect of #{config.slug} failed: #{inspect(e)}")
      %{container_id: id, ip: nil, healthcheck: false}
  end

  defp bridge_ip(%Config{host_network: true}, _info), do: nil

  defp bridge_ip(_config, %{"NetworkSettings" => %{"Networks" => networks}}) do
    case Map.get(networks, Network.name()) do
      %{"IPAddress" => ip} when is_binary(ip) and ip != "" -> ip
      _ -> nil
    end
  end

  defp bridge_ip(_config, _info), do: nil

  # Upstream reports `startup` until the first healthy event only for an
  # image that declares a healthcheck.
  defp healthcheck?(%{"Config" => %{"Healthcheck" => %{"Test" => [first | _]}}}),
    do: first != "NONE"

  defp healthcheck?(_info), do: false

  defp pick_port(_directory, _probe, _rand, 0), do: {:error, :no_free_port}

  defp pick_port(directory, probe, rand, tries) do
    port = rand.()

    if Registry.lookup(directory, {:ingress_port, port}) != [] or
         probe.(Network.gateway(), port) == :listening,
       do: pick_port(directory, probe, rand, tries - 1),
       else: {:ok, port}
  end

  # Upstream's `check_port`: a connect that succeeds means something listens.
  defp listening?(ip, port) do
    case :gen_tcp.connect(String.to_charlist(ip), port, [active: false], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :listening

      {:error, _reason} ->
        :free
    end
  end

  @doc "Whether `config` runs in-BEAM: only a first-party allowlisted slug may."
  @spec native?(Config.t() | nil) :: boolean()
  def native?(%Config{backend: :native, slug: slug}), do: native_allowed?(slug)
  def native?(_config), do: false

  @spec native_allowed?(String.t()) :: boolean()
  def native_allowed?(slug),
    do: slug in Application.get_env(:vagus, :native_addon_slugs, ["core_mqtt"])

  # A container named `addon_<slug>` may already exist — e.g. after a device
  # reboot or emulator restart, the previous session's container survives while
  # the in-memory add-on state does not, and `create` would 409 on the fixed
  # name. The real Supervisor's `DockerInterface.run` stops+removes any
  # existing container before creating (§A1.4 — no restart policy, the manager
  # owns the lifecycle), so do the same, tolerantly (absent/not-running is fine).
  # Through `stop_thawed/2`: a container a snapshot left paused refuses the
  # stop, and boot replaces one here, so it gets its graceful stop rather
  # than only the forced remove's kill.
  defp remove_stale_container(spec, opts) do
    _ = stop_thawed(spec.name, Keyword.take(opts, [:backend]))
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
      name: container_name(config.slug),
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
  # `ensure_mount_sources/1` — an empty bind means direct QNN dies at device
  # creation on start; an add-on that instead wraps QNN with its own CPU
  # fallback would run the whole session silently on the CPU reporting
  # success. Either way the operator sees a broken add-on, not missing setup,
  # which is the failure this flag exists to prevent. A create-time refusal is
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
        Logger.warning("Vagus.App.Steps: unknown map type '#{type}', skipping")
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
  # version rescan, and an app's restart ladder can drive starts in a loop.
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

  # The data dir is bound at the app's `/data`, so the app owns every entry in
  # it and can make `options.json` a symlink to anywhere on the host. The leaf
  # is therefore never opened by name: the options go to a fresh file created
  # with O_EXCL (which refuses any existing entry, a symlink included) and are
  # renamed over `options.json`, which replaces whatever entry is there rather
  # than following it. The directory itself is the bind source, which the
  # container cannot replace, so the app keeps reading `/data/options.json`.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp write_options(config, data_root, user_options) do
    case OptionsSchema.effective(config.schema, config.options, user_options) do
      {:ok, options} ->
        dir = data_dir(data_root, config.slug)
        tmp = Path.join(dir, ".options-#{Base.url_encode64(:crypto.strong_rand_bytes(12))}")

        with :ok <- File.mkdir_p(dir),
             :ok <- write_new(tmp, Jason.encode!(options)),
             :ok <- File.rename(tmp, Path.join(dir, "options.json")) do
          :ok
        else
          {:error, reason} ->
            _ = File.rm(tmp)
            {:error, {:write_options, reason}}
        end

      {:error, reason} ->
        {:error, {:invalid_options, reason}}
    end
  end

  # Raw, so a full disk is an `{:error, reason}` here rather than a raise.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_new(path, content) do
    with {:ok, fd} <- :file.open(path, [:write, :binary, :exclusive, :raw]) do
      case {:file.write(fd, content), :file.close(fd)} do
        {:ok, close} -> close
        {error, _close} -> error
      end
    end
  end

  defp data_dir(data_root, slug), do: Path.join([data_root, "addons", "data", slug])

  # An absent or stopped container is success; otherwise a failing daemon must
  # not keep a stop from completing, unless the stop is strict. A failed
  # remove leaves the container stopped, so it is tolerated either way.
  defp stop_and_remove_container(id, opts, strict?) do
    with :ok <- stop_container(id, opts, strict?) do
      with {:error, reason} <- backend(opts).remove(id, opts),
           do:
             Logger.warning(
               "Vagus.App.Steps: remove #{id} failed (tolerated): #{inspect(reason)}"
             )

      :ok
    end
  end

  defp stop_container(id, opts, strict?) do
    case stop_thawed(id, opts) do
      result when result in [:ok, {:error, {:http, 404}}] ->
        :ok

      {:error, reason} = error when strict? ->
        Logger.error("Vagus.App.Steps: stop #{id} failed: #{inspect(reason)}")
        error

      {:error, reason} ->
        Logger.warning("Vagus.App.Steps: stop #{id} failed (tolerated): #{inspect(reason)}")
        :ok
    end
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
              "Vagus.App.Steps: remove image #{image} failed (tolerated): #{inspect(reason)}"
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

  # A restore's aside goes first: one that outlived the data dir (its drop
  # failed, or the restore's start did before it) is what the boot sweep
  # would move back as the app's only copy.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_data_dir(slug, opts) do
    if Config.valid_slug?(slug) do
      parent = Path.join([data_root(opts), "addons", "data"])

      asides =
        for path <- Path.wildcard(Path.join(parent, ".restore-*.old"), match_dot: true),
            Regex.match?(~r/\A\.restore-#{Regex.escape(slug)}-\d+\.old\z/, Path.basename(path)),
            do: path

      Enum.reduce_while(asides ++ [Path.join(parent, slug)], :ok, fn path, :ok ->
        case File.rm_rf(path) do
          {:ok, _removed} -> {:cont, :ok}
          {:error, reason, failed} -> {:halt, {:error, {:remove_data_dir, failed, reason}}}
        end
      end)
    else
      Logger.warning(
        "Vagus.App.Steps: refusing to rm_rf the data dir for unsafe slug #{inspect(slug)}"
      )

      {:error, {:invalid_slug, slug}}
    end
  end

  # Uninstall only, as upstream: Core answers a push for a panel it already
  # holds with a 500 and a traceback in its log, and registers every enabled
  # panel itself at startup. Always a DELETE: the app's own process still
  # answers `info` while this runs, so letting `Panels` choose would read the
  # panel as still enabled.
  defp maybe_push_panel(%Config{ingress: true, slug: slug}, opts) do
    panels(opts).update_hass_panel(slug, method: :delete)
    :ok
  end

  defp maybe_push_panel(_config, _opts), do: :ok

  defp panels(opts), do: Keyword.get(opts, :panels, Panels)

  defp container_name(slug), do: "addon_#{slug}"

  defp data_root(opts),
    do:
      Keyword.get(
        opts,
        :data_root,
        Application.get_env(:vagus, :addon_data_root, @default_data_root)
      )
end
