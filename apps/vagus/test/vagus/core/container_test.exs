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
               "Env" => [
                 "SUPERVISOR=#{@ip}",
                 "HASSIO=#{@ip}",
                 "SUPERVISOR_TOKEN=test-token",
                 "HASSIO_TOKEN=test-token",
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
