defmodule Vagus.App.Units do
  @moduledoc """
  The side effects `Vagus.App.Orchestrator` sequences, one function each, so
  the orchestrator holds only the order and a test can swap any of them.
  """

  require Logger

  alias Vagus.Addon.Backend.{Container, Native}
  alias Vagus.Addon.{Config, Manager, State}
  alias Vagus.Addon.Store.BuiltinFetcher
  alias Vagus.App.{CoreUnit, Gates, Instances}
  alias Vagus.Core.{EventPusher, Events}

  @app_stop_s 30

  @spec all() :: map()
  def all do
    %{
      list: &State.list/0,
      install_default: &install_default/1,
      want_started: &want_started/1,
      native?: &native?/1,
      running?: &running?/1,
      start: &start/1,
      demote: &demote/1,
      stop: &stop/1,
      core_start: &CoreUnit.start(deadline: &1),
      core_stop: &CoreUnit.stop/0,
      gates: Gates.all(),
      report: &report/2,
      push_complete: &push_complete/0
    }
  end

  # One app whose process cannot start must not take the others down with it.
  @spec ensure(String.t()) :: :ok
  def ensure(slug) do
    case Instances.ensure(slug) do
      {:error, reason} -> Logger.warning("App #{slug} process did not start: #{inspect(reason)}")
      _started_or_gone -> :ok
    end
  end

  @spec install_default(String.t()) :: :installed | :present | {:error, term()}
  def install_default(slug) do
    case State.get(slug) do
      {:ok, _entry} ->
        :present

      :error ->
        with {:ok, config} <- builtin_config(slug), :ok <- Vagus.App.install(config) do
          :installed
        end
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

  @spec want_started(String.t()) :: :ok | :error
  def want_started(slug) do
    with {:ok, %{config: config}} <- State.get(slug), do: State.put(config, :started)
  end

  # The allowlist and not the config's `backend` tag alone: a non-allowlisted
  # `backend: native` config runs in a container, which must still be stopped.
  @spec native?(map()) :: boolean()
  def native?(%{config: %{backend: :native, slug: slug}}), do: Manager.native_allowed?(slug)
  def native?(_entry), do: false

  @spec running?(map()) :: boolean()
  def running?(%{config: %{slug: slug}} = entry) do
    backend = if native?(entry), do: Native, else: Container
    match?({:ok, :running}, backend.state("addon_" <> slug))
  end

  @spec start(String.t()) :: :ok | {:error, term()}
  def start(slug) do
    with {:ok, _started} <- Manager.start_slug(slug), do: :ok
  end

  @spec demote(map()) :: :ok
  def demote(%{config: config}), do: State.put(config, :stopped)

  # Not `Manager.stop/2`, which removes the container, and no State write:
  # a reboot must neither churn containers nor forget which apps ran.
  @spec stop(String.t()) :: :ok | {:error, term()}
  def stop(slug), do: Vagus.Runtime.Docker.stop_container("addon_" <> slug, timeout: @app_stop_s)

  @spec report(atom(), [{String.t(), :ready | :failed | :pending}]) :: :ok
  def report(step, outcomes) do
    case for {slug, outcome} <- outcomes, outcome != :ready, do: {slug, outcome} do
      [] -> Logger.info("Boot: #{step} ready (#{length(outcomes)})")
      late -> Logger.warning("Boot: #{step} carried on without #{inspect(late)}")
    end
  end

  @spec push_complete() :: :ok
  def push_complete do
    "supervisor" |> Events.supervisor_update(%{"startup" => "complete"}) |> EventPusher.push()
  end
end
