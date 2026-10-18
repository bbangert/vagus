defmodule Vagus.Runtime.Engine.PodmanLiveTest do
  # Engine.Podman against a real podman: `mix test --include podman`, with
  # podman on PATH or VAGUS_PODMAN_BIN naming one (on a dev machine,
  # test/support/podman_docker_exec.sh). It needs docker.io/library/alpine:3.20
  # present and a `hassio` network. The shared contract suite cannot run
  # here: it pins ids, timestamps and failures no real engine reproduces, so
  # this suite checks the same behaviours on real containers. It creates and
  # removes only `vagus_live_*` containers (through the wrapper, in a store
  # of the run's own, which it empties at the end). Log follow and the
  # events source read files podman writes, which through the wrapper live
  # in another container, so they are covered on recorded output only.
  use ExUnit.Case, async: false

  @moduletag :podman
  @moduletag timeout: 300_000

  alias Vagus.Runtime.Engine
  alias Vagus.Runtime.Engine.{Container, ContainerSpec}
  alias Vagus.Runtime.Podman.Cmd
  alias Vagus.Test.EngineContract, as: C

  @image "docker.io/library/alpine:3.20"
  @x "vagus_live_x"
  @h "vagus_live_h"

  setup_all do
    bin = System.get_env("VAGUS_PODMAN_BIN") || System.find_executable("podman") || "podman"
    run = System.fetch_env!("VAGUS_PODMAN_RUN")
    # The run id, not just a VM-local integer: through the wrapper this path
    # also exists in the shared podman container.
    root = Path.join(System.tmp_dir!(), "vagus-live-#{run}")
    name = :vagus_live_host
    logs = Path.join(root, "logs")
    # Through the wrapper podman runs in another container, where conmon
    # needs the log directory too.
    in_container = String.ends_with?(bin, "podman_docker_exec.sh")
    container = System.get_env("VAGUS_PODMAN_CONTAINER", "vagus-podman-fixtures")
    if in_container, do: seed_store(bin, container, logs, root)

    {:ok, pid} =
      Vagus.Runtime.Host.start_link(
        name: name,
        podman_bin: bin,
        graphroot: Path.join(root, "storage"),
        run_dir: Path.join(root, "run"),
        socket_dir: Path.join(root, "supervisor"),
        resolv_conf: Path.join(root, "resolv.conf"),
        log_dir: logs,
        run: fn _bin, _args -> {"", 0} end,
        shutting_down?: fn -> false end,
        migration: [
          legacy_root: Path.join(root, "balena-engine"),
          marker: Path.join(root, "engine-migrated"),
          config_dir: Path.join(root, "core/config"),
          notify: fn _ -> :ok end
        ]
      )

    Process.unlink(pid)
    opts = [engine: Engine.Podman, host: name, podman_bin: bin]
    cleanup(opts)

    on_exit(fn ->
      cleanup(opts)
      Process.exit(pid, :kill)
      File.rm_rf(root)
      if in_container, do: drop_store(bin, container, run, root)
    end)

    Enum.find(1..300, fn _ -> Engine.ready(opts) == :ok or (Process.sleep(50) && false) end)
    %{opts: opts, logs: logs}
  end

  # The wrapper's per-run store starts empty, and the suite runs offline,
  # so the image is copied in from the container's default store.
  defp seed_store(bin, container, logs, root) do
    {_, 0} = System.cmd("docker", ["exec", container, "mkdir", "-p", logs])
    tar = Path.join(root, "image.tar")
    {_, 0} = System.cmd(bin, ["save", "-o", tar, @image], env: [{"VAGUS_PODMAN_RUN", nil}])
    {_, 0} = System.cmd(bin, ["load", "--quiet", "-i", tar])
  end

  # Best effort: these are the paths the wrapper derives from the run id.
  defp drop_store(bin, container, run, root) do
    System.cmd(bin, ["rm", "--all", "--force", "--time", "0"], stderr_to_stdout: true)
    System.cmd(bin, ["rmi", "--all", "--force"], stderr_to_stdout: true)
    dirs = [root, "/var/lib/vagus-test/#{run}", "/run/vagus-test/#{run}"]
    System.cmd("docker", ["exec", container, "rm", "-rf" | dirs])
  end

  defp cleanup(opts) do
    for n <- [@x, @h, "vagus_live_y"], do: Engine.remove(n, opts)
  end

  defp spec do
    %ContainerSpec{
      name: @x,
      image: @image,
      cmd: ["sh", "-c", "echo line one; echo line two >&2; exec sleep 600"],
      hostname: "live-x",
      env: [{"SUPERVISOR_TOKEN", "s3cret"}, {"TZ", "UTC"}],
      secret_env: ["SUPERVISOR_TOKEN"],
      labels: %{"supervisor_managed" => ""},
      network: {:bridge, "hassio"},
      network_aliases: ["live-x"],
      dns: ["172.30.32.3"],
      extra_hosts: [{"supervisor", "172.30.32.2"}],
      mounts: [%{type: :bind, source: "/tmp", target: "/data"}],
      tmpfs: %{"/dev/shm" => ""},
      cap_add: ["NET_ADMIN"],
      init: true,
      oom_score_adj: 200,
      security_opt: ["seccomp=unconfined"],
      restart: :no
    }
  end

  test "the engine is ready", %{opts: opts} do
    assert Engine.ready(opts) == :ok
  end

  test "a container's whole life", %{opts: opts} do
    assert {:ok, id} = Engine.create(spec(), opts)
    assert byte_size(id) == 64
    assert Engine.create(spec(), opts) == {:error, :conflict}

    assert :ok = Engine.start(@x, opts)
    assert :ok = Engine.start(@x, opts)

    assert {:ok, %Container{name: @x, state: :running, image: @image, ips: %{"hassio" => _}}} =
             Engine.inspect(@x, opts)

    assert {:ok, [%Container{name: @x}]} = Engine.list([name_prefix: @x] ++ opts)

    assert Engine.exec(@x, ["sh", "-c", "echo $SUPERVISOR_TOKEN"], opts) ==
             {:ok, %{exit_code: 0, output: "s3cret\n"}}

    assert {:ok, %{exit_code: 3}} = Engine.exec(@x, ["sh", "-c", "exit 3"], opts)

    assert {:ok, %{exit_code: 3, output: ""}} =
             Engine.exec(@x, ["sh", "-c", "exit 3"], [capture: false] ++ opts)

    Process.sleep(500)
    assert {:ok, logs} = Engine.logs(@x, opts)
    assert logs =~ "line one" and logs =~ "line two"
    assert {:ok, stamped} = Engine.logs(@x, [timestamps: true] ++ opts)
    assert stamped =~ ~r/^\d{4}-\d\d-\d\dT\S+Z line /m

    assert {:ok, %{cpu_percent: _}} = Engine.stats(@x, opts)
    assert {:ok, stats} = Engine.stats(@x, opts)
    assert Map.keys(stats) == Map.keys(C.stats())

    assert Engine.healthcheck(@x, opts) == {:error, :no_healthcheck}
    assert Engine.remove_image(@image, opts) == {:error, :in_use}

    assert {:error, {:failed, :remove, _}} = Engine.remove(@x, [force: false] ++ opts)
    assert :ok = Engine.restart(@x, [timeout_s: 0] ++ opts)
    assert :ok = Engine.stop(@x, [timeout_s: 1] ++ opts)
    assert {:ok, %Container{state: :exited}} = Engine.inspect(@x, opts)
    assert :ok = Engine.stop(@x, opts)
    assert :ok = Engine.remove(@x, opts)
    assert Engine.inspect(@x, opts) == {:error, :not_found}
    assert :ok = Engine.remove(@x, opts)
  end

  test "the rendered log path and cap are what podman uses", %{opts: opts, logs: logs} do
    {:ok, _} = Engine.create(spec(), opts)
    path = Path.join(logs, @x <> ".log")
    assert {:ok, %{path: ^path}} = Engine.Podman.log_target(@x, opts)

    {:ok, size} =
      Cmd.run(["container", "inspect", "--format", "{{.HostConfig.LogConfig.Size}}", "--", @x],
        timeout_ms: 30_000,
        podman_bin: opts[:podman_bin]
      )

    # podman prints the byte cap in decimal units: 2 MiB is 2.097MB.
    cap = Vagus.Runtime.Host.log_config(opts[:host]).max_bytes
    assert String.trim(size) == %{2_097_152 => "2.097MB", 8_388_608 => "8.389MB"}[cap]

    :ok = Engine.start(@x, opts)
    assert wait_for_logs(opts) =~ "line one"
    :ok = Engine.remove(@x, opts)
  end

  defp wait_for_logs(opts) do
    Enum.find_value(1..100, fn _ ->
      case Engine.logs(@x, opts) do
        {:ok, text} when text != "" -> text
        _ -> Process.sleep(100) && nil
      end
    end) || flunk("no logs")
  end

  test "an absent container", %{opts: opts} do
    ghost = "vagus_live_ghost"
    assert Engine.inspect(ghost, opts) == {:error, :not_found}
    assert Engine.start(ghost, opts) == {:error, :not_found}
    assert Engine.stop(ghost, opts) == {:error, :not_found}
    assert Engine.restart(ghost, opts) == {:error, :not_found}
    assert Engine.logs(ghost, opts) == {:error, :not_found}
    assert Engine.stats(ghost, opts) == {:error, :not_found}
    assert Engine.exec(ghost, ["true"], opts) == {:error, :not_found}
    assert Engine.healthcheck(ghost, opts) == {:error, :not_found}
    assert Engine.remove(ghost, opts) == :ok
  end

  test "create failures", %{opts: opts} do
    assert Engine.create(
             %{spec() | name: "vagus_live_y", image: "docker.io/library/nope:1"},
             opts
           ) ==
             {:error, {:failed, :create, :image_not_found}}

    assert Engine.create(
             %{spec() | name: "vagus_live_y", network: {:bridge, "vagus_live_none"}},
             opts
           ) ==
             {:error, {:failed, :create, :network_not_found}}
  end

  test "a pull goes through docker:// and lands under the plain ref", %{opts: opts} do
    assert Engine.pull(@image, opts) == :ok
    assert Engine.image_present?(@image, opts) == true
    assert {:ok, %Container{image: @image}} = create_x(opts)
    assert :ok = Engine.remove(@x, opts)
  end

  defp create_x(opts) do
    {:ok, _} = Engine.create(spec(), opts)
    Engine.inspect(@x, opts)
  end

  test "images", %{opts: opts} do
    assert Engine.image_present?(@image, opts) == true
    assert Engine.image_present?("docker.io/library/nope:1", opts) == false
    assert Engine.remove_image("docker.io/library/nope:1", opts) == :ok

    assert {:error, {:pull_failed, _}} =
             Engine.pull("docker.io/library/vagus-nosuchimage:1", opts)
  end

  test "health from a check podman runs on demand", %{opts: opts} do
    {:ok, _} =
      Cmd.run(
        ["run", "-d", "--name", @h, "--health-cmd", "true", "--", @image, "sleep", "600"],
        timeout_ms: 60_000,
        podman_bin: opts[:podman_bin]
      )

    assert Engine.healthcheck(@h, opts) == {:ok, :healthy}
    assert {:ok, %Container{health: :healthy, healthcheck: %{test: _}}} = Engine.inspect(@h, opts)
  end

  test "a paused container stops, and stop_all stops every name", %{opts: opts} do
    {:ok, _} = Engine.create(%{spec() | name: "vagus_live_y"}, opts)
    :ok = Engine.start("vagus_live_y", opts)

    {:ok, _} =
      Cmd.run(["pause", "--", "vagus_live_y"], timeout_ms: 30_000, podman_bin: opts[:podman_bin])

    assert {:ok, %Container{state: :paused}} = Engine.inspect("vagus_live_y", opts)
    assert :ok = Engine.stop("vagus_live_y", [timeout_s: 1] ++ opts)
    assert {:ok, %Container{state: :exited}} = Engine.inspect("vagus_live_y", opts)

    :ok = Engine.start("vagus_live_y", opts)

    assert Engine.stop_all(["vagus_live_y", "vagus_live_ghost"], 1, opts) ==
             {:ok, ["vagus_live_y", "vagus_live_ghost"], []}
  end

  test "ensure_network on the existing hassio network", %{opts: opts} do
    assert Engine.ensure_network(C.hassio(), opts) == :ok
  end
end
