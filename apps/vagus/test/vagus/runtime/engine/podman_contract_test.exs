defmodule Vagus.Runtime.Engine.PodmanContractTest.Leg do
  @behaviour Vagus.Test.EngineContract

  alias Vagus.Runtime.Engine
  alias Vagus.Test.FakePodman

  @fixtures Path.expand("../../../fixtures/podman", __DIR__)

  # Texts as podman 6.1.4 prints them (test/fixtures/podman/cli_results.txt).
  @no_such ~s([]\nError: no such container "ghost"\n)
  @lookup ~s(Error: no container with name or ID "ghost" found: no such container\n)

  def fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  @impl true
  def arrange(:unavailable, ctx), do: start(ctx, [], podman_bin: "/nonexistent/podman")

  # A running container whose conmon is a real process: `release/1` writes
  # the second record and ends it, as conmon does when the container exits.
  def arrange(:follow, ctx) do
    log = log_file(["2026-10-14T21:00:00.000000001+00:00 stdout F line one"])
    conmon = Port.open({:spawn_executable, System.find_executable("sleep")}, args: ["600"])
    {:os_pid, pid} = Port.info(conmon, :os_pid)

    ExUnit.Callbacks.on_exit(fn ->
      System.cmd("kill", ["-9", "#{pid}"], stderr_to_stdout: true)
    end)

    start(ctx, [{"container inspect *", [{0, inspect_out(log_json(log, pid))}]}], []) ++
      [log_file: log, conmon_pid: pid]
  end

  def arrange({:stamped, _} = scenario, ctx) do
    log =
      log_file([
        "2026-10-14T21:00:00.000000001+00:00 stdout F line one",
        "2026-10-14T21:00:00.000000002+00:00 stderr F line two"
      ])

    rules = script(scenario) ++ [{"container inspect *", [{0, inspect_out(log_json(log, nil))}]}]
    start(ctx, rules, [])
  end

  # A stop's floor is podman's 10 s grace plus 15 s by default; shrunk here
  # so `timeout_ms` can be seen to bound the call.
  def arrange(:stop_slow, ctx),
    do: start(ctx, script(:stop_slow), []) ++ [default_stop_grace_s: 0, stop_margin_ms: 100]

  def arrange(scenario, ctx), do: start(ctx, script(scenario), [])

  @impl true
  def release(opts) do
    with log when is_binary(log) <- opts[:log_file],
         false <- File.read!(log) =~ "line two" do
      File.write!(log, "2026-10-14T21:00:00.000000002+00:00 stderr F line two\n", [:append])
      System.cmd("kill", ["-9", "#{opts[:conmon_pid]}"])
    end

    :ok
  end

  def log_file(records) do
    path = Path.join(System.tmp_dir!(), "podman-ctr-#{System.unique_integer([:positive])}.log")
    File.write!(path, Enum.map_join(records, &(&1 <> "\n")))
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    path
  end

  # A stopped container has no conmon.
  def log_json(log, conmon_pid) do
    running_json()
    |> put_in(["HostConfig", "LogConfig", "Path"], log)
    |> put_in(["State", "Running"], conmon_pid != nil)
    |> put_in(["State", "ConmonPid"], conmon_pid || 0)
  end

  def start(ctx, rules, opts) do
    fake = FakePodman.start(rules)
    bin = Keyword.get(opts, :podman_bin, fake.bin)
    host = start_host(ctx, bin)
    [engine: Engine.Podman, host: host, podman_bin: bin, fake_podman: fake]
  end

  def start_host(_ctx, bin), do: FakePodman.start_host(bin)

  def running_json(health \\ "healthy") do
    [base] = fixture("inspect_running.json")
    [checked] = fixture("inspect_health.json")

    base
    |> Map.merge(%{
      "Id" => "4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a",
      "Name" => "addon_local_x"
    })
    |> put_in(["Config", "Image"], "ghcr.io/vagus/aarch64-addon-x:1.2.0")
    |> put_in(["Config", "Env"], ["TZ=UTC", "SUPERVISOR_TOKEN=tok", "OPTS=a=b"])
    |> put_in(["Config", "Labels"], %{"supervisor_managed" => "", "io.hass.version" => "1.2.0"})
    |> put_in(["Config", "Healthcheck"], %{
      checked["Config"]["Healthcheck"]
      | "Test" => ["CMD-SHELL", "curl -f http://localhost/ || exit 1"]
    })
    |> put_in(["State", "StartedAt"], "2026-10-14T10:00:00.123456789Z")
    |> put_in(["State", "Health"], %{checked["State"]["Health"] | "Status" => health})
    |> put_in(["NetworkSettings", "Networks", "hassio", "IPAddress"], "172.30.33.4")
  end

  def exited_json(exit_code \\ 137) do
    [base] = fixture("inspect_exited.json")

    base
    |> Map.merge(%{
      "Id" => "9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a",
      "Name" => "addon_local_y"
    })
    |> put_in(["Config", "Image"], "ghcr.io/vagus/aarch64-addon-y:2.0.0")
    |> put_in(["Config", "Env"], ["TZ=UTC"])
    |> put_in(["Config", "Labels"], %{"supervisor_managed" => ""})
    |> put_in(["State", "ExitCode"], exit_code)
    |> put_in(["State", "StartedAt"], "2026-10-14T09:00:00Z")
    |> put_in(["State", "FinishedAt"], "2026-10-14T09:30:00Z")
  end

  def json(term), do: Jason.encode!(term) <> "\n"
  def inspect_out(raw), do: json([raw])

  defp summary(id, name, image, state, exit_code, labels) do
    [base | _] = fixture("ps_all.json")

    %{
      base
      | "Id" => id,
        "Names" => [name],
        "Image" => image,
        "State" => state,
        "ExitCode" => exit_code,
        "Labels" => labels
    }
  end

  defp ps do
    x_labels = %{"supervisor_managed" => "", "io.hass.version" => "1.2.0"}
    x_image = "ghcr.io/vagus/aarch64-addon-x:1.2.0"

    [
      summary(String.duplicate("4f1c2b3a", 8), "addon_local_x", x_image, "running", 0, x_labels),
      summary(
        String.duplicate("9d2e7f6a", 8),
        "addon_local_y",
        "ghcr.io/vagus/aarch64-addon-y:2.0.0",
        "exited",
        137,
        %{"supervisor_managed" => ""}
      ),
      summary(String.duplicate("aa11bb22", 8), "addon_local_p", x_image, "paused", 0, x_labels),
      summary(
        String.duplicate("cc33dd44", 8),
        "addon_local_r",
        x_image,
        "restarting",
        0,
        x_labels
      ),
      summary(
        String.duplicate("77aa88bb", 8),
        "homeassistant",
        "ghcr.io/home-assistant/home-assistant:2026.7.0",
        "running",
        0,
        %{"io.vagus.spec-fingerprint" => "0123456789abcdef0123456789abcdef"}
      )
    ]
  end

  def stats_line do
    json(%{
      "AvgCPU" => 25.0,
      "ContainerID" => String.duplicate("4f1c2b3a", 8),
      "Name" => "addon_local_x",
      "CPU" => 25.0,
      "CPUNano" => 3_000_000_000,
      "CPUSystemNano" => 3_000_000_000,
      "SystemNano" => 1_792_086_179_909_417_426,
      "MemUsage" => 50_000_000,
      "MemLimit" => 1_000_000_000,
      "MemPerc" => 5.0,
      "Network" => %{
        "eth0" => %{"RxBytes" => 1000, "TxBytes" => 2000},
        "eth1" => %{"RxBytes" => 24, "TxBytes" => 48}
      },
      "BlockInput" => 4096,
      "BlockOutput" => 8192,
      "PIDs" => 1
    })
  end

  defp script(:ready), do: []

  defp script(:absent) do
    [
      {"container inspect *", [{125, @no_such}]},
      {"start *", [{125, @lookup}]},
      {"stop *", [{125, @lookup}]},
      {"restart *", [{125, @lookup}]},
      {"rm *", [{0, ""}]},
      {"logs *", [{125, @lookup}]},
      {"stats *", [{125, "Error: unable to get list of containers: " <> @lookup}]},
      {"exec *", [{125, @lookup}]},
      {"healthcheck run *",
       [{125, "Error: unable to look up ghost to perform a health check: " <> @lookup}]}
    ]
  end

  defp script(:inspect_running), do: [{"container inspect *", [{0, inspect_out(running_json())}]}]

  defp script(:inspect_exited) do
    [
      {"container inspect *", [{0, inspect_out(exited_json())}]},
      {"healthcheck run *", [{125, "Error: container 9d2e7f6a9d2e has no defined healthcheck\n"}]}
    ]
  end

  defp script(:list), do: [{"ps --all --format json", [{0, json(ps())}]}]

  defp script({:live, state}) do
    [
      {"container inspect *",
       [{0, inspect_out(put_in(running_json(), ["State", "Status"], to_string(state)))}]}
    ]
  end

  defp script({:remove_live, state}) do
    word = if state == :paused, do: "paused", else: "running"

    [
      {"rm *",
       [
         {2,
          "Error: cannot remove container 4f1c2b3a as it is #{word} - running or paused " <>
            "containers cannot be removed without force: container state improper\n"}
       ]},
      {"container inspect *",
       [{0, inspect_out(put_in(running_json(), ["State", "Status"], to_string(state)))}]}
    ]
  end

  defp script({:stop_live, :paused}) do
    [
      {"stop *",
       [
         {125,
          "Error: container 4f1c2b3a is running or paused, refusing to clean up: " <>
            "container state improper\n"},
         {0, "addon_local_x\n"}
       ]},
      {"unpause *", [{0, "addon_local_x\n"}]},
      {"container inspect *", [{0, inspect_out(exited_json(0))}]}
    ]
  end

  defp script({:stop_live, _state}) do
    [
      {"stop *", [{0, "addon_local_x\n"}]},
      {"container inspect *", [{0, inspect_out(exited_json(0))}]}
    ]
  end

  defp script(:start_created) do
    [
      {"start *", [{0, "addon_local_x\n"}]},
      {"container inspect *", [{0, inspect_out(running_json())}]}
    ]
  end

  defp script(:start_running), do: script(:start_created)

  defp script(:stop_running) do
    [
      {"stop *", [{0, "addon_local_x\n"}]},
      {"container inspect *", [{0, inspect_out(exited_json(0))}]}
    ]
  end

  defp script(:stop_stopped), do: [{"stop *", [{0, "addon_local_y\n"}]}]

  defp script(:stop_within_grace), do: [{"stop *", [{0, "addon_local_x\n", delay_ms: 500}]}]

  defp script(:stop_all_slow),
    do: [{"stop *", [{0, "addon_local_x\naddon_local_d\n", delay_ms: 5_100}]}]

  defp script(:stop_slow), do: [{"stop *", [{0, "addon_local_x\n", delay_ms: 1_500}]}]

  defp script(:inspect_slow),
    do: [{"container inspect *", [{0, inspect_out(running_json()), delay_ms: 1_500}]}]

  defp script(:hang_up), do: [{"container inspect *", [{0, :killed}]}]
  defp script(:restart), do: [{"restart *", [{0, "addon_local_x\n"}]}]

  defp script(:remove) do
    [{"rm *", [{0, "addon_local_y\n"}]}, {"container inspect *", [{125, @no_such}]}]
  end

  # podman prints each stopped name, skips an absent one under --ignore and
  # reports the failure last.
  defp script(:stop_all) do
    [
      {"stop *",
       [
         {125,
          "addon_local_x\naddon_local_y\nError: cannot stop addon_local_d: permission denied\n"}
       ]},
      {"container exists -- addon_local_d", [{0, ""}]},
      {"container exists -- ghost", [{1, ""}]}
    ]
  end

  defp script(:create), do: [{"create *", [{0, "c0ffee\n"}]}]

  defp script(:create_conflict) do
    [
      {"create *",
       [
         {125,
          ~s(Error: creating container storage: the container name "addon_local_x" is already ) <>
            "in use by 4f1c2b3a. You have to remove that container to be able to reuse that " <>
            "name: that name is already in use, or use --replace to instruct Podman to do so.\n"}
       ]}
    ]
  end

  defp script(:create_no_image),
    do: [{"create *", [{125, "Error: ghcr.io/vagus/aarch64-addon-x:1.2.0: image not known\n"}]}]

  defp script(:create_no_network) do
    [
      {"create *",
       [{125, "Error: unable to find network with name or ID hassio: network not found\n"}]}
    ]
  end

  defp script(:pull) do
    [{"pull *", [{0, "5b0e9d3c\n"}]}, {"image exists *", [{0, ""}]}]
  end

  defp script(:pull_failed) do
    [
      {"pull *",
       [
         {125,
          "Error: unable to copy from source docker://ghcr.io/vagus/missing:1.0: initializing " <>
            "source docker://ghcr.io/vagus/missing:1.0: reading manifest 1.0 in " <>
            "ghcr.io/vagus/missing: manifest unknown\n"}
       ]}
    ]
  end

  defp script(:image_absent), do: [{"image exists *", [{1, ""}]}, {"rmi *", [{0, ""}]}]

  defp script(:remove_image) do
    [{"rmi *", [{0, "Untagged: x\nDeleted: 5b0e9d3c\n"}]}, {"image exists *", [{1, ""}]}]
  end

  defp script(:image_in_use) do
    [
      {"rmi *",
       [
         {2,
          "Error: image used by 4f1c2b3a: image is in use by a container: consider listing " <>
            "external containers and force-removing image\n"}
       ]}
    ]
  end

  defp script(:logs), do: [{"logs *", [{0, "line one\nline two\n"}]}]

  defp script({:stamped, true}) do
    [
      {"logs *",
       [{0, "2026-10-14T21:00:00.000000001Z line one\n2026-10-14T21:00:00.000000002Z line two\n"}]}
    ]
  end

  defp script({:stamped, false}), do: script(:logs)

  defp script(:health_never_ran) do
    [
      {"healthcheck run *",
       [
         {125,
          "Error: container 4f1c2b3a is not running: can only create exec sessions on running " <>
            "containers: container state improper\n"}
       ]}
    ]
  end

  defp script(:stats), do: [{"stats *", [{0, stats_line()}]}]
  defp script({:exec, code, output}), do: [{"exec *", [{code, output}]}]
  defp script(:exec_no_capture), do: [{"exec *", [{3, "ignored\n"}]}]
  defp script(:exec_timeout), do: [{"exec *", [{0, "late\n", delay_ms: 2_000}]}]

  defp script({:health, :healthy}), do: [{"healthcheck run *", [{0, ""}]}]

  # One failed probe prints `unhealthy` whatever the stored status is.
  defp script({:health, health}) do
    [
      {"healthcheck run *", [{1, "unhealthy\n"}]},
      {"container inspect *", [{0, inspect_out(running_json(Atom.to_string(health)))}]}
    ]
  end

  defp script(:network_exists), do: [{"network exists *", [{0, ""}]}]

  defp script(:network_created),
    do: [{"network exists *", [{1, ""}]}, {"network create *", [{0, "hassio\n"}]}]

  defp script(:network_race) do
    [
      {"network exists *", [{1, ""}]},
      {"network create *", [{125, "Error: netavark: network already exists hassio\n"}]}
    ]
  end

  # An exec's 125 is the command's own unless podman's text says otherwise.
  defp script(:engine_error) do
    [
      {"info*", [{125, "Error: cannot open the store\n"}]},
      {"exec *",
       [
         {255,
          "Error: can only create exec sessions on running containers: container state improper\n"}
       ]}
    ]
  end
end

defmodule Vagus.Runtime.Engine.PodmanContractTest do
  use Vagus.Test.EngineContract,
    leg: Vagus.Runtime.Engine.PodmanContractTest.Leg,
    async: true

  alias Vagus.Runtime.Engine.PodmanContractTest.Leg
  alias Vagus.Test.EngineContract, as: C
  alias Vagus.Test.FakePodman

  defp engine(ctx, rules) do
    opts = Leg.start(ctx, rules, [])
    {opts[:fake_podman], opts}
  end

  describe "parsing what podman 6.1.4 printed" do
    test "inspect of a running, an exited, a stopped and a checked container", ctx do
      inspects =
        for name <- ~w(running exited stopped health) do
          {_fake, opts} =
            engine(ctx, [
              {"container inspect *",
               [
                 {0,
                  File.read!(
                    Path.expand("../../../fixtures/podman/inspect_#{name}.json", __DIR__)
                  )}
               ]}
            ])

          {:ok, container} = Engine.inspect("fx_#{name}", opts)
          container
        end

      [running, exited, stopped, checked] = inspects

      assert %Container{
               name: "fx_running",
               image: "docker.io/library/alpine:3.20",
               state: :running,
               exit_code: nil,
               health: nil,
               healthcheck: nil,
               finished_at: nil,
               labels: %{"supervisor_managed" => "", "io.hass.version" => "1.2.0"},
               ips: %{"hassio" => "172.30.33.2"}
             } = running

      assert %{"TZ" => "UTC", "container" => "podman"} = running.env

      assert %Container{state: :exited, exit_code: 3, labels: %{}, ips: %{}} = exited
      assert %Container{state: :exited, exit_code: 137} = stopped

      assert %Container{
               health: :healthy,
               healthcheck: %{
                 test: ["CMD-SHELL", "test -e /tmp"],
                 interval_ms: 30_000,
                 timeout_ms: 5_000,
                 start_period_ms: nil,
                 start_interval_ms: nil,
                 retries: 3
               }
             } = checked
    end

    test "an image's start period and start interval reach the healthcheck", ctx do
      # The shape podman 6.1.4 gives an image built with HEALTHCHECK
      # --start-period=1m --start-interval=10s.
      [raw] = Leg.fixture("inspect_health.json")

      raw =
        update_in(raw, ["Config", "Healthcheck"], fn hc ->
          Map.merge(hc, %{"StartPeriod" => 60_000_000_000, "StartInterval" => 10_000_000_000})
        end)

      {_fake, opts} = engine(ctx, [{"container inspect *", [{0, Leg.inspect_out(raw)}]}])

      assert {:ok, %Container{healthcheck: %{start_period_ms: 60_000, start_interval_ms: 10_000}}} =
               Engine.inspect("fx_health", opts)
    end

    test "podman's stopped state is :exited", ctx do
      [raw] = Leg.fixture("inspect_stopped.json")
      raw = put_in(raw, ["State", "Status"], "stopped")
      {_fake, opts} = engine(ctx, [{"container inspect *", [{0, Leg.inspect_out(raw)}]}])

      assert {:ok, %Container{state: :exited, exit_code: 137}} =
               Engine.inspect("fx_stopped", opts)
    end

    test "ps: names without /, the exit code from its own field, paused counts as live", ctx do
      ps = File.read!(Path.expand("../../../fixtures/podman/ps_all.json", __DIR__))
      {_fake, opts} = engine(ctx, [{"ps *", [{0, ps}]}])

      assert {:ok, all} = Engine.list([all: true] ++ opts)

      assert Enum.map(all, &{&1.name, &1.state, &1.exit_code}) == [
               {"fx_running", :running, nil},
               {"fx_exited", :exited, 3},
               {"fx_stopped", :exited, 137},
               {"fx_health", :running, nil}
             ]

      paused =
        ps |> Jason.decode!() |> hd() |> Map.merge(%{"Names" => ["p"], "State" => "paused"})

      {_fake, opts} = engine(ctx, [{"ps *", [{0, Jason.encode!([paused])}]}])
      assert {:ok, [%Container{name: "p", state: :paused}]} = Engine.list(opts)
    end
  end

  describe "podman stats" do
    test "the first sample is podman's since-start average; later ones the delta", ctx do
      [first, second] =
        for n <- [1, 2],
            do: File.read!(Path.expand("../../../fixtures/podman/stats_sample#{n}.json", __DIR__))

      third =
        second
        |> Jason.decode!()
        |> Map.update!("CPUNano", &(&1 + 50_000_000))
        |> Map.update!("SystemNano", &(&1 + 1_000_000_000))
        |> Jason.encode!()

      {_fake, opts} = engine(ctx, [{"stats *", [{0, first}, {0, second}, {0, third}]}])

      assert {:ok, %{cpu_percent: 0.04, network_rx: 2342, network_tx: 628}} =
               Engine.stats("fx_running", opts)

      # The recorded pair: no CPU used in between.
      assert {:ok, %{cpu_percent: +0.0}} = Engine.stats("fx_running", opts)
      # 50 ms of CPU over one second of wall time.
      assert {:ok, %{cpu_percent: 5.0}} = Engine.stats("fx_running", opts)
    end

    test "a new container under the same name starts over from its average", ctx do
      line = Leg.stats_line()
      other = line |> Jason.decode!() |> Map.put("ContainerID", "other") |> Jason.encode!()
      {_fake, opts} = engine(ctx, [{"stats *", [{0, line}, {0, other}]}])
      assert {:ok, %{cpu_percent: 25.0}} = Engine.stats("addon_local_x", opts)
      assert {:ok, %{cpu_percent: 25.0}} = Engine.stats("addon_local_x", opts)
    end

    test "removing a container forgets its sample", ctx do
      {_fake, opts} = engine(ctx, [{"stats *", [{0, Leg.stats_line()}]}, {"rm *", [{0, ""}]}])
      {:ok, _} = Engine.stats("addon_local_x", opts)
      assert Vagus.Runtime.Host.last_sample(opts[:host], "addon_local_x") != nil
      :ok = Engine.remove("addon_local_x", opts)
      assert Vagus.Runtime.Host.last_sample(opts[:host], "addon_local_x") == nil
    end

    test "removing a container by its id forgets the sample its name keys", ctx do
      {_fake, opts} =
        engine(ctx, [
          {"stats *", [{0, Leg.stats_line()}]},
          {"container inspect *", [{0, Leg.inspect_out(Leg.running_json())}]},
          {"rm *", [{0, ""}]}
        ])

      {:ok, _} = Engine.stats("addon_local_x", opts)
      assert Vagus.Runtime.Host.last_sample(opts[:host], "addon_local_x") != nil
      :ok = Engine.remove(Leg.running_json()["Id"], opts)
      assert Vagus.Runtime.Host.last_sample(opts[:host], "addon_local_x") == nil
    end

    test "a stopped container is all zeros", ctx do
      stopped = File.read!(Path.expand("../../../fixtures/podman/stats_stopped.json", __DIR__))
      {_fake, opts} = engine(ctx, [{"stats *", [{0, stopped}]}])
      assert Engine.stats("fx_stopped", opts) == {:ok, Vagus.Runtime.Stats.zero()}
    end
  end

  describe "what reaches podman" do
    test "each verb's argv", ctx do
      {fake, opts} =
        engine(ctx, [
          {"container inspect *", [{0, Leg.inspect_out(Leg.running_json())}]},
          {"ps *", [{0, "[]"}]},
          {"stats *", [{0, Leg.stats_line()}]},
          {"create *", [{0, "c0ffee\n"}]},
          {"*", [{0, ""}]}
        ])

      x = "addon_local_x"
      :ok = Engine.start(x, opts)
      :ok = Engine.stop(x, [timeout_s: 7] ++ opts)
      :ok = Engine.stop(x, opts)
      :ok = Engine.restart(x, [timeout_s: 3] ++ opts)
      :ok = Engine.remove(x, opts)
      :ok = Engine.remove(x, [force: false] ++ opts)
      {:ok, _} = Engine.inspect(x, opts)
      {:ok, []} = Engine.list(opts)
      {:ok, _} = Engine.logs(x, [tail: 5, timestamps: true] ++ opts)
      {:ok, _} = Engine.logs(x, opts)
      {:ok, _} = Engine.stats(x, opts)
      {:ok, _} = Engine.exec(x, ["ha", "core", "check"], opts)
      {:ok, :healthy} = Engine.healthcheck(x, opts)
      :ok = Engine.pull("ghcr.io/vagus/x:1", [platform: "linux/arm64"] ++ opts)
      true = Engine.image_present?("ghcr.io/vagus/x:1", opts)
      :ok = Engine.remove_image("ghcr.io/vagus/x:1", opts)
      :ok = Engine.ensure_network(C.hassio(), opts)
      {:ok, "c0ffee"} = Engine.create(C.spec(), opts)

      assert FakePodman.verbs(fake) -- [["info", "--format", "{{.Version.Version}}"]] == [
               ["start", "--", x],
               ["stop", "--time", "7", "--", x],
               ["stop", "--", x],
               ["restart", "--time", "3", "--", x],
               ["rm", "--force", "--ignore", "--time", "0", "--", x],
               ["rm", "--ignore", "--", x],
               ["container", "inspect", "--", x],
               ["ps", "--all", "--format", "json"],
               ["logs", "--tail", "5", "--timestamps", "--", x],
               ["logs", "--tail", "100", "--", x],
               [
                 "stats",
                 "--no-stream",
                 "--no-reset",
                 "--format",
                 "{{json .ContainerStats}}",
                 "--",
                 x
               ],
               ["exec", "--", x, "ha", "core", "check"],
               ["healthcheck", "run", "--", x],
               [
                 "pull",
                 "--quiet",
                 "--platform",
                 "linux/arm64",
                 "--",
                 "docker://ghcr.io/vagus/x:1"
               ],
               ["image", "exists", "--", "ghcr.io/vagus/x:1"],
               ["rmi", "--ignore", "--", "ghcr.io/vagus/x:1"],
               ["network", "exists", "--", "hassio"],
               Engine.Podman.render_create(C.spec(), Vagus.Runtime.Host.log_config(opts[:host]))
             ]
    end

    test "every call runs with the global flags first", ctx do
      {fake, opts} = engine(ctx, [{"start *", [{0, ""}]}])
      :ok = Engine.start("addon_local_x", opts)

      assert Enum.all?(
               FakePodman.calls(fake),
               &match?(["--log-level=error", "--transient-store" | _], &1)
             )
    end

    test "stop_all is one podman stop for every name", ctx do
      {fake, opts} = engine(ctx, [{"stop *", [{0, "a\nb\n"}]}])
      assert Engine.stop_all(["a", "b"], 30, opts) == {:ok, ["a", "b"], []}

      assert [["stop", "--ignore", "--time", "30", "--", "a", "b"]] =
               FakePodman.verbs(fake) -- [["info", "--format", "{{.Version.Version}}"]]
    end

    test "create puts a secret in podman's env, never on the argv", ctx do
      fake = FakePodman.start([{"create *", [{0, "c0ffee\n"}]}], log_env: ["SUPERVISOR_TOKEN"])
      host = Leg.start_host(ctx, fake.bin)
      opts = [engine: Engine.Podman, host: host, podman_bin: fake.bin]
      spec = Vagus.Core.Container.to_container_spec("2026.7.0", token: "s3cret-token", tz: "UTC")

      {:ok, _} = Engine.create(spec, opts)

      assert List.last(FakePodman.envs(fake)) == ["SUPERVISOR_TOKEN=s3cret-token"]
      refute fake |> FakePodman.calls() |> List.flatten() |> Enum.any?(&(&1 =~ "s3cret"))
    end

    test "a create whose mount path holds a comma fails without running podman", ctx do
      {fake, opts} = engine(ctx, [])
      spec = %{C.spec() | mounts: [%{type: :bind, source: "/a,b", target: "/data"}]}
      assert {:error, {:failed, :create, _}} = Engine.create(spec, opts)
      assert FakePodman.verbs(fake) == [["info", "--format", "{{.Version.Version}}"]]
    end

    test "a failed or killed pull empties the spool; a good one leaves it" do
      root = Path.join(System.tmp_dir!(), "podman-spool-#{System.unique_integer([:positive])}")
      spool = Path.join(root, "storage/tmp")

      # An interrupted pull's leftovers from an hour ago, made by podman
      # itself: past the pull's preflight clear, and there before podman can
      # answer or be killed.
      leak = [
        run:
          ~s(d="#{spool}/layer-$$"; mkdir -p "$d"; touch -d @#{System.os_time(:second) - 3_600} "$d")
      ]

      fake =
        FakePodman.start([
          {"pull * docker://ghcr.io/vagus/good:1", [{0, "5b0e\n", leak}]},
          {"pull * docker://ghcr.io/vagus/slow:1", [{0, "", [hold: true] ++ leak}]},
          {"pull *", [{125, "Error: initializing source docker://x: manifest unknown\n", leak}]}
        ])

      host = FakePodman.start_host(fake.bin, root: root)
      opts = [engine: Engine.Podman, host: host, podman_bin: fake.bin]

      # What a live pull is writing now: it stays.
      live = Path.join(spool, "live")
      File.mkdir_p!(live)

      assert Engine.pull("ghcr.io/vagus/good:1", opts) == :ok
      assert length(File.ls!(spool)) == 2

      {:error, {:pull_failed, _}} = Engine.pull("ghcr.io/vagus/bad:1", opts)
      assert File.ls!(spool) == ["live"]

      assert Engine.pull("ghcr.io/vagus/slow:1", [timeout_ms: 1_000] ++ opts) ==
               {:error, :timeout}

      assert File.ls!(spool) == ["live"]
    end

    test "remove deletes the container's log, so a recreate starts it empty" do
      root = Path.join(System.tmp_dir!(), "podman-logs-#{System.unique_integer([:positive])}")
      fake = FakePodman.start([{"rm *", [{0, ""}]}])
      host = FakePodman.start_host(fake.bin, root: root)
      opts = [engine: Engine.Podman, host: host, podman_bin: fake.bin]
      logs = Path.join(root, "logs")
      outside = Path.join(root, "outside.log")
      File.write!(outside, "keep")

      File.write!(Path.join(logs, "addon_local_x.log"), "old lines")
      File.ln_s!(outside, Path.join(logs, "addon_local_y.log"))
      File.mkdir_p!(Path.join(logs, "addon_local_z.log"))
      File.write!(Path.join(logs, "addon_local_w.log"), "another container's")

      for name <- ~w(addon_local_x addon_local_y addon_local_z),
          do: :ok = Engine.remove(name, opts)

      # The link is gone and its target untouched; a directory is left be.
      assert File.ls!(logs) |> Enum.sort() == ["addon_local_w.log", "addon_local_z.log"]
      assert File.read!(outside) == "keep"
    end

    test "remove by container id deletes the log named for the container" do
      root = Path.join(System.tmp_dir!(), "podman-logs-#{System.unique_integer([:positive])}")

      fake =
        FakePodman.start([
          {"container inspect *", [{0, Leg.inspect_out(Leg.running_json())}]},
          {"rm *", [{0, ""}]}
        ])

      host = FakePodman.start_host(fake.bin, root: root)
      opts = [engine: Engine.Podman, host: host, podman_bin: fake.bin]
      File.write!(Path.join(root, "logs/addon_local_x.log"), "old lines")

      :ok = Engine.remove(Leg.running_json()["Id"], opts)
      assert File.ls!(Path.join(root, "logs")) == []
    end

    test "remove by id spends one timeout_ms across the lookup and the rm" do
      fake =
        FakePodman.start([
          {"container inspect *", [{0, Leg.inspect_out(Leg.running_json()), delay_ms: 140}]},
          {"rm *", [{0, "", delay_ms: 140}]}
        ])

      host = FakePodman.start_host(fake.bin)
      opts = [engine: Engine.Podman, host: host, podman_bin: fake.bin, timeout_ms: 200]
      assert Engine.remove(Leg.running_json()["Id"], opts) == {:error, :timeout}
    end

    test "a failed remove keeps the log" do
      root = Path.join(System.tmp_dir!(), "podman-logs-#{System.unique_integer([:positive])}")
      fake = FakePodman.start([{"rm *", [{125, "Error: boom\n"}]}])
      host = FakePodman.start_host(fake.bin, root: root)
      opts = [engine: Engine.Podman, host: host, podman_bin: fake.bin]
      File.write!(Path.join(root, "logs/addon_local_x.log"), "lines")

      assert {:error, {:failed, :remove, _}} = Engine.remove("addon_local_x", opts)
      assert File.exists?(Path.join(root, "logs/addon_local_x.log"))
    end

    test "a pull refused at shutdown is :busy" do
      fake = FakePodman.start([])
      host = FakePodman.start_host(fake.bin, shutting_down?: fn -> true end)
      opts = [engine: Engine.Podman, host: host, podman_bin: fake.bin]
      assert Engine.pull("ghcr.io/vagus/x:1", opts) == {:error, :busy}
    end

    test "a healthcheck refused at shutdown is :busy, and never runs podman" do
      fake = FakePodman.start([{"healthcheck run *", [{0, ""}]}])
      host = FakePodman.start_host(fake.bin, shutting_down?: fn -> true end)
      opts = [engine: Engine.Podman, host: host, podman_bin: fake.bin]
      assert Engine.healthcheck("addon_local_x", opts) == {:error, :busy}
      refute Enum.any?(FakePodman.calls(fake), &("healthcheck" in &1))
    end

    test "a healthcheck that would take the last ops permit is skipped at once, not queued" do
      fake = FakePodman.start([{"healthcheck run *", [{0, ""}]}])
      host = FakePodman.start_host(fake.bin, permits: %{pull: 1, ops: 2, shutdown: 1})
      opts = [engine: Engine.Podman, host: host, podman_bin: fake.bin, timeout_ms: 30_000]
      {:ok, permit} = Vagus.Runtime.Host.checkout(host, :ops, 0)
      assert Engine.healthcheck("addon_local_x", opts) == {:error, :busy}
      Vagus.Runtime.Host.checkin(permit)
      assert Engine.healthcheck("addon_local_x", opts) == {:ok, :healthy}
    end

    test "an unhealthy run's follow-up inspect skips rather than queue behind ops" do
      fake =
        FakePodman.start([
          {"healthcheck run *", [{1, "unhealthy\n", hold: true}]},
          {"container inspect *", [{0, Leg.inspect_out(Leg.running_json())}]}
        ])

      host = FakePodman.start_host(fake.bin, permits: %{pull: 1, ops: 2, shutdown: 1})
      opts = [engine: Engine.Podman, host: host, podman_bin: fake.bin, timeout_ms: 20_000]
      check = Task.async(fn -> Engine.healthcheck("addon_local_x", opts) end)

      Enum.find(1..1_000, fn _ ->
        Enum.any?(FakePodman.calls(fake), &("healthcheck" in &1)) or (Process.sleep(5) && false)
      end) || flunk("the check never ran")

      # The other permit taken, the holder queues behind the run and is
      # handed the permit the run frees; only then does the run answer.
      {:ok, _other} = Vagus.Runtime.Host.checkout(host, :ops, 0)
      holder = Task.async(fn -> Vagus.Runtime.Host.checkout(host, :ops, 30_000) end)
      await_waiter(host)
      released = System.monotonic_time(:millisecond)
      FakePodman.release(fake)

      assert Task.await(check, 30_000) == {:error, :busy}
      assert System.monotonic_time(:millisecond) - released < 10_000
      refute Enum.any?(FakePodman.calls(fake), &("inspect" in &1))
      assert {:ok, _permit} = Task.await(holder)
    end

    # The app process passes the image's declared timeout; podman's 35 s is
    # only the default.
    test "a healthcheck runs for the timeout_ms it is given, not a fixed deadline" do
      fake = FakePodman.start([{"healthcheck run *", [{0, "", delay_ms: 1_000}]}])
      host = FakePodman.start_host(fake.bin)
      opts = [engine: Engine.Podman, host: host, podman_bin: fake.bin]

      assert Engine.healthcheck("addon_local_x", [timeout_ms: 300] ++ opts) == {:error, :timeout}
      assert Engine.healthcheck("addon_local_x", [timeout_ms: 10_000] ++ opts) == {:ok, :healthy}
    end

    # What `Engine.Fake` answers with no instance, which stands in for this.
    test "with no Host, stop_all fails each name as unavailable" do
      opts = [engine: Engine.Podman, host: :vagus_no_such_host]

      assert Engine.stop_all(["addon_a", "addon_b"], 5, opts) ==
               {:ok, [], [{"addon_a", :unavailable}, {"addon_b", :unavailable}]}

      assert Engine.stop_all([], 5, opts) == {:ok, [], []}
    end

    test "podman schedules no healthchecks" do
      refute Engine.schedules_healthchecks?(engine: Engine.Podman)
    end

    test "Core's pull waits for the pull permit ahead of an app's" do
      fake = FakePodman.start([{"pull *", [{0, "5b0e\n"}]}])
      host = FakePodman.start_host(fake.bin)
      opts = [engine: Engine.Podman, host: host, podman_bin: fake.bin]
      {:ok, held} = Vagus.Runtime.Host.checkout(host, :pull, 0)

      app = Task.async(fn -> Engine.pull("ghcr.io/vagus/app:1", opts) end)
      await_waiter(host, :pull, 1)
      core = Task.async(fn -> Engine.pull(Vagus.Core.Container.image("2026.7.3"), opts) end)
      await_waiter(host, :pull, 2)

      Vagus.Runtime.Host.checkin(held)
      assert Task.await(core, 10_000) == :ok
      assert Task.await(app, 10_000) == :ok

      pulled = for ["pull" | args] <- FakePodman.verbs(fake), do: List.last(args)

      assert pulled == [
               "docker://ghcr.io/home-assistant/home-assistant:2026.7.3",
               "docker://ghcr.io/vagus/app:1"
             ]
    end

    test "the Provisioner's Core pull, through Lifecycle, also goes first" do
      fake = FakePodman.start([{"pull *", [{0, "5b0e\n"}]}])
      host = FakePodman.start_host(fake.bin)
      opts = [engine: Engine.Podman, host: host, podman_bin: fake.bin]
      {:ok, held} = Vagus.Runtime.Host.checkout(host, :pull, 0)

      app = Task.async(fn -> Engine.pull("ghcr.io/vagus/app:1", opts) end)
      await_waiter(host, :pull, 1)
      core = Task.async(fn -> Vagus.Core.Lifecycle.pull("2026.7.3", engine_opts: opts) end)
      await_waiter(host, :pull, 2)

      Vagus.Runtime.Host.checkin(held)
      assert Task.await(core, 10_000) == :ok
      assert Task.await(app, 10_000) == :ok

      assert [first | _] = for(["pull" | args] <- FakePodman.verbs(fake), do: List.last(args))
      assert first == "docker://ghcr.io/home-assistant/home-assistant:2026.7.3"
    end

    test "an app's ensure-image pull the migration found no room for fails, without podman" do
      root = Path.join(System.tmp_dir!(), "podman-nospace-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "balena-engine"))
      File.write!(Path.join(root, "mountinfo"), "")
      on_exit(fn -> File.rm_rf(root) end)

      df = fn _ ->
        {"Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/root 9999 1 10 1% /\n", 0}
      end

      fake = FakePodman.start([{"image exists *", [{1, ""}]}, {"pull *", [{0, "5b0e\n"}]}])

      host =
        FakePodman.start_host(fake.bin,
          migration: [
            legacy_root: Path.join(root, "balena-engine"),
            marker: Path.join(root, "engine-migrated"),
            config_dir: Path.join(root, "core/config"),
            mountinfo: Path.join(root, "mountinfo"),
            validated?: fn -> false end,
            wanted_images: fn -> {:ok, ["ghcr.io/vagus/app:1"]} end,
            core_image: fn -> nil end,
            image_present?: fn _ -> false end,
            notify: fn _ -> :ok end,
            df: df
          ]
        )

      spec = %Vagus.Addon.Backend.Spec{name: "addon_local_app", image: "ghcr.io/vagus/app:1"}
      opts = [engine: Engine.Podman, host: host, podman_bin: fake.bin]

      assert Vagus.Addon.Backend.Container.ensure_image(spec, opts) ==
               {:error, {:pull, {:failed, :pull, :no_space}}}

      refute Enum.any?(FakePodman.verbs(fake), &match?(["pull" | _], &1))
    end

    test "a stale spool an earlier pull left is cleared before the room check" do
      root = Path.join(System.tmp_dir!(), "podman-stale-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "balena-engine"))
      File.write!(Path.join(root, "mountinfo"), "")
      on_exit(fn -> File.rm_rf(root) end)

      host_root = Path.join(root, "host")
      leaked = Path.join(host_root, "storage/tmp/leaked")

      # Room exists only once the leaked layers are gone.
      df = fn _ ->
        avail = if File.exists?(leaked), do: 10, else: 99_999_999

        {"Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/root 9999 1 #{avail} 1% /\n",
         0}
      end

      fake = FakePodman.start([{"pull *", [{0, "5b0e\n"}]}])

      host =
        FakePodman.start_host(fake.bin,
          root: host_root,
          spool_quiet_ms: 60_000,
          migration: [
            legacy_root: Path.join(root, "balena-engine"),
            marker: Path.join(root, "engine-migrated"),
            config_dir: Path.join(root, "core/config"),
            mountinfo: Path.join(root, "mountinfo"),
            validated?: fn -> false end,
            wanted_images: fn -> {:ok, ["ghcr.io/vagus/app:1"]} end,
            core_image: fn -> nil end,
            image_present?: fn _ -> false end,
            notify: fn _ -> :ok end,
            df: df
          ]
        )

      File.mkdir_p!(leaked)
      File.write!(Path.join(leaked, "layer"), "x")
      hour_ago = "@#{System.os_time(:second) - 3_600}"
      {_, 0} = System.cmd("find", [leaked, "-exec", "touch", "-h", "-d", hour_ago, "{}", "+"])

      opts = [engine: Engine.Podman, host: host, podman_bin: fake.bin]

      assert Engine.pull("ghcr.io/vagus/app:1", opts) == :ok
      refute File.exists?(leaked)
    end

    test "an app asking first is refused the room Core still needs, and Core then pulls" do
      root = Path.join(System.tmp_dir!(), "podman-room-#{System.unique_integer([:positive])}")
      store = Path.join(root, "balena-engine/image/overlay2")
      on_exit(fn -> File.rm_rf(root) end)

      # balena holds Core as one 100 MiB layer and the app as one of 200 MiB.
      # 350 MiB free: Core alone needs 150, the app alone 300, both 400.
      core = Vagus.Core.Container.image("2026.7.3")
      app = "ghcr.io/vagus/app:1"

      tags =
        for {ref, hex, size} <- [{core, "a", 100}, {app, "b", 200}], into: %{} do
          diff = "sha256:" <> String.duplicate(hex, 64)
          config = Jason.encode!(%{"rootfs" => %{"diff_ids" => [diff]}})
          id = Base.encode16(:crypto.hash(:sha256, config), case: :lower)
          File.mkdir_p!(Path.join(store, "imagedb/content/sha256"))
          File.write!(Path.join(store, "imagedb/content/sha256/#{id}"), config)
          layer = Path.join(store, "layerdb/sha256/" <> String.duplicate(hex, 64))
          File.mkdir_p!(layer)
          File.write!(Path.join(layer, "size"), "#{size * 1_048_576}")
          {ref, "sha256:" <> id}
        end

      File.write!(
        Path.join(store, "repositories.json"),
        Jason.encode!(%{"Repositories" => %{"r" => tags}})
      )

      File.write!(Path.join(root, "mountinfo"), "")

      df = fn _ ->
        {"Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/root 9999999 1 #{350 * 1024} 1% /\n",
         0}
      end

      core_back = :atomics.new(1, [])
      fake = FakePodman.start([{"pull *", [{0, "5b0e\n"}]}])

      host =
        FakePodman.start_host(fake.bin,
          migration: [
            legacy_root: Path.join(root, "balena-engine"),
            marker: Path.join(root, "engine-migrated"),
            config_dir: Path.join(root, "core/config"),
            mountinfo: Path.join(root, "mountinfo"),
            validated?: fn -> false end,
            notify: fn _ -> :ok end,
            core_image: fn -> core end,
            image_present?: fn ref -> ref == core and :atomics.get(core_back, 1) == 1 end,
            df: df
          ]
        )

      opts = [engine: Engine.Podman, host: host, podman_bin: fake.bin]

      # The pull permit is idle and the app asks first.
      ExUnit.CaptureLog.capture_log(fn ->
        assert Engine.pull(app, opts) == {:error, {:failed, :pull, :no_space}}
      end)

      assert Engine.pull(core, opts) == :ok
      :atomics.put(core_back, 1, 1)
      assert Engine.pull(app, opts) == :ok

      pulled = for ["pull" | args] <- FakePodman.verbs(fake), do: List.last(args)
      assert pulled == ["docker://" <> core, "docker://" <> app]
    end

    # The stop must outlast the 300 ms its permit wait may use.
    test "a stop waiting for its permit still gets its grace once granted" do
      fake = FakePodman.start([{"stop *", [{0, "addon_local_x\n", delay_ms: 1_000}]}])
      host = FakePodman.start_host(fake.bin, permits: %{pull: 1, ops: 1, shutdown: 1})
      opts = [engine: Engine.Podman, host: host, podman_bin: fake.bin]
      test = self()

      holder =
        spawn_link(fn ->
          {:ok, permit} = Vagus.Runtime.Host.checkout(host, :ops, 0)
          send(test, :held)
          receive do: (:release -> Vagus.Runtime.Host.checkin(permit))
        end)

      assert_receive :held, 5_000

      # The command gets its grace plus the margin (1.5 s here), not what
      # `timeout_ms` left after the wait, and no more than that either.
      stop =
        Task.async(fn ->
          Engine.stop(
            "addon_local_x",
            [timeout_ms: 300, timeout_s: 0, stop_margin_ms: 1_500] ++ opts
          )
        end)

      await_waiter(host)
      send(holder, :release)
      assert Task.await(stop, 30_000) == :ok
    end

    test "a stop past its grace and margin is cut off" do
      fake = FakePodman.start([{"stop *", [{0, "addon_local_x\n", delay_ms: 5_000}]}])
      host = FakePodman.start_host(fake.bin)
      opts = [engine: Engine.Podman, host: host, podman_bin: fake.bin]

      assert Engine.stop(
               "addon_local_x",
               [timeout_ms: 100, timeout_s: 0, stop_margin_ms: 1_000] ++ opts
             ) == {:error, :timeout}
    end

    test "create refuses a port key that could name a host port, without podman" do
      {fake, opts} = engine(%{}, [{"create *", [{0, "c0ffee\n"}]}])

      for key <- ["8123:8123/tcp", "0.0.0.0:80:80/tcp", "1-1024", "80/xyz"] do
        spec = %{C.spec() | ports: %{key => nil}}
        assert Engine.create(spec, opts) == {:error, {:failed, :create, {:invalid_port, key}}}
      end

      refute Enum.any?(FakePodman.verbs(fake), &match?(["create" | _], &1))

      spec = %{C.spec() | ports: %{"8080/tcp" => 8080, "53/udp" => nil, "9000" => 9000}}
      assert {:ok, "c0ffee"} = Engine.create(spec, opts)
    end

    test "an image ref naming a transport or a bad name never reaches podman" do
      {fake, opts} = engine(%{}, [])

      for image <- [
            "oci-archive:/root/vagus/x.tar",
            "dir:/tmp/x",
            "docker-archive:/tmp/x.tar",
            "containers-storage:alpine",
            "docker://alpine:3.20",
            "oci:latest",
            "Ghcr.io/Vagus/x:1"
          ] do
        assert Engine.pull(image, opts) == {:error, {:pull_failed, {:invalid_image, image}}}

        assert Engine.image_present?(image, opts) ==
                 {:error, {:failed, :image_present?, {:invalid_image, image}}}

        assert Engine.remove_image(image, opts) ==
                 {:error, {:failed, :remove_image, {:invalid_image, image}}}

        assert Engine.create(%{C.spec() | image: image}, opts) ==
                 {:error, {:failed, :create, {:invalid_image, image}}}
      end

      for name <- ["-x", "a/b", "a b", ""] do
        assert Engine.start(name, opts) == {:error, {:failed, :start, {:invalid_name, name}}}
      end

      assert FakePodman.verbs(fake) == [["info", "--format", "{{.Version.Version}}"]]
    end
  end

  defp await_waiter(host, class \\ :ops, n \\ 1) do
    Enum.find(1..1_000, fn _ ->
      :queue.len(:sys.get_state(host).waiting[class]) == n or (Process.sleep(5) && false)
    end) || flunk("no #{n} #{class} waiter(s) queued")
  end

  describe "exec exit codes" do
    test "125-127 without an Error: line are the command's own", ctx do
      for code <- [125, 126, 127] do
        {_fake, opts} = engine(ctx, [{"exec *", [{code, "cmd says no\n"}]}])

        assert Engine.exec("addon_local_x", ["x"], opts) ==
                 {:ok, %{exit_code: code, output: "cmd says no\n"}}
      end
    end

    test "a container that is not running is podman's failure", ctx do
      {_fake, opts} =
        engine(ctx, [
          {"exec *",
           [
             {255,
              "Error: can only create exec sessions on running containers: container state improper\n"}
           ]}
        ])

      assert {:error, {:failed, :exec, _}} = Engine.exec("addon_local_x", ["true"], opts)
    end
  end

  test "the readiness of a Host still preparing is :unavailable" do
    fake = FakePodman.start([])
    test_pid = self()

    # Answers once the test is over, so the probe task ends with it.
    probe = fn _opts ->
      ref = Process.monitor(test_pid)
      receive do: ({:DOWN, ^ref, :process, _pid, _reason} -> {:error, :gone})
    end

    host = FakePodman.start_host(fake.bin, await: false, probe: probe)

    assert Engine.ready(engine: Engine.Podman, host: host) == {:error, :unavailable}
  end

  test "a stop's floor: podman's default 10 s grace or timeout_s, plus 15 s" do
    assert Engine.Podman.grace([]) == {[], 25_000}
    assert Engine.Podman.grace(timeout_ms: 100) == {[], 25_000}
    assert Engine.Podman.grace(timeout_s: 5) == {["--time", "5"], 20_000}
    assert Engine.Podman.grace(timeout_s: 0, timeout_ms: 100) == {["--time", "0"], 15_000}
  end

  test "its event source is the events-file tail" do
    assert Engine.Podman.event_source() == Engine.Podman.EventSource
  end
end
