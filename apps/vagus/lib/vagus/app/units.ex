defmodule Vagus.App.Units do
  @moduledoc """
  The side effects `Vagus.App.Orchestrator` sequences, one function each, so
  the orchestrator holds only the order and a test can swap any of them.
  """

  require Logger

  alias Vagus.Addon.Config
  alias Vagus.Addon.Store.BuiltinFetcher
  alias Vagus.App
  alias Vagus.App.{CoreUnit, Gates, Instances, Steps}
  alias Vagus.App.File, as: AppFile
  alias Vagus.Core.{EventPusher, Events}
  alias Vagus.Runtime.Engine
  alias Vagus.Runtime.Engine.Container

  @spec all() :: map()
  def all do
    %{
      import: &import/0,
      slugs: &App.slugs/0,
      list: &App.list/0,
      ensure: &ensure/1,
      in_flight?: &Vagus.Host.Shutdown.in_flight?/0,
      install_default: &install_default/1,
      builtin_native?: &builtin_native?/1,
      native?: &native?/1,
      boot_start: &App.boot_start/2,
      start: &App.start/1,
      running: &running/0,
      inspect: &running?/1,
      halt: &App.halt/1,
      stop_containers: &stop_containers/2,
      agent?: &Vagus.Flavor.agent?/0,
      core_start: &CoreUnit.start(deadline: &1),
      core_stop: &CoreUnit.stop(deadline: &1),
      gates: Gates.all(),
      report: &report/2,
      push_complete: &push_complete/0
    }
  end

  # A failed import must not keep the apps already imported from booting.
  @spec import() :: :ok
  def import do
    AppFile.import_once()
    :ok
  rescue
    exception -> Logger.error("Apps not imported: #{Exception.message(exception)}")
  end

  # Only the first boot in a VM can find staging an earlier VM left with no
  # backup still writing it. A later one is the orchestrator restarted alone,
  # under app processes that may be mid-backup or mid-restore: wiping their
  # live staging loses a backup or fails a swap, where an orphan costs only
  # disk until reboot.
  @swept {__MODULE__, :swept}

  # Boot must go on without the sweep.
  @spec sweep() :: :ok
  def sweep do
    unless :persistent_term.get(@swept, false) do
      :persistent_term.put(@swept, true)
      Vagus.Backups.sweep_stale()
    end

    :ok
  rescue
    exception -> Logger.error("Stale backup staging not swept: #{Exception.message(exception)}")
  end

  # Always `:ok`: one app whose process cannot start is logged, and must not
  # take the others down with it.
  @spec ensure(String.t()) :: :ok
  def ensure(slug) do
    case Instances.ensure(slug) do
      {:error, reason} -> Logger.warning("App #{slug} process did not start: #{inspect(reason)}")
      _started_or_gone -> :ok
    end
  end

  @doc """
  A fresh install is wanted started, so boot starts it; a present one is left
  as the user set it, except that a container one gets its protected settings
  back (`install_settings/1`).
  """
  @spec install_default(String.t()) :: :installed | :present | {:error, term()}
  def install_default(slug) do
    cond do
      slug in App.slugs() ->
        ensure_settings(slug)
        :present

      # Its file would create the apps directory, and a legacy file whose
      # import failed would count as imported at the next boot.
      not File.dir?(AppFile.dir()) ->
        {:error, :not_imported}

      true ->
        with {:ok, config} <- builtin_config(slug),
             :ok <- App.install(config, wanted: :started, settings: install_settings(config)),
             do: :installed
    end
  end

  # A container default app is revived after a crash and started at boot,
  # which a request cannot later change for a protected app (`App.set/2`).
  # The native broker is revived by its boot rule alone (`Policy.restart?/2`).
  defp install_settings(config) do
    if Steps.native?(config), do: [], else: [boot: "auto", watchdog: true]
  end

  # A protected app installed before it was protected, or by a store install,
  # lacks them, and `App.set/2` refuses them to every request.
  defp ensure_settings(slug) do
    with {:ok, config} <- builtin_config(slug),
         [_ | _] = settings <- install_settings(config),
         {:ok, entry} <- App.info(slug),
         [_ | _] = stale <- Enum.reject(settings, fn {key, value} -> entry[key] == value end),
         :error <- App.put_settings(slug, stale) do
      Logger.warning("Boot: default app #{slug} settings #{inspect(stale)} not written")
    end
  end

  @doc "Whether a default app's builtin config runs natively; one with none is not."
  @spec builtin_native?(String.t()) :: boolean()
  def builtin_native?(slug) do
    case builtin_config(slug) do
      {:ok, config} -> Steps.native?(config)
      {:error, _reason} -> false
    end
  end

  # No `watchdog`: in a config it is the URL a probe checks, and this app
  # serves none; the crash-restart flag is a per-install setting.
  @agent_orchestrator %{
    "name" => "Agent orchestrator",
    "version" => "0.1.0",
    "slug" => "agent_orchestrator",
    "description" => "Claude Code orchestrator for the agent-dev-board, on the board's own node.",
    "arch" => ["aarch64"],
    "image" => "ghcr.io/bbangert/vagus-agent-orchestrator",
    "startup" => "application",
    "boot" => "auto",
    "init" => false,
    "host_network" => true,
    "host_dbus" => true
  }

  # Cold, not a hot tar: a tar of a live cluster's PGDATA is not restorable,
  # and pg_dump plus `backup_exclude` would need the exclude applied, which
  # backups do not do yet. Its env is a per-slug hook (`Vagus.App.Steps`).
  # The watchdog dials Postgres's port, so a hung server is restarted.
  @agent_memory %{
    "name" => "Agent memory",
    "version" => "pg17",
    "slug" => "agent_memory",
    "description" => "Postgres 17 with pgvector: the agents' memory, on the board-only agentnet.",
    "arch" => ["aarch64"],
    "image" => "docker.io/pgvector/pgvector",
    "startup" => "application",
    "boot" => "auto",
    "init" => false,
    "watchdog" => "tcp://[HOST]:5432",
    "backup" => "cold"
  }

  # Native, so it runs only where `:native_addon_slugs` allows it (the agent
  # flavor); its image is a placeholder that is never pulled.
  @vagus_memory %{
    "name" => "Agent memory server",
    "version" => "1.0.0",
    "slug" => "vagus_memory",
    "description" => "MCP memory tools for the board's containers, over the agent memory DB.",
    "arch" => ["amd64", "aarch64", "armv7", "armhf", "i386"],
    "backend" => "native",
    "image" => "local/vagus_memory",
    "startup" => "services",
    "boot" => "auto",
    "init" => false,
    "host_network" => false,
    "options" => %{},
    "schema" => %{}
  }

  @doc """
  A default app's config, embedded so boot needs no store reload. The mqttx
  broker's is the store's own source, under the installed slug as the
  store-install route writes it.
  """
  @spec builtin_config(String.t()) :: {:ok, Config.t()} | {:error, term()}
  def builtin_config("agent_orchestrator"), do: Config.parse(@agent_orchestrator)
  def builtin_config("agent_memory"), do: Config.parse(@agent_memory)
  def builtin_config("vagus_memory"), do: Config.parse(@vagus_memory)

  def builtin_config("core_mqtt" = slug) do
    with {:ok, config} <- Config.parse(BuiltinFetcher.config(:mqtt)),
         do: {:ok, %{config | slug: slug}}
  end

  def builtin_config(_slug), do: {:error, :no_builtin}

  # The allowlist and not the config's `backend` tag alone: a non-allowlisted
  # `backend: native` config runs in a container, which must still be halted.
  @spec native?(map()) :: boolean()
  def native?(%{config: config}), do: Steps.native?(config)
  def native?(_entry), do: false

  @doc "The slugs whose container the engine reports running; one listing for the whole boot."
  @spec running(keyword()) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def running(opts \\ []) do
    with {:ok, containers} <- Engine.list([name_prefix: "addon_"] ++ opts) do
      {:ok, MapSet.new(for %{name: "addon_" <> slug} <- containers, do: slug)}
    end
  end

  @spec running?(String.t(), keyword()) :: boolean() | :unknown
  def running?(slug, opts \\ []) do
    case Engine.inspect("addon_" <> slug, opts) do
      {:ok, container} -> Container.alive?(container)
      {:error, :not_found} -> false
      _unknown -> :unknown
    end
  end

  @doc """
  One engine call that stops a group's containers together, ahead of their
  halts: each app's own `stop` is a podman process, and a frugal board's
  two `:ops` permits would queue a group's stops past its budget.
  `Engine.Podman.stop_all/3` takes the reserved shutdown permit.

  The grace is what fits the budget once podman's kill margin is set aside
  (`grace_s/1`): podman gives a stop its grace plus that margin whatever
  `timeout_ms` says, so a longer grace would outlast the budget and be cut
  off unkilled.
  """
  @spec stop_containers([String.t()], non_neg_integer(), keyword()) ::
          {:ok, [String.t()], [{String.t(), term()}]}
  def stop_containers(slugs, budget_ms, opts \\ []) do
    names = for slug <- slugs, do: "addon_" <> slug
    Engine.stop_all(names, grace_s(budget_ms), [timeout_ms: budget_ms] ++ opts)
  end

  @doc "The longest grace whose stop, kill margin included, ends within `budget_ms`."
  @spec grace_s(non_neg_integer()) :: non_neg_integer()
  def grace_s(budget_ms),
    do: min(max(div(budget_ms - Engine.Podman.stop_margin_ms(), 1000), 0), Steps.halt_timeout_s())

  @spec report(atom(), [{String.t(), :ready | :failed | :pending}]) :: :ok
  def report(step, outcomes) do
    case for {slug, outcome} <- outcomes, outcome != :ready, do: {slug, outcome} do
      [] -> Logger.info("Boot: #{step} ready (#{length(outcomes)})")
      late -> Logger.warning("Boot: #{step} carried on without #{inspect(late)}")
    end
  end

  @spec push_complete(GenServer.server()) :: :ok
  def push_complete(pusher \\ EventPusher) do
    "supervisor"
    |> Events.supervisor_update(%{"startup" => "complete"})
    |> EventPusher.push(pusher)
  end
end
