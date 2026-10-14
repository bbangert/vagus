defmodule Vagus.Runtime.Engine.DockerContractTest.Leg do
  @behaviour Vagus.Test.EngineContract

  alias Vagus.Runtime.Engine
  alias Vagus.Test.FakeEngine

  @no_such_container {404, %{"message" => "No such container: ghost"}}

  @impl true
  def arrange(:unavailable, _ctx) do
    socket =
      Path.join(System.tmp_dir!(), "vagus-nobody-#{System.unique_integer([:positive])}.sock")

    [engine: Engine.Docker, socket: socket]
  end

  def arrange(scenario, _ctx) do
    engine = FakeEngine.start(script(scenario))
    ExUnit.Callbacks.on_exit(fn -> FakeEngine.stop(engine) end)
    [engine: Engine.Docker, socket: engine.socket]
  end

  def framed(payload, stream \\ 1), do: <<stream, 0, 0, 0, byte_size(payload)::32>> <> payload

  def running_json(health \\ "healthy") do
    %{
      "Id" => "4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a",
      "Name" => "/addon_local_x",
      "Image" => "sha256:5b0e9d3c",
      "State" => %{
        "Status" => "running",
        "Running" => true,
        "Restarting" => false,
        "ExitCode" => 0,
        "StartedAt" => "2026-10-14T10:00:00.123456789Z",
        "FinishedAt" => "0001-01-01T00:00:00Z",
        "Health" => %{"Status" => health, "FailingStreak" => 0, "Log" => []}
      },
      "Config" => %{
        "Hostname" => "local-x",
        "Image" => "ghcr.io/vagus/aarch64-addon-x:1.2.0",
        "Env" => ["TZ=UTC", "SUPERVISOR_TOKEN=tok", "OPTS=a=b"],
        "Labels" => %{"supervisor_managed" => "", "io.hass.version" => "1.2.0"},
        "Healthcheck" => %{
          "Test" => ["CMD-SHELL", "curl -f http://localhost/ || exit 1"],
          "Interval" => 30_000_000_000,
          "Timeout" => 5_000_000_000,
          "Retries" => 3
        }
      },
      "NetworkSettings" => %{
        "Networks" => %{"hassio" => %{"IPAddress" => "172.30.33.4", "Gateway" => "172.30.32.1"}}
      }
    }
  end

  def exited_json(exit_code \\ 137) do
    %{
      "Id" => "9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a",
      "Name" => "/addon_local_y",
      "Image" => "sha256:77c1",
      "State" => %{
        "Status" => "exited",
        "Running" => false,
        "Restarting" => false,
        "ExitCode" => exit_code,
        "StartedAt" => "2026-10-14T09:00:00Z",
        "FinishedAt" => "2026-10-14T09:30:00Z"
      },
      "Config" => %{
        "Image" => "ghcr.io/vagus/aarch64-addon-y:2.0.0",
        "Env" => ["TZ=UTC"],
        "Labels" => %{"supervisor_managed" => ""}
      },
      "NetworkSettings" => %{"Networks" => %{"hassio" => %{"IPAddress" => ""}}}
    }
  end

  defp summary(id, name, image, state, status, labels) do
    %{
      "Id" => id,
      "Names" => ["/" <> name],
      "Image" => image,
      "ImageID" => "sha256:5b0e9d3c",
      "State" => state,
      "Status" => status,
      "Labels" => labels
    }
  end

  defp x_summary do
    summary(
      "4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a",
      "addon_local_x",
      "ghcr.io/vagus/aarch64-addon-x:1.2.0",
      "running",
      "Up 2 hours (healthy)",
      %{"supervisor_managed" => "", "io.hass.version" => "1.2.0"}
    )
  end

  defp y_summary do
    summary(
      "9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a",
      "addon_local_y",
      "ghcr.io/vagus/aarch64-addon-y:2.0.0",
      "exited",
      "Exited (137) 2 minutes ago",
      %{"supervisor_managed" => ""}
    )
  end

  defp core_summary do
    summary(
      "77aa88bb77aa88bb77aa88bb77aa88bb77aa88bb77aa88bb77aa88bb77aa88bb",
      "homeassistant",
      "ghcr.io/home-assistant/home-assistant:2026.7.0",
      "running",
      "Up 3 hours",
      %{"io.vagus.spec-fingerprint" => "0123456789abcdef0123456789abcdef"}
    )
  end

  defp raw_stats do
    %{
      "cpu_stats" => %{
        "cpu_usage" => %{"total_usage" => 300_000_000},
        "system_cpu_usage" => 10_000_000_000,
        "online_cpus" => 4
      },
      "precpu_stats" => %{
        "cpu_usage" => %{"total_usage" => 100_000_000},
        "system_cpu_usage" => 6_800_000_000,
        "online_cpus" => 4
      },
      "memory_stats" => %{
        "usage" => 60_000_000,
        "limit" => 1_000_000_000,
        "stats" => %{"inactive_file" => 10_000_000}
      },
      "networks" => %{
        "eth0" => %{"rx_bytes" => 1000, "tx_bytes" => 2000},
        "eth1" => %{"rx_bytes" => 24, "tx_bytes" => 48}
      },
      "blkio_stats" => %{
        "io_service_bytes_recursive" => [
          %{"major" => 179, "minor" => 0, "op" => "read", "value" => 4096},
          %{"major" => 179, "minor" => 0, "op" => "write", "value" => 8192}
        ]
      }
    }
  end

  defp pull_stream(lines), do: Enum.map_join(lines, "", &(Jason.encode!(&1) <> "\n"))

  defp script(:ready), do: [{200, "OK"}]
  defp script(:absent), do: [@no_such_container]
  defp script(:inspect_running), do: [{200, running_json()}]
  defp script(:inspect_exited), do: [{200, exited_json()}]

  # A real daemon filters `all=false` itself.
  defp script(:list),
    do: [{200, [x_summary(), core_summary()]}, {200, [x_summary(), y_summary(), core_summary()]}]

  defp script(:start_created), do: [{204, nil}, {200, running_json()}]
  defp script(:start_running), do: [{304, nil}]
  defp script(:stop_running), do: [{204, nil}, {200, exited_json(0)}]
  defp script(:stop_stopped), do: [{304, nil}]
  defp script(:restart), do: [{204, nil}]

  defp script(:remove),
    do: [{204, nil}, {404, %{"message" => "No such container: addon_local_y"}}]

  defp script(:stop_all) do
    [
      {500, %{"message" => "cannot stop container: permission denied"}},
      {204, nil},
      {304, nil},
      @no_such_container
    ]
  end

  defp script(:create), do: [{201, %{"Id" => "c0ffee", "Warnings" => []}}]

  defp script(:create_conflict) do
    [
      {409,
       %{
         "message" =>
           ~s(Conflict. The container name "/addon_local_x" is already in use by container "4f1c". You have to remove (or rename\) that container to be able to reuse that name.)
       }}
    ]
  end

  defp script(:create_no_image) do
    [{404, %{"message" => "No such image: ghcr.io/vagus/aarch64-addon-x:1.2.0"}}]
  end

  defp script(:pull) do
    body =
      pull_stream([
        %{"status" => "Pulling from vagus/aarch64-addon-x", "id" => "1.2.0"},
        %{"status" => "Download complete", "id" => "a1b2"},
        %{"status" => "Status: Downloaded newer image for ghcr.io/vagus/aarch64-addon-x:1.2.0"}
      ])

    [
      {200, body},
      {200, %{"Id" => "sha256:5b0e9d3c", "RepoTags" => ["ghcr.io/vagus/aarch64-addon-x:1.2.0"]}}
    ]
  end

  defp script(:pull_failed) do
    body =
      pull_stream([
        %{"status" => "Pulling from vagus/missing", "id" => "1.0"},
        %{"errorDetail" => %{"message" => "manifest unknown"}, "error" => "manifest unknown"}
      ])

    [{200, body}]
  end

  defp script(:image_absent),
    do: [{404, %{"message" => "No such image: ghcr.io/vagus/missing:1.0"}}]

  defp script(:remove_image) do
    [
      {200,
       [%{"Untagged" => "ghcr.io/vagus/aarch64-addon-x:1.2.0"}, %{"Deleted" => "sha256:5b0e9d3c"}]},
      {404, %{"message" => "No such image: ghcr.io/vagus/aarch64-addon-x:1.2.0"}}
    ]
  end

  defp script(:image_in_use) do
    [
      {409,
       %{
         "message" =>
           ~s(conflict: unable to remove repository reference "ghcr.io/vagus/aarch64-addon-x:1.2.0" (must force\) - container 4f1c is using its referenced image 5b0e9d3c)
       }}
    ]
  end

  defp script(:logs), do: [{200, framed("line one\n") <> framed("line two\n", 2)}]
  defp script(:follow), do: script(:logs)
  defp script(:stats), do: [{200, raw_stats()}]

  defp script({:exec, code, output}) do
    [
      {201, %{"Id" => "exec-1"}},
      {200, framed(output, if(code == 0, do: 1, else: 2))},
      {200, %{"Running" => false, "ExitCode" => code}}
    ]
  end

  defp script(:exec_no_capture) do
    [{201, %{"Id" => "exec-1"}}, {200, nil}, {200, %{"Running" => false, "ExitCode" => 3}}]
  end

  defp script(:exec_timeout) do
    [{201, %{"Id" => "exec-1"}}, {200, framed("late\n"), delay: 2_000}]
  end

  defp script({:health, health}), do: [{200, running_json(Atom.to_string(health))}]

  defp script(:network_exists),
    do: [{200, %{"Name" => "hassio", "Id" => "n1", "Driver" => "bridge"}}]

  defp script(:network_created) do
    [{404, %{"message" => "network hassio not found"}}, {201, %{"Id" => "n1", "Warning" => ""}}]
  end

  defp script(:network_race) do
    [
      {404, %{"message" => "network hassio not found"}},
      {409, %{"message" => "network with name hassio already exists"}}
    ]
  end

  # Past its script FakeEngine answers every request 500.
  defp script(:engine_error), do: []
end

defmodule Vagus.Runtime.Engine.DockerContractTest do
  use Vagus.Test.EngineContract, leg: Vagus.Runtime.Engine.DockerContractTest.Leg, async: true

  alias Vagus.Runtime.Engine.DockerContractTest.Leg
  alias Vagus.Test.EngineContract, as: C
  alias Vagus.Test.FakeEngine

  defp engine(script) do
    engine = FakeEngine.start(script)
    on_exit(fn -> FakeEngine.stop(engine) end)
    {engine, [engine: Engine.Docker, socket: engine.socket]}
  end

  describe "Docker inspect parsing" do
    test "dead is :exited; zero times, a NONE healthcheck and empty IPs are absent" do
      raw =
        Leg.exited_json()
        |> put_in(["State", "Status"], "dead")
        |> put_in(["State", "FinishedAt"], "0001-01-01T00:00:00Z")
        |> put_in(["Config", "Healthcheck"], %{"Test" => ["NONE"]})

      {_engine, opts} = engine([{200, raw}])

      assert {:ok,
              %Container{
                state: :exited,
                exit_code: 137,
                finished_at: nil,
                healthcheck: nil,
                ips: %{}
              }} =
               Engine.inspect("addon_local_y", opts)
    end

    test "a running container reports no exit code even though Docker says 0" do
      {_engine, opts} = engine([{200, Leg.running_json()}])
      assert {:ok, %Container{exit_code: nil}} = Engine.inspect("addon_local_x", opts)
    end
  end

  describe "what reaches the daemon" do
    test "create sends the name and the rendered spec" do
      {engine, opts} = engine([{201, %{"Id" => "c0ffee"}}])
      assert {:ok, "c0ffee"} = Engine.create(C.spec(), opts)

      assert [
               %{
                 method: :post,
                 path: "/containers/create",
                 query: %{"name" => "addon_local_x"},
                 body: body
               }
             ] =
               FakeEngine.requests(engine)

      assert body == Engine.Docker.render_container(C.spec())
    end

    test "stop passes timeout_s as t; logs pass tail and timestamps" do
      {engine, opts} = engine([{204, nil}, {200, ""}])
      :ok = Engine.stop("addon_local_x", [timeout_s: 7] ++ opts)
      {:ok, ""} = Engine.logs("addon_local_x", [tail: 5, timestamps: true] ++ opts)

      assert [%{query: %{"t" => "7"}}, %{query: %{"tail" => "5", "timestamps" => "true"}}] =
               FakeEngine.requests(engine)
    end

    test "exec sends the argv as Cmd, unwrapped" do
      {engine, opts} =
        engine(
          Leg.framed("")
          |> then(
            &[{201, %{"Id" => "e"}}, {200, &1}, {200, %{"Running" => false, "ExitCode" => 0}}]
          )
        )

      {:ok, _} = Engine.exec("addon_local_x", ["ha", "core", "check"], opts)
      assert [%{body: %{"Cmd" => ["ha", "core", "check"]}} | _] = FakeEngine.requests(engine)
    end

    test "ensure_network creates the rendered network" do
      {engine, opts} =
        engine([{404, %{"message" => "network hassio not found"}}, {201, %{"Id" => "n1"}}])

      :ok = Engine.ensure_network(C.hassio(), opts)

      assert [%{path: "/networks/hassio"}, %{path: "/networks/create", body: body}] =
               FakeEngine.requests(engine)

      assert body == Vagus.Network.config()
    end
  end

  test "a registry refusal is {:pull_failed, message} without its HTTP status" do
    {_engine, opts} = engine([{404, %{"message" => "pull access denied for ghcr.io/vagus/x"}}])

    assert Engine.pull("ghcr.io/vagus/x:1", opts) ==
             {:error, {:pull_failed, "pull access denied for ghcr.io/vagus/x"}}
  end
end
