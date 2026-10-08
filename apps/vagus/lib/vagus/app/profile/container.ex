defmodule Vagus.App.Profile.Container do
  @moduledoc """
  An app from a store manifest, run as the container `app_<slug>`. The
  container is made for each start and removed by each stop, so it has no
  engine restart policy and nothing of it is ever reused.
  """

  @behaviour Vagus.App.Profile

  alias Vagus.Addon.Config
  alias Vagus.App.Profile

  @impl true
  def fields do
    [
      :lifecycle,
      :config,
      :version,
      :options,
      :settings,
      :ingress_port,
      :run,
      :restart_counter,
      :start_counter,
      :holds
    ]
  end

  @impl true
  def settings do
    %{
      ports: %{},
      protected: true,
      watchdog: false,
      boot: nil,
      ingress_panel: false,
      auto_update: nil
    }
  end

  @impl true
  def backend, do: Vagus.App.Backend.Container

  @impl true
  def container_name(app), do: "app_" <> app

  @impl true
  def on_stop, do: :remove

  @impl true
  def reuse, do: :never

  @impl true
  def engine_restart, do: ""

  # A run-once app that has exited has done what it was for.
  @impl true
  def restart_policy(%{config: %Config{startup: "once"}}), do: :never
  def restart_policy(%{settings: %{watchdog: true}}), do: Profile.watchdog_budget()
  def restart_policy(_spec), do: :never

  @impl true
  def readiness(_spec), do: %{kind: :container, deadline_ms: :infinity}

  @impl true
  def stop_grace(_spec), do: :default

  @impl true
  def hooks, do: []

  @impl true
  def boot(%{config: %Config{} = config, settings: settings}) do
    case Config.effective_boot(config, Map.get(settings, :boot)) do
      "auto" -> :auto
      _manual -> :manual
    end
  end

  @impl true
  def wave(%{config: %Config{startup: startup}}), do: Profile.wave_of_startup(startup)

  @impl true
  def wave_wait_ms(_spec), do: Profile.default_wave_wait_ms()

  @impl true
  def token, do: :minted

  @impl true
  def backup(%{config: %Config{backup: "cold"}}), do: :cold
  def backup(_spec), do: :hot
end
