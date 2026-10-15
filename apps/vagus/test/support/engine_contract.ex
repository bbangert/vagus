defmodule Vagus.Test.EngineContract do
  @moduledoc """
  The behaviour every `Vagus.Runtime.Engine` adapter must share, run through
  `Engine` dispatch: `use Vagus.Test.EngineContract, leg: Leg, async: true`.

  `Leg.arrange(scenario, ctx)` makes the scenario true for its engine and
  returns the opts aiming calls at it. A scripted leg must answer the
  scenario's calls in the order the test makes them.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions, only: [flunk: 1]

  alias Vagus.Runtime.Engine
  alias Vagus.Runtime.Engine.{Container, ContainerSpec, NetworkSpec}
  alias Vagus.Test.EngineContract, as: C

  @callback arrange(scenario :: atom() | tuple(), ctx :: map()) :: keyword()
  @doc "Lets a scripted follow stream send its next piece; a no-op for a leg that needs none."
  @callback release(opts :: keyword()) :: :ok

  @running_id "4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a4f1c2b3a"
  @exited_id "9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a9d2e7f6a"
  @paused_id "aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22"
  @restarting_id "cc33dd44cc33dd44cc33dd44cc33dd44cc33dd44cc33dd44cc33dd44cc33dd44"
  @core_id "77aa88bb77aa88bb77aa88bb77aa88bb77aa88bb77aa88bb77aa88bb77aa88bb"

  def running do
    %Container{
      id: @running_id,
      name: "addon_local_x",
      image: "ghcr.io/vagus/aarch64-addon-x:1.2.0",
      state: :running,
      exit_code: nil,
      health: :healthy,
      labels: %{"supervisor_managed" => "", "io.hass.version" => "1.2.0"},
      env: %{"TZ" => "UTC", "SUPERVISOR_TOKEN" => "tok", "OPTS" => "a=b"},
      ips: %{"hassio" => "172.30.33.4"},
      healthcheck: %{
        test: ["CMD-SHELL", "curl -f http://localhost/ || exit 1"],
        interval_ms: 30_000,
        timeout_ms: 5_000,
        start_period_ms: nil,
        retries: 3
      },
      started_at: ~U[2026-10-14 10:00:00.123456Z],
      finished_at: nil
    }
  end

  def exited do
    %Container{
      id: @exited_id,
      name: "addon_local_y",
      image: "ghcr.io/vagus/aarch64-addon-y:2.0.0",
      state: :exited,
      exit_code: 137,
      health: nil,
      labels: %{"supervisor_managed" => ""},
      env: %{"TZ" => "UTC"},
      ips: %{},
      healthcheck: nil,
      started_at: ~U[2026-10-14 09:00:00Z],
      finished_at: ~U[2026-10-14 09:30:00Z]
    }
  end

  def paused, do: %{running() | id: @paused_id, name: "addon_local_p", state: :paused}

  def restarting,
    do: %{running() | id: @restarting_id, name: "addon_local_r", state: :restarting}

  def core do
    %Container{
      id: @core_id,
      name: "homeassistant",
      image: "ghcr.io/home-assistant/home-assistant:2026.7.0",
      state: :running,
      labels: %{"io.vagus.spec-fingerprint" => "0123456789abcdef0123456789abcdef"},
      env: %{},
      ips: %{}
    }
  end

  def summary(%Container{} = c) do
    %Container{
      id: c.id,
      name: c.name,
      image: c.image,
      state: c.state,
      labels: c.labels,
      exit_code: c.exit_code
    }
  end

  def spec do
    %ContainerSpec{
      name: "addon_local_x",
      image: "ghcr.io/vagus/aarch64-addon-x:1.2.0",
      network: {:bridge, "hassio"},
      env: [{"TZ", "UTC"}],
      labels: %{"supervisor_managed" => ""}
    }
  end

  def hassio do
    %NetworkSpec{
      name: "hassio",
      subnet: "172.30.32.0/23",
      gateway: "172.30.32.1",
      ip_range: "172.30.33.0/24",
      interface_name: "hassio"
    }
  end

  def logs, do: "line one\nline two\n"

  def stats do
    %{
      cpu_percent: 25.0,
      memory_usage: 50_000_000,
      memory_limit: 1_000_000_000,
      memory_percent: 5.0,
      network_rx: 1024,
      network_tx: 2048,
      blk_read: 4096,
      blk_write: 8192
    }
  end

  # What the failing-engine test calls, so the Fake leg can fail each one.
  def failing_verbs do
    [
      :ready,
      :image_present?,
      :remove_image,
      :create,
      :start,
      :stop,
      :restart,
      :remove,
      :inspect,
      :list,
      :logs,
      :stats,
      :exec,
      :healthcheck,
      :ensure_network
    ]
  end

  @closed [:not_found, :conflict, :in_use, :busy, :timeout, :unavailable]

  def closed_error?(error) when error in @closed, do: true
  def closed_error?({:pull_failed, _detail}), do: true
  def closed_error?({:failed, verb, _detail}) when is_atom(verb), do: true
  def closed_error?(_other), do: false

  @doc "Flunks unless every error in `result` of `verb` is in the closed set."
  def check!(verb, {:error, error} = result) do
    unless closed_error?(error) or {verb, error} == {:healthcheck, :no_healthcheck},
      do: flunk("#{verb} returned #{inspect(error)}, outside the closed error set")

    result
  end

  def check!(:stop_all, {:ok, _stopped, failed} = result) do
    for {_name, error} <- failed, do: check!(:stop, {:error, error})
    result
  end

  def check!(_verb, result), do: result

  # `skip_follow: reason` skips the log-follow tests for an adapter that
  # does not follow yet.
  using opts do
    leg = Keyword.fetch!(opts, :leg)
    skip_follow = Keyword.get(opts, :skip_follow)

    # Split only to keep each quote readable; they land in one module.
    {:__block__, [],
     [
       __helpers__(leg, skip_follow),
       __container_tests__(),
       __live_tests__(),
       __create_tests__(),
       __io_tests__(),
       __exec_tests__(),
       __failure_tests__()
     ]}
  end

  @doc false
  def __helpers__(leg, skip_follow \\ nil) do
    quote do
      @skip_follow unquote(skip_follow)

      alias Vagus.Runtime.Engine
      alias Vagus.Runtime.Engine.Container
      alias Vagus.Test.EngineContract, as: C

      @leg unquote(leg)

      # Every call goes through Checked, so every result is held to the
      # closed error set.
      defp arrange(scenario, ctx) do
        {engine, opts} = Keyword.pop!(@leg.arrange(scenario, ctx), :engine)
        [engine: C.Checked, checked_engine: engine] ++ opts
      end

      defp sorted({:ok, containers}), do: Enum.sort_by(containers, & &1.name)

      defp follow(name, opts) do
        {:ok, pid} = Engine.follow_logs(name, self(), opts)
        collect(pid, [])
      end

      defp follow_chunks(name, opts) do
        {:ok, pid} = Engine.follow_logs(name, self(), opts)
        chunks_until_eof(pid, opts, [])
      end

      # The next piece is released while the chunk is un-acked: it must not
      # arrive until the ack.
      defp chunks_until_eof(pid, opts, acc) do
        receive do
          {:log_chunk, chunk} ->
            @leg.release(opts)
            refute_receive {:log_chunk, _}, 300
            Vagus.Runtime.Logs.Follow.ack(pid)
            chunks_until_eof(pid, opts, [chunk | acc])

          :log_eof ->
            Enum.reverse(acc)
        after
          2_000 -> flunk("no :log_eof")
        end
      end

      defp assert_stamps(text, false), do: assert(text == C.logs())

      defp assert_stamps(text, true) do
        lines = String.split(text, "\n", trim: true)
        assert Enum.all?(lines, &(&1 =~ ~r/^\d{4}-\d\d-\d\dT\S+Z /))

        assert Enum.map(lines, &(&1 |> String.split(" ", parts: 2) |> List.last())) ==
                 ["line one", "line two"]
      end

      defp collect(pid, acc) do
        receive do
          {:log_chunk, chunk} ->
            Vagus.Runtime.Logs.Follow.ack(pid)
            collect(pid, [chunk | acc])

          :log_eof ->
            acc |> Enum.reverse() |> IO.iodata_to_binary()
        after
          2_000 -> flunk("no :log_eof")
        end
      end
    end
  end

  @doc false
  def __container_tests__ do
    quote do
      describe "readiness" do
        test "a live engine is ready", ctx do
          assert Engine.ready(arrange(:ready, ctx)) == :ok
        end

        test "an engine nobody answers for is :unavailable", ctx do
          assert Engine.ready(arrange(:unavailable, ctx)) == {:error, :unavailable}
        end
      end

      describe "inspect" do
        test "a running container: name without /, env, ips, healthcheck, health", ctx do
          assert Engine.inspect("addon_local_x", arrange(:inspect_running, ctx)) ==
                   {:ok, C.running()}
        end

        test "an exited container: exit code, no healthcheck, empty ips skipped", ctx do
          assert Engine.inspect("addon_local_y", arrange(:inspect_exited, ctx)) ==
                   {:ok, C.exited()}
        end

        test "an absent container is :not_found", ctx do
          assert Engine.inspect("ghost", arrange(:absent, ctx)) == {:error, :not_found}
        end
      end

      describe "list" do
        test "live (running, paused, restarting) by default; all + name_prefix adds exited",
             ctx do
          opts = arrange(:list, ctx)
          live = [C.paused(), C.restarting(), C.running()]

          assert sorted(Engine.list(opts)) == Enum.map(live ++ [C.core()], &C.summary/1)

          assert sorted(Engine.list([all: true, name_prefix: "addon_"] ++ opts)) ==
                   Enum.map(live ++ [C.exited()], &C.summary/1)
        end
      end

      describe "lifecycle" do
        test "start of a created container runs it", ctx do
          opts = arrange(:start_created, ctx)
          assert Engine.start("addon_local_x", opts) == :ok
          assert {:ok, %Container{state: :running}} = Engine.inspect("addon_local_x", opts)
        end

        test "start of a running container is :ok and leaves it as it was", ctx do
          opts = arrange(:start_running, ctx)
          {:ok, before} = Engine.inspect("addon_local_x", opts)
          assert Engine.start("addon_local_x", opts) == :ok
          {:ok, now} = Engine.inspect("addon_local_x", opts)
          assert {now.started_at, now.health} == {before.started_at, before.health}
        end

        test "start of an absent container is :not_found", ctx do
          assert Engine.start("ghost", arrange(:absent, ctx)) == {:error, :not_found}
        end

        test "stop of a running container exits it", ctx do
          opts = arrange(:stop_running, ctx)
          assert Engine.stop("addon_local_x", [timeout_s: 5] ++ opts) == :ok

          assert {:ok, %Container{state: :exited, exit_code: 0}} =
                   Engine.inspect("addon_local_x", opts)
        end

        test "inspect past timeout_ms is :timeout", ctx do
          opts = [timeout_ms: 200] ++ arrange(:inspect_slow, ctx)
          assert Engine.inspect("addon_local_x", opts) == {:error, :timeout}
        end

        test "a stop's grace outlasts a smaller timeout_ms", ctx do
          opts = [timeout_ms: 100, timeout_s: 0] ++ arrange(:stop_within_grace, ctx)
          assert Engine.stop("addon_local_x", opts) == :ok
        end

        test "stop past timeout_ms is :timeout", ctx do
          opts = [timeout_ms: 200] ++ arrange(:stop_slow, ctx)
          assert Engine.stop("addon_local_x", opts) == {:error, :timeout}
        end

        test "an engine that hangs up mid-call is :unavailable", ctx do
          assert Engine.inspect("addon_local_x", arrange(:hang_up, ctx)) ==
                   {:error, :unavailable}
        end

        test "stop of a stopped container is :ok", ctx do
          assert Engine.stop("addon_local_y", arrange(:stop_stopped, ctx)) == :ok
        end

        test "stop of an absent container is :not_found", ctx do
          assert Engine.stop("ghost", arrange(:absent, ctx)) == {:error, :not_found}
        end

        test "restart of a running container is :ok", ctx do
          assert Engine.restart("addon_local_x", arrange(:restart, ctx)) == :ok
        end

        test "restart of an absent container is :not_found", ctx do
          assert Engine.restart("ghost", arrange(:absent, ctx)) == {:error, :not_found}
        end

        test "remove deletes the container", ctx do
          opts = arrange(:remove, ctx)
          assert Engine.remove("addon_local_y", opts) == :ok
          assert Engine.inspect("addon_local_y", opts) == {:error, :not_found}
        end

        test "remove of an absent container is :ok", ctx do
          assert Engine.remove("ghost", arrange(:absent, ctx)) == :ok
        end

        # 2 x 5.1 s outlasts one 10 s grace but not the two the call owes.
        @tag timeout: 30_000
        test "stop_all's budget covers every container's grace in turn", ctx do
          opts = [timeout_ms: 100] ++ arrange(:stop_all_slow, ctx)

          assert Engine.stop_all(["addon_local_x", "addon_local_d"], 0, opts) ==
                   {:ok, ["addon_local_x", "addon_local_d"], []}
        end

        test "stop_all: stopped and absent count as stopped, a failure is reported", ctx do
          opts = arrange(:stop_all, ctx)
          names = ["addon_local_d", "addon_local_x", "addon_local_y", "ghost"]

          assert {:ok, ["addon_local_x", "addon_local_y", "ghost"],
                  [{"addon_local_d", {:failed, :stop, _}}]} = Engine.stop_all(names, 5, opts)
        end
      end
    end
  end

  @doc false
  def __live_tests__ do
    quote do
      describe "live states (paused, restarting)" do
        for state <- [:running, :paused, :restarting] do
          @tag state: state
          test "remove with force: false refuses a #{state} container and keeps it", ctx do
            opts = arrange({:remove_live, ctx.state}, ctx)

            assert {:error, {:failed, :remove, _}} =
                     Engine.remove("addon_local_x", [force: false] ++ opts)

            assert {:ok, %Container{state: state}} = Engine.inspect("addon_local_x", opts)
            assert state == ctx.state
          end
        end

        for state <- [:paused, :restarting] do
          @tag state: state
          test "a #{state} container is alive?", ctx do
            opts = arrange({:live, ctx.state}, ctx)
            assert {:ok, container} = Engine.inspect("addon_local_x", opts)
            assert container.state == ctx.state
            assert Container.alive?(container)
          end
        end

        for state <- [:paused, :restarting] do
          @tag state: state
          test "stop of a #{state} container exits it", ctx do
            opts = arrange({:stop_live, ctx.state}, ctx)
            assert Engine.stop("addon_local_x", opts) == :ok
            assert {:ok, %Container{state: :exited}} = Engine.inspect("addon_local_x", opts)
          end
        end
      end
    end
  end

  @doc false
  def __create_tests__ do
    quote do
      describe "create" do
        test "creates from a present image", ctx do
          assert {:ok, id} = Engine.create(C.spec(), arrange(:create, ctx))
          assert is_binary(id) and id != ""
        end

        test "an existing name is :conflict", ctx do
          assert Engine.create(C.spec(), arrange(:create_conflict, ctx)) == {:error, :conflict}
        end

        test "an absent image is {:failed, :create, :image_not_found}", ctx do
          assert Engine.create(C.spec(), arrange(:create_no_image, ctx)) ==
                   {:error, {:failed, :create, :image_not_found}}
        end

        test "an absent network is {:failed, :create, :network_not_found}", ctx do
          assert Engine.create(C.spec(), arrange(:create_no_network, ctx)) ==
                   {:error, {:failed, :create, :network_not_found}}
        end
      end
    end
  end

  @doc false
  def __io_tests__ do
    quote do
      describe "images" do
        test "pull makes the image present", ctx do
          opts = arrange(:pull, ctx)
          assert Engine.pull("ghcr.io/vagus/aarch64-addon-x:1.2.0", opts) == :ok
          assert Engine.image_present?("ghcr.io/vagus/aarch64-addon-x:1.2.0", opts) == true
        end

        test "a failed pull carries the registry's message", ctx do
          assert Engine.pull("ghcr.io/vagus/missing:1.0", arrange(:pull_failed, ctx)) ==
                   {:error, {:pull_failed, "manifest unknown"}}
        end

        test "image_present? of an absent image is false", ctx do
          assert Engine.image_present?("ghcr.io/vagus/missing:1.0", arrange(:image_absent, ctx)) ==
                   false
        end

        test "remove_image of an unused image removes it", ctx do
          opts = arrange(:remove_image, ctx)
          assert Engine.remove_image("ghcr.io/vagus/aarch64-addon-x:1.2.0", opts) == :ok
          assert Engine.image_present?("ghcr.io/vagus/aarch64-addon-x:1.2.0", opts) == false
        end

        test "remove_image of an absent image is :ok", ctx do
          assert Engine.remove_image("ghcr.io/vagus/missing:1.0", arrange(:image_absent, ctx)) ==
                   :ok
        end

        test "remove_image of an image a container uses is :in_use", ctx do
          assert Engine.remove_image(
                   "ghcr.io/vagus/aarch64-addon-x:1.2.0",
                   arrange(:image_in_use, ctx)
                 ) ==
                   {:error, :in_use}
        end
      end

      describe "logs" do
        test "are plain text", ctx do
          assert Engine.logs("addon_local_x", arrange(:logs, ctx)) == {:ok, C.logs()}
        end

        test "of an absent container are :not_found", ctx do
          assert Engine.logs("ghost", arrange(:absent, ctx)) == {:error, :not_found}
        end

        @tag skip: @skip_follow
        test "follow delivers one chunk per ack, then :log_eof", ctx do
          assert follow_chunks("addon_local_x", arrange(:follow, ctx)) ==
                   ["line one\n", "line two\n"]
        end

        for timestamps <- [true, false] do
          @tag timestamps: timestamps
          @tag skip: @skip_follow
          test "timestamps: #{timestamps} on logs and follow_logs", ctx do
            opts = [timestamps: ctx.timestamps] ++ arrange({:stamped, ctx.timestamps}, ctx)
            {:ok, text} = Engine.logs("addon_local_x", opts)
            assert_stamps(text, ctx.timestamps)

            opts = [timestamps: ctx.timestamps] ++ arrange({:stamped, ctx.timestamps}, ctx)
            assert_stamps(follow("addon_local_x", opts), ctx.timestamps)
          end
        end

        @tag skip: @skip_follow
        test "follow of an absent container is just :log_eof", ctx do
          assert follow("ghost", arrange(:absent, ctx)) == ""
        end
      end

      describe "stats" do
        test "are the computed eight-key map", ctx do
          assert Engine.stats("addon_local_x", arrange(:stats, ctx)) == {:ok, C.stats()}
        end

        test "of an absent container are :not_found", ctx do
          assert Engine.stats("ghost", arrange(:absent, ctx)) == {:error, :not_found}
        end
      end
    end
  end

  @doc false
  def __exec_tests__ do
    quote do
      describe "exec" do
        test "exit 0 with its output", ctx do
          assert Engine.exec("addon_local_x", ["ha", "check"], arrange({:exec, 0, "ok\n"}, ctx)) ==
                   {:ok, %{exit_code: 0, output: "ok\n"}}
        end

        test "a non-zero exit is still {:ok, _} with its output", ctx do
          opts = arrange({:exec, 3, "bad config\n"}, ctx)

          assert Engine.exec("addon_local_x", ["ha", "check"], opts) ==
                   {:ok, %{exit_code: 3, output: "bad config\n"}}
        end

        test "capture: false reports the exit code with empty output", ctx do
          opts = [capture: false] ++ arrange(:exec_no_capture, ctx)

          assert Engine.exec("addon_local_x", ["ha", "check"], opts) ==
                   {:ok, %{exit_code: 3, output: ""}}
        end

        test "in an absent container is :not_found", ctx do
          assert Engine.exec("ghost", ["true"], arrange(:absent, ctx)) == {:error, :not_found}
        end

        test "past timeout_ms is :timeout", ctx do
          opts = [timeout_ms: 200] ++ arrange(:exec_timeout, ctx)
          assert Engine.exec("addon_local_x", ["sleep", "9"], opts) == {:error, :timeout}
        end
      end

      describe "healthcheck" do
        for health <- [:healthy, :unhealthy, :starting] do
          @tag health: health
          test "reports #{health}", ctx do
            opts = arrange({:health, ctx.health}, ctx)
            assert Engine.healthcheck("addon_local_x", opts) == {:ok, ctx.health}
          end
        end

        test "one configured but never run is :no_healthcheck", ctx do
          assert Engine.healthcheck("addon_local_x", arrange(:health_never_ran, ctx)) ==
                   {:error, :no_healthcheck}
        end

        test "a container without one is :no_healthcheck", ctx do
          assert Engine.healthcheck("addon_local_y", arrange(:inspect_exited, ctx)) ==
                   {:error, :no_healthcheck}
        end

        test "an absent container is :not_found", ctx do
          assert Engine.healthcheck("ghost", arrange(:absent, ctx)) == {:error, :not_found}
        end
      end

      describe "ensure_network" do
        for scenario <- [:network_exists, :network_created, :network_race] do
          @tag scenario: scenario
          test "is :ok when #{scenario}", ctx do
            assert Engine.ensure_network(C.hassio(), arrange(ctx.scenario, ctx)) == :ok
          end
        end
      end
    end
  end

  @doc false
  def __failure_tests__ do
    quote do
      describe "an engine failing every call" do
        test "answers {:failed, verb, _} for every verb", ctx do
          opts = arrange(:engine_error, ctx)

          results = [
            ready: Engine.ready(opts),
            image_present?: Engine.image_present?("ghcr.io/vagus/x:1", opts),
            remove_image: Engine.remove_image("ghcr.io/vagus/x:1", opts),
            create: Engine.create(C.spec(), opts),
            start: Engine.start("addon_local_x", opts),
            stop: Engine.stop("addon_local_x", opts),
            restart: Engine.restart("addon_local_x", opts),
            remove: Engine.remove("addon_local_x", opts),
            inspect: Engine.inspect("addon_local_x", opts),
            list: Engine.list(opts),
            logs: Engine.logs("addon_local_x", opts),
            stats: Engine.stats("addon_local_x", opts),
            exec: Engine.exec("addon_local_x", ["true"], opts),
            healthcheck: Engine.healthcheck("addon_local_x", opts),
            ensure_network: Engine.ensure_network(C.hassio(), opts)
          ]

          assert Keyword.keys(results) == C.failing_verbs()

          for {verb, result} <- results do
            assert {:error, {:failed, ^verb, _detail}} = result
          end

          pull = Engine.pull("ghcr.io/vagus/x:1", opts)
          stop_all = Engine.stop_all(["addon_local_x"], 1, opts)

          assert {:error, {:pull_failed, _}} = pull
          assert {:ok, [], [{"addon_local_x", {:failed, :stop, _}}]} = stop_all

          case Engine.follow_logs("addon_local_x", self(), opts) do
            {:error, error} ->
              assert {:failed, :follow_logs, _} = error

            {:ok, _pid} ->
              assert_receive :log_eof, 2_000
              refute_received {:log_chunk, _}
          end
        end
      end
    end
  end
end

defmodule Vagus.Test.EngineContract.Checked do
  @moduledoc false

  @behaviour Vagus.Runtime.Engine

  import Kernel, except: [inspect: 2]

  # Delegates to `opts[:checked_engine]` and checks the result.
  for {fun, arity} <- Vagus.Runtime.Engine.behaviour_info(:callbacks) do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl true
    def unquote(fun)(unquote_splicing(args)) do
      engine = Keyword.fetch!(List.last([unquote_splicing(args)]), :checked_engine)

      Vagus.Test.EngineContract.check!(
        unquote(fun),
        apply(engine, unquote(fun), [unquote_splicing(args)])
      )
    end
  end
end
