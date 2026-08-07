defmodule Vagus.Core.ContainerTest do
  @moduledoc """
  async: false — the `name/0` config-override test mutates the global
  `:vagus, :core_container` app env (same key `LogsFollowRouterTest`
  mutates), which is not safe to run concurrently with other tests.
  """
  use ExUnit.Case, async: false

  alias Vagus.Core.Container

  @ip Vagus.Network.supervisor_ip()

  describe "create_config/2" do
    test "golden map: every parity field pinned" do
      config = Container.create_config("2026.7.0", token: "test-token")

      assert config == %{
               "Image" => "ghcr.io/home-assistant/home-assistant:2026.7.0",
               "Hostname" => "homeassistant",
               "Labels" => %{
                 Container.spec_fingerprint_label() => Container.spec_fingerprint(config)
               },
               "Env" => [
                 "SUPERVISOR=#{@ip}",
                 "HASSIO=#{@ip}",
                 "SUPERVISOR_TOKEN=test-token",
                 "HASSIO_TOKEN=test-token",
                 "SUPERVISOR_CORE_API_SOCKET=/run/supervisor/core.sock",
                 "TZ=UTC"
               ],
               "HostConfig" => %{
                 "NetworkMode" => "host",
                 "Privileged" => true,
                 "OomScoreAdj" => -300,
                 "RestartPolicy" => %{"Name" => "unless-stopped"},
                 "ExtraHosts" => ["supervisor:#{@ip}"],
                 "Tmpfs" => %{"/tmp" => ""},
                 "Mounts" => [
                   %{
                     "Type" => "bind",
                     "Source" => "/dev",
                     "Target" => "/dev",
                     "ReadOnly" => true,
                     "BindOptions" => %{"ReadOnlyNonRecursive" => true}
                   },
                   %{
                     "Type" => "bind",
                     "Source" => "/run/dbus",
                     "Target" => "/run/dbus",
                     "ReadOnly" => true
                   },
                   %{
                     "Type" => "bind",
                     "Source" => "/run/udev",
                     "Target" => "/run/udev",
                     "ReadOnly" => true
                   },
                   %{
                     "Type" => "bind",
                     "Source" => "/run/supervisor",
                     "Target" => "/run/supervisor",
                     "ReadOnly" => false
                   },
                   %{
                     "Type" => "volume",
                     "Source" => "vagus-core-config",
                     "Target" => "/config"
                   }
                 ]
               }
             }
    end

    test "custom tz overrides the UTC default" do
      config = Container.create_config("2026.7.0", token: "test-token", tz: "America/New_York")

      assert "TZ=America/New_York" in config["Env"]
    end

    test "omitting :token falls back to Vagus.API.Token.get/0" do
      config = Container.create_config("2026.7.0")

      assert "SUPERVISOR_TOKEN=#{Vagus.API.Token.get()}" in config["Env"]
    end
  end

  describe "the Supervisor socket (Phase A1)" do
    test "socket_dir/0 + socket_path/0 are the upstream paths" do
      assert Container.socket_dir() == "/run/supervisor"
      assert Container.socket_path() == "/run/supervisor/core.sock"
    end

    test "the socket dir is bind-mounted writable, same path on both sides" do
      config = Container.create_config("2026.7.0", token: "test-token")

      assert %{
               "Type" => "bind",
               "Source" => "/run/supervisor",
               "Target" => "/run/supervisor",
               "ReadOnly" => false
             } in config["HostConfig"]["Mounts"]
    end

    test "SUPERVISOR_CORE_API_SOCKET points at socket_path/0" do
      config = Container.create_config("2026.7.0", token: "test-token")

      assert "SUPERVISOR_CORE_API_SOCKET=#{Container.socket_path()}" in config["Env"]
    end
  end

  describe "spec_fingerprint/1" do
    test "is pure: the same spec always hashes to the same value" do
      config = Container.create_config("2026.7.0", token: "test-token")

      assert Container.spec_fingerprint(config) == Container.spec_fingerprint(config)

      assert Container.spec_fingerprint(config) ==
               Container.spec_fingerprint(
                 Container.create_config("2026.7.0", token: "test-token")
               )
    end

    test "is a lowercase hex digest" do
      config = Container.create_config("2026.7.0", token: "test-token")

      assert Container.spec_fingerprint(config) =~ ~r/\A[0-9a-f]{32}\z/
    end

    test "ignores the Labels key it is itself stamped into" do
      config = Container.create_config("2026.7.0", token: "test-token")

      assert Container.spec_fingerprint(Map.delete(config, "Labels")) ==
               Container.spec_fingerprint(config)

      assert Container.spec_fingerprint(Map.put(config, "Labels", %{"other" => "value"})) ==
               Container.spec_fingerprint(config)
    end

    test "ignores map key ordering (canonicalized before hashing)" do
      config = Container.create_config("2026.7.0", token: "test-token")

      reordered =
        config
        |> Map.delete("HostConfig")
        |> Map.put("HostConfig", config["HostConfig"])

      assert Container.spec_fingerprint(reordered) == Container.spec_fingerprint(config)
    end

    test "changes with the image, env, and mounts" do
      base = Container.create_config("2026.7.0", token: "test-token")
      fingerprint = Container.spec_fingerprint(base)

      refute Container.spec_fingerprint(Container.create_config("2026.8.0", token: "test-token")) ==
               fingerprint

      refute Container.spec_fingerprint(Container.create_config("2026.7.0", token: "other-token")) ==
               fingerprint

      refute Container.spec_fingerprint(
               Container.create_config("2026.7.0", token: "test-token", tz: "Europe/Berlin")
             ) == fingerprint

      dropped_mount =
        update_in(base, ["HostConfig", "Mounts"], fn [_socket | rest] -> rest end)

      refute Container.spec_fingerprint(dropped_mount) == fingerprint
    end

    test "list order is significant (a reordered Env is a different spec)" do
      config = Container.create_config("2026.7.0", token: "test-token")
      reversed = Map.put(config, "Env", Enum.reverse(config["Env"]))

      refute Container.spec_fingerprint(reversed) == Container.spec_fingerprint(config)
    end
  end

  describe "create_config/2 fingerprint label" do
    test "stamps the fingerprint of the spec it just built" do
      config = Container.create_config("2026.7.0", token: "test-token")

      assert config["Labels"] == %{
               Container.spec_fingerprint_label() => Container.spec_fingerprint(config)
             }
    end

    test "the label key is namespaced" do
      assert Container.spec_fingerprint_label() == "io.vagus.spec-fingerprint"
    end
  end

  describe "config_path/1" do
    test "defaults to <engine data root>/volumes/<config_volume>/_data" do
      assert Container.config_path() ==
               Path.join([
                 Vagus.Engine.Manager.data_root(),
                 "volumes",
                 Container.config_volume(),
                 "_data"
               ])
    end

    test "opts[:homeassistant_path] overrides the whole path" do
      assert Container.config_path(homeassistant_path: "/tmp/fake-core-config") ==
               "/tmp/fake-core-config"
    end
  end

  describe "image/1" do
    test "formats the generic Core image repo with the given version tag" do
      assert Container.image("2026.7.0") == "ghcr.io/home-assistant/home-assistant:2026.7.0"
    end
  end

  describe "name/0" do
    test "defaults to \"homeassistant\" with no app-env override" do
      assert Container.name() == "homeassistant"
    end
  end

  describe "name/0 with a config override" do
    setup do
      previous = Application.get_env(:vagus, :core_container)
      on_exit(fn -> restore_env(previous) end)
      :ok
    end

    test "prefers config :vagus, :core_container when set" do
      Application.put_env(:vagus, :core_container, "homeassistant-dev")
      assert Container.name() == "homeassistant-dev"
    end

    defp restore_env(nil), do: Application.delete_env(:vagus, :core_container)
    defp restore_env(value), do: Application.put_env(:vagus, :core_container, value)
  end
end
