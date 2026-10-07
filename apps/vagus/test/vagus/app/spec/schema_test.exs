defmodule Vagus.App.Spec.SchemaTest do
  use ExUnit.Case, async: true

  alias Vagus.Addon.Config
  alias Vagus.App.{Facts, Profile}
  alias Vagus.App.Spec.Schema
  alias Vagus.Resource
  alias Vagus.Resource.{Persistence, Store, TestInstance}
  alias Vagus.Test.AppManifests

  # `Vagus.Addon.OptionsSchema` warns of every option a schema does not name.
  @moduletag :capture_log

  @facts Facts.read(
           arch: "aarch64",
           machine: "raspberrypi3-64",
           core_version: "2026.10.1",
           native_apps: ["core_mqtt"]
         )

  defp spec(slug, fields \\ %{}) do
    config = AppManifests.get(slug)

    fields =
      if Schema.dynamic_ingress?(config),
        do: Map.put_new(fields, :ingress_port, 62_000),
        else: fields

    Schema.from_manifest(config, @facts, fields)
  end

  defp admitted(slug, fields \\ %{}) do
    {:ok, spec} = Schema.validate(spec(slug, fields), @facts)
    spec
  end

  defp refused(spec, facts \\ @facts) do
    assert {:error, reason} = Schema.validate(spec, facts)
    reason
  end

  defp kinds do
    %{
      app: [
        validators: [&Schema.validate(&1, @facts)],
        writer_entries: Schema.writer_entries(),
        encode_spec: &Schema.encode_spec/1,
        decode_spec: &Schema.decode_spec/1
      ]
    }
  end

  # A spec as varied as admission lets it be, for one manifest.
  defp varied(config) do
    plain_map = fn ->
      for _ <- 1..:rand.uniform(3), into: %{}, do: {AppManifests.string(), AppManifests.plain()}
    end

    profile = Profile.of(%{lifecycle: Schema.lifecycle_for(config, @facts)})

    settings =
      %{
        ports:
          for(
            {port, _host} <- config.ports,
            into: %{},
            do: {port, AppManifests.pick([nil, 0, 1883, 65_535])}
          ),
        protected: AppManifests.pick([true, false]),
        watchdog: config.startup != "once" and AppManifests.pick([true, false]),
        boot: AppManifests.pick([nil, "auto", "manual"]),
        ingress_panel: AppManifests.pick([true, false]),
        auto_update: AppManifests.pick([nil, true, false])
      }
      |> Map.take(Map.keys(profile.settings()))

    fields = %{
      version: AppManifests.pick([config.version, "1.2.3-rc.1", "latest", "2026.10.0b3"]),
      settings: settings,
      run: AppManifests.pick([true, false]),
      restart_counter: :rand.uniform(1_000_000) - 1,
      start_counter: :rand.uniform(50) - 1,
      holds: AppManifests.pick([%{}, plain_map.()])
    }

    fields =
      if Schema.dynamic_ingress?(config),
        do: Map.put(fields, :ingress_port, 61_999 + :rand.uniform(3_501)),
        else: fields

    {:ok, spec} = config |> Schema.from_manifest(@facts, fields) |> Schema.validate(@facts)
    spec
  end

  defp through_json(spec),
    do: spec |> Schema.encode_spec() |> Jason.encode!() |> Jason.decode!() |> Schema.decode_spec()

  describe "what admission fills in" do
    test "a manifest alone is a whole spec, with the container profile's defaults" do
      config = AppManifests.get("core_mosquitto")

      assert Schema.validate(%{lifecycle: :container, config: config}, @facts) ==
               {:ok,
                %{
                  lifecycle: :container,
                  config: config,
                  version: "7.1.0",
                  options: %{},
                  settings: %{
                    ports: %{},
                    protected: true,
                    watchdog: false,
                    boot: nil,
                    ingress_panel: false,
                    auto_update: nil
                  },
                  ingress_port: nil,
                  run: false,
                  restart_counter: 0,
                  start_counter: 0,
                  holds: %{}
                }}
    end

    test "the native profile has its own settings and no ingress port" do
      config = AppManifests.native()

      assert {:ok, spec} = Schema.validate(%{lifecycle: :native, config: config}, @facts)
      assert spec.settings == %{watchdog: true}
      refute is_map_key(spec, :ingress_port)
      assert Enum.sort(Map.keys(spec)) == Enum.sort(Profile.Native.fields())
    end

    test "Core is a version and what commands write, and nothing of a manifest" do
      assert Schema.validate(%{lifecycle: :core, version: "2026.10.1"}, @facts) ==
               {:ok,
                %{
                  lifecycle: :core,
                  version: "2026.10.1",
                  run: false,
                  restart_counter: 0,
                  start_counter: 0,
                  holds: %{}
                }}
    end

    test "settings given are kept and the rest filled in; admitting twice changes nothing" do
      spec = admitted("core_mosquitto", %{settings: %{watchdog: true}, run: true})

      assert spec.settings.watchdog
      assert spec.settings.protected
      assert spec.run
      assert Schema.validate(spec, @facts) == {:ok, spec}
    end

    test "every manifest is admitted, as the profile its backend asks for" do
      for config <- AppManifests.all() do
        spec = admitted(config.slug)
        assert spec.lifecycle == if(config.slug == "core_mqtt", do: :native, else: :container)
        assert Schema.validate(spec, @facts) == {:ok, spec}
      end
    end
  end

  describe "what admission refuses" do
    test "a spec with no lifecycle, or one that is no profile" do
      assert refused(%{version: "1"}) == {:missing, :lifecycle}
      assert refused(%{lifecycle: :microvm}) == {:unknown_lifecycle, :microvm}
      assert refused(%{lifecycle: "container"}) == {:unknown_lifecycle, "container"}
    end

    test "a field its profile lacks, named, and the first of several by order" do
      assert refused(%{lifecycle: :core, version: "1", settings: %{}}) ==
               {:field_not_in_profile, :settings, :core}

      assert refused(%{lifecycle: :core, version: "1", options: %{}, config: nil}) ==
               {:field_not_in_profile, :config, :core}

      assert refused(spec("core_mqtt", %{ingress_port: 62_000})) ==
               {:field_not_in_profile, :ingress_port, :native}

      assert refused(spec("core_mosquitto", %{wave: 10})) ==
               {:field_not_in_profile, :wave, :container}
    end

    test "a setting its profile lacks" do
      assert refused(spec("core_mqtt", %{settings: %{boot: "manual"}})) ==
               {:setting_not_in_profile, :boot, :native}

      assert refused(spec("core_mosquitto", %{settings: %{nice: 5}})) ==
               {:setting_not_in_profile, :nice, :container}
    end

    test "a required field left out" do
      assert refused(%{lifecycle: :core}) == {:missing, :version}
      assert refused(%{lifecycle: :container}) == {:missing, :config}
      assert refused(%{lifecycle: :native, version: "1"}) == {:missing, :config}
    end

    test "each field of the wrong shape, by name" do
      rows = [
        config: %{"slug" => "x"},
        version: "has space",
        version: "",
        version: 7,
        options: %{atom: 1},
        options: %{"pid" => self()},
        options: [],
        settings: [],
        ingress_port: 0,
        ingress_port: 65_536,
        ingress_port: "8099",
        run: nil,
        restart_counter: -1,
        start_counter: 1.0,
        holds: %{hold: true},
        holds: %{"backup" => {:a, 1}},
        holds: nil
      ]

      for {field, value} <- rows do
        assert refused(spec("5c53de3b_esphome", %{field => value})) == {:malformed, field},
               "#{field}: #{inspect(value)}"
      end
    end

    test "each setting of the wrong shape, by name" do
      rows = [
        ports: %{"80/tcp" => "80"},
        ports: %{"80/tcp" => 65_536},
        ports: %{80 => 80},
        ports: [],
        protected: nil,
        watchdog: "yes",
        ingress_panel: 1,
        boot: "manual_only",
        boot: :auto,
        auto_update: "no"
      ]

      for {key, value} <- rows do
        assert refused(spec("core_mosquitto", %{settings: %{key => value}})) ==
                 {:malformed, {:settings, key}},
               "#{key}: #{inspect(value)}"
      end
    end

    test "a profile the manifest's backend is not, either way round" do
      native = AppManifests.native()

      assert refused(%{lifecycle: :container, config: native}) ==
               {:lifecycle_mismatch, :container}

      assert refused(%{lifecycle: :native, config: AppManifests.get("core_mosquitto")}) ==
               {:lifecycle_mismatch, :native}
    end

    test "the native profile for an app that is not one of ours, which runs unconfined" do
      foreign = %{AppManifests.native() | slug: "evil_mqtt"}
      foreign = AppManifests.parse!(Config.to_persistable(foreign))

      assert Schema.lifecycle_for(foreign, @facts) == :container
      assert refused(%{lifecycle: :native, config: foreign}) == {:lifecycle_mismatch, :native}

      nobody = %{@facts | native_apps: []}

      assert refused(%{lifecycle: :native, config: AppManifests.native()}, nobody) ==
               {:lifecycle_mismatch, :native}
    end

    test "a slug the system keeps for itself" do
      config = %{AppManifests.get("core_mosquitto") | slug: "vagus"}
      assert refused(%{lifecycle: :container, config: config}) == {:reserved_slug, "vagus"}
    end

    test "a manifest that would not read back as itself" do
      config = %{AppManifests.get("core_mosquitto") | timeout: "soon"}
      assert refused(%{lifecycle: :container, config: config}) == :config_not_persistable

      config = %{AppManifests.get("core_mosquitto") | map: [:share]}
      assert refused(%{lifecycle: :container, config: config}) == :config_not_persistable
    end

    test "a container app with no image" do
      config = AppManifests.parse!(%{"name" => "n", "version" => "1", "slug" => "local_build"})
      assert refused(%{lifecycle: :container, config: config}) == :no_image
    end

    test "an app this machine cannot run, by each of upstream's three reasons" do
      assert {:not_supported, :architecture, message} =
               refused(spec("core_mosquitto"), %{@facts | arch: "i386"})

      assert message ==
               "App Mosquitto broker not supported on this platform, supported architectures: " <>
                 "aarch64, amd64, armv7"

      assert {:not_supported, :machine_type, message} =
               refused(spec("local_dsp"), %{@facts | machine: "odroid-n2"})

      assert message =~ "supported machine types: generic-aarch64, raspberrypi3-64"

      assert {:not_supported, :home_assistant_version, message} =
               refused(spec("45df7312_zigbee2mqtt"), %{@facts | core_version: "2023.12.4"})

      assert message =~ "requires Home Assistant version 2024.1.0 or greater"
    end

    test "the first of the three that applies is the one named, as upstream orders them" do
      config =
        AppManifests.parse!(%{
          "name" => "n",
          "version" => "1",
          "slug" => "picky",
          "image" => "i",
          "arch" => ["amd64"],
          "machine" => ["qemux86-64"],
          "homeassistant" => "2030.1.0"
        })

      spec = %{lifecycle: :container, config: config}

      assert {:not_supported, :architecture, _} = refused(spec)
      assert {:not_supported, :machine_type, _} = refused(spec, %{@facts | arch: "amd64"})

      assert {:not_supported, :home_assistant_version, _} =
               refused(spec, %{@facts | arch: "amd64", machine: "qemux86-64"})
    end

    test "a Core version that is not known refuses nobody" do
      assert {:ok, _spec} =
               Schema.validate(spec("45df7312_zigbee2mqtt"), %{@facts | core_version: nil})
    end

    test "options the manifest's schema does not accept" do
      assert {:invalid_options, message} =
               refused(spec("local.Init-1", %{options: %{"level" => 9}}))

      assert message =~ "level"

      assert {:invalid_options, _} =
               refused(spec("core_mosquitto", %{options: %{"require_certificate" => "maybe"}}))

      assert {:ok, _} =
               Schema.validate(spec("local.Init-1", %{options: %{"level" => 5}}), @facts)
    end

    test "the watchdog for an app that runs once" do
      assert refused(spec("local_once", %{settings: %{watchdog: true}})) == :watchdog_run_once

      assert {:ok, _} =
               Schema.validate(spec("local_once", %{settings: %{watchdog: false}}), @facts)
    end

    test "a dynamic ingress app without its port, and a port for any other app" do
      dynamic = AppManifests.get("5c53de3b_esphome")

      assert refused(%{lifecycle: :container, config: dynamic}) == :ingress_port_missing

      assert refused(%{lifecycle: :container, config: dynamic, ingress_port: nil}) ==
               :ingress_port_missing

      assert refused(spec("45df7312_zigbee2mqtt", %{ingress_port: 8099})) ==
               :ingress_port_not_assignable

      assert refused(spec("core_mosquitto", %{ingress_port: 62_000})) ==
               :ingress_port_not_assignable
    end
  end

  describe "validate/2 on anything at all" do
    test "refuses what is no spec, without raising" do
      AppManifests.each(3_000, &AppManifests.garbage/0, fn term ->
        assert {:error, _reason} = Schema.validate(term, @facts)
      end)
    end

    test "answers a spec with any one field replaced by anything, without raising" do
      base = admitted("5c53de3b_esphome")

      generator = fn ->
        field = AppManifests.pick(Map.keys(base) ++ [:settings, :settings, :wave, "run"])
        {field, AppManifests.garbage()}
      end

      AppManifests.each(3_000, generator, fn {field, value} ->
        result =
          if field == :settings and is_map(value) and not is_struct(value),
            do: Schema.validate(%{base | settings: Map.merge(base.settings, value)}, @facts),
            else: Schema.validate(Map.put(base, field, value), @facts)

        assert match?({:ok, %{}}, result) or match?({:error, _}, result)
      end)
    end

    test "answers a manifest with any one field replaced by anything, without raising" do
      config = AppManifests.get("45df7312_zigbee2mqtt")
      keys = config |> Map.from_struct() |> Map.keys()
      generator = fn -> {AppManifests.pick(keys), AppManifests.garbage()} end

      AppManifests.each(3_000, generator, fn {key, value} ->
        spec = %{lifecycle: :container, config: Map.put(config, key, value)}
        result = Schema.validate(spec, @facts)
        assert match?({:ok, %{}}, result) or match?({:error, _}, result)
      end)
    end
  end

  describe "the codec" do
    test "what it encodes is JSON's own: strings for keys, no atom but true, false and nil" do
      encoded = Schema.encode_spec(admitted("core_mosquitto", %{settings: %{watchdog: true}}))

      assert Jason.decode!(Jason.encode!(encoded)) == encoded
      assert encoded["lifecycle"] == "container"
      assert encoded["settings"]["watchdog"] == true
      assert encoded["config"]["slug"] == "core_mosquitto"
    end

    test "every manifest's spec comes back from JSON exactly, in every variation" do
      generator = fn -> varied(AppManifests.pick(AppManifests.all())) end

      AppManifests.each(600, generator, fn spec ->
        assert through_json(spec) == spec
      end)

      for config <- AppManifests.all() do
        spec = admitted(config.slug)
        assert through_json(spec) == spec
      end
    end

    test "user options and holds of any JSON shape come back exactly" do
      config =
        AppManifests.parse!(%{
          "name" => "n",
          "version" => "1",
          "slug" => "free",
          "image" => "i",
          "schema" => false
        })

      generator = fn ->
        map = fn ->
          for _ <- 1..:rand.uniform(4),
              into: %{},
              do: {AppManifests.string(), AppManifests.plain(3)}
        end

        %{options: map.(), holds: map.()}
      end

      AppManifests.each(600, generator, fn fields ->
        {:ok, spec} = config |> Schema.from_manifest(@facts, fields) |> Schema.validate(@facts)
        assert through_json(spec) == spec
      end)
    end

    test "a Core spec comes back exactly" do
      {:ok, spec} =
        Schema.validate(
          %{lifecycle: :core, version: "2026.10.1", run: true, holds: %{"u" => true}},
          @facts
        )

      assert through_json(spec) == spec
    end

    test "decoding refuses a lifecycle, a field or a setting this build does not know" do
      encoded = Schema.encode_spec(admitted("core_mosquitto"))

      for broken <- [
            Map.put(encoded, "lifecycle", "microvm"),
            Map.put(encoded, "wave", 10),
            put_in(encoded, ["settings", "nice"], 1),
            put_in(encoded, ["config", "arch"], ["z80"])
          ] do
        assert_raise ArgumentError, fn -> Schema.decode_spec(broken) end
      end
    end

    @tag :tmp_dir
    test "the store writes every manifest's spec and reads it back the same", %{tmp_dir: dir} do
      path = Path.join(dir, "resources.json")
      i = [instance: TestInstance.start!(path: path, kinds: kinds())]

      for config <- AppManifests.all() do
        assert {:ok, %Resource{}} = Store.create(:app, config.slug, spec(config.slug), i)
      end

      assert {:ok, _} =
               Store.create(:app, "homeassistant", %{lifecycle: :core, version: "2026.10.1"}, i)

      before = Store.list(:app, i)
      assert length(before) == length(AppManifests.all()) + 1

      {:ok, kinds} =
        {:ok, Map.new(kinds(), fn {kind, fields} -> {kind, Vagus.Resource.Kind.new(fields)} end)}

      assert {:ok, %{resources: read}} = Persistence.read(path, kinds)
      assert Enum.sort_by(read, & &1.name) == before
    end
  end

  describe "who owns which path" do
    setup do
      i = [instance: TestInstance.start!(kinds: kinds())]
      {:ok, _} = Store.create(:app, "core_mosquitto", spec("core_mosquitto", %{run: true}), i)
      %{i: i}
    end

    test "an Update's version is refused to a command until it is released", %{i: i} do
      update = Resource.writer(%Resource{kind: :update, name: "u1", uid: 9})

      assert {:ok, _} =
               Store.update_spec(
                 :app,
                 "core_mosquitto",
                 [{:put, Schema.version_path(), "7.2.0"}],
                 [writer: update] ++ i
               )

      assert {:error, {:conflict, [:version], ^update}} =
               Store.update_spec(:app, "core_mosquitto", %{version: "9.9.9"}, i)

      assert {:ok, _} = Store.update_spec(:app, "core_mosquitto", %{run: false}, i)

      assert {:ok, released} = Store.release_writer(:app, "core_mosquitto", update, i)
      assert released.spec.version == "7.2.0"
      assert {:ok, _} = Store.update_spec(:app, "core_mosquitto", %{version: "7.2.1"}, i)
    end

    test "a hold goes with the writer that placed it, and another's stays", %{i: i} do
      backup = Resource.writer(%Resource{kind: :backup, name: "b1", uid: 4})
      other = Resource.writer(%Resource{kind: :backup, name: "b2", uid: 5})

      for {writer, name} <- [{backup, "b1"}, {other, "b2"}] do
        assert {:ok, _} =
                 Store.update_spec(
                   :app,
                   "core_mosquitto",
                   [{:put, Schema.hold_path(name), true}],
                   [writer: writer] ++ i
                 )
      end

      held = Store.get(:app, "core_mosquitto", i)
      assert held.spec.holds == %{"b1" => true, "b2" => true}
      refute Schema.wanted?(held.spec)

      assert {:ok, released} = Store.release_writer(:app, "core_mosquitto", backup, i)
      assert released.spec.holds == %{"b2" => true}

      assert {:ok, free} = Store.release_writer(:app, "core_mosquitto", other, i)
      assert free.spec.holds == %{}
      assert Schema.wanted?(free.spec)
    end

    test "a write that would leave the spec unadmitted is refused whole", %{i: i} do
      assert {:error, {:invalid, {:malformed, :run}}} =
               Store.update_spec(:app, "core_mosquitto", %{run: "yes"}, i)

      assert {:error, {:invalid, {:field_not_in_profile, :wave, :container}}} =
               Store.update_spec(:app, "core_mosquitto", %{wave: 1}, i)

      assert Store.get(:app, "core_mosquitto", i).spec.run
    end
  end

  describe "the ingress port" do
    defp app(name, uid, port) do
      %Resource{kind: :app, name: name, uid: uid, spec: %{ingress_port: port}}
    end

    test "is the manifest's when it names one, the assigned one when it does not" do
      assert Schema.ingress_port(admitted("45df7312_zigbee2mqtt")) == 8099
      assert Schema.ingress_port(admitted("5c53de3b_esphome", %{ingress_port: 62_010})) == 62_010
      assert Schema.ingress_port(admitted("core_mosquitto")) == nil
      assert Schema.ingress_port(admitted("core_mqtt")) == nil
    end

    test "is assigned only to a manifest that asks for a dynamic one" do
      assert Schema.assign_ingress_port(AppManifests.get("core_mosquitto"), []) == {:ok, nil}

      assert Schema.assign_ingress_port(AppManifests.get("45df7312_zigbee2mqtt"), []) ==
               {:ok, nil}

      assert Schema.assign_ingress_port(AppManifests.get("5c53de3b_esphome"), []) == {:ok, 62_000}
    end

    test "is the lowest port neither held by another app nor found in use" do
      dynamic = AppManifests.get("5c53de3b_esphome")

      held =
        Schema.held_ingress_ports([app("a", 1, 62_000), app("b", 2, 62_002), app("c", 3, nil)])

      assert held == MapSet.new([62_000, 62_002])
      assert Schema.assign_ingress_port(dynamic, held) == {:ok, 62_001}
      assert Schema.assign_ingress_port(dynamic, held, in_use: [62_001]) == {:ok, 62_003}
      assert Schema.assign_ingress_port(dynamic, [], range: 7..9, in_use: [7, 8]) == {:ok, 9}
    end

    test "with no port free is an error and not a port" do
      dynamic = AppManifests.get("5c53de3b_esphome")

      assert Schema.assign_ingress_port(dynamic, [7, 8], range: 7..9, in_use: [9]) ==
               {:error, :no_ingress_port_free}

      assert Schema.assign_ingress_port(dynamic, 62_000..65_500) ==
               {:error, :no_ingress_port_free}
    end

    test "an app's own port is not held against it" do
      apps = [app("a", 1, 62_000), app("b", 2, 62_001)]
      assert Schema.held_ingress_ports(apps, "a") == MapSet.new([62_001])
    end

    test "of two apps that picked the same port, exactly the later one must pick again" do
      first = app("a", 3, 62_000)
      second = app("b", 8, 62_000)
      bystander = app("c", 1, 62_001)
      apps = [first, second, bystander, app("d", 2, nil)]

      refute Schema.ingress_port_contested?(first, apps)
      assert Schema.ingress_port_contested?(second, apps)
      refute Schema.ingress_port_contested?(bystander, apps)
      refute Schema.ingress_port_contested?(app("d", 2, nil), apps)

      # The earlier one looked before the later existed: still not contested.
      refute Schema.ingress_port_contested?(first, [first, bystander])

      # Having picked again from what is held, nobody is.
      {:ok, port} =
        Schema.assign_ingress_port(
          AppManifests.get("5c53de3b_esphome"),
          Schema.held_ingress_ports(apps, "b")
        )

      repicked = app("b", 8, port)
      assert port == 62_002
      refute Schema.ingress_port_contested?(repicked, [first, repicked, bystander])
    end
  end
end
