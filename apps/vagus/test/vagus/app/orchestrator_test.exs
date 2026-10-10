defmodule Vagus.App.OrchestratorTest do
  # Every unit is injected and reports to the test process, so nothing here
  # starts an app, touches the engine or reaches Core.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Vagus.AppFixtures, only: [app_config: 2]

  alias Vagus.App.{CoreUnit, Orchestrator}

  @moduletag :capture_log

  defp app(slug, startup, attrs \\ []) do
    config = app_config(slug, %{"startup" => startup})
    Map.merge(%{state: :stopped, config: config, native: false}, Map.new(attrs))
  end

  defp gate(test_pid, name), do: fn -> send(test_pid, {:gate, name}) && :ok end

  defp units(test_pid, apps, overrides) do
    report = fn what, slug -> send(test_pid, {what, slug}) && :ok end

    Map.merge(
      %{
        import: fn -> :ok end,
        sweep: fn -> :ok end,
        slugs: fn -> Agent.get(apps, &Enum.map(&1, fn a -> a.config.slug end)) end,
        list: fn -> Agent.get(apps, & &1) end,
        install_default: fn _slug -> :present end,
        native?: & &1.native,
        boot_start: fn slug, _running? -> report.(:boot_start, slug) end,
        running: fn -> {:ok, MapSet.new()} end,
        inspect: fn _slug -> false end,
        halt: &report.(:halt, &1),
        ensure: fn _slug -> :ok end,
        in_flight?: fn -> false end,
        core_start: fn _deadline -> send(test_pid, :core_start) && :ok end,
        core_stop: fn _deadline -> send(test_pid, :core_stop) && :ok end,
        gates: Map.new([:tree, :engine, :network, :api], &{&1, gate(test_pid, &1)}),
        report: fn stage, outcomes -> send(test_pid, {:report, stage, outcomes}) end,
        push_complete: fn -> send(test_pid, :complete) end
      },
      overrides
    )
  end

  defp start_orchestrator(apps, overrides \\ %{}, opts \\ []) do
    {:ok, store} = Agent.start_link(fn -> apps end)
    name = :"orchestrator_#{System.unique_integer([:positive])}"

    defaults = [
      name: name,
      boot: true,
      gate_interval: 0,
      gate_tries: 3,
      stage_timeout: 1_000,
      units: units(self(), store, overrides)
    ]

    start_supervised!({Orchestrator, Keyword.merge(defaults, opts)})
    name
  end

  defp collect_until(last, acc \\ []) do
    receive do
      ^last -> Enum.reverse([last | acc])
      message -> collect_until(last, [message | acc])
    after
      1_000 -> flunk("never saw #{inspect(last)}; got #{inspect(Enum.reverse(acc))}")
    end
  end

  # The boot task's reply reaches the orchestrator before the task exits, so
  # once the task is down the orchestrator has seen the end of the boot.
  defp await_boot(name) do
    with %{task: %Task{pid: pid}} <- :sys.get_state(name) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end

    :sys.get_state(name)
  end

  # Units run unlinked, so a blocked one is released when the test ends.
  defp blocking(test_pid, tag) do
    fn ->
      send(test_pid, {tag, self()})
      ref = Process.monitor(test_pid)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      end
    end
  end

  # Blocks until the test sends `:release`, then answers `result`.
  defp held(test_pid, tag, result \\ :ok) do
    fn ->
      send(test_pid, {tag, self()})

      receive do
        :release -> send(test_pid, {tag, :returned}) && result
      end
    end
  end

  defp await_phase(name, phase, tries \\ 1_000) do
    case :sys.get_state(name) do
      %{phase: ^phase} = state -> state
      _other when tries > 0 -> await_phase(name, phase, tries - 1)
      other -> flunk("never reached #{phase}: #{inspect(other)}")
    end
  end

  # Everything the test process received up to now, in order.
  defp drain do
    marker = make_ref()
    send(self(), marker)
    collect_until(marker) |> List.delete_at(-1)
  end

  test "boot runs gates and stages in order, natives before the engine, the push last" do
    apps = [
      app("app", "application"),
      app("svc", "services"),
      app("sys", "system"),
      app("init", "initialize"),
      app("broker", "services", native: true)
    ]

    name = start_orchestrator(apps)

    assert collect_until(:complete) == [
             {:gate, :tree},
             {:boot_start, "broker"},
             {:report, :native, [{"broker", :ready}]},
             {:gate, :engine},
             {:gate, :network},
             {:gate, :api},
             {:boot_start, "init"},
             {:report, :initialize, [{"init", :ready}]},
             {:boot_start, "sys"},
             {:report, :system, [{"sys", :ready}]},
             {:boot_start, "svc"},
             {:boot_start, "broker"},
             {:report, :services, [{"svc", :ready}, {"broker", :ready}]},
             :core_start,
             {:report, :core, [{"core", :ready}]},
             {:boot_start, "app"},
             {:report, :application, [{"app", :ready}]},
             :complete
           ]

    assert %{phase: :up, task: nil} = await_boot(name)
  end

  test "an app whose start fails is reported failed and boot carries on" do
    start_orchestrator([app("a", "application")], %{
      boot_start: fn _slug, _running? -> {:error, :no_image} end
    })

    messages = collect_until(:complete)
    assert {:report, :application, [{"a", :failed}]} in messages
  end

  test "a once app is started but not awaited, and a straggler is reported pending" do
    test_pid = self()

    start = fn
      "once", _running? -> blocking(test_pid, :once_started).()
      "slow", _running? -> blocking(test_pid, :slow_started).()
    end

    start_orchestrator([app("once", "once"), app("slow", "services")], %{boot_start: start},
      stage_timeout: 50
    )

    messages = collect_until(:complete)
    assert {:report, :services, [{"slow", :pending}]} in messages
    assert {:report, :application, []} in messages

    # The unwaited start may land on either side of the push.
    unless Enum.any?(messages, &match?({:once_started, _pid}, &1)),
      do: assert_receive({:once_started, _pid})
  end

  describe "whether a container runs" do
    defp report_running(test_pid),
      do: fn slug, running? -> send(test_pid, {:boot_start, slug, running?}) && :ok end

    test "is listed once after the engine gate, and each stage's apps are told theirs" do
      test_pid = self()

      running = fn ->
        send(test_pid, :listed)
        {:ok, MapSet.new(["app"])}
      end

      apps = [
        app("app", "application"),
        app("svc", "services"),
        app("broker", "services", native: true)
      ]

      start_orchestrator(apps, %{boot_start: report_running(test_pid), running: running})
      messages = collect_until(:complete)

      assert [:listed] == Enum.filter(messages, &(&1 == :listed))

      assert Enum.find_index(messages, &(&1 == :listed)) >
               Enum.find_index(messages, &(&1 == {:gate, :engine}))

      assert {:boot_start, "broker", :unknown} in messages
      assert {:boot_start, "app", true} in messages
      assert {:boot_start, "svc", false} in messages
    end

    test "a listing that fails tells every app :unknown" do
      running = fn -> {:error, :engine_down} end

      start_orchestrator([app("app", "application")], %{
        boot_start: report_running(self()),
        running: running
      })

      assert {:boot_start, "app", :unknown} in collect_until(:complete)
    end

    test "a process that restarted has its own container inspected before its boot rule" do
      test_pid = self()

      inspect = fn slug ->
        send(test_pid, {:inspected, slug})
        true
      end

      name =
        start_orchestrator([], %{boot_start: report_running(test_pid), inspect: inspect})

      assert %{phase: :up} = await_boot(name)
      Orchestrator.up("late", name)
      assert_receive {:inspected, "late"}
      assert_receive {:boot_start, "late", true}
    end
  end

  test "a gate that fails is retried until it passes" do
    test_pid = self()
    counter = :counters.new(1, [])

    engine = fn ->
      :counters.add(counter, 1, 1)
      send(test_pid, {:gate, :engine})
      if :counters.get(counter, 1) < 3, do: {:error, :down}, else: :ok
    end

    log =
      capture_log(fn ->
        start_orchestrator([], %{
          gates:
            Map.new([:tree, :network, :api], &{&1, gate(test_pid, &1)})
            |> Map.put(:engine, engine)
        })

        messages = collect_until(:complete)
        assert Enum.count(messages, &(&1 == {:gate, :engine})) == 3
        assert {:gate, :api} in messages
      end)

    assert log =~ "waiting on gate engine"
    assert log =~ "gate engine passed"
  end

  test "a gate that never passes is carried past after its tries, a hung one bounded by its timeout" do
    test_pid = self()

    api = fn ->
      send(test_pid, {:gate, :api})

      receive do
      end
    end

    gates = Map.new([:tree, :engine, :network], &{&1, gate(test_pid, &1)}) |> Map.put(:api, api)

    log =
      capture_log(fn ->
        start_orchestrator([app("a", "application")], %{gates: gates},
          gate_tries: 2,
          gate_timeout: 10
        )

        messages = collect_until(:complete)
        assert Enum.count(messages, &(&1 == {:gate, :api})) == 2
        assert {:boot_start, "a"} in messages
      end)

    assert log =~ "gate api failing after 2 tries"
  end

  test "a fresh default app is recorded wanted and started before the engine gate" do
    test_pid = self()
    broker = app("core_mqtt", "services", native: true, state: :stopped)

    install = fn slug -> send(test_pid, {:install, slug}) && :installed end
    start_orchestrator([broker], %{install_default: install}, default_native_app: "core_mqtt")

    messages = collect_until({:gate, :engine})
    assert [{:install, "core_mqtt"}, {:gate, :tree}, {:boot_start, "core_mqtt"} | _] = messages
  end

  test "an installed default app is not installed again, and boots by its own rule" do
    test_pid = self()
    broker = app("core_mqtt", "services", native: true)
    install = fn slug -> send(test_pid, {:install, slug}) && :present end
    start_orchestrator([broker], %{install_default: install}, default_native_app: "core_mqtt")

    messages = collect_until(:complete)
    assert {:install, "core_mqtt"} in messages
    assert {:report, :native, [{"core_mqtt", :ready}]} in messages
  end

  test "a default app that cannot be installed is logged and boot carries on" do
    log =
      capture_log(fn ->
        start_orchestrator([], %{install_default: fn _slug -> {:error, :no_builtin} end},
          default_native_app: "core_mqtt"
        )

        assert :complete in collect_until(:complete)
      end)

    assert log =~ "default app core_mqtt not installed"
  end

  test "an absent Core is ready, with a warning" do
    core_start = &CoreUnit.start(adopt: fn -> :absent end, deadline: &1)

    log =
      capture_log(fn ->
        start_orchestrator([], %{core_start: core_start})
        assert {:report, :core, [{"core", :ready}]} in collect_until(:complete)
      end)

    assert log =~ "no Core container"
  end

  test "shutdown waits out a stage unit in flight, then stops apps, Core and earlier stages" do
    test_pid = self()

    start = fn
      "svc", _running? -> held(test_pid, :svc).()
      slug, _running? -> send(test_pid, {:boot_start, slug}) && :ok
    end

    apps = [
      app("app", "application"),
      app("once", "once"),
      app("svc", "services"),
      app("idle", "application", state: :stopped),
      app("broker", "services", native: true, state: :started)
    ]

    name = start_orchestrator(apps, %{boot_start: start}, stage_timeout: 60_000)
    assert_receive {:svc, unit}
    %{task: %Task{pid: boot}} = :sys.get_state(name)
    boot_ref = Process.monitor(boot)

    shutdown = Task.async(fn -> Orchestrator.shutdown(name) end)
    await_phase(name, :cancelling)
    send(unit, :release)

    assert Task.await(shutdown) == {{4, 4}, :ok}
    assert_receive {:DOWN, ^boot_ref, :process, ^boot, :normal}
    messages = drain()

    assert [{:svc, :returned} | after_unit] =
             Enum.drop_while(messages, &(&1 != {:svc, :returned}))

    refute Enum.any?(after_unit, &match?({:boot_start, _}, &1))
    refute :core_start in messages
    refute :complete in messages

    refute Enum.any?(
             messages,
             &match?({:report, stage, _} when stage in [:core, :application], &1)
           )

    stops = Enum.filter(after_unit, &(match?({:halt, _}, &1) or &1 == :core_stop))
    assert [first, second, third, :core_stop, {:halt, "svc"}] = stops
    assert Enum.sort([first, second, third]) == [{:halt, "app"}, {:halt, "idle"}, {:halt, "once"}]
    assert %{phase: :stopping} = :sys.get_state(name)
  end

  test "shutdown ends a boot waiting out a gate interval at once" do
    test_pid = self()
    engine = fn -> send(test_pid, {:gate, :engine}) && {:error, :down} end

    gates =
      Map.new([:tree, :network, :api], &{&1, gate(test_pid, &1)}) |> Map.put(:engine, engine)

    name =
      start_orchestrator([app("a", "application")], %{gates: gates},
        gate_interval: 60_000,
        gate_tries: 2
      )

    assert_receive {:gate, :engine}
    %{task: %Task{pid: boot}} = :sys.get_state(name)
    boot_ref = Process.monitor(boot)

    shutdown = Task.async(fn -> Orchestrator.shutdown(name) end)
    assert Task.await(shutdown, 5_000) == {{1, 1}, :ok}
    assert_receive {:DOWN, ^boot_ref, :process, ^boot, :normal}

    messages = drain()
    assert {:halt, "a"} in messages
    refute {:gate, :network} in messages
    refute {:gate, :engine} in messages
  end

  test "a boot task crash stops the orchestrator, and its restart boots again" do
    counter = :counters.new(1, [])

    list = fn ->
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) == 1, do: raise("listing failed")
      [app("a", "application")]
    end

    name = start_orchestrator([], %{list: list})
    pid = Process.whereis(name)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:boot_crashed, {%RuntimeError{}, _stack}}},
                   1_000

    assert {:boot_start, "a"} in collect_until(:complete)
    assert %{phase: :up} = await_boot(name)
    assert Process.whereis(name) != pid
  end

  test "resume during a stop is remembered, and boots once the stop ends" do
    test_pid = self()

    name =
      start_orchestrator([app("a", "application")], %{
        halt: fn _slug -> held(test_pid, :halt).() end
      })

    collect_until(:complete)
    await_boot(name)

    shutdown = Task.async(fn -> Orchestrator.shutdown(name) end)
    assert_receive {:halt, unit}
    Orchestrator.resume(name)
    assert %{resume: true} = :sys.get_state(name)
    send(unit, :release)

    assert {{1, 1}, :ok} = Task.await(shutdown)
    assert {:gate, :tree} in collect_until(:complete)
    assert %{phase: :up} = await_boot(name)
  end

  test "Core stops by a deadline that leaves the earlier group its bound" do
    test_pid = self()

    core_stop = fn deadline ->
      send(test_pid, {:core_deadline, deadline})
      blocking(test_pid, :core_stopping).()
    end

    apps = [app("app", "application"), app("init", "initialize")]

    name =
      start_orchestrator(apps, %{core_stop: core_stop},
        boot: false,
        app_stop_timeout: 50,
        stop_margin: 0
      )

    shutdown = Task.async(fn -> Orchestrator.shutdown(name, 300) end)
    assert {{2, 2}, {:error, :timeout}} = Task.await(shutdown, 2_000)
    assert_received {:core_deadline, deadline}
    assert deadline in 1..250
    assert_received {:halt, "init"}
  end

  test "a listing that fails still stops Core" do
    name = start_orchestrator([], %{list: fn -> exit(:no_answer) end}, boot: false)

    log = capture_log(fn -> assert Orchestrator.shutdown(name) == {{0, 0}, :ok} end)
    assert_received :core_stop
    assert log =~ "could not list apps"
  end

  test "the stop outlives a crash of the orchestrator" do
    test_pid = self()

    name =
      start_orchestrator(
        [app("a", "application")],
        %{halt: fn _slug -> held(test_pid, :halt).() end},
        boot: false
      )

    {:ok, _caller} = Task.start(fn -> Orchestrator.shutdown(name) end)
    assert_receive {:halt, unit}
    pid = Process.whereis(name)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    send(unit, :release)
    assert_receive {:halt, :returned}
    assert_receive :core_stop
  end

  test "an orchestrator started mid-shutdown does not boot, and a resume boots it" do
    name = start_orchestrator([app("a", "application")], %{in_flight?: fn -> true end})
    assert %{phase: :stopping, task: nil} = :sys.get_state(name)
    refute_received {:gate, :tree}

    Orchestrator.resume(name)
    assert {:boot_start, "a"} in collect_until(:complete)
  end

  test "the tree gate retries on its own short interval" do
    test_pid = self()
    counter = :counters.new(1, [])

    tree = fn ->
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) == 1, do: {:error, :starting}, else: :ok
    end

    gates = Map.new([:engine, :network, :api], &{&1, gate(test_pid, &1)}) |> Map.put(:tree, tree)
    start_orchestrator([], %{gates: gates}, gate_interval: 60_000)
    assert_receive {:gate, :engine}, 5_000
  end

  test "a partial gates override keeps the default gates it leaves out" do
    test_pid = self()
    gates = Map.new([:engine, :network, :api], &{&1, gate(test_pid, &1)})

    log =
      capture_log(fn ->
        start_orchestrator([], %{gates: gates})
        assert {:gate, :engine} in collect_until(:complete)
      end)

    assert log =~ "gate tree passed"
  end

  test "apps are imported, then a process ensured per app, through the units" do
    test_pid = self()
    ensure = fn slug -> send(test_pid, {:ensure, slug}) && :ok end
    import = fn -> send(test_pid, :imported) end

    start_orchestrator(
      [app("a", "application"), app("b", "services")],
      %{ensure: ensure, import: import},
      boot: false
    )

    assert drain() == [:imported, {:ensure, "a"}, {:ensure, "b"}]
  end

  describe "core stage" do
    test "Core start gets the stage budget as its deadline" do
      test_pid = self()
      core_start = fn deadline -> send(test_pid, {:core_deadline, deadline}) && :ok end
      start_orchestrator([], %{core_start: core_start}, stage_timeout: 4_321)
      assert {:core_deadline, 4_321} in collect_until(:complete)
    end

    test "a failed Core start is reported failed and boot carries on" do
      start_orchestrator([app("a", "application")], %{core_start: fn _ -> {:error, :no_image} end})

      messages = collect_until(:complete)
      assert {:report, :core, [{"core", :failed}]} in messages
      assert {:boot_start, "a"} in messages
    end

    test "a hung Core start is carried past at the budget and left running" do
      test_pid = self()
      core_start = fn _deadline -> blocking(test_pid, :core_starting).() end

      start_orchestrator([app("a", "application")], %{core_start: core_start}, stage_timeout: 50)

      assert_receive {:core_starting, unit}
      messages = collect_until(:complete)
      assert {:report, :core, [{"core", :pending}]} in messages
      assert {:boot_start, "a"} in messages
      assert Process.alive?(unit)
    end
  end

  test "a failed or hung app stop is counted, and does not hold the rest back" do
    test_pid = self()

    stop = fn
      "bad" -> {:error, :gone}
      "hung" -> blocking(test_pid, :hung).()
      slug -> send(test_pid, {:halt, slug}) && :ok
    end

    apps = [app("bad", "application"), app("hung", "application"), app("good", "application")]
    name = start_orchestrator(apps, %{halt: stop}, boot: false, app_stop_timeout: 50)

    assert Orchestrator.shutdown(name) == {{1, 3}, :ok}
    assert_received {:halt, "good"}
    assert_received :core_stop
  end

  # The unit, not the orchestrator, keeps it to the first boot in the VM.
  test "stale backup staging is swept before any app process starts or anything boots" do
    test_pid = self()
    sweep = fn -> send(test_pid, :sweep) && :ok end
    ensure = fn slug -> send(test_pid, {:ensure, slug}) && :ok end
    install = fn slug -> send(test_pid, {:install, slug}) && :present end
    broker = app("core_mqtt", "services", native: true)
    overrides = %{sweep: sweep, ensure: ensure, install_default: install}

    start_orchestrator([broker, app("a", "initialize")], overrides,
      default_native_app: "core_mqtt"
    )

    assert [:sweep, {:ensure, "core_mqtt"}, {:ensure, "a"}, {:install, "core_mqtt"} | rest] =
             collect_until(:complete)

    refute :sweep in rest
  end

  test "with boot off nothing is swept" do
    test_pid = self()
    start_orchestrator([], %{sweep: fn -> send(test_pid, :sweep) && :ok end}, boot: false)
    refute_received :sweep
  end

  test "resume boots again after a shutdown" do
    name = start_orchestrator([app("a", "application")])
    collect_until(:complete)
    await_boot(name)

    assert {{1, 1}, :ok} = Orchestrator.shutdown(name)
    Orchestrator.resume(name)

    assert {:boot_start, "a"} in collect_until(:complete)
    assert %{phase: :up} = await_boot(name)
  end

  test "an app reported up is ignored while booting" do
    test_pid = self()
    gates = Map.new([:engine, :network, :api], &{&1, gate(test_pid, &1)})
    gates = Map.put(gates, :tree, blocking(test_pid, :tree))

    name = start_orchestrator([], %{gates: gates}, gate_timeout: 60_000)
    assert_receive {:tree, _pid}

    Orchestrator.up("late", name)
    assert %{phase: :booting} = :sys.get_state(name)
    refute_received {:boot_start, "late"}
  end

  test "an app reported up once boot is over is given its boot rule" do
    name = start_orchestrator([app("late", "application")])
    assert {:boot_start, "late"} in collect_until(:complete)
    assert %{phase: :up} = await_boot(name)

    Orchestrator.up("late", name)
    assert_receive {:boot_start, "late"}
  end

  test "with boot off, an app reported up is given no boot rule" do
    name = start_orchestrator([], %{}, boot: false)
    assert %{phase: :up} = :sys.get_state(name)

    Orchestrator.up("late", name)
    _ = :sys.get_state(name)
    refute_receive {:boot_start, "late"}, 100
  end
end
