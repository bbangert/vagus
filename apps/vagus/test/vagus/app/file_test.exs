defmodule Vagus.App.FileTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.Addon.Config
  alias Vagus.App.File, as: AppFile

  @moduletag :tmp_dir

  # Written by 0.9.0's `Vagus.Addon.State` itself: a native app, an ingress app
  # with every setting moved off its default, and a stopped host-network app
  # with a dynamic ingress port.
  @fixture Path.expand("../../fixtures/addons-0.9.0.json", __DIR__)

  setup %{tmp_dir: tmp} do
    {:ok, config} =
      Config.parse(%{
        "name" => "Mosquitto broker",
        "version" => "7.1.0",
        "slug" => "core_mosquitto",
        "description" => "MQTT",
        "arch" => ["aarch64"]
      })

    %{config: config, dir: Path.join(tmp, "apps")}
  end

  defp data(config, extra \\ %{}) do
    Map.merge(
      %{
        config: config,
        wanted: :started,
        user_options: %{"greeting" => "hi"},
        ingress_token: "itok",
        ingress_port: 62_001,
        ingress_panel: true,
        watchdog: true,
        ports: %{"1883/tcp" => 1884},
        boot: "manual",
        auto_update: false,
        protected: false
      },
      extra
    )
  end

  defp put_raw(dir, slug, raw) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, slug <> ".json"), Jason.encode!(raw))
  end

  defp file_body(config, extra \\ %{}),
    do: Map.merge(%{"config" => Config.to_persistable(config), "wanted" => "started"}, extra)

  test "write then read round-trips every persisted field", %{config: c, dir: dir} do
    saved = data(c)
    assert :ok = AppFile.write(Map.merge(saved, %{token: "secret", container_id: "c1"}), dir)
    assert {:ok, ^saved} = AppFile.read("core_mosquitto", dir)

    on_disk = Jason.decode!(File.read!(Path.join(dir, "core_mosquitto.json")))
    refute Map.has_key?(on_disk, "token")
    refute Map.has_key?(on_disk, "container_id")
    assert on_disk["network"] == %{"1883/tcp" => 1884}
    assert File.ls!(dir) == ["core_mosquitto.json"]
  end

  test "saved/0 lists slugs with a file; delete/1 removes one and tolerates none", %{
    config: c,
    dir: dir
  } do
    assert AppFile.saved(dir) == []
    :ok = AppFile.write(data(c), dir)
    File.write!(Path.join(dir, "core_mosquitto.json.tmp"), "")
    File.write!(Path.join(dir, "notes.txt"), "")
    File.write!(Path.join(dir, "...json"), "")

    assert AppFile.saved(dir) == ["core_mosquitto"]
    assert :ok = AppFile.delete("core_mosquitto", dir)
    assert AppFile.saved(dir) == []
    assert :error = AppFile.read("core_mosquitto", dir)
    assert :ok = AppFile.delete("core_mosquitto", dir)
  end

  test "an unsafe slug is never read", %{dir: dir} do
    assert :error = AppFile.read("../addons", dir)
  end

  describe "decoding is tolerant except where it must fail closed" do
    test "a file with only the required fields gets defaults and a generated token", %{
      config: c,
      dir: dir
    } do
      put_raw(dir, "core_mosquitto", file_body(c))

      assert {:ok,
              %{
                wanted: :started,
                user_options: %{},
                ingress_token: token,
                ingress_port: nil,
                ingress_panel: false,
                watchdog: false,
                ports: %{},
                boot: nil,
                auto_update: nil,
                protected: true
              }} = AppFile.read("core_mosquitto", dir)

      assert token =~ ~r/^[-_A-Za-z0-9]{43}$/
      {:ok, entry} = AppFile.read("core_mosquitto", dir)
      assert {entry.user_options, entry.ports} == {%{}, %{}}
    end

    test "garbage settings fall back; protected falls back to true", %{config: c, dir: dir} do
      put_raw(
        dir,
        "core_mosquitto",
        file_body(c, %{
          "user_options" => "nope",
          "ingress_token" => 7,
          "ingress_port" => -1,
          "ingress_panel" => "yes",
          "watchdog" => 1,
          "network" => %{"1883/tcp" => 70_000, "8883/tcp" => nil, "x" => "y"},
          "boot" => "manual_only",
          "auto_update" => "yes",
          "protected" => "false"
        })
      )

      assert {:ok, entry} = AppFile.read("core_mosquitto", dir)

      assert %{
               user_options: %{},
               ingress_port: nil,
               ingress_panel: false,
               watchdog: false,
               ports: %{"8883/tcp" => nil},
               boot: nil,
               auto_update: nil,
               protected: true
             } = entry

      assert is_binary(entry.ingress_token)
      # Map patterns match partially; the filter is only proven by equality.
      assert {entry.user_options, entry.ports} == {%{}, %{"8883/tcp" => nil}}
    end

    test "a file whose config fails to parse, names another slug, or is reserved is skipped",
         %{config: c, dir: dir} do
      put_raw(dir, "bad", %{"config" => %{"not" => "a config"}, "wanted" => "started"})
      put_raw(dir, "other", file_body(c))

      put_raw(
        dir,
        "vagus",
        file_body(%{c | slug: "vagus"}) |> put_in(["config", "slug"], "vagus")
      )

      put_raw(dir, "core_mosquitto", file_body(c, %{"wanted" => "running"}))

      log =
        capture_log(fn ->
          for slug <- ["bad", "other", "vagus", "core_mosquitto"],
              do: assert({:error, :invalid} = AppFile.read(slug, dir))
        end)

      assert log =~ "skipping invalid or mismatched app \"vagus\""
    end

    test "a file that is not JSON is an error, not raised and not taken for no file", %{
      dir: dir
    } do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "core_mosquitto.json"), "{{{ not json")

      assert capture_log(fn ->
               assert {:error, :not_json} = AppFile.read("core_mosquitto", dir)
             end) =~ "not valid JSON"
    end

    test "a file that cannot be read is an error with its reason", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "core_mosquitto.json"))

      assert capture_log(fn ->
               assert {:error, :eisdir} = AppFile.read("core_mosquitto", dir)
             end) =~ "could not read"
    end
  end

  describe "import_once/2" do
    setup %{tmp_dir: tmp} do
      legacy = Path.join(tmp, "addons.json")
      File.cp!(@fixture, legacy)
      %{legacy: legacy}
    end

    test "every field of every 0.9.0 entry, and addons.json untouched", %{
      dir: dir,
      legacy: legacy
    } do
      before = File.read!(legacy)
      %{mtime: mtime} = File.stat!(legacy)
      fixture = Jason.decode!(before)["addons"]

      capture_log(fn -> assert {:ok, 3} = AppFile.import_once(dir, legacy) end)

      assert Enum.sort(AppFile.saved(dir)) == ["core_mqtt", "core_ssh", "esphome_esphome"]
      assert File.read!(legacy) == before
      assert File.stat!(legacy).mtime == mtime

      assert {:ok, mqtt} = AppFile.read("core_mqtt", dir)

      assert %{
               wanted: :started,
               user_options: %{},
               ingress_port: nil,
               ingress_panel: false,
               watchdog: false,
               ports: %{},
               boot: nil,
               auto_update: nil,
               protected: true
             } = mqtt

      assert mqtt.config.backend == :native
      assert {mqtt.user_options, mqtt.ports} == {%{}, %{}}
      assert mqtt.ingress_token == fixture["core_mqtt"]["ingress_token"]

      assert {:ok, ssh} = AppFile.read("core_ssh", dir)

      assert %{
               wanted: :started,
               user_options: %{"authorized_keys" => ["ssh-ed25519 AAAA test"], "password" => ""},
               ingress_panel: true,
               ports: %{"22/tcp" => 2222},
               protected: false
             } = ssh

      assert ssh.ingress_token == fixture["core_ssh"]["ingress_token"]
      assert ssh.config.full_access
      assert ssh.config.version == "10.5.0"

      assert {:ok, esphome} = AppFile.read("esphome_esphome", dir)

      assert %{
               wanted: :stopped,
               user_options: %{"leave_front_door_open" => true},
               ingress_port: 62_917,
               ingress_panel: true,
               watchdog: true,
               boot: "manual",
               auto_update: true,
               protected: true
             } = esphome

      assert esphome.ingress_token == fixture["esphome_esphome"]["ingress_token"]
      assert esphome.config.host_network
      assert esphome.config.backup == "cold"

      for {slug, entry} <- fixture,
          do: assert({:ok, read!(slug, dir)} == Config.parse(entry["config"]))
    end

    test "a second call is a no-op, even after addons.json changes", %{dir: dir, legacy: legacy} do
      capture_log(fn -> assert {:ok, 3} = AppFile.import_once(dir, legacy) end)
      :ok = AppFile.delete("core_ssh", dir)
      File.write!(legacy, ~s({"version": 1, "addons": {}}))

      assert {:ok, :skipped} = AppFile.import_once(dir, legacy)
      assert Enum.sort(AppFile.saved(dir)) == ["core_mqtt", "esphome_esphome"]
    end

    test "a stray staging dir from an earlier attempt is discarded", %{dir: dir, legacy: legacy} do
      staging = dir <> ".import"
      File.mkdir_p!(staging)
      File.write!(Path.join(staging, "stray.json"), "{}")

      capture_log(fn -> assert {:ok, 3} = AppFile.import_once(dir, legacy) end)
      refute File.exists?(staging)
      refute "stray" in AppFile.saved(dir)
    end

    test "a corrupt entry is skipped and the rest imported", %{dir: dir, legacy: legacy} do
      addons = Jason.decode!(File.read!(legacy))["addons"]
      addons = Map.put(addons, "broken", %{"config" => %{}, "state" => "started"})
      File.write!(legacy, Jason.encode!(%{"version" => 1, "addons" => addons}))

      log = capture_log(fn -> assert {:ok, 3} = AppFile.import_once(dir, legacy) end)
      assert log =~ "broken"
    end

    test "with no addons.json the directory is created empty", %{dir: dir, tmp_dir: tmp} do
      capture_log(fn ->
        assert {:ok, 0} = AppFile.import_once(dir, Path.join(tmp, "absent.json"))
        assert {:ok, 0} = AppFile.import_once(dir <> "2", nil)
      end)

      assert File.dir?(dir)
      assert {:ok, :skipped} = AppFile.import_once(dir, @fixture)
    end
  end

  defp read!(slug, dir) do
    {:ok, %{config: config}} = AppFile.read(slug, dir)
    config
  end
end
