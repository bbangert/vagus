defmodule Vagus.Runtime.Engine.DockerRenderTest do
  # The ContainerSpec renders must equal today's builders byte-for-byte, so
  # moving the builders onto ContainerSpec changes no create body and no
  # Core spec fingerprint.
  use ExUnit.Case, async: true

  alias Vagus.Addon.Backend.Container, as: AppContainer
  alias Vagus.Addon.Backend.Spec
  alias Vagus.Core.Container, as: CoreContainer
  alias Vagus.Runtime.Engine.{ContainerSpec, Docker, NetworkSpec}

  @ip "172.30.32.2"

  test "Core's create config" do
    config = CoreContainer.create_config("2026.7.0", token: "t", tz: "UTC")
    fingerprint = config["Labels"][CoreContainer.spec_fingerprint_label()]

    spec = %ContainerSpec{
      name: "homeassistant",
      image: "ghcr.io/home-assistant/home-assistant:2026.7.0",
      hostname: "homeassistant",
      env: [
        {"SUPERVISOR", @ip},
        {"HASSIO", @ip},
        {"SUPERVISOR_TOKEN", "t"},
        {"HASSIO_TOKEN", "t"},
        {"SUPERVISOR_CORE_API_SOCKET", "/run/supervisor/core.sock"},
        {"TZ", "UTC"}
      ],
      secret_env: ["SUPERVISOR_TOKEN", "HASSIO_TOKEN"],
      labels: %{"io.vagus.spec-fingerprint" => fingerprint},
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
        %{type: :bind, source: "/run/supervisor", target: "/run/supervisor", read_only: false},
        %{type: :volume, source: "vagus-core-config", target: "/config"}
      ]
    }

    rendered = Docker.render_container(spec)
    assert rendered == config
    assert CoreContainer.spec_fingerprint(rendered) == fingerprint
  end

  test "a bridged app" do
    app = %Spec{
      name: "addon_local_x",
      image: "ghcr.io/vagus/aarch64-addon-x:1.2.0",
      hostname: "local-x",
      cmd: ["/run.sh", "--flag"],
      env: %{"TZ" => "UTC", "SUPERVISOR_TOKEN" => "tok", "A" => "1"},
      network: :hassio,
      network_name: "hassio",
      extra_hosts: %{"supervisor" => @ip, "homeassistant" => "172.30.32.1"},
      dns: ["172.30.32.3"],
      dns_search: ["local.hass.io"],
      dns_options: ["timeout:2", "ndots:0"],
      init: true,
      open_stdin: true,
      cap_add: ["NET_ADMIN", "SYS_RAWIO"],
      apparmor: "addon_local_x",
      tmpfs: %{"/tmp" => "", "/run" => "exec"},
      mounts: [
        %{source: "/data/addons/data/local_x", target: "/data"},
        %{source: "/data/share", target: "/share", read_only: true, propagation: "rslave"},
        %{source: "/dev", target: "/dev", read_only: true, read_only_non_recursive: true},
        %{source: "/run/dbus", target: "/run/dbus", read_only: true, system: true}
      ],
      device_cgroup_rules: ["c 189:* rwm", "c 166:* rwm"],
      ports: %{"8080/tcp" => 8080, "53/udp" => 5353},
      pid_mode: "host",
      uts_mode: "host",
      labels: %{"io.hass.version" => "1.2.0"}
    }

    spec = %ContainerSpec{
      name: "addon_local_x",
      image: "ghcr.io/vagus/aarch64-addon-x:1.2.0",
      hostname: "local-x",
      domainname: "local.hass.io",
      cmd: ["/run.sh", "--flag"],
      env: [{"A", "1"}, {"SUPERVISOR_TOKEN", "tok"}, {"TZ", "UTC"}],
      open_stdin: true,
      labels: %{"io.hass.version" => "1.2.0", "supervisor_managed" => ""},
      network: {:bridge, "hassio"},
      network_aliases: ["local-x"],
      dns: ["172.30.32.3"],
      dns_search: ["local.hass.io"],
      dns_options: ["timeout:2", "ndots:0"],
      extra_hosts: [{"homeassistant", "172.30.32.1"}, {"supervisor", @ip}],
      mounts: [
        %{type: :bind, source: "/data/addons/data/local_x", target: "/data"},
        %{
          type: :bind,
          source: "/data/share",
          target: "/share",
          read_only: true,
          propagation: "rslave"
        },
        %{
          type: :bind,
          source: "/dev",
          target: "/dev",
          read_only: true,
          read_only_non_recursive: true
        },
        %{type: :bind, source: "/run/dbus", target: "/run/dbus", read_only: true}
      ],
      tmpfs: %{"/tmp" => "", "/run" => "exec"},
      device_cgroup_rules: ["c 189:* rwm", "c 166:* rwm"],
      cap_add: ["NET_ADMIN", "SYS_RAWIO"],
      privileged: false,
      init: true,
      oom_score_adj: 200,
      security_opt: ["seccomp=unconfined", "apparmor=addon_local_x"],
      restart: :no,
      ports: %{"8080/tcp" => 8080, "53/udp" => 5353},
      pid_mode: "host",
      uts_mode: "host"
    }

    assert Docker.render_container(spec) == AppContainer.build_config(app)
  end

  test "a host-network app publishes no ports and joins no bridge" do
    app = %Spec{
      name: "addon_local_y",
      image: "ghcr.io/vagus/aarch64-addon-y:2.0.0",
      hostname: "local-y",
      env: %{"TZ" => "UTC"},
      network: :host,
      ports: %{"8080/tcp" => 8080}
    }

    spec = %ContainerSpec{
      name: "addon_local_y",
      image: "ghcr.io/vagus/aarch64-addon-y:2.0.0",
      hostname: "local-y",
      env: [{"TZ", "UTC"}],
      open_stdin: false,
      labels: %{"supervisor_managed" => ""},
      network: :host,
      network_aliases: ["local-y"],
      dns: [],
      dns_search: [],
      dns_options: [],
      extra_hosts: [],
      mounts: [],
      tmpfs: %{},
      device_cgroup_rules: [],
      cap_add: [],
      privileged: false,
      init: false,
      oom_score_adj: 200,
      security_opt: ["seccomp=unconfined"],
      restart: :no,
      ports: %{"8080/tcp" => 8080}
    }

    assert Docker.render_container(spec) == AppContainer.build_config(app)
  end

  test "the hassio network" do
    spec = %NetworkSpec{
      name: "hassio",
      subnet: "172.30.32.0/23",
      gateway: "172.30.32.1",
      ip_range: "172.30.33.0/24",
      interface_name: "hassio"
    }

    assert Docker.render_network(spec) == Vagus.Network.config()
  end
end
