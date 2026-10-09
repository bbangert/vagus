defmodule Vagus.App.OrchestratorTest do
  # Every unit is injected and reports to the test process, so nothing here
  # starts an app, touches the engine or reaches Core.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Vagus.AppFixtures, only: [app_config: 2]

  alias Vagus.App.{CoreUnit, Orchestrator}

  @moduletag :capture_log

  defp app(slug, startup, attrs \\ []) do
    {boot, attrs} = Keyword.pop(attrs, :boot, "auto")
    config = app_config(slug, %{"startup" => startup, "boot" => boot})

    Map.merge(
      %{state: :started, boot: nil, config: config, running: false, native: false},
      Map.new(attrs)
    )
  end

  defp gate(test_pid, name), do: fn -> send(test_pid, {:gate, name}) && :ok end

  defp units(test_pid, apps, overrides) do
    report = fn
      what, %{config: %{slug: slug}} -> send(test_pid, {what, slug}) && :ok
      what, slug -> send(test_pid, {what, slug}) && :ok
    end

    Map.merge(
      %{
        list: fn -> Agent.get(apps, & &1) end,
        install_default: fn _slug -> :present end,
        want_started: fn slug ->
          Agent.update(
            apps,
            &Enum.map(&1, fn a ->
              if a.config.slug == slug, do: %{a | state: :started}, else: a
            end)
          )
        end,
        native?: & &1.native,
        running?: & &1.running,
        start: fn slug ->
          Agent.update(
            apps,
            &Enum.map(&1, fn a -> if a.config.slug == slug, do: %{a | running: true}, else: a end)
          )

          report.(:start, slug)
        end,
        demote: &report.(:demote, &1),
        stop: fn slug ->
          Agent.update(
            apps,
            &Enum.map(&1, fn a -> if a.config.slug == slug, do: %{a | running: false}, else: a end)
          )

          report.(:stop, slug)
        end,
        core_start: fn _deadline -> send(test_pid, :core_start) && :ok end,
        core_stop: fn -> send(test_pid, :core_stop) && :ok end,
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

  defp blocking(test_pid, tag) do
    fn ->
      send(test_pid, {tag, self()})

      receive do
      end
    end
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
             {:start, "broker"},
             {:report, :native, [{"broker", :ready}]},
             {:gate, :engine},
             {:gate, :network},
             {:gate, :api},
             {:start, "init"},
             {:report, :initialize, [{"init", :ready}]},
             {:start, "sys"},
             {:report, :system, [{"sys", :ready}]},
             {:start, "svc"},
             {:report, :services, [{"svc", :ready}, {"broker", :ready}]},
             :core_start,
             {:report, :core, [{"core", :ready}]},
             {:start, "app"},
             {:report, :application, [{"app", :ready}]},
             :complete
           ]

    assert %{phase: :up, task: nil} = await_boot(name)
  end

  for {label, attrs, unit, outcome} <- [
        {"started, auto, not running starts", [], {:start, "a"}, :ready},
        {"started, manual, not running is demoted", [boot: "manual"], {:demote, "a"}, :ready},
        {"started, manual_only is demoted", [boot: "manual_only"], {:demote, "a"}, :ready},
        {"started, manual, running is left alone", [boot: "manual", running: true], nil, :ready},
        {"started, auto, running is left alone", [running: true], nil, :ready},
        {"started with a manual override is demoted", [boot: "auto", boot_override: "manual"],
         {:demote, "a"}, :ready},
        {"stopped is left alone", [state: :stopped], nil, :ready}
      ] do
    test "boot rule: #{label}" do
      attrs = unquote(attrs)
      {override, attrs} = Keyword.pop(attrs, :boot_override)
      entry = app("a", "application", attrs) |> Map.put(:boot, override)
      start_orchestrator([entry])

      messages = collect_until(:complete)
      assert {:report, :application, [{"a", unquote(outcome)}]} in messages
      acted = for {what, "a"} = message <- messages, what in [:start, :demote], do: message
      assert acted == List.wrap(unquote(Macro.escape(unit)))
    end
  end

  test "an app whose start fails is reported failed and boot carries on" do
    start_orchestrator([app("a", "application")], %{start: fn _slug -> {:error, :no_image} end})

    messages = collect_until(:complete)
    assert {:report, :application, [{"a", :failed}]} in messages
  end

  test "a once app is started but not awaited, and a straggler is reported pending" do
    test_pid = self()

    start = fn
      "once" -> blocking(test_pid, :once_started).()
      "slow" -> blocking(test_pid, :slow_started).()
    end

    start_orchestrator([app("once", "once"), app("slow", "services")], %{start: start},
      stage_timeout: 50
    )

    messages = collect_until(:complete)
    assert {:report, :services, [{"slow", :pending}]} in messages
    assert {:report, :application, []} in messages
    assert_receive {:once_started, _pid}
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
        assert {:start, "a"} in messages
      end)

    assert log =~ "gate api failing after 2 tries"
  end

  test "a fresh default app is recorded wanted and started before the engine gate" do
    test_pid = self()
    broker = app("core_mqtt", "services", native: true, state: :stopped)

    install = fn slug -> send(test_pid, {:install, slug}) && :installed end
    start_orchestrator([broker], %{install_default: install}, default_native_app: "core_mqtt")

    messages = collect_until({:gate, :engine})
    assert [{:install, "core_mqtt"}, {:gate, :tree}, {:start, "core_mqtt"} | _] = messages
  end

  test "an installed default app the user stopped stays stopped" do
    broker = app("core_mqtt", "services", native: true, state: :stopped)
    start_orchestrator([broker], %{}, default_native_app: "core_mqtt")

    messages = collect_until(:complete)
    assert {:report, :native, [{"core_mqtt", :ready}]} in messages
    refute {:start, "core_mqtt"} in messages
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

  test "shutdown pre-empts a boot in flight, then stops apps, Core and earlier stages in order" do
    test_pid = self()

    gates =
      Map.new([:tree, :engine, :network], &{&1, gate(test_pid, &1)})
      |> Map.put(:api, blocking(test_pid, :api))

    apps = [
      app("app", "application"),
      app("once", "once"),
      app("svc", "services"),
      app("idle", "application", state: :stopped),
      app("broker", "services", native: true)
    ]

    name = start_orchestrator(apps, %{gates: gates}, gate_timeout: 60_000)
    assert_receive {:api, gate_pid}
    gate_ref = Process.monitor(gate_pid)

    assert Orchestrator.shutdown(name) == {{3, 3}, :ok}
    assert_received {:DOWN, ^gate_ref, :process, ^gate_pid, _reason}

    messages = collect_until(:core_stop) ++ collect_until({:stop, "svc"})
    assert for({:start, slug} <- messages, do: slug) == ["broker"]
    stops = Enum.filter(messages, &(match?({:stop, _}, &1) or &1 == :core_stop))
    assert [first, second, :core_stop, {:stop, "svc"}] = stops
    assert Enum.sort([first, second]) == [{:stop, "app"}, {:stop, "once"}]
    refute_received {:stop, "broker"}
    refute_received {:stop, "idle"}
    refute_received :complete
    assert %{phase: :stopping} = :sys.get_state(name)
  end

  test "a failed or hung app stop is counted, and does not hold the rest back" do
    test_pid = self()

    stop = fn
      "bad" -> {:error, :gone}
      "hung" -> blocking(test_pid, :hung).()
      slug -> send(test_pid, {:stop, slug}) && :ok
    end

    apps = [app("bad", "application"), app("hung", "application"), app("good", "application")]
    name = start_orchestrator(apps, %{stop: stop}, boot: false, app_stop_timeout: 50)

    assert Orchestrator.shutdown(name) == {{1, 3}, :ok}
    assert_received {:stop, "good"}
    assert_received :core_stop
  end

  test "resume boots again after a shutdown" do
    name = start_orchestrator([app("a", "application")])
    collect_until(:complete)
    await_boot(name)

    assert {{1, 1}, :ok} = Orchestrator.shutdown(name)
    Orchestrator.resume(name)

    assert {:start, "a"} in collect_until(:complete)
    assert %{phase: :up} = await_boot(name)
  end

  test "an app reported up is ignored while booting" do
    test_pid = self()
    gates = Map.new([:engine, :network, :api], &{&1, gate(test_pid, &1)})
    gates = Map.put(gates, :tree, blocking(test_pid, :tree))

    list = fn ->
      send(test_pid, :listed)
      [app("late", "application")]
    end

    name = start_orchestrator([], %{gates: gates, list: list}, gate_timeout: 60_000)
    assert_receive {:tree, _pid}
    flush(:listed)

    Orchestrator.up("late", name)
    assert %{phase: :booting} = :sys.get_state(name)
    refute_received :listed
  end

  test "an app reported up once boot is over is given its boot rule" do
    name = start_orchestrator([app("late", "application")], %{running?: fn _entry -> false end})
    assert {:start, "late"} in collect_until(:complete)
    assert %{phase: :up} = await_boot(name)

    Orchestrator.up("late", name)
    assert_receive {:start, "late"}
  end

  defp flush(message) do
    receive do
      ^message -> flush(message)
    after
      0 -> :ok
    end
  end
end
