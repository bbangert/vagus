defmodule Vagus.Test.AppManifests do
  @moduledoc """
  Manifests to run the App spec's functions over, and a generator of
  variations on them.

  The repository keeps no store manifests as files. Three here are ones it
  does hold: the built-in broker's (`Vagus.Addon.Store.BuiltinFetcher`),
  the probe app the device-captured container fingerprint was taken from,
  and the broker manifest the old builder's own tests use. The rest are
  written after store apps, one for each thing a manifest can ask of a
  container.

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
      "homeassistant" => "2024.1.0"
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
      fn -> :rand.uniform(2_000_000) - 1_000_000 end,
      fn -> :rand.uniform() * 100 end,
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
    pick(["", "a", "é ü", ":atom", "{\"tuple\": [1]}", "$stamp", "true", "0", "x/y.z-1_2"]) <>
      Integer.to_string(:rand.uniform(99))
  end

  @doc "Any term at all: what a validator must refuse without raising."
  @spec garbage(non_neg_integer()) :: term()
  def garbage(depth \\ 2) do
    leaves = [
      fn ->
        pick([nil, true, :lifecycle, :container, :core, :native, :config, "", "x", 0, -1])
      end,
      fn -> pick([1.5, self(), make_ref(), <<255, 254>>, &is_atom/1, 65_536, {}, {:a, 1}]) end,
      fn -> pick([[1 | 2], [], %{}, ~D[2026-10-07], 1..3, MapSet.new([1]), "9" <> <<0>>]) end
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
