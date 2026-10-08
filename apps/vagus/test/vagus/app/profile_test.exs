defmodule Vagus.App.ProfileTest do
  use ExUnit.Case, async: true

  alias Vagus.App.{Facts, Profile}
  alias Vagus.App.Spec.Schema
  alias Vagus.Test.AppManifests

  defp facts, do: Facts.read(arch: "aarch64", machine: "raspberrypi3-64")

  defp admitted(slug, fields \\ %{}) do
    config = AppManifests.get(slug)

    fields =
      if Schema.dynamic_ingress?(config),
        do: Map.put_new(fields, :ingress_port, 62_000),
        else: fields

    {:ok, spec} = config |> Schema.from_manifest(facts(), fields) |> Schema.validate(facts())
    spec
  end

  defp core do
    {:ok, spec} = Schema.validate(%{lifecycle: :core, version: "2026.10.1"}, facts())
    spec
  end

  defp answers(profile, app, spec) do
    %{
      backend: profile.backend(),
      container_name: profile.container_name(app),
      on_stop: profile.on_stop(),
      reuse: profile.reuse(),
      engine_restart: profile.engine_restart(),
      restart_policy: profile.restart_policy(spec),
      readiness: profile.readiness(spec),
      stop_grace: profile.stop_grace(spec),
      hooks: profile.hooks(),
      boot: profile.boot(spec),
      wave: profile.wave(spec),
      wave_wait_ms: profile.wave_wait_ms(spec),
      token: profile.token(),
      backup: profile.backup(spec)
    }
  end

  describe "the three profiles answer every question of the lifecycle table" do
    test "a store app is a container made for each start and removed by each stop" do
      spec = admitted("core_mosquitto")

      assert Profile.of(spec) == Profile.Container

      assert answers(Profile.Container, "core_mosquitto", spec) == %{
               backend: Vagus.App.Backend.Container,
               container_name: "app_core_mosquitto",
               on_stop: :remove,
               reuse: :never,
               engine_restart: "",
               restart_policy: :never,
               readiness: %{kind: :container, deadline_ms: :infinity},
               stop_grace: :default,
               hooks: [],
               boot: :auto,
               wave: 20,
               wave_wait_ms: 120_000,
               token: :minted,
               backup: :hot
             }
    end

    test "Core is kept, reused by fingerprint, restarted by the engine, and keeps its name" do
      spec = core()

      assert Profile.of(spec) == Profile.Core

      assert answers(Profile.Core, "homeassistant", spec) == %{
               backend: Vagus.App.Backend.Container,
               container_name: "homeassistant",
               on_stop: :keep,
               reuse: :fingerprint,
               engine_restart: "unless-stopped",
               restart_policy:
                 {:crash_loop,
                  %{restarts: 3, window_ms: 600_000, max_actions: 10, action_window_ms: 1_800_000}},
               readiness: %{kind: {:http, "/manifest.json"}, deadline_ms: 600_000},
               stop_grace: {:image_env, "S6_SERVICES_GRACETIME", 20},
               hooks: [:port_migration, :safe_mode, :http_config_refresh, :socket_unlink],
               boot: :always,
               wave: 40,
               wave_wait_ms: 120_000,
               token: :supervisor,
               backup: :excluded
             }
    end

    test "the native broker has no container, no image and no token" do
      spec = admitted("core_mqtt")

      assert Profile.of(spec) == Profile.Native

      assert answers(Profile.Native, "core_mqtt", spec) == %{
               backend: Vagus.App.Backend.Native,
               container_name: nil,
               on_stop: nil,
               reuse: nil,
               engine_restart: nil,
               restart_policy: Profile.watchdog_budget(),
               readiness: %{kind: :process, deadline_ms: :infinity},
               stop_grace: :default,
               hooks: [],
               boot: :auto,
               wave: 30,
               wave_wait_ms: 120_000,
               token: :none,
               backup: :native
             }
    end
  end

  describe "answers that depend on the spec" do
    test "the restart policy is the watchdog setting's, and a run-once app's is never" do
      budget =
        {:restart,
         %{
           attempts: 5,
           backoff_ms: 10_000,
           max_sequences: 10,
           sequence_window_ms: 1_800_000,
           reset_after_ms: 600_000
         }}

      on = admitted("core_mosquitto", %{settings: %{watchdog: true}})
      assert Profile.Container.restart_policy(on) == budget
      assert Profile.Container.restart_policy(admitted("core_mosquitto")) == :never
      assert Profile.Container.restart_policy(admitted("local_once")) == :never

      # Admission refuses the two together; the profile does not rely on it.
      once = admitted("local_once")
      once = %{once | settings: %{once.settings | watchdog: true}}
      assert Profile.Container.restart_policy(once) == :never

      off = admitted("core_mqtt", %{settings: %{watchdog: false}})
      assert Profile.Native.restart_policy(off) == :never
    end

    test "the wave is the manifest's startup stage" do
      waves =
        for startup <- ["initialize", "system", "services", "application", "once"] do
          config =
            AppManifests.parse!(%{
              "name" => "w",
              "version" => "1",
              "slug" => "w",
              "image" => "w",
              "startup" => startup
            })

          {:ok, spec} = config |> Schema.from_manifest(facts()) |> Schema.validate(facts())
          {startup, Profile.Container.wave(spec)}
        end

      assert waves == [
               {"initialize", 10},
               {"system", 20},
               {"services", 30},
               {"application", 50},
               {"once", 50}
             ]

      assert Profile.Core.wave(core()) == 40
    end

    test "boot is the user's choice unless the manifest allows only manual" do
      assert Profile.Container.boot(admitted("core_mosquitto")) == :auto
      assert Profile.Container.boot(admitted("elixir_probe")) == :manual

      manual = admitted("core_mosquitto", %{settings: %{boot: "manual"}})
      assert Profile.Container.boot(manual) == :manual

      auto = admitted("elixir_probe", %{settings: %{boot: "auto"}})
      assert Profile.Container.boot(auto) == :auto

      forced = admitted("local_once", %{settings: %{boot: "auto"}})
      assert Profile.Container.boot(forced) == :manual
    end

    test "Core's answers are the same whatever its spec says" do
      {:ok, other} =
        Schema.validate(
          %{
            lifecycle: :core,
            version: "dev",
            run: true,
            restart_counter: 9,
            holds: %{"u" => true}
          },
          facts()
        )

      assert answers(Profile.Core, "anything", other) ==
               answers(Profile.Core, "homeassistant", core())
    end

    test "a native app's wave is its manifest's, and nothing else of its spec changes an answer" do
      plain = admitted("core_mqtt")
      later = %{plain | config: %{plain.config | startup: "system"}}

      assert Profile.Native.wave(plain) == 30
      assert Profile.Native.wave(later) == 20

      differing = %{plain | run: true, options: %{"a" => 1}, restart_counter: 4}

      assert answers(Profile.Native, "core_mqtt", differing) ==
               answers(Profile.Native, "core_mqtt", plain)
    end

    test "a startup stage nobody knows is the last wave" do
      assert Profile.wave_of_startup("application") == 50

      for unknown <- ["later", "", nil, :system, 20],
          do: assert(Profile.wave_of_startup(unknown) == 50)
    end

    test "the backup rule is the manifest's" do
      assert Profile.Container.backup(admitted("local_dsp")) == :cold
    end
  end

  describe "app_of_container/1" do
    test "names the app of each kind of container, and of nothing else" do
      assert Profile.app_of_container("app_core_mosquitto") == "core_mosquitto"
      assert Profile.app_of_container("addon_core_mosquitto") == "core_mosquitto"
      assert Profile.app_of_container("homeassistant") == "homeassistant"
      assert Profile.app_of_container(Profile.Core.container_name("any")) == Profile.core_app()

      for other <- ["app_", "addon_", "hassio_dns", "xapp_a", "", nil, :app_a, 7] do
        assert Profile.app_of_container(other) == nil
      end
    end

    test "inverts the container profile's name" do
      for config <- AppManifests.containers() do
        name = Profile.Container.container_name(config.slug)
        assert Profile.app_of_container(name) == config.slug
      end
    end
  end

  test "fetch/1 knows the three tags and nothing else" do
    assert Enum.map(Profile.tags(), &Profile.fetch/1) == [
             {:ok, Profile.Container},
             {:ok, Profile.Core},
             {:ok, Profile.Native}
           ]

    for other <- [:microvm, nil, "container", 1], do: assert(Profile.fetch(other) == :error)
  end
end
