defmodule Vagus.App.OrchestratorAnnouncementsTest do
  # Real app processes announce themselves to the registered Orchestrator, so
  # the test's takes that name from the app tree's, and the steps stub is
  # global: neither may be shared with an async test's app processes.
  use ExUnit.Case, async: false

  import Vagus.AppFixtures

  alias Vagus.App.Orchestrator

  @moduletag :capture_log

  @started %{container_id: "c1", ip: "172.30.33.9"}

  setup do
    stub_app_steps()
    app_deadlines(%{})
    :ok = Supervisor.terminate_child(Vagus.App.Supervisor, Orchestrator)
    on_exit(fn -> Supervisor.restart_child(Vagus.App.Supervisor, Orchestrator) end)
  end

  defp slug, do: "announced_#{System.unique_integer([:positive])}"

  defp app(slug, startup) do
    %{state: :started, config: app_config(slug, %{"startup" => startup}), native: false}
  end

  defp gate(test_pid, name), do: fn -> send(test_pid, {:gate, name}) && :ok end

  # Blocks until the test sends `:release`.
  defp held(test_pid, tag) do
    fn ->
      send(test_pid, {tag, self()})

      receive do
        :release -> :ok
      end
    end
  end

  # Every unit but `ensure` and `boot_start` is a stub; those two reach the
  # real app processes, whose steps come to the test. Each app is wanted
  # started, so a boot rule that applies shows as one `:start` step.
  defp start_with_processes(apps, overrides \\ %{}) do
    test_pid = self()
    Enum.each(apps, &install_app(&1.config, state: :started, process: false))

    units =
      Map.merge(
        %{
          import: fn -> :ok end,
          sweep: fn -> :ok end,
          slugs: fn -> Enum.map(apps, & &1.config.slug) end,
          list: fn -> apps end,
          install_default: fn _slug -> :present end,
          native?: & &1.native,
          ensure: &Vagus.App.Units.ensure/1,
          boot_start: fn slug, running? ->
            send(test_pid, {:boot_start, slug})
            Vagus.App.boot_start(slug, running?)
          end,
          running: fn -> {:ok, MapSet.new()} end,
          inspect: fn _slug -> false end,
          halt: fn _slug -> :ok end,
          in_flight?: fn -> false end,
          core_start: fn _deadline -> :ok end,
          core_stop: fn _deadline -> :ok end,
          gates: Map.new([:tree, :engine, :network, :api], &{&1, gate(test_pid, &1)}),
          report: fn stage, outcomes -> send(test_pid, {:report, stage, outcomes}) end,
          push_complete: fn -> send(test_pid, :complete) end
        },
        overrides
      )

    opts = [name: Orchestrator, boot: true, gate_interval: 0, gate_tries: 3]
    start_supervised!({Orchestrator, opts ++ [stage_timeout: 1_000, units: units]})
  end

  # Answers every `:start` step with `outcome` until `last` (or `{last, _}`)
  # arrives, or with `:quiet` until nothing arrives for 200 ms; what was seen
  # is returned, each step as `{:start, slug}`.
  defp serve(last, outcome, acc \\ []) do
    receive do
      {:step, :start, %{slug: slug}, task} ->
        send(task, {:outcome, outcome})
        serve(last, outcome, [{:start, slug} | acc])

      message when message == last or (is_tuple(message) and elem(message, 0) == last) ->
        Enum.reverse([message | acc])

      message ->
        serve(last, outcome, [message | acc])
    after
      if(last == :quiet, do: 200, else: 2_000) ->
        if last == :quiet, do: Enum.reverse(acc), else: flunk("never saw #{inspect(last)}")
    end
  end

  # The boot task's reply reaches the orchestrator before the task exits, so
  # once the task is down the orchestrator has seen the end of the boot.
  defp await_boot do
    with %{task: %Task{pid: pid}} <- :sys.get_state(Orchestrator) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end

    :sys.get_state(Orchestrator)
  end

  defp successor(slug) do
    # Not a kill: the supervisor's restart budget is shared with the suite.
    [{pid, _}] = Registry.lookup(Vagus.App.Directory, {:slug, slug})
    :ok = Vagus.App.Instances.stop(slug)
    assert {:ok, successor} = Vagus.App.Instances.ensure(slug)
    assert successor != pid
  end

  defp count(messages, message), do: Enum.count(messages, &(&1 == message))

  test "each started at boot is given its boot rule once, by its stage, and the replay does nothing" do
    [early, once] = [slug(), slug()]
    hold = held(self(), :complete)
    start_with_processes([app(early, "initialize"), app(once, "once")], %{push_complete: hold})

    # The `once` app completes before boot ends, so its replay finds it
    # stopped and wanted started: only the process's one rule keeps that
    # replay from starting it again.
    messages = serve(:complete, {:ok, @started})
    {:complete, pusher} = List.last(messages)
    messages = messages ++ serve(:quiet, {:ok, @started})
    [{pid, _}] = Registry.lookup(Vagus.App.Directory, {:slug, once})
    send(pid, {:docker_event, %{id: "c1", action: "die", exit_code: 0}})
    _ = :sys.get_state(pid)
    send(pusher, :release)

    assert %{phase: :up} = await_boot()
    messages = messages ++ serve(:quiet, {:ok, @started})

    # Each process announced itself as the boot began, so each is replayed.
    for slug <- [early, once] do
      assert count(messages, {:boot_start, slug}) == 2
      assert count(messages, {:start, slug}) == 1
    end
  end

  test "a successor started after its stage ran is given its boot rule once boot ends" do
    slug = slug()
    hold = held(self(), :core)
    start_with_processes([app(slug, "initialize")], %{core_start: fn _ -> hold.() end})
    messages = serve(:core, {:ok, @started})
    assert count(messages, {:start, slug}) == 1
    {:core, core} = List.last(messages)

    successor(slug)
    assert %{phase: :booting} = :sys.get_state(Orchestrator)
    send(core, :release)

    messages = serve(:complete, {:ok, @started})
    assert %{phase: :up} = await_boot()
    messages = messages ++ serve(:quiet, {:ok, @started})
    assert count(messages, {:start, slug}) == 1
  end

  test "a successor started before its stage, whose start then fails, is not given it again" do
    slug = slug()
    gates = Map.new([:tree, :engine, :network], &{&1, gate(self(), &1)})

    start_with_processes([app(slug, "initialize")], %{
      gates: Map.put(gates, :api, held(self(), :api))
    })

    assert_receive {:api, api}

    successor(slug)
    assert %{phase: :booting} = :sys.get_state(Orchestrator)
    send(api, :release)

    messages = serve(:complete, {:error, :boom})
    assert {:report, :initialize, [{slug, :failed}]} in messages
    assert %{phase: :up} = await_boot()
    messages = messages ++ serve(:quiet, {:error, :boom})
    assert count(messages, {:boot_start, slug}) == 2
    assert count(messages, {:start, slug}) == 1
  end

  test "a successor started once boot is over is given its boot rule" do
    slug = slug()
    start_with_processes([app(slug, "application")])
    assert {:start, slug} in serve(:complete, {:ok, @started})
    assert %{phase: :up} = await_boot()
    assert [] == serve(:quiet, {:ok, @started}) |> Enum.filter(&match?({:start, _}, &1))

    successor(slug)
    assert count(serve(:quiet, {:ok, @started}), {:start, slug}) == 1
  end
end
