defmodule Vagus.Addon.ManagerTest do
  use ExUnit.Case, async: false

  alias Vagus.Addon.{Config, Manager}

  defp mosquitto_config do
    {:ok, c} =
      Config.parse(%{
        "name" => "Mosquitto broker",
        "version" => "7.1.0",
        "slug" => "core_mosquitto",
        "description" => "MQTT broker",
        "arch" => ["aarch64", "amd64"],
        "image" => "homeassistant/{arch}-addon-mosquitto",
        "init" => false,
        "startup" => "system",
        "auth_api" => true,
        "services" => ["mqtt:provide"],
        "discovery" => ["mqtt"],
        "ports" => %{"1883/tcp" => 1883, "8883/tcp" => 8883},
        "map" => ["ssl", "share"]
      })

    c
  end

  describe "build_spec/2 (hermetic)" do
    setup do
      spec =
        Manager.build_spec(mosquitto_config(),
          access_token: "tok123",
          arch: "amd64",
          data_root: "/data"
        )

      %{spec: spec}
    end

    test "identity: name, hostname, arch-resolved image", %{spec: s} do
      assert s.name == "addon_core_mosquitto"
      assert s.hostname == "core-mosquitto"
      assert s.image == "homeassistant/amd64-addon-mosquitto:7.1.0"
      assert s.platform == "linux/amd64"
    end

    test "env carries TZ + both supervisor token names", %{spec: s} do
      assert s.env["SUPERVISOR_TOKEN"] == "tok123"
      assert s.env["HASSIO_TOKEN"] == "tok123"
      assert s.env["TZ"] == "UTC"
    end

    test "hassio-bridge attach with injected hosts + CoreDNS resolver (P1-T3)", %{spec: s} do
      assert s.network == :hassio
      assert s.extra_hosts == %{"supervisor" => "172.30.32.2", "hassio" => "172.30.32.2"}
      assert s.dns == ["172.30.32.3"]
      assert s.dns_search == ["local.hass.io"]
      assert s.dns_options == ["timeout:10"]
    end

    test "init from config, /dev/shm tmpfs, ports passthrough", %{spec: s} do
      assert s.init == false
      assert s.tmpfs == %{"/dev/shm" => ""}
      assert s.ports == %{"1883/tcp" => 1883, "8883/tcp" => 8883}
    end

    test "mounts: /data always + map-derived /ssl,/share with data-root sources", %{spec: s} do
      data = Enum.find(s.mounts, &(&1.target == "/data"))
      assert data.source == "/data/addons/data/core_mosquitto"
      assert data.read_only == false

      ssl = Enum.find(s.mounts, &(&1.target == "/ssl"))
      assert ssl.source == "/data/ssl"

      share = Enum.find(s.mounts, &(&1.target == "/share"))
      assert share.source == "/data/share"
      assert share.propagation == "rslave"
    end

    test "host_network add-on: NetworkMode host, no ports/hostname", %{} do
      {:ok, hostcfg} =
        Config.parse(%{
          "name" => "N",
          "version" => "1",
          "slug" => "hostnet",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "x/y",
          "host_network" => true,
          "ports" => %{"9/tcp" => 9}
        })

      s = Manager.build_spec(hostcfg, access_token: "t", arch: "amd64")
      assert s.network == :host
      assert s.hostname == nil
      assert s.ports == %{}
    end
  end

  describe "install + start orchestration (fake backend)" do
    # Real bind-mount execution can't be exercised in this docker-outside-of-
    # docker devcontainer (host daemon can't resolve devcontainer paths); that
    # is covered by the on-device Gate-1 run. Here an injected fake backend
    # verifies the orchestration + the spec the manager builds, deterministically
    # and without a daemon.
    setup do
      :persistent_term.put({__MODULE__.FakeBackend, :pid}, self())
      data_root = Path.join(System.tmp_dir!(), "vagus-mgr-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(data_root) end)

      {:ok, config} =
        Config.parse(%{
          "name" => "Test",
          "version" => "3",
          "slug" => "test_addon",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "homeassistant/{arch}-addon-test",
          "map" => ["share"],
          "host_network" => true,
          "options" => %{"greeting" => "hi"},
          "schema" => %{"greeting" => "str"}
        })

      %{config: config, data_root: data_root}
    end

    test "install pulls via the backend", %{config: config, data_root: dr} do
      assert :ok = Manager.install(config, backend: __MODULE__.FakeBackend, data_root: dr)
      assert_received {:pull, %{image: "homeassistant/amd64-addon-test:3"}}
    end

    test "start writes options.json, creates + starts, returns id + 112-char token",
         %{config: config, data_root: dr} do
      assert {:ok, %{id: "fake-id", access_token: token}} =
               Manager.start(config, backend: __MODULE__.FakeBackend, data_root: dr)

      assert byte_size(token) == 112

      # options validated (against schema) + written to the /data source dir
      opts_path = Path.join([dr, "addons", "data", "test_addon", "options.json"])
      assert File.exists?(opts_path)
      assert Jason.decode!(File.read!(opts_path)) == %{"greeting" => "hi"}

      # the backend received a fully-built spec with the token + mounts
      assert_received {:create, spec}
      assert spec.name == "addon_test_addon"
      assert spec.env["SUPERVISOR_TOKEN"] == token
      assert Enum.any?(spec.mounts, &(&1.target == "/data"))
      assert Enum.any?(spec.mounts, &(&1.target == "/share"))
      assert_received {:start, "fake-id"}
    end

    test "invalid options (schema mismatch) fail start before any create",
         %{data_root: dr} do
      {:ok, bad} =
        Config.parse(%{
          "name" => "B",
          "version" => "1",
          "slug" => "bad",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "x/y",
          "host_network" => true,
          "schema" => %{"port" => "port"},
          "options" => %{"port" => 70_000}
        })

      assert {:error, {:invalid_options, _}} =
               Manager.start(bad, backend: __MODULE__.FakeBackend, data_root: dr)

      refute_received {:create, _}
    end
  end

  defmodule FakeBackend do
    @behaviour Vagus.Addon.Backend

    defp notify(msg),
      do: send(:persistent_term.get({Vagus.Addon.ManagerTest.FakeBackend, :pid}), msg)

    @impl true
    def pull(spec), do: notify({:pull, spec}) && :ok

    @impl true
    def create(spec) do
      notify({:create, spec})
      {:ok, "fake-id"}
    end

    @impl true
    def start(id), do: notify({:start, id}) && :ok

    @impl true
    def stop(_id, _opts \\ []), do: :ok

    @impl true
    def remove(_id, _opts \\ []), do: :ok

    @impl true
    def state(_id), do: {:ok, :running}
  end
end
