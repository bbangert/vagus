defmodule Vagus.App.UnitsTest do
  # `async: false`: installed apps are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Vagus.AppFixtures, only: [app_config: 2, install_app: 1, listening_api_port: 0]

  alias Vagus.App.{Gates, Units}
  alias Vagus.Core.EventPusher

  @arities %{
    import: 0,
    slugs: 0,
    list: 0,
    ensure: 1,
    in_flight?: 0,
    install_default: 1,
    native?: 1,
    boot_start: 2,
    running: 0,
    inspect: 1,
    halt: 1,
    core_start: 1,
    core_stop: 1,
    report: 2,
    push_complete: 0
  }

  test "every unit is a function of the arity the orchestrator calls it with" do
    units = Units.all()
    assert Map.keys(units) |> Enum.sort() == Enum.sort([:gates | Map.keys(@arities)])

    for {key, arity} <- @arities do
      assert is_function(Map.fetch!(units, key), arity), "#{key}/#{arity}"
    end

    assert Map.keys(units.gates) |> Enum.sort() == [:api, :engine, :network, :tree]
    assert Enum.all?(Map.values(units.gates), &is_function(&1, 0))
  end

  describe "sweep/0" do
    setup do
      base = Path.join(System.tmp_dir!(), "vagus-units-#{System.unique_integer([:positive])}")
      prev = Application.fetch_env(:vagus, :addon_data_root)
      Application.put_env(:vagus, :addon_data_root, Path.join(base, "data"))
      :persistent_term.erase({Units, :swept})

      on_exit(fn ->
        :persistent_term.erase({Units, :swept})

        case prev do
          {:ok, root} -> Application.put_env(:vagus, :addon_data_root, root)
          :error -> Application.delete_env(:vagus, :addon_data_root)
        end

        File.rm_rf(base)
      end)

      %{staging: Path.join(base, "staging")}
    end

    test "clears the backup staging beside the configured data root", %{staging: staging} do
      leftover = Path.join(staging, "backup-deadbeef-1")
      File.mkdir_p!(leftover)

      assert Units.sweep() == :ok
      refute File.exists?(leftover)
    end

    test "sweeps only once per VM, so a later boot leaves live staging alone", %{
      staging: staging
    } do
      assert Units.sweep() == :ok
      live = Path.join(staging, "backup-live-1")
      File.mkdir_p!(live)

      assert Units.sweep() == :ok
      assert File.dir?(live)
    end
  end

  test "the tree gate passes once the application is started" do
    assert Gates.tree() == :ok
  end

  test "the api gate passes while the API's port accepts, and fails once it does not" do
    socket = listening_api_port()
    assert Gates.api() == :ok

    :ok = :gen_tcp.close(socket)
    assert Gates.api() == {:error, :not_accepting}
  end

  test "an installed default app is present, and is not installed again" do
    slug = "units_#{System.unique_integer([:positive])}"
    install_app(app_config(slug, %{}))
    assert Units.install_default(slug) == :present
  end

  test "no default app is installed while a failed import left no apps directory" do
    dir = Application.fetch_env!(:vagus, :app_files_dir)
    absent = Path.join(System.tmp_dir!(), "units_apps_#{System.unique_integer([:positive])}")
    Application.put_env(:vagus, :app_files_dir, absent)
    on_exit(fn -> Application.put_env(:vagus, :app_files_dir, dir) end)

    assert Units.install_default("units_default") == {:error, :not_imported}
    refute File.exists?(absent)
  end

  test "an import that raises is logged, not raised" do
    prev = Application.fetch_env!(:vagus, :legacy_addons_json)
    dir = Application.fetch_env!(:vagus, :app_files_dir)
    blocker = Path.join(System.tmp_dir!(), "units_import_#{System.unique_integer([:positive])}")
    File.write!(blocker, "")
    Application.put_env(:vagus, :app_files_dir, Path.join(blocker, "apps"))

    on_exit(fn ->
      Application.put_env(:vagus, :app_files_dir, dir)
      Application.put_env(:vagus, :legacy_addons_json, prev)
      File.rm(blocker)
    end)

    assert capture_log(fn -> assert Units.import() == :ok end) =~ "Apps not imported"
  end

  test "native? holds only for an allowlisted native app" do
    native = %{config: %{app_config("core_mqtt", %{}) | backend: :native}}
    assert Units.native?(native)
    refute Units.native?(%{config: %{app_config("other", %{}) | backend: :native}})
    refute Units.native?(%{config: app_config("core_mqtt", %{})})
  end

  test "push_complete pushes Core the startup complete event" do
    assert Units.push_complete(self()) == :ok
    assert_received {:"$gen_cast", {:push, data}}

    assert data == %{
             "event" => "supervisor_update",
             "update_key" => "supervisor",
             "data" => %{"startup" => "complete"}
           }

    state = %{
      ready: true,
      connection_pid: self(),
      conn_mod: EventPusher.Connection,
      next_id: 7
    }

    EventPusher.handle_cast({:push, data}, state)
    assert_received {:"$gen_cast", {:request, {:text, json}}}

    assert Jason.decode!(json) == %{
             "id" => 7,
             "type" => "supervisor/event",
             "data" => data
           }
  end

  describe "what the engine says runs" do
    alias Vagus.Test.FakeEngine

    defp engine(responses) do
      engine = FakeEngine.start(responses)
      on_exit(fn -> FakeEngine.stop(engine) end)
      [socket: engine.socket]
    end

    test "one listing names the apps whose container runs" do
      containers = [
        %{"Names" => ["/addon_core_ssh"]},
        %{"Names" => ["/hassio_dns"]},
        %{"Names" => ["/addon_local_x", "/alias"]}
      ]

      assert {:ok, running} = Units.running(engine([{200, containers}]))
      assert running == MapSet.new(["core_ssh", "local_x"])
      assert {:error, {:http, 500, _}} = Units.running(engine([{500, %{"message" => "x"}}]))
    end

    test "one app's container: running, absent, or no answer" do
      assert Units.running?("core_ssh", engine([{200, %{"State" => %{"Running" => true}}}]))
      refute Units.running?("core_ssh", engine([{200, %{"State" => %{"Running" => false}}}]))
      refute Units.running?("core_ssh", engine([{404, %{"message" => "no such container"}}]))
      assert :unknown == Units.running?("core_ssh", engine([{500, %{"message" => "x"}}]))
    end

    defp posts(engine),
      do: for(%{method: :post, path: path} <- FakeEngine.requests(engine), do: path)

    test "a container found paused is unpaused, logged, and still counts as running" do
      paused = %{"State" => %{"Running" => true, "Paused" => true}}
      engine = FakeEngine.start([{200, paused}, {204, nil}])
      on_exit(fn -> FakeEngine.stop(engine) end)

      log = capture_log(fn -> assert Units.running?("core_ssh", socket: engine.socket) end)

      assert posts(engine) == ["/containers/addon_core_ssh/unpause"]
      assert log =~ "core_ssh's container was left paused; unpaused"
    end

    test "the boot listing unpauses a paused container, and a failed unpause is logged" do
      containers = [
        %{"Names" => ["/addon_core_ssh"], "State" => "paused"},
        %{"Names" => ["/addon_local_x"], "State" => "running"}
      ]

      engine = FakeEngine.start([{200, containers}, {500, %{"message" => "x"}}])
      on_exit(fn -> FakeEngine.stop(engine) end)

      log =
        capture_log(fn ->
          assert {:ok, running} = Units.running(socket: engine.socket)
          assert running == MapSet.new(["core_ssh", "local_x"])
        end)

      assert posts(engine) == ["/containers/addon_core_ssh/unpause"]
      assert log =~ "core_ssh's container is paused and did not unpause"
    end
  end
end
