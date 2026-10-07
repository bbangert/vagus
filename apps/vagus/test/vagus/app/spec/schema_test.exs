defmodule Vagus.App.Spec.SchemaTest do
  use ExUnit.Case, async: true

  alias Vagus.Addon.Config
  alias Vagus.App.{Facts, Profile}
  alias Vagus.App.Spec.Schema
  alias Vagus.Resource
  alias Vagus.Resource.{Kind, Persistence, Store, TestInstance}
  alias Vagus.Test.AppManifests

  # `Vagus.Addon.OptionsSchema` warns of every option a schema does not name.
  @moduletag :capture_log

  defp facts(overrides \\ []) do
    Facts.read(
      [
        arch: "aarch64",
        machine: "raspberrypi3-64",
        core_version: "2026.10.1",
        native_apps: ["core_mqtt"]
      ] ++ overrides
    )
  end

  defp spec(slug, fields \\ %{}) do
    config = AppManifests.get(slug)

    fields =
      if Schema.dynamic_ingress?(config),
        do: Map.put_new(fields, :ingress_port, 62_000),
        else: fields

    Schema.from_manifest(config, facts(), fields)
  end

  defp core(fields \\ %{}), do: Map.merge(%{lifecycle: :core, version: "2026.10.1"}, fields)

  defp admitted(slug, fields \\ %{}) do
    {:ok, spec} = Schema.validate(spec(slug, fields), facts())
    spec
  end

  defp refused(spec, facts \\ facts()) do
    assert {:error, reason} = Schema.validate(spec, facts)
    reason
  end

  defp kinds do
    facts = facts()

    %{
      app: [
        validators: [&Schema.validate(&1, facts)],
        writer_entries: Schema.writer_entries(),
        encode_spec: &Schema.encode_spec/1,
        decode_spec: &Schema.decode_spec/1
      ]
    }
  end

  # Options a user could have set, which the manifest's schema accepts.
  @options %{
    "core_mosquitto" => [
      %{"require_certificate" => true},
      %{
        "logins" => [
          %{"username" => "ü\n\"x\"", "password" => "p\\w"},
          %{"username" => "", "password" => "\u{1F511}"}
        ]
      }
    ],
    "core_samba" => [%{"username" => "me", "password" => "s3cret", "workgroup" => ""}],
    "45df7312_zigbee2mqtt" => [
      %{"serial" => %{"port" => "/dev/serial/by-id/usb-1", "baudrate" => 9_600}},
      %{
        "retries" => [5, 1],
        "ratio" => 1.0,
        "level" => "warn",
        "mqtt" => %{"server" => "mqtt://x"}
      }
    ],
    "local.Init-1" => [
      %{"level" => 5, "extra" => "x"},
      %{"nested" => %{"ratio" => 1.0e-320, "names" => []}}
    ]
  }

  defp plain_map do
    for _ <- 1..:rand.uniform(4), into: %{}, do: {AppManifests.string(), AppManifests.plain(3)}
  end

  defp options_for(config) do
    cond do
      is_map_key(@options, config.slug) -> AppManifests.pick([%{} | @options[config.slug]])
      # No schema, or one that names nothing: anything is kept as given.
      config.schema in [false, %{}] -> AppManifests.pick([%{}, plain_map()])
      true -> %{}
    end
  end

  # A spec as varied as admission lets it be, for one manifest.
  defp varied(config) do
    profile = Profile.of(%{lifecycle: Schema.lifecycle_for(config, facts())})

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

    holds =
      AppManifests.pick([
        %{},
        plain_map(),
        %{"backup-1" => true, "update/2" => %{"since" => 1.5}, "" => nil}
      ])

    fields = %{
      version: AppManifests.pick([config.version, "1.2.3-rc.1", "latest", "2026.10.0b3"]),
      options: options_for(config),
      settings: settings,
      run: AppManifests.pick([true, false]),
      restart_counter: AppManifests.pick([0, 1, 2 ** 70]),
      start_counter: :rand.uniform(50) - 1,
      holds: holds
    }

    fields =
      if Schema.dynamic_ingress?(config),
        do: Map.put(fields, :ingress_port, 61_999 + :rand.uniform(3_501)),
        else: fields

    {:ok, spec} = config |> Schema.from_manifest(facts(), fields) |> Schema.validate(facts())
    spec
  end

  defp varied_core do
    {:ok, spec} =
      Schema.validate(
        core(%{
          version: AppManifests.pick(["2026.10.1", "2026.11.0b2", "dev"]),
          run: AppManifests.pick([true, false]),
          restart_counter: :rand.uniform(9),
          holds: AppManifests.pick([%{}, plain_map()])
        }),
        facts()
      )

    spec
  end

  defp any_spec do
    case AppManifests.pick([:core | AppManifests.all()]) do
      :core -> varied_core()
      config -> varied(config)
    end
  end

  defp through_json(spec),
    do: spec |> Schema.encode_spec() |> Jason.encode!() |> Jason.decode!() |> Schema.decode_spec()

  describe "what admission fills in" do
    test "a manifest alone is a whole spec, with the container profile's defaults" do
      config = AppManifests.get("core_mosquitto")

      assert Schema.validate(%{lifecycle: :container, config: config}, facts()) ==
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

      assert {:ok, spec} = Schema.validate(%{lifecycle: :native, config: config}, facts())
      assert spec.settings == %{watchdog: true}
      refute is_map_key(spec, :ingress_port)
      assert Enum.sort(Map.keys(spec)) == Enum.sort(Profile.Native.fields())
    end

    test "Core is a version and what commands write, and nothing of a manifest" do
      assert Schema.validate(core(), facts()) ==
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
      assert Schema.validate(spec, facts()) == {:ok, spec}
    end

    test "every manifest is admitted, as the profile its backend asks for" do
      for config <- AppManifests.all() do
        spec = admitted(config.slug)
        assert spec.lifecycle == if(config.slug == "core_mqtt", do: :native, else: :container)
        assert Schema.validate(spec, facts()) == {:ok, spec}
      end
    end
  end

  describe "what admission refuses" do
    test "what is no map at all, by name" do
      for term <- [
            nil,
            [],
            "spec",
            7,
            {:lifecycle, :core},
            %Config{name: "n", version: "1", slug: "s", description: "d", arch: []},
            [lifecycle: :core, version: "1"]
          ] do
        assert Schema.validate(term, facts()) == {:error, {:malformed, :spec}}
      end
    end

    test "a spec with no lifecycle, or one that is no profile" do
      assert refused(%{version: "1"}) == {:missing, :lifecycle}
      assert refused(%{lifecycle: :microvm}) == {:unknown_lifecycle, :microvm}
      assert refused(%{lifecycle: "container"}) == {:unknown_lifecycle, "container"}
    end

    test "a field its profile lacks, named, and the first of several by order" do
      assert refused(core(%{settings: %{}})) == {:field_not_in_profile, :settings, :core}

      assert refused(core(%{options: %{}, config: nil})) ==
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
        version: "1.0\n",
        version: "\n1.0",
        options: %{atom: 1},
        options: %{"pid" => self()},
        options: %{"list" => [1 | 2]},
        options: %{"deep" => [%{"k" => [1, {:t}]}]},
        options: %{<<255>> => 1},
        options: %{"bytes" => <<255, 0>>},
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
        holds: %{"backup" => ["a" | "b"]},
        holds: nil
      ]

      for {field, value} <- rows do
        assert refused(spec("5c53de3b_esphome", %{field => value})) == {:malformed, field},
               "#{field}: #{inspect(value)}"
      end

      assert refused(core(%{version: "1.0\n"})) == {:malformed, :version}

      # The manifest's own version is the default, and no better for it.
      newline = %{AppManifests.get("core_mosquitto") | version: "1.0\n"}
      assert refused(%{lifecycle: :container, config: newline}) == {:malformed, :version}
    end

    test "each setting of the wrong shape, by name" do
      rows = [
        ports: %{"80/tcp" => "80"},
        ports: %{"80/tcp" => 65_536},
        ports: %{"80/tcp" => -1},
        ports: %{"80/tcp" => %{}},
        ports: %{80 => 80},
        ports: %{<<255>> => 1},
        ports: [1],
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

      assert refused(spec("core_mqtt", %{settings: %{watchdog: 1}})) ==
               {:malformed, {:settings, :watchdog}}
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

      assert Schema.lifecycle_for(foreign, facts()) == :container
      assert refused(%{lifecycle: :native, config: foreign}) == {:lifecycle_mismatch, :native}

      assert refused(%{lifecycle: :native, config: AppManifests.native()}, facts(native_apps: [])) ==
               {:lifecycle_mismatch, :native}
    end

    test "a native app that runs once, which nothing would keep up" do
      once = %{AppManifests.native() | startup: "once"}

      assert refused(%{lifecycle: :native, config: once}) == :native_run_once

      assert refused(%{lifecycle: :native, config: once, settings: %{watchdog: false}}) ==
               :native_run_once
    end

    test "a slug the system keeps for itself, Core's name among them" do
      for slug <- ["vagus", "homeassistant", Profile.core_app()] do
        config = %{AppManifests.get("core_mosquitto") | slug: slug}
        assert refused(%{lifecycle: :container, config: config}) == {:reserved_slug, slug}
      end

      native = %{AppManifests.native() | slug: "homeassistant"}

      assert refused(%{lifecycle: :native, config: native}, facts(native_apps: ["homeassistant"])) ==
               {:reserved_slug, "homeassistant"}

      # Core itself is called so, and is no manifest's app.
      assert {:ok, _} = Schema.validate(core(), facts())
    end

    test "a slug that is no name for a directory or a container" do
      for slug <- ["ok\n", "\nok", "a b", "a/b", "", ".", "..", "ü", nil, :slug, "a\0"] do
        config = %{AppManifests.get("core_mosquitto") | slug: slug}

        assert refused(%{lifecycle: :container, config: config}) == {:invalid_slug, slug},
               inspect(slug)
      end
    end

    test "a manifest that would not come back from the file as itself" do
      base = AppManifests.get("core_mosquitto")

      for broken <- [
            %{base | timeout: "soon"},
            %{base | map: [:share]},
            %{base | options: %{level: 3}},
            %{base | options: %{"nested" => %{1 => "one"}}},
            %{base | options: %{"when" => ~D[2026-10-07]}},
            %{base | schema: %{level: "int"}},
            %{base | schema: %{"nested" => %{nil => "str"}}},
            %{base | ports: %{"80/tcp" => 80.0}},
            %{base | description: <<255>>}
          ] do
        assert refused(%{lifecycle: :container, config: broken}) == :config_not_persistable,
               inspect(
                 Map.from_struct(broken)
                 |> Map.take([:timeout, :map, :options, :schema, :ports, :description, :version])
               )
      end
    end

    test "a spec that would not come back from the file as itself" do
      # A map with this one key is a stored instant, wherever it stands.
      for {field, value} <- [
            options: %{"at" => %{"$stamp" => [1, 2]}},
            holds: %{"backup" => %{"$stamp" => [3, 4]}}
          ] do
        assert refused(spec("5c53de3b_esphome", %{field => value})) == :not_persistable
      end

      assert refused(core(%{holds: %{"u" => [%{"$stamp" => [1, 2]}]}})) == :not_persistable
      assert {:ok, _} = Schema.validate(core(%{holds: %{"u" => %{"$stamp" => "no"}}}), facts())
    end

    test "a container app with no image" do
      config = AppManifests.parse!(%{"name" => "n", "version" => "1", "slug" => "local_build"})
      assert refused(%{lifecycle: :container, config: config}) == :no_image
    end

    test "options the manifest's schema does not accept" do
      assert {:invalid_options, message} =
               refused(spec("local.Init-1", %{options: %{"level" => 9}}))

      assert message =~ "level"

      assert {:invalid_options, _} =
               refused(spec("core_mosquitto", %{options: %{"require_certificate" => "maybe"}}))

      assert {:invalid_options, _} =
               refused(spec("45df7312_zigbee2mqtt", %{options: %{"retries" => [1, [2]]}}))

      assert {:invalid_options, _} =
               refused(spec("45df7312_zigbee2mqtt", %{options: %{"serial" => "tty"}}))

      assert {:ok, _} =
               Schema.validate(spec("local.Init-1", %{options: %{"level" => 5}}), facts())
    end

    test "the watchdog for an app that runs once" do
      assert refused(spec("local_once", %{settings: %{watchdog: true}})) == :watchdog_run_once

      assert {:ok, _} =
               Schema.validate(spec("local_once", %{settings: %{watchdog: false}}), facts())
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

    test "a dynamic ingress port outside the range, or one the system keeps" do
      for port <- [1, 8_099, 61_999, 65_501, 65_535] do
        assert refused(spec("5c53de3b_esphome", %{ingress_port: port})) ==
                 :ingress_port_out_of_range
      end

      for port <- [62_000, 65_500] do
        assert {:ok, _} =
                 Schema.validate(spec("5c53de3b_esphome", %{ingress_port: port}), facts())
      end

      assert refused(
               spec("5c53de3b_esphome", %{ingress_port: 62_500}),
               facts(reserved_host_ports: [80, 62_500])
             ) == :ingress_port_reserved
    end
  end

  describe "availability/2, which is not a rule of admission" do
    test "names upstream's three reasons, with its messages" do
      assert Schema.availability(AppManifests.get("core_mosquitto"), facts()) == :ok

      assert {:error, {:not_supported, :architecture, message}} =
               Schema.availability(AppManifests.get("core_mosquitto"), facts(arch: "i386"))

      assert message ==
               "App Mosquitto broker not supported on this platform, supported architectures: " <>
                 "aarch64, amd64, armv7"

      assert {:error, {:not_supported, :machine_type, message}} =
               Schema.availability(AppManifests.get("local_dsp"), facts(machine: "odroid-n2"))

      assert message =~ "supported machine types: generic-aarch64, raspberrypi3-64"

      assert {:error, {:not_supported, :home_assistant_version, message}} =
               Schema.availability(
                 AppManifests.get("45df7312_zigbee2mqtt"),
                 facts(core_version: "2023.12.4")
               )

      assert message =~ "requires Home Assistant version 2024.1.0 or greater"
    end

    test "names the first of the three that applies, as upstream orders them" do
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

      assert {:error, {:not_supported, :architecture, _}} = Schema.availability(config, facts())

      assert {:error, {:not_supported, :machine_type, _}} =
               Schema.availability(config, facts(arch: "amd64"))

      assert {:error, {:not_supported, :home_assistant_version, _}} =
               Schema.availability(config, facts(arch: "amd64", machine: "qemux86-64"))
    end

    test "a Core version that is not known refuses nobody" do
      assert Schema.availability(
               AppManifests.get("45df7312_zigbee2mqtt"),
               facts(core_version: nil)
             ) ==
               :ok
    end

    test "an app this machine could not be given is still admitted, and can be stopped" do
      for {slug, facts} <- [
            {"core_mosquitto", facts(arch: "i386")},
            {"local_dsp", facts(machine: "odroid-n2")},
            {"45df7312_zigbee2mqtt", facts(core_version: "2023.12.4")}
          ] do
        config = AppManifests.get(slug)
        assert {:error, {:not_supported, _which, _message}} = Schema.availability(config, facts)

        assert {:ok, running} =
                 Schema.validate(Schema.from_manifest(config, facts, %{run: true}), facts)

        assert {:ok, %{run: false}} = Schema.validate(%{running | run: false}, facts)
      end
    end
  end

  describe "validate/2 on anything at all" do
    # Whatever is admitted is what the file gives back.
    defp answered!({:ok, %{} = admitted}), do: assert(through_json(admitted) == admitted)
    defp answered!({:error, _reason}), do: :ok

    test "refuses what is no spec, without raising" do
      AppManifests.each(3_000, fn -> AppManifests.garbage(3) end, fn term ->
        assert {:error, _reason} = Schema.validate(term, facts())
      end)
    end

    test "answers every manifest's spec with any one field replaced by anything" do
      generator = fn ->
        base = any_spec()
        # Sorted: the order a map lists its keys in is not ours to rely on.
        field = AppManifests.pick(Enum.sort(Map.keys(base)) ++ [:wave, "run", :settings])
        {base, field, AppManifests.garbage(AppManifests.pick([0, 1, 3]))}
      end

      AppManifests.each(2_000, generator, fn {base, field, value} ->
        answered!(Schema.validate(Map.put(base, field, value), facts()))
      end)
    end

    test "answers each real setting given anything, alone and beside valid ones" do
      generator = fn ->
        base = varied(AppManifests.pick(AppManifests.all()))
        key = AppManifests.pick(Enum.sort(Map.keys(Profile.Container.settings())))
        {base, key, AppManifests.garbage(AppManifests.pick([0, 1, 2]))}
      end

      AppManifests.each(1_500, generator, fn {base, key, value} ->
        answered!(
          Schema.validate(%{base | settings: Map.put(base.settings, key, value)}, facts())
        )

        answered!(Schema.validate(%{base | settings: %{key => value}}, facts()))
      end)
    end

    test "answers options of any shape against every manifest's schema" do
      generator = fn ->
        config = AppManifests.pick(AppManifests.all())
        keys = if is_map(config.schema), do: Enum.sort(Map.keys(config.schema)), else: []

        options =
          case :rand.uniform(4) do
            1 ->
              for key <- keys, into: %{}, do: {key, AppManifests.plain(3)}

            2 ->
              for key <- keys, into: %{}, do: {key, AppManifests.garbage(3)}

            3 ->
              Map.put(config.options, AppManifests.pick(keys ++ ["other"]), AppManifests.plain(3))

            4 ->
              AppManifests.garbage(3)
          end

        {config, options}
      end

      AppManifests.each(2_000, generator, fn {config, options} ->
        answered!(Schema.validate(spec(config.slug, %{options: options}), facts()))
      end)
    end

    test "answers a manifest with any one field replaced by anything, or by nothing" do
      keys = AppManifests.native() |> Map.from_struct() |> Map.keys() |> Enum.sort()

      generator = fn ->
        config = AppManifests.pick(AppManifests.all())
        value = AppManifests.pick([nil, AppManifests.garbage(AppManifests.pick([0, 2]))])
        {config, AppManifests.pick(keys), value}
      end

      AppManifests.each(2_000, generator, fn {config, key, value} ->
        base = spec(config.slug)
        answered!(Schema.validate(%{base | config: Map.put(config, key, value)}, facts()))
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

    test "every manifest's spec comes back from JSON exactly, in every variation, and is admitted again" do
      AppManifests.each(1_500, &any_spec/0, fn spec ->
        back = through_json(spec)
        assert back == spec
        assert Schema.validate(back, facts()) == {:ok, spec}
      end)
    end

    test "the corpus fills every field of a manifest at least once with other than its default" do
      blank = AppManifests.parse!(%{"name" => "n", "version" => "0", "slug" => "s"})

      for {field, default} <- Map.from_struct(blank),
          field not in [:name, :version, :slug, :description, :arch] do
        assert Enum.any?(AppManifests.all(), &(Map.fetch!(&1, field) != default)),
               "no manifest sets #{field}"
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

      generator = fn -> %{options: plain_map(), holds: plain_map()} end

      AppManifests.each(1_500, generator, fn fields ->
        {:ok, spec} = config |> Schema.from_manifest(facts(), fields) |> Schema.validate(facts())
        assert through_json(spec) == spec
      end)
    end

    test "numbers at the edges, and strings JSON has to escape, come back exactly" do
      options = %{
        "big" => 2 ** 200,
        "negative" => -(2 ** 80),
        "past doubles" => 9_007_199_254_740_993,
        "max" => 1.0e308,
        "denormal" => 5.0e-324,
        "tenth" => 0.1 + 0.2,
        "zero" => 0.0,
        "integral float" => 3.0,
        "" => "",
        "new\nline" => "tab\tquote\"back\\slash",
        <<0, 31, 127>> => <<1, 2, 3>>,
        "\u{1F600}" => "\u{10FFFF}\u{0301}e",
        "\\u0041" => ["\\n", "</script>", "\u2028"]
      }

      spec = admitted("5c53de3b_esphome", %{options: options, holds: options})
      back = through_json(spec)

      assert back == spec
      assert is_float(back.options["integral float"]) and is_float(back.options["zero"])
      assert is_integer(back.options["big"])
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
    test "the store writes varied specs of every profile to its file, and a new store reads them the same",
         %{tmp_dir: dir} do
      path = Path.join(dir, "resources.json")
      instance = TestInstance.start!(path: path, kinds: kinds())
      i = [instance: instance]

      :rand.seed(:exsss, {11, 12, 13})

      written =
        for config <- AppManifests.all(), n <- 1..3 do
          spec = varied(config)
          name = "#{config.slug}-#{n}"
          assert {:ok, %Resource{spec: ^spec}} = Store.create(:app, name, spec, i)

          backup = Resource.writer(%Resource{kind: :backup, name: "b", uid: 4})
          update = Resource.writer(%Resource{kind: :update, name: "u", uid: 5})

          {:ok, _} =
            Store.update_spec(
              :app,
              name,
              [{:put, Schema.hold_path("b"), true}],
              [writer: backup] ++ i
            )

          {:ok, held} =
            Store.update_spec(
              :app,
              name,
              [{:put, Schema.hold_path("u"), %{"n" => n}}],
              [writer: update] ++ i
            )

          assert map_size(held.managed_fields) == 2
          held
        end

      {:ok, core} = Store.create(:app, Profile.core_app(), varied_core(), i)
      before = Enum.sort_by([core | written], & &1.name)
      assert Store.list(:app, i) == before

      assert Enum.map(before, & &1.spec.lifecycle) |> Enum.uniq() |> Enum.sort() == [
               :container,
               :core,
               :native
             ]

      kinds = Map.new(kinds(), fn {kind, fields} -> {kind, Kind.new(fields)} end)
      assert {:ok, %{resources: read}} = Persistence.read(path, kinds)
      assert Enum.sort_by(read, & &1.name) == before

      # A store that starts on the file holds the same, and admits each again.
      :ok = stop_supervised(instance)
      again = [instance: TestInstance.start!(path: path, kinds: kinds())]
      assert Store.list(:app, again) == before

      for %{spec: spec} <- before do
        assert Schema.validate(spec, facts()) == {:ok, spec}
      end

      assert {:ok, _} = Store.update_spec(:app, hd(before).name, %{run: true}, again)
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
      assert Schema.assign_ingress_port(dynamic, held, [62_001]) == {:ok, 62_003}
      assert Schema.assign_ingress_port(dynamic, 62_000..65_499) == {:ok, 65_500}

      # What it assigns, admission takes.
      assert {:ok, _} =
               Schema.validate(spec("5c53de3b_esphome", %{ingress_port: 65_500}), facts())
    end

    test "with no port free is an error and not a port" do
      dynamic = AppManifests.get("5c53de3b_esphome")

      assert Schema.assign_ingress_port(dynamic, 62_000..65_000, 65_001..65_500) ==
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
