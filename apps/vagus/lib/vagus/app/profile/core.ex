defmodule Vagus.App.Profile.Core do
  @moduledoc """
  Home Assistant Core: one container, kept across stops and reused while it
  still matches what would be made, restarted by the engine.

  The container is named `homeassistant` whatever the app is called: the
  other firmware slot finds Core by that name.

  This module says what Core's lifecycle is and nothing of how. Its
  container config, the fingerprint `reuse/0` compares and the steps
  `hooks/0` names are none of this module's, and a Core spec carries
  `fields/0` and nothing else.
  """

  @behaviour Vagus.App.Profile

  @container "homeassistant"
  @wave 40

  @impl true
  def fields, do: [:lifecycle, :version, :run, :restart_counter, :start_counter, :holds]

  @impl true
  def settings, do: %{}

  @impl true
  def backend, do: Vagus.App.Backend.Container

  @impl true
  def container_name(_app), do: @container

  @impl true
  def on_stop, do: :keep

  @impl true
  def reuse, do: :fingerprint

  @impl true
  def engine_restart, do: "unless-stopped"

  # The engine heals a single crash. What is acted on is restarts that do
  # not stick.
  @impl true
  def restart_policy(_spec) do
    {:crash_loop,
     %{
       restarts: 3,
       window_ms: :timer.minutes(10),
       max_actions: 10,
       action_window_ms: :timer.minutes(30)
     }}
  end

  @impl true
  def readiness(_spec), do: %{kind: {:http, "/manifest.json"}, deadline_ms: :timer.minutes(10)}

  @impl true
  def stop_grace(_spec), do: {:image_env, "S6_SERVICES_GRACETIME", 20}

  @impl true
  def hooks, do: [:port_migration, :safe_mode, :http_config_refresh, :socket_unlink]

  @impl true
  def boot(_spec), do: :always

  @impl true
  def wave(_spec), do: @wave

  @impl true
  def wave_wait_ms(_spec), do: Vagus.App.Profile.default_wave_wait_ms()

  @impl true
  def token, do: :supervisor

  @impl true
  def backup(_spec), do: :excluded
end
