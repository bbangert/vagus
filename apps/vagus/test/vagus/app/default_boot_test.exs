defmodule Vagus.App.DefaultBootTest do
  # The real units on host: no engine, no Core. `async: false` so no other
  # test's apps are booted by it.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Vagus.App.Orchestrator
  alias Vagus.Core.EventPusher

  @moduletag :capture_log

  @complete %{
    "event" => "supervisor_update",
    "update_key" => "supervisor",
    "data" => %{"startup" => "complete"}
  }

  test "boots through the default units to up, pushing startup complete" do
    Vagus.AppFixtures.listening_api_port()
    name = :"orchestrator_#{System.unique_integer([:positive])}"

    # The boot task logs from init/handle_continue onward, so capture must
    # start before the Orchestrator does or early lines escape it.
    {{pid, ref}, log} =
      with_log(fn ->
        pid =
          start_supervised!({
            Orchestrator,
            # The primary check reads the network backend, a Mox stub that
            # another test's private mode can hide from this boot's tasks.
            name: name,
            boot: true,
            gate_tries: 1,
            gate_interval: 0,
            tree_interval: 0,
            gate_timeout: 2_000,
            stage_timeout: 2_000,
            primary_timeout: 0
          })

        ref = Process.monitor(pid)

        with %{task: %Task{pid: task_pid}} <- :sys.get_state(name) do
          task_ref = Process.monitor(task_pid)
          assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _reason}, 10_000
        end

        {pid, ref}
      end)

    refute_received {:DOWN, ^ref, :process, ^pid, _reason}
    assert log =~ "gate tree passed"
    assert log =~ "gate api passed"
    assert %{phase: :up, task: nil} = :sys.get_state(name)
    assert @complete in :queue.to_list(:sys.get_state(EventPusher).queue)
  end

  # The native stage, ahead of every gate an offline board can fail.
  @tag :tmp_dir
  test "the native stage installs the admin panel wanted started and starts its subtree", %{
    tmp_dir: tmp
  } do
    Vagus.AppFixtures.listening_api_port()
    # Its start makes its data dir, which its backups then hold.
    Application.put_env(:vagus, :addon_data_root, tmp)
    name = :"orchestrator_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Application.delete_env(:vagus, :addon_data_root)
      Vagus.AppFixtures.forget_app("vagus")
      Vagus.Addon.Backend.Native.stop("addon_vagus")
    end)

    with_log(fn ->
      start_supervised!({
        Orchestrator,
        name: name,
        boot: true,
        default_apps: ["vagus"],
        gate_tries: 1,
        gate_interval: 0,
        tree_interval: 0,
        gate_timeout: 2_000,
        stage_timeout: 2_000,
        primary_timeout: 0
      })

      with %{task: %Task{pid: task_pid}} <- :sys.get_state(name) do
        task_ref = Process.monitor(task_pid)
        assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _reason}, 10_000
      end
    end)

    assert {:ok, %{wanted: :started, ingress_panel: true, state: :started}} =
             Vagus.App.info("vagus")

    assert Vagus.Addon.Backend.Native.running?("addon_vagus")
    assert File.dir?(Path.join([tmp, "addons", "data", "vagus"]))
  end

  # A board converted from the stock flavor: the panel stays installed though
  # the agent flavor's default apps lack it.
  @tag :tmp_dir
  test "an installed panel on the agent flavor still starts natively", %{tmp_dir: tmp} do
    Vagus.AppFixtures.listening_api_port()
    Application.put_env(:vagus, :addon_data_root, tmp)
    Application.put_env(:vagus, :native_addon_slugs, agent_flavor()[:native_addon_slugs])
    name = :"orchestrator_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Application.delete_env(:vagus, :addon_data_root)
      Application.delete_env(:vagus, :native_addon_slugs)
      Vagus.AppFixtures.forget_app("vagus")
      Vagus.Addon.Backend.Native.stop("addon_vagus")
    end)

    Vagus.AppFixtures.install_app(Vagus.AppFixtures.admin_panel_config(),
      state: :started,
      process: false
    )

    with_log(fn ->
      start_supervised!({
        Orchestrator,
        name: name,
        boot: true,
        default_apps: [],
        gate_tries: 1,
        gate_interval: 0,
        tree_interval: 0,
        gate_timeout: 2_000,
        stage_timeout: 2_000,
        primary_timeout: 0
      })

      with %{task: %Task{pid: task_pid}} <- :sys.get_state(name) do
        task_ref = Process.monitor(task_pid)
        assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _reason}, 10_000
      end
    end)

    assert {:ok, %{wanted: :started, state: :started}} = Vagus.App.info("vagus")
    assert Vagus.Addon.Backend.Native.running?("addon_vagus")
  end

  defp agent_flavor do
    prev = System.get_env("VAGUS_FLAVOR")
    System.put_env("VAGUS_FLAVOR", "agent-dev-board")

    try do
      Config.Reader.read!(Path.expand("../../../../../config/flavor.exs", __DIR__))[:vagus]
    after
      if prev, do: System.put_env("VAGUS_FLAVOR", prev), else: System.delete_env("VAGUS_FLAVOR")
    end
  end
end
