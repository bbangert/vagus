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
  alias Vagus.Runtime.Docker

  @spec all() :: map()
  def all do
    %{
      import: &import/0,
      sweep: &sweep/0,
      slugs: &App.slugs/0,
      list: &App.list/0,
      ensure: &ensure/1,
      in_flight?: &Vagus.Host.Shutdown.in_flight?/0,
      install_default: &install_default/1,
      native?: &native?/1,
      boot_start: &App.boot_start/2,
      running: &running/0,
      inspect: &running?/1,
      halt: &App.halt/1,
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

  # Once per VM: a boot re-run by an orchestrator restart or a resume can
  # find backups and restores in flight, and wiping their staging loses a
  # backup or fails a swap, where an orphan costs only disk until reboot.
  # Boot must go on without it.
  @spec sweep() :: :ok
  def sweep do
    unless :persistent_term.get({__MODULE__, :swept}, false) do
      Vagus.Backups.sweep_stale()
      :persistent_term.put({__MODULE__, :swept}, true)
    end

    :ok
  rescue
    exception -> Logger.error("Stale backup staging not swept: #{Exception.message(exception)}")
  end

  # One app whose process cannot start must not take the others down with it.
  @spec ensure(String.t()) :: :ok
  def ensure(slug) do
    case Instances.ensure(slug) do
      {:error, reason} -> Logger.warning("App #{slug} process did not start: #{inspect(reason)}")
      _started_or_gone -> :ok
    end
  end

  @doc "A fresh install is wanted started, so boot starts it; a present one is left as the user set it."
  @spec install_default(String.t()) :: :installed | :present | {:error, term()}
  def install_default(slug) do
    cond do
      slug in App.slugs() ->
        :present

      # Its file would create the apps directory, and a legacy file whose
      # import failed would count as imported at the next boot.
      not File.dir?(AppFile.dir()) ->
        {:error, :not_imported}

      true ->
        with {:ok, config} <- builtin_config(slug),
             :ok <- App.install(config, wanted: :started),
             do: :installed
    end
  end

  # The only builtin native app is the mqttx broker. Its config comes from the
  # embedded source, so boot needs no store reload, under the installed slug
  # as the store-install route writes it.
  defp builtin_config(slug) do
    case BuiltinFetcher.config(:mqtt) do
      nil -> {:error, :no_builtin}
      raw -> with {:ok, config} <- Config.parse(raw), do: {:ok, %{config | slug: slug}}
    end
  end

  # The allowlist and not the config's `backend` tag alone: a non-allowlisted
  # `backend: native` config runs in a container, which must still be halted.
  @spec native?(map()) :: boolean()
  def native?(%{config: config}), do: Steps.native?(config)
  def native?(_entry), do: false

  @doc "The slugs whose container the engine reports running; one listing for the whole boot."
  @spec running(keyword()) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def running(opts \\ []) do
    with {:ok, containers} <- Docker.list_containers(opts) do
      slugs =
        for %{"Names" => names} = container <- containers, "/addon_" <> slug <- names do
          if container["State"] == "paused", do: thaw(slug, opts)
          slug
        end

      {:ok, MapSet.new(slugs)}
    end
  end

  @spec running?(String.t(), keyword()) :: boolean() | :unknown
  def running?(slug, opts \\ []) do
    case Docker.inspect_container("addon_" <> slug, opts) do
      {:ok, %{"State" => %{"Running" => running} = state}} ->
        if state["Paused"] == true, do: thaw(slug, opts)
        running == true

      {:error, {:http, 404, _message}} ->
        false

      _unknown ->
        :unknown
    end
  end

  # A snapshot whose app process died left it paused: frozen, it hangs its
  # watchdog probe and the engine refuses to stop it. A paused container
  # still counts as running.
  defp thaw(slug, opts) do
    case Docker.unpause_container("addon_" <> slug, opts) do
      :ok ->
        Logger.warning("Boot: #{slug}'s container was left paused; unpaused")

      {:error, reason} ->
        Logger.error(
          "Boot: #{slug}'s container is paused and did not unpause: #{inspect(reason)}"
        )
    end
  end

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
