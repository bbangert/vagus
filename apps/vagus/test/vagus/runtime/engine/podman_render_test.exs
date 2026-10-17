defmodule Vagus.Runtime.Engine.PodmanRenderTest do
  # Golden argv for every spec shape Vagus creates. Each list was also run
  # through `podman create` on podman 6.1.4 and accepted.
  use ExUnit.Case, async: true

  alias Vagus.Addon.Backend.Container, as: AppContainer
  alias Vagus.Addon.Backend.Spec
  alias Vagus.Core.Container, as: CoreContainer
  alias Vagus.Runtime.Engine.{ContainerSpec, Podman}

  @ip "172.30.32.2"
  @fixed ~w(--pull=never --pids-limit=-1 --ipc=private --unsetenv=container --http-proxy=false)
  @log %{dir: "/run/vagus/logs", max_bytes: 2_097_152}

  # On tmpfs, capped at the frugal profile's 2 MiB, in the byte count podman
  # reads.
  defp log_opts(name) do
    ["--log-driver", "k8s-file", "--log-opt", "path=/run/vagus/logs/#{name}.log"] ++
      ["--log-opt", "max-size=2097152"]
  end

  test "Core" do
    spec =
      CoreContainer.to_container_spec("2026.7.0",
        token: "t",
        tz: "UTC",
        homeassistant_path: "/root/vagus/core/config"
      )

    fingerprint = spec.labels[CoreContainer.spec_fingerprint_label()]

    assert Podman.render_create(spec, @log) ==
             ["create", "--name", "homeassistant"] ++
               @fixed ++
               log_opts("homeassistant") ++
               [
                 "--hostname",
                 "homeassistant",
                 "--env",
                 "SUPERVISOR=#{@ip}",
                 "--env",
                 "HASSIO=#{@ip}",
                 "--env",
                 "SUPERVISOR_TOKEN",
                 "--env",
                 "HASSIO_TOKEN",
                 "--env",
                 "SUPERVISOR_CORE_API_SOCKET=/run/supervisor/core.sock",
                 "--env",
                 "TZ=UTC",
                 "--label",
                 "io.vagus.spec-fingerprint=#{fingerprint}",
                 "--network",
                 "host",
                 "--add-host",
                 "supervisor:#{@ip}",
                 "--mount",
                 "type=bind,src=/dev,dst=/dev,ro=true",
                 "--mount",
                 "type=bind,src=/run/dbus,dst=/run/dbus,ro=true",
                 "--mount",
                 "type=bind,src=/run/udev,dst=/run/udev,ro=true",
                 "--mount",
                 "type=bind,src=/run/supervisor,dst=/run/supervisor",
                 "--mount",
                 "type=bind,src=/root/vagus/core/config,dst=/config",
                 "--mount",
                 "type=bind,src=/run/resolv.conf,dst=/etc/resolv.conf,ro=true",
                 "--tmpfs",
                 "/tmp:rw,noexec,nosuid,nodev,notmpcopyup",
                 "--privileged",
                 "--oom-score-adj",
                 "-300",
                 "--restart",
                 "unless-stopped",
                 "--",
                 "ghcr.io/home-assistant/home-assistant:2026.7.0"
               ]
  end

  defp app(overrides) do
    struct!(
      %Spec{
        name: "addon_local_x",
        image: "ghcr.io/vagus/aarch64-addon-x:1.2.0",
        env: %{"TZ" => "UTC", "SUPERVISOR_TOKEN" => "tok", "HASSIO_TOKEN" => "tok"},
        extra_hosts: %{"supervisor" => @ip, "hassio" => @ip},
        dns: ["172.30.32.3"],
        dns_search: ["local.hass.io"],
        dns_options: ["timeout:10"],
        tmpfs: %{"/dev/shm" => ""}
      },
      overrides
    )
  end

  test "a bridged app" do
    spec =
      app(
        hostname: "local-x",
        network: :hassio,
        init: true,
        cap_add: ["NET_ADMIN", "SYS_RAWIO"],
        apparmor: "addon_local_x",
        mounts: [
          %{source: "/data/addons/data/local_x", target: "/data"},
          %{source: "/data/share", target: "/share", read_only: true, propagation: "rslave"},
          %{source: "/dev", target: "/dev", read_only: true, read_only_non_recursive: true},
          %{source: "/run/dbus", target: "/run/dbus", read_only: true, system: true}
        ],
        device_cgroup_rules: ["c 189:* rwm"],
        ports: %{"8080/tcp" => 8080, "53/udp" => 5353, "9000/tcp" => nil},
        labels: %{"io.hass.version" => "1.2.0"}
      )

    assert Podman.render_create(AppContainer.to_container_spec(spec), @log) ==
             ["create", "--name", "addon_local_x"] ++
               @fixed ++
               log_opts("addon_local_x") ++
               [
                 "--hostname",
                 "local-x",
                 "--env",
                 "HASSIO_TOKEN",
                 "--env",
                 "SUPERVISOR_TOKEN",
                 "--env",
                 "TZ=UTC",
                 "--label",
                 "io.hass.version=1.2.0",
                 "--label",
                 "supervisor_managed=",
                 "--network",
                 "hassio",
                 "--network-alias",
                 "local-x",
                 "--dns",
                 "172.30.32.3",
                 "--dns-search",
                 "local.hass.io",
                 "--dns-option",
                 "timeout:10",
                 "--hosts-file=none",
                 "--add-host",
                 "hassio:#{@ip}",
                 "--add-host",
                 "supervisor:#{@ip}",
                 "--mount",
                 "type=bind,src=/data/addons/data/local_x,dst=/data",
                 "--mount",
                 "type=bind,src=/data/share,dst=/share,ro=true,bind-propagation=rslave",
                 "--mount",
                 "type=bind,src=/dev,dst=/dev,ro=true",
                 "--mount",
                 "type=bind,src=/run/dbus,dst=/run/dbus,ro=true",
                 "--tmpfs",
                 "/dev/shm:rw,noexec,nosuid,nodev,notmpcopyup",
                 "--device-cgroup-rule",
                 "c 189:* rwm",
                 "--cap-add",
                 "NET_ADMIN",
                 "--cap-add",
                 "SYS_RAWIO",
                 "--cap-add",
                 "AUDIT_WRITE",
                 "--cap-add",
                 "MKNOD",
                 "--cap-add",
                 "NET_RAW",
                 "--init",
                 "--oom-score-adj",
                 "200",
                 "--security-opt",
                 "seccomp=unconfined",
                 "--security-opt",
                 "apparmor=addon_local_x",
                 "--restart",
                 "no",
                 "--publish",
                 "5353:53/udp",
                 "--publish",
                 "8080:8080/tcp",
                 "--publish",
                 "9000/tcp",
                 "--",
                 "ghcr.io/vagus/aarch64-addon-x:1.2.0"
               ]
  end

  test "a host-network app" do
    spec =
      app(
        name: "addon_local_y",
        image: "ghcr.io/vagus/aarch64-addon-y:2.0.0",
        network: :host,
        init: true,
        ports: %{"8080/tcp" => 8080},
        pid_mode: "host",
        uts_mode: "host",
        cmd: ["/run.sh", "--flag"]
      )

    assert Podman.render_create(AppContainer.to_container_spec(spec), @log) ==
             ["create", "--name", "addon_local_y"] ++
               @fixed ++
               log_opts("addon_local_y") ++
               [
                 "--env",
                 "HASSIO_TOKEN",
                 "--env",
                 "SUPERVISOR_TOKEN",
                 "--env",
                 "TZ=UTC",
                 "--label",
                 "supervisor_managed=",
                 "--network",
                 "host",
                 "--add-host",
                 "hassio:#{@ip}",
                 "--add-host",
                 "supervisor:#{@ip}",
                 "--mount",
                 "type=bind,src=/run/resolv.conf,dst=/etc/resolv.conf,ro=true",
                 "--tmpfs",
                 "/dev/shm:rw,noexec,nosuid,nodev,notmpcopyup",
                 "--cap-add",
                 "AUDIT_WRITE",
                 "--cap-add",
                 "MKNOD",
                 "--cap-add",
                 "NET_RAW",
                 "--oom-score-adj",
                 "200",
                 "--security-opt",
                 "seccomp=unconfined",
                 "--restart",
                 "no",
                 "--pid",
                 "host",
                 "--uts",
                 "host",
                 "--",
                 "ghcr.io/vagus/aarch64-addon-y:2.0.0",
                 "/run.sh",
                 "--flag"
               ]
  end

  describe "single fields" do
    defp render(fields) do
      Podman.render_create(
        struct!(%ContainerSpec{name: "n", image: "i", network: :host}, fields),
        @log
      )
    end

    test "the live resolv.conf goes only into a host-network container without its own" do
      bind = ["--mount", "type=bind,src=/run/resolv.conf,dst=/etc/resolv.conf,ro=true"]
      assert bind -- render([]) == []

      bridged = render(network: {:bridge, "hassio"})
      refute Enum.any?(bridged, &(&1 =~ "resolv.conf"))

      own = %{type: :bind, source: "/data/resolv", target: "/etc/resolv.conf", read_only: true}
      assert Enum.count(render(mounts: [own]), &(&1 =~ "dst=/etc/resolv.conf")) == 1
    end

    test "a secret's value never reaches the argv" do
      argv = render(env: [{"TOKEN", "s3cret"}, {"TZ", "UTC"}], secret_env: ["TOKEN"])
      assert ["--env", "TOKEN", "--env", "TZ=UTC"] -- argv == []
      refute Enum.any?(argv, &(&1 =~ "s3cret"))
    end

    test "read-only non-recursive is plain ro, never bind-nonrecursive" do
      argv =
        render(
          mounts: [
            %{
              type: :bind,
              source: "/dev",
              target: "/dev",
              read_only: true,
              read_only_non_recursive: true
            }
          ]
        )

      assert ["--mount", "type=bind,src=/dev,dst=/dev,ro=true"] -- argv == []
      refute Enum.any?(argv, &(&1 =~ "nonrecursive"))
    end

    test "a given tmpfs option replaces its Docker default" do
      assert ["--tmpfs", "/run:rw,nosuid,nodev,notmpcopyup,exec"] --
               render(tmpfs: %{"/run" => "exec"}) ==
               []
    end

    test "init is dropped in the host PID namespace, hostname in the host UTS namespace" do
      argv = render(init: true, pid_mode: "host", hostname: "h", uts_mode: "host")
      refute "--init" in argv
      refute "--hostname" in argv
    end

    test "a privileged container gets the spec's capabilities but not Docker's three" do
      argv = render(privileged: true, cap_add: ["NET_ADMIN"])
      assert ["--cap-add", "NET_ADMIN"] -- argv == []
      refute Enum.any?(["AUDIT_WRITE", "MKNOD", "NET_RAW"], &(&1 in argv))
    end

    test "DNS settings render on a bridge only: the host network keeps the host's resolv.conf" do
      dns = [dns: ["172.30.32.3"], dns_search: ["local.hass.io"], dns_options: ["timeout:10"]]

      for flag <- ~w(--dns --dns-search --dns-option) do
        refute flag in render(dns)
        assert flag in render([network: {:bridge, "hassio"}] ++ dns)
      end
    end

    test "ports publish only from a bridge" do
      refute "--publish" in render(ports: %{"80/tcp" => 80})
      assert "--publish" in render(network: {:bridge, "hassio"}, ports: %{"80/tcp" => 80})
    end
  end

  test "the log path and cap come from the Host's log config" do
    argv =
      Podman.render_create(%ContainerSpec{name: "n", image: "i", network: :host}, %{
        dir: "/x",
        max_bytes: 8_388_608
      })

    assert ["--log-opt", "path=/x/n.log", "--log-opt", "max-size=8388608"] -- argv == []
  end

  test "the hassio network" do
    assert Podman.render_network(Vagus.Network.spec()) == [
             "network",
             "create",
             "--driver",
             "bridge",
             "--disable-dns",
             "--subnet",
             "172.30.32.0/23",
             "--gateway",
             "172.30.32.1",
             "--ip-range",
             "172.30.33.0-172.30.33.255",
             "--interface-name",
             "hassio",
             "--",
             "hassio"
           ]
  end
end
