defmodule Vagus.App.Profile.Native do
  @moduledoc """
  An app that runs inside the VM: the MQTT broker. There is no container,
  no image and no token, so every question about one is answered `nil`.
  """

  @behaviour Vagus.App.Profile

  alias Vagus.Addon.Config
  alias Vagus.App.Profile

  @impl true
  def fields,
    do: [
      :lifecycle,
      :config,
      :version,
      :options,
      :settings,
      :run,
      :restart_counter,
      :start_counter,
      :holds
    ]

  # On, where a container's is off: nothing else brings the broker back, and
  # every other app's MQTT depends on it.
  @impl true
  def settings, do: %{watchdog: true}

  @impl true
  def backend, do: Vagus.App.Backend.Native

  @impl true
  def container_name(_app), do: nil

  @impl true
  def on_stop, do: nil

  @impl true
  def reuse, do: nil

  @impl true
  def engine_restart, do: nil

  @impl true
  def restart_policy(%{settings: %{watchdog: true}}), do: Profile.watchdog_budget()
  def restart_policy(_spec), do: :never

  @impl true
  def readiness(_spec), do: %{kind: :process, deadline_ms: :infinity}

  @impl true
  def stop_grace(_spec), do: :default

  @impl true
  def hooks, do: []

  @impl true
  def boot(_spec), do: :auto

  @impl true
  def wave(%{config: %Config{startup: startup}}), do: Profile.wave_of_startup(startup)

  @impl true
  def wave_wait_ms(_spec), do: Profile.default_wave_wait_ms()

  @impl true
  def token, do: :none

  @impl true
  def backup(_spec), do: :native
end
