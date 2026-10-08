defmodule Vagus.Test.AppManifests do
  @moduledoc """
  Manifests to run the App spec's functions over, and a generator of
  variations on them.

  The repository keeps no store manifests as files, so none here is a real
  one read from a store. Three are manifests the repository does hold in
  code: the built-in broker's (`Vagus.Addon.Store.BuiltinFetcher`), the
  probe app the device-captured container fingerprint was taken from, and
  the broker manifest the old builder's own tests use. The rest are written
  by hand: some after store apps, and one for each thing a manifest can ask
  of a container alone, so that a flag read for another's key shows.
  `manifest/0` generates more, over every field the container builders
  read.

  Generated values come from a seeded generator: a run is the same every
  time, and a failure names the case.
  """

  alias Vagus.Addon.Config
  alias Vagus.Addon.Store.BuiltinFetcher

  @base %{
    "description" => "test manifest",
    "arch" => ["aarch64", "amd64", "armv7"]
  }

  @raw [
    %{
      "name" => "Elixir probe",
      "version" => "0.7.0",
      "slug" => "elixir_probe",
      "arch" => ["aarch64"],
      "image" => "ghcr.io/bbangert/ha-bench-addons/elixir_probe",
      "init" => false,
      "boot" => "manual",
      "homeassistant_api" => true,
      "hassio_api" => true,
      "ports" => %{"4000/tcp" => 4000}
    },
    %{
      "name" => "Mosquitto broker",
      "version" => "7.1.0",
      "slug" => "core_mosquitto",
      "image" => "homeassistant/{arch}-addon-mosquitto",
      "init" => false,
      "startup" => "system",
      "auth_api" => true,
      "services" => ["mqtt:provide"],
      "discovery" => ["mqtt"],
      "ports" => %{"1883/tcp" => 1883, "8883/tcp" => 8883, "1884/tcp" => nil},
      "map" => ["ssl", "share"],
      "options" => %{"logins" => [], "require_certificate" => false},
      "schema" => %{
        "logins" => [%{"username" => "str", "password" => "password"}],
        "require_certificate" => "bool"
      }
    },
    %{
      "name" => "ESPHome",
      "version" => "2026.9.1",
      "slug" => "5c53de3b_esphome",
      "image" => "ghcr.io/esphome/esphome-hassio",
      "host_network" => true,
      "ingress" => true,
      "ingress_port" => 0,
      "panel_icon" => "mdi:chip",
      "auth_api" => true,
      "hassio_api" => true,
      "map" => ["ssl", "config:rw"],
      "backup_exclude" => ["*/*/"],
      "schema" => false
    },
    %{
      "name" => "Samba share",
      "version" => "12.5.4",
      "slug" => "core_samba",
      "image" => "homeassistant/{arch}-addon-samba",
      "host_network" => true,
      "hassio_api" => true,
      "startup" => "services",
      "map" => [
        "addons:rw",
        %{"type" => "all_addon_configs", "read_only" => false},
        "backup:rw",
        "homeassistant_config:rw",
        "media:rw",
        "share:rw",
        "ssl:rw"
      ],
      "options" => %{"username" => "homeassistant", "workgroup" => "WORKGROUP"},
      "schema" => %{"username" => "str", "workgroup" => "str", "password" => "password?"}
    },
    %{
      "name" => "Zigbee2MQTT",
      "version" => "2.6.1-1",
      "slug" => "45df7312_zigbee2mqtt",
      "image" => "ghcr.io/zigbee2mqtt/zigbee2mqtt-{arch}",
      "ingress" => true,
      "ingress_port" => 8099,
      "ports" => %{"8485/tcp" => 8485, "8099/tcp" => nil},
      "devices" => ["/dev/null", "/dev/ttyUSB0"],
      "map" => ["share:rw", %{"type" => "addon_config", "read_only" => false}],
      "services" => ["mqtt:need"],
      "watchdog" => "http://[HOST]:[PORT:8099]/",
      "timeout" => 30,
      "homeassistant" => "2024.1.0",
      "ingress_entry" => "index.html",
      "ingress_stream" => true,
      "panel_title" => "Zigbee\n2 \u{1F41D} MQTT",
      "panel_icon" => "mdi:zigbee",
      "panel_admin" => false,
      "webui" => "http://[HOST]:[PORT:8099]/",
      "backup_pre" => "sh -c 'sync; echo \"pre\"'",
      "backup_post" => "true",
      "backup_exclude" => ["log/*", "**/*.tmp"],
      "docker_api" => true,
      "description" => String.duplicate("A bridge between Zigbee and MQTT. ", 40),
      "options" => %{
        "data_path" => "/config/zigbee2mqtt",
        "serial" => %{"port" => "/dev/ttyUSB0", "baudrate" => 115_200},
        "retries" => [1, 2, 3],
        "ratio" => 0.25,
        "mqtt" => %{}
      },
      "schema" => %{
        "data_path" => "str",
        "serial" => %{"port" => "str", "baudrate" => "int(9600,921600)?"},
        "retries" => ["int(1,5)"],
        "ratio" => "float(0,1)",
        "mqtt" => %{"server" => "str?", "password" => "password?"},
        "level" => "list(debug|info|warn)?"
      }
    },
    %{
      "name" => "Glances",
      "version" => "0.21.1",
      "slug" => "a0d7b954_glances",
      "image" => "ghcr.io/hassio-addons/glances/{arch}",
      "host_network" => true,
      "host_pid" => true,
      "host_uts" => true,
      "host_ipc" => true,
      "host_dbus" => true,
      "apparmor" => false,
      "privileged" => ["NET_ADMIN", "SYS_ADMIN", "SYS_PTRACE"],
      "full_access" => true,
      "ingress" => true,
      "ingress_port" => 0,
      "hassio_role" => "manager"
    },
    %{
      "name" => "Bridged, with the host's namespaces",
      "version" => "1.0.0",
      "slug" => "local_namespaces",
      "image" => "local/{arch}-namespaces",
      "host_pid" => true,
      "host_uts" => true,
      "host_ipc" => true,
      "host_dbus" => true,
      "init" => false,
      "privileged" => ["SYS_RAWIO"],
      "full_access" => true,
      "ports" => %{"80/tcp" => 80, "8123/tcp" => 8123, "8888/tcp" => 8888, "53/udp" => 53}
    },
    %{
      "name" => "Only the host's pids",
      "version" => "1",
      "slug" => "only_host_pid",
      "image" => "local/{arch}-one",
      "host_pid" => true,
      "ports" => %{"7000/tcp" => 7000, "7001/tcp" => nil, "7002/udp" => 0}
    },
    %{
      "name" => "Only the host's name",
      "version" => "1",
      "slug" => "only_host_uts",
      "image" => "local/one",
      "host_uts" => true
    },
    %{
      "name" => "Only the host's IPC",
      "version" => "1",
      "slug" => "only_host_ipc",
      "image" => "local/one",
      "host_ipc" => true
    },
    %{
      "name" => "Only the host's bus",
      "version" => "1",
      "slug" => "only_host_dbus",
      "image" => "local/one",
      "host_dbus" => true
    },
    %{
      "name" => "Only full access",
      "version" => "1",
      "slug" => "only_full_access",
      "image" => "local/one",
      "full_access" => true
    },
    %{
      "name" => "Only capabilities",
      "version" => "1",
      "slug" => "only_privileged",
      "image" => "local/one",
      "privileged" => ["NET_ADMIN"]
    },
    %{
      "name" => "Host network, and ports all the same",
      "version" => "1",
      "slug" => "host_with_ports",
      "image" => "local/one",
      "host_network" => true,
      "ports" => %{"8080/tcp" => 8080, "53/udp" => nil}
    },
    %{
      "name" => "Full access and devices",
      "version" => "1",
      "slug" => "full_and_devices",
      "image" => "local/one",
      "full_access" => true,
      "devices" => ["/dev/null", "/dev/zero", "/dev/absent0"]
    },
    %{
      "name" => "DSP on the host network",
      "version" => "1",
      "slug" => "dsp_on_host",
      "image" => "local/one",
      "dsp" => true,
      "host_network" => true
    },
    %{
      "name" => "Two mappings, one target",
      "version" => "1",
      "slug" => "two_configs",
      "image" => "local/one",
      "map" => [
        "config:rw",
        %{"type" => "addon_config", "read_only" => true, "path" => "/custom"},
        "ssl"
      ]
    },
    %{
      "name" => "DSP inference",
      "version" => "1.2.3",
      "slug" => "local_dsp",
      "image" => "local/dsp",
      "arch" => ["aarch64"],
      "dsp" => true,
      "machine" => ["generic-aarch64", "raspberrypi3-64"],
      "backup" => "cold"
    },
    %{
      "name" => "Run once",
      "version" => "2024.10.0",
      "slug" => "local_once",
      "image" => "local/{arch}-once",
      "startup" => "once",
      "boot" => "manual_only",
      "map" => ["config", "nonsense", "media:ro"]
    },
    %{
      "name" => "Initialize first",
      "version" => "3",
      "slug" => "local.Init-1",
      "image" => "local/init",
      "startup" => "initialize",
      "stage" => "experimental",
      "advanced" => true,
      "url" => "https://example.org",
      "ports" => %{"53/udp" => 53, "53/tcp" => 53},
      "options" => %{"level" => 3, "nested" => %{"ratio" => 0.5, "names" => ["a", "b"]}},
      "schema" => %{
        "level" => "int(1,5)",
        "nested" => %{"ratio" => "float", "names" => ["str"]},
        "extra" => "str?"
      }
    }
  ]

  @doc "Every manifest, parsed, the built-in broker's among them."
  @spec all() :: [Config.t()]
  def all, do: [native() | containers()]

  @doc "The manifests that run as containers."
  @spec containers() :: [Config.t()]
  def containers, do: Enum.map(@raw, &parse!(Map.merge(@base, &1)))

  @spec native() :: Config.t()
  def native, do: parse!(Map.put(BuiltinFetcher.config(:mqtt), "slug", "core_mqtt"))

  @spec get(String.t()) :: Config.t()
  def get(slug), do: Enum.find(all(), &(&1.slug == slug)) || raise("no manifest #{slug}")

  @spec parse!(map()) :: Config.t()
  def parse!(raw) do
    {:ok, config} = Config.parse(Map.merge(@base, raw))
    config
  end

  @doc """
  Calls `fun` with `count` values of `generator`, each from a seed of its
  own, and names the seed of the one that fails.
  """
  @spec each(pos_integer(), (-> term()), (term() -> term())) :: :ok
  def each(count, generator, fun) do
    for seed <- 1..count do
      :rand.seed(:exsss, {seed, 20_261_007, 7})
      value = generator.()

      try do
        fun.(value)
      rescue
        error ->
          reraise RuntimeError,
                  [
                    message:
                      "case #{seed} (#{inspect(value, limit: 40)}): #{Exception.message(error)}"
                  ],
                  __STACKTRACE__
      end
    end

    :ok
  end

  @spec pick([term()]) :: term()
  def pick(list), do: Enum.at(list, :rand.uniform(length(list)) - 1)

  @doc "A JSON value: what a user's options or a hold may carry."
  @spec plain(non_neg_integer()) :: term()
  def plain(depth \\ 2) do
    leaves = [
      fn -> string() end,
      fn -> number() end,
      fn -> pick([true, false, nil]) end
    ]

    nested = [
      fn -> for _ <- 1..:rand.uniform(3), do: plain(depth - 1) end,
      fn -> for _ <- 1..:rand.uniform(3), into: %{}, do: {string(), plain(depth - 1)} end,
      fn -> pick([[], %{}]) end
    ]

    pick(if(depth > 0, do: leaves ++ nested, else: leaves)).()
  end

  @spec string() :: String.t()
  def string do
    pick([
      "",
      "a",
      "é ü",
      ":atom",
      "{\"tuple\": [1]}",
      "$stamp",
      "true",
      "0",
      "x/y.z-1_2",
      "line\nbreak\ttab",
      <<0, 1, 31, 127>>,
      "\u{1F600}\u{10FFFF}",
      "\\\"\\u0000\\n",
      "</script>"
    ]) <> pick(["", Integer.to_string(:rand.uniform(99))])
  end

  @doc "A number JSON carries: among them the largest and smallest of each kind."
  @spec number() :: number()
  def number do
    pick([
      0,
      -1,
      9_007_199_254_740_993,
      -(2 ** 80),
      2 ** 200,
      0.0,
      -0.5,
      1.0e-320,
      5.0e-324,
      1.0e308,
      -1.0e300,
      0.1 + 0.2,
      :rand.uniform() * 1.0e15,
      :rand.uniform(2_000_000) - 1_000_000
    ])
  end

  # Every field `Vagus.Addon.Manager.build_spec/2` and
  # `Vagus.App.Container.Config.build/3` read of a manifest, and nothing
  # else: `slug`, `image`, `version`, `host_network`, `init`, `privileged`,
  # `host_ipc`, `host_pid`, `host_uts`, `host_dbus`, `full_access`,
  # `devices`, `dsp`, `map` and `ports`.
  @doc "A manifest that runs as a container, with every field a container is built from at random."
  @spec manifest() :: Config.t()
  def manifest do
    flag = fn -> pick([true, false, false]) end
    some = fn list -> Enum.filter(list, fn _ -> :rand.uniform(3) == 1 end) end

    ports =
      for port <- some.(["80/tcp", "443/tcp", "53/udp", "1883/tcp", "8888/tcp", "9000/tcp"]),
          into: %{},
          do: {port, pick([nil, 0, 80, 8_123, 8_888, 1_883, 40_000])}

    map =
      for type <- some.(~w(ssl share media backup config homeassistant_config
                           all_addon_configs addons addon_config unknown_type)) do
        pick([
          type,
          type <> ":rw",
          type <> ":ro",
          %{"type" => type, "read_only" => flag.(), "path" => pick([nil, "/custom"])}
        ])
      end

    parse!(%{
      "name" => "generated",
      "version" => pick(["1", "2.0.1", "2026.10.0b1", "latest"]),
      "slug" => pick(["gen", "gen_under_score", "Gen.Dot-dash", "a0d7b954_gen"]),
      "image" => pick(["local/gen", "ghcr.io/x/{arch}-gen", "{arch}/gen-{arch}"]),
      "host_network" => flag.(),
      "init" => flag.(),
      "privileged" => some.(["NET_ADMIN", "SYS_ADMIN", "SYS_RAWIO", "SYS_PTRACE"]),
      "host_ipc" => flag.(),
      "host_pid" => flag.(),
      "host_uts" => flag.(),
      "host_dbus" => flag.(),
      "full_access" => flag.(),
      "devices" => some.(["/dev/null", "/dev/zero", "/dev/absent0", "/etc/hostname"]),
      "dsp" => flag.(),
      "map" => map,
      "ports" => ports
    })
  end

  @doc "Any term at all: what a validator must refuse without raising."
  @spec garbage(non_neg_integer()) :: term()
  def garbage(depth \\ 2) do
    leaves = [
      fn ->
        pick([nil, true, :lifecycle, :container, :core, :native, :config, "", "x", 0, -1])
      end,
      fn -> pick([1.5, self(), make_ref(), <<255, 254>>, &is_atom/1, 65_536, {}, {:a, 1}]) end,
      fn -> pick([[1 | 2], [], %{}, ~D[2026-10-07], 1..3, MapSet.new([1]), "9" <> <<0>>]) end,
      fn -> pick([[1], %{"x" => %{}}, %{<<255>> => 1}, %{1 => 1}, ["a" | "b"], 1.0e308]) end,
      fn ->
        pick(["1.0\n", "auto", "manual", "once", 62_000, 61_999, 8_888, [%{}], %{"a" => []}])
      end
    ]

    nested = [
      fn -> for _ <- 1..:rand.uniform(3), do: garbage(depth - 1) end,
      fn ->
        for _ <- 1..:rand.uniform(4), into: %{}, do: {garbage(0), garbage(depth - 1)}
      end,
      fn -> List.to_tuple(for _ <- 1..:rand.uniform(3), do: garbage(depth - 1)) end
    ]

    pick(if(depth > 0, do: leaves ++ nested, else: leaves)).()
  end
end
