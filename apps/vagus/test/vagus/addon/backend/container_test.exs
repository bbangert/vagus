defmodule Vagus.Addon.Backend.ContainerTest do
  use ExUnit.Case, async: true

  alias Vagus.Addon.Backend.{Container, Spec}

  defp mosquitto_spec(overrides \\ []) do
    base = %Spec{
      name: "addon_core_mosquitto",
      image: "homeassistant/amd64-addon-mosquitto:7.1.0",
      hostname: "core-mosquitto",
      env: %{"TZ" => "UTC", "SUPERVISOR_TOKEN" => "tok", "HASSIO_TOKEN" => "tok"},
      network: :hassio,
      extra_hosts: %{"supervisor" => "172.30.32.2", "hassio" => "172.30.32.2"},
      dns: ["172.30.32.3"],
      dns_search: ["local.hass.io"],
      dns_options: ["timeout:10"],
      init: false,
      ports: %{"1883/tcp" => "1883", "8883/tcp" => "8883"},
      mounts: [
        %{source: "/data/ssl", target: "/ssl", read_only: false},
        %{source: "/data/share", target: "/share", read_only: false, propagation: "rslave"}
      ]
    }

    struct(base, overrides)
  end

  defp container_spec(overrides \\ []),
    do: overrides |> mosquitto_spec() |> Container.to_container_spec()

  describe "to_container_spec/1 — pinned §A1.4 invariants" do
    setup do
      %{spec: container_spec()}
    end

    test("never privileged", %{spec: spec}, do: assert(spec.privileged == false))

    test "security_opt always includes seccomp=unconfined", %{spec: spec} do
      assert spec.security_opt == ["seccomp=unconfined"]
    end

    test("oom_score_adj is 200", %{spec: spec}, do: assert(spec.oom_score_adj == 200))

    test("restart is :no, so the engine never restarts it", %{spec: spec},
      do: assert(spec.restart == :no)
    )

    test "supervisor_managed label always present", %{spec: spec} do
      assert spec.labels["supervisor_managed"] == ""
    end

    test "extra_hosts sorted", %{spec: spec} do
      assert spec.extra_hosts == [{"hassio", "172.30.32.2"}, {"supervisor", "172.30.32.2"}]
    end

    test "DNS wiring", %{spec: spec} do
      assert spec.dns == ["172.30.32.3"]
      assert spec.dns_search == ["local.hass.io"]
      assert spec.dns_options == ["timeout:10"]
    end

    test("init reflects the spec", %{spec: spec}, do: assert(spec.init == false))

    test "hostname + domainname + bridge alias", %{spec: spec} do
      assert spec.hostname == "core-mosquitto"
      assert spec.domainname == "local.hass.io"
      assert spec.network == {:bridge, "hassio"}
      assert spec.network_aliases == ["core-mosquitto"]
    end

    test "ports pass through", %{spec: spec} do
      assert spec.ports == %{"1883/tcp" => "1883", "8883/tcp" => "8883"}
    end

    test "env map normalized to a sorted pair list", %{spec: spec} do
      assert spec.env == [{"HASSIO_TOKEN", "tok"}, {"SUPERVISOR_TOKEN", "tok"}, {"TZ", "UTC"}]
    end

    test "mounts → bind mounts with propagation + read_only", %{spec: spec} do
      assert [ssl, share] = spec.mounts
      assert %{type: :bind, source: "/data/ssl", target: "/ssl", read_only: false} = ssl
      assert share.propagation == "rslave"
    end
  end

  describe "to_container_spec/1 — variants" do
    test "apparmor profile adds a security_opt entry" do
      assert container_spec(apparmor: "addon_core_mosquitto").security_opt == [
               "seccomp=unconfined",
               "apparmor=addon_core_mosquitto"
             ]
    end

    test "host network: no bridge and no alias" do
      spec = container_spec(network: :host)
      assert spec.network == :host
      assert spec.network_aliases == nil
    end

    test "no hostname → no domainname or alias" do
      spec = container_spec(hostname: nil)
      assert spec.domainname == nil
      assert spec.network_aliases == nil
    end
  end

  describe "to_container_spec/1 — advanced fields" do
    test "cap_add / tmpfs / pid_mode / uts_mode / open_stdin flow through" do
      spec =
        container_spec(
          cap_add: ["NET_ADMIN"],
          tmpfs: %{"/tmp" => "", "/dev/shm" => ""},
          pid_mode: "host",
          uts_mode: "host",
          open_stdin: true
        )

      assert spec.cap_add == ["NET_ADMIN"]
      assert spec.tmpfs == %{"/tmp" => "", "/dev/shm" => ""}
      assert spec.pid_mode == "host"
      assert spec.uts_mode == "host"
      assert spec.open_stdin == true
    end

    test "device_cgroup_rules flow through, and are stated even when empty" do
      assert container_spec(device_cgroup_rules: ["c 1:3 rwm"]).device_cgroup_rules ==
               ["c 1:3 rwm"]

      # `[]` rather than nil: an add-on granted nothing must still say so
      # explicitly, same as cap_add/dns (D-C).
      assert container_spec().device_cgroup_rules == []
    end

    test "a mount asking for neither bind option sets neither" do
      spec =
        container_spec(
          mounts: [
            %{source: "/a", target: "/a", read_only: true},
            %{source: "/dev", target: "/dev", read_only: true, read_only_non_recursive: true},
            %{source: "/b", target: "/b", read_only: false, propagation: "rslave"}
          ]
        )

      [plain, dev, prop] = spec.mounts

      assert {plain.propagation, plain.read_only_non_recursive} == {nil, nil}
      assert {dev.propagation, dev.read_only_non_recursive} == {nil, true}
      assert {prop.propagation, prop.read_only_non_recursive} == {"rslave", nil}
    end

    test "hostname set but empty dns → no domainname" do
      assert container_spec(dns: []).domainname == nil
    end
  end

  describe "to_container_spec/1" do
    # Sorted as the `K=V` / `name:ip` strings they render to, which is not
    # the bare-key order once a key ends in a character below `=`/`:`.
    test "env and extra_hosts sort as their rendered strings" do
      spec =
        container_spec(
          env: %{"VAR" => "b", "VAR1" => "a"},
          extra_hosts: %{"h" => "2.2.2.2", "h-1" => "1.1.1.1"}
        )

      assert spec.env == [{"VAR1", "a"}, {"VAR", "b"}]
      assert spec.extra_hosts == [{"h-1", "1.1.1.1"}, {"h", "2.2.2.2"}]
    end

    test "the tokens are marked secret" do
      assert Container.to_container_spec(mosquitto_spec()).secret_env ==
               ["HASSIO_TOKEN", "SUPERVISOR_TOKEN"]
    end
  end

  describe "lifecycle on Engine.Fake" do
    alias Vagus.Runtime.Engine
    alias Vagus.Runtime.Engine.Fake

    setup do
      fake = Fake.start()
      %{fake: fake, opts: [engine: Fake, fake: fake]}
    end

    test "pull then create renders the container from to_container_spec/1", %{
      fake: fake,
      opts: opts
    } do
      spec = mosquitto_spec()
      Engine.ensure_network(%Engine.NetworkSpec{name: "hassio"}, opts)

      assert :ok = Container.pull(spec, opts)
      assert {:ok, _id} = Container.create(spec, opts)
      assert Fake.spec(fake, spec.name) == Container.to_container_spec(spec)
      assert {:pull, ["homeassistant/amd64-addon-mosquitto:7.1.0"]} in Fake.calls(fake)
    end

    test "state: live is :running, otherwise :stopped, absent is :unknown", %{
      fake: fake,
      opts: opts
    } do
      for {state, expected} <- [
            running: :running,
            paused: :running,
            restarting: :running,
            created: :stopped,
            exited: :stopped
          ] do
        Fake.put_container(fake, "addon_x", state: state)
        assert Container.state("addon_x", opts) == {:ok, expected}, "#{state}"
      end

      assert Container.state("addon_ghost", opts) == {:ok, :unknown}

      Fake.fail_next(fake, :inspect, :unavailable)
      assert Container.state("addon_x", opts) == {:error, :unavailable}
    end

    test "stop maps the backend's :timeout to the engine's grace", %{fake: fake, opts: opts} do
      Fake.put_container(fake, "addon_x")
      Fake.delay_next(fake, :stop, 5_000)

      # A 1 s timeout_ms alone would cut the stop; a 3 s grace never is.
      assert Container.stop("addon_x", [timeout: 3, timeout_ms: 1_000] ++ opts) == :ok
      assert Container.state("addon_x", opts) == {:ok, :stopped}
    end

    # Steps passes its own opts, with the engine nested under `:engine_opts`.
    test "a nested :engine_opts reaches the engine", %{fake: fake, opts: opts} do
      Fake.put_container(fake, "addon_x")
      steps_opts = [backend: Container, data_root: "/data", timeout: 1, engine_opts: opts]

      assert Container.stop("addon_x", steps_opts) == :ok
      assert Container.remove("addon_x", steps_opts) == :ok
      assert Container.state("addon_x", opts) == {:ok, :unknown}
    end

    test "stop of an absent container is :not_found; remove and remove_image of absent are :ok",
         %{opts: opts} do
      assert Container.stop("addon_ghost", opts) == {:error, :not_found}
      assert Container.remove("addon_ghost", opts) == :ok
      assert Container.remove_image("ghcr.io/x/absent:1", opts) == :ok
    end
  end
end
