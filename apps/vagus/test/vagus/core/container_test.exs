defmodule Vagus.Core.ContainerTest do
  @moduledoc """
  async: false — the `name/0` config-override test mutates the global
  `:vagus, :core_container` app env (same key `LogsFollowRouterTest`
  mutates), which is not safe to run concurrently with other tests.
  """
  use ExUnit.Case, async: false

  alias Vagus.Core.Container
  alias Vagus.Runtime.Engine.ContainerSpec

  @ip Vagus.Network.supervisor_ip()

  @config "/tmp/core-config"

  defp spec(version \\ "2026.7.0", opts \\ []),
    do:
      Container.to_container_spec(
        version,
        Keyword.merge([token: "test-token", homeassistant_path: @config], opts)
      )

  describe "to_container_spec/2" do
    test "golden spec: every parity field pinned" do
      spec = spec()

      assert spec == %ContainerSpec{
               name: "homeassistant",
               image: "ghcr.io/home-assistant/home-assistant:2026.7.0",
               hostname: "homeassistant",
               labels: %{Container.spec_fingerprint_label() => Container.spec_fingerprint(spec)},
               env: [
                 {"SUPERVISOR", @ip},
                 {"HASSIO", @ip},
                 {"SUPERVISOR_TOKEN", "test-token"},
                 {"HASSIO_TOKEN", "test-token"},
                 {"SUPERVISOR_CORE_API_SOCKET", "/run/supervisor/core.sock"},
                 {"TZ", "UTC"}
               ],
               secret_env: ["SUPERVISOR_TOKEN", "HASSIO_TOKEN"],
               network: :host,
               privileged: true,
               oom_score_adj: -300,
               restart: :unless_stopped,
               extra_hosts: [{"supervisor", @ip}],
               tmpfs: %{"/tmp" => ""},
               mounts: [
                 %{
                   type: :bind,
                   source: "/dev",
                   target: "/dev",
                   read_only: true,
                   read_only_non_recursive: true
                 },
                 %{type: :bind, source: "/run/dbus", target: "/run/dbus", read_only: true},
                 %{type: :bind, source: "/run/udev", target: "/run/udev", read_only: true},
                 %{
                   type: :bind,
                   source: "/run/supervisor",
                   target: "/run/supervisor",
                   read_only: false
                 },
                 %{type: :bind, source: @config, target: "/config", read_only: false}
               ]
             }
    end

    test "custom tz overrides the UTC default" do
      assert {"TZ", "America/New_York"} in spec("2026.7.0", tz: "America/New_York").env
    end

    test "omitting :token falls back to Vagus.API.Token.get/0" do
      spec = Container.to_container_spec("2026.7.0", homeassistant_path: @config)

      assert {"SUPERVISOR_TOKEN", Vagus.API.Token.get()} in spec.env
    end

    test "passes the podman adapter's validation" do
      assert Vagus.Runtime.Engine.Podman.validate(spec()) == :ok
    end
  end

  describe "the add-on/Core contract address" do
    # The Supervisor-API listener no longer holds port 80: it binds
    # `172.30.32.2:<:api_port>` (`Vagus.API.Listener`) and 80 on that same
    # address is a DNAT (`Vagus.Network.Nat`). Core has no way to be told a
    # port — upstream reads `SUPERVISOR` as a bare host and dials 80 — so the
    # bare form below is what makes the rewrite load-bearing. Growing a
    # `:8888` suffix here would point Core at a port that answers today and
    # bypasses the contract, and an explicit suffix was device-proven to break
    # Core outright during the bluetooth work.
    test "SUPERVISOR/HASSIO carry the bare anchor — never a port suffix" do
      env = spec().env

      assert {"SUPERVISOR", "172.30.32.2"} in env
      assert {"HASSIO", "172.30.32.2"} in env

      refute Enum.any?(env, fn {key, value} ->
               key in ["SUPERVISOR", "HASSIO"] and value =~ ~r/:\d+\z/
             end)
    end

    test "extra_hosts maps `supervisor` to the anchor, portless by construction" do
      assert spec().extra_hosts == [{"supervisor", "172.30.32.2"}]
    end

    test "the anchor the env carries is Vagus.Network's, not a second copy" do
      assert Vagus.Network.supervisor_ip() == "172.30.32.2"
      assert {"SUPERVISOR", Vagus.Network.supervisor_ip()} in spec("x").env
    end
  end

  describe "the Supervisor socket (Phase A1)" do
    test "socket_dir/0 + socket_path/0 are the upstream paths" do
      assert Container.socket_dir() == "/run/supervisor"
      assert Container.socket_path() == "/run/supervisor/core.sock"
    end

    test "the socket dir is bind-mounted writable, same path on both sides" do
      assert %{
               type: :bind,
               source: "/run/supervisor",
               target: "/run/supervisor",
               read_only: false
             } in spec().mounts
    end

    test "SUPERVISOR_CORE_API_SOCKET points at socket_path/0" do
      assert {"SUPERVISOR_CORE_API_SOCKET", Container.socket_path()} in spec().env
    end
  end

  describe "spec_fingerprint/1" do
    test "is a pure lowercase hex digest" do
      assert Container.spec_fingerprint(spec()) == Container.spec_fingerprint(spec())
      assert Container.spec_fingerprint(spec()) =~ ~r/\A[0-9a-f]{32}\z/
    end

    test "ignores the labels it is itself stamped into, the name and secret_env" do
      fingerprint = Container.spec_fingerprint(spec())

      for changed <- [
            %{spec() | labels: nil},
            %{spec() | labels: %{"other" => "value"}},
            %{spec() | name: "homeassistant-dev"},
            %{spec() | secret_env: []}
          ] do
        assert Container.spec_fingerprint(changed) == fingerprint
      end
    end

    test "changes with the image, env, mounts and any field the spec gains" do
      base = spec()
      fingerprint = Container.spec_fingerprint(base)

      for changed <- [
            spec("2026.8.0"),
            spec("2026.7.0", token: "other-token"),
            spec("2026.7.0", tz: "Europe/Berlin"),
            spec("2026.7.0", homeassistant_path: "/tmp/elsewhere"),
            %{base | mounts: tl(base.mounts)},
            %{base | privileged: false},
            %{base | cap_add: ["NET_ADMIN"]},
            %{base | init: false},
            %{base | security_opt: ["seccomp=unconfined"]}
          ] do
        refute Container.spec_fingerprint(changed) == fingerprint, inspect(changed)
      end
    end

    test "list order is significant (a reordered env is a different spec)" do
      base = spec()

      refute Container.spec_fingerprint(%{base | env: Enum.reverse(base.env)}) ==
               Container.spec_fingerprint(base)
    end

    test "the label key is namespaced" do
      assert Container.spec_fingerprint_label() == "io.vagus.spec-fingerprint"
    end
  end

  # Literals 0.10.0 stamped on podman boards (computed over the Docker
  # Engine-API create body it rendered), so a fingerprint that drifts from
  # them — and would recreate Core on every board — fails here rather than
  # echoing itself.
  describe "fingerprint parity with 0.10.0" do
    test "the boards' config path, a token and the default tz" do
      assert fingerprint("2026.7.0", "t", "UTC", "/root/vagus/core/config") ==
               "1548a524eb16e2cecf3ec8cb9dab5fb3"

      assert fingerprint("2026.10.1", "abc", "UTC", "/root/vagus/core/config") ==
               "f4ab354997ccffb1adfa6a74487cc8fe"
    end

    test "a board still on the legacy config path, with another tz" do
      legacy = "/root/balena-engine/volumes/vagus-core-config/_data"

      assert fingerprint("2026.10.1", "tok123", "Europe/Berlin", legacy) ==
               "d450c49453f44732f995f3d945c65b93"
    end

    defp fingerprint(version, token, tz, path) do
      Container.to_container_spec(version, token: token, tz: tz, homeassistant_path: path).labels[
        Container.spec_fingerprint_label()
      ]
    end
  end

  describe "config_path/1" do
    test "the migration's resolver decides" do
      assert Container.config_path() == Vagus.Runtime.Migration.core_config_path()
    end

    test "opts[:homeassistant_path] overrides the whole path" do
      assert Container.config_path(homeassistant_path: "/tmp/fake-core-config") ==
               "/tmp/fake-core-config"
    end
  end

  describe "image?/1" do
    test "any version of Core's image, and nothing else" do
      assert Container.image?(Container.image("2026.7.0"))
      refute Container.image?("ghcr.io/home-assistant/home-assistant-dev:1")
      refute Container.image?("ghcr.io/home-assistant/aarch64-addon-mosquitto:6.5.0")
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
