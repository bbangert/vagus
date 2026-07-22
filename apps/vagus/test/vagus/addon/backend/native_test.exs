defmodule Vagus.Addon.Backend.NativeTest do
  # async: false — drives the app-global Native.Supervisor / State and binds a
  # real TCP port for the broker subtree.
  use ExUnit.Case, async: false

  alias Vagus.Addon.{Config, Info, Manager, State}
  alias Vagus.Addon.Backend.Native
  alias Vagus.Addon.Store.BuiltinFetcher

  @slug "core_mqtt"
  @id "addon_core_mqtt"

  # The store rewrites `config.slug` to the store slug on install (router
  # handle_install); mirror that so the installed add-on runs under "core_mqtt".
  defp mqtt_config do
    {:ok, config} = Config.parse(BuiltinFetcher.config(:mqtt))
    %{config | slug: @slug}
  end

  describe "native add-on lifecycle (real broker subtree, Manager routes to :native)" do
    setup do
      port = free_port()
      prev_port = Application.get_env(:vagus, :mqtt_broker_port)
      Application.put_env(:vagus, :mqtt_broker_port, port)
      data_root = tmp_dir()

      on_exit(fn ->
        Manager.uninstall(@slug, data_root: data_root)

        if prev_port,
          do: Application.put_env(:vagus, :mqtt_broker_port, prev_port),
          else: Application.delete_env(:vagus, :mqtt_broker_port)
      end)

      %{config: mqtt_config(), port: port, data_root: data_root}
    end

    test "install → start → state → stop → uninstall", %{
      config: config,
      port: port,
      data_root: dr
    } do
      # install routes to Native.pull (no Docker); the router persists :stopped.
      assert :ok = Manager.install(config, data_root: dr)
      :ok = State.put(config, :stopped)

      # start routes to Native → a real supervised broker subtree.
      assert {:ok, %{id: @id}} = Manager.start(config, data_root: dr)
      assert {:ok, :running} = Native.state(@id)
      assert {:ok, %{state: :started}} = State.get(@slug)

      # the listener is actually bound on the configured port.
      assert {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [active: false], 1_000)
      :gen_tcp.close(sock)

      # Info.render surfaces the add-on from its Config (no backend coupling).
      info = Info.render(config, :started, config.options)
      assert info["slug"] == @slug
      assert info["name"] == config.name

      # stop tears the subtree down and records :stopped.
      assert :ok = Manager.stop(@slug, data_root: dr)
      assert {:ok, :stopped} = Native.state(@id)
      assert {:ok, %{state: :stopped}} = State.get(@slug)
      assert {:error, _} = :gen_tcp.connect(~c"127.0.0.1", port, [active: false], 500)

      # uninstall purges State.
      assert :ok = Manager.uninstall(@slug, data_root: dr)
      assert :error = State.get(@slug)
    end

    test "start is idempotent and stop tolerates an already-stopped add-on", %{
      config: config,
      data_root: dr
    } do
      assert :ok = Manager.install(config, data_root: dr)
      :ok = State.put(config, :stopped)
      assert {:ok, _} = Manager.start(config, data_root: dr)

      # Native.start on an already-running id is :ok, not a crash.
      assert :ok = Native.start(@id)
      assert {:ok, :running} = Native.state(@id)

      assert :ok = Manager.stop(@slug, data_root: dr)
      # Native.stop/remove on an unstarted id is idempotent.
      assert :ok = Native.stop(@id)
      assert :ok = Native.remove(@id)
      assert {:ok, :stopped} = Native.state(@id)
    end
  end

  describe "store catalog" do
    test "the builtin fetcher exposes the native add-on as core_mqtt" do
      catalog = Vagus.Addon.Store.build_catalog([%{slug: "core", builtin: :mqtt}], BuiltinFetcher)
      assert %{"core_mqtt" => %{config: %Config{backend: :native, slug: "mqtt"}}} = catalog
    end
  end

  describe "Sentinel (native lifecycle → State sync, MQ-P2-T3)" do
    defmodule FakeState do
      @moduledoc false
      def get(_slug), do: {:ok, %{config: :fake_config}}

      def put(config, state) do
        send(:persistent_term.get(__MODULE__), {:state_put, config, state})
        :ok
      end
    end

    setup do
      :persistent_term.put(FakeState, self())
      name = :"sentinel_#{System.unique_integer([:positive])}"
      start_supervised!({Native.Sentinel, name: name, state_mod: FakeState, recheck_ms: 30})
      %{sentinel: name}
    end

    test "demotes to :stopped when a watched broker does not restart", %{sentinel: sentinel} do
      id = unique_id()
      {:ok, dummy} = Agent.start(fn -> :ok end, name: Native.broker_name(id))

      Native.Sentinel.watch(id, sentinel)
      Process.sleep(20)
      Agent.stop(dummy)

      # No process re-registers broker_name(id) → permanent death → demote.
      assert_receive {:state_put, :fake_config, :stopped}, 500
    end

    test "does NOT demote after an intentional unwatch (manual stop)", %{sentinel: sentinel} do
      id = unique_id()
      {:ok, dummy} = Agent.start(fn -> :ok end, name: Native.broker_name(id))

      Native.Sentinel.watch(id, sentinel)
      Process.sleep(20)
      Native.Sentinel.unwatch(id, sentinel)
      Process.sleep(20)
      Agent.stop(dummy)

      refute_receive {:state_put, _config, :stopped}, 200
    end
  end

  # ---------- helpers ----------

  defp unique_id, do: "addon_sentinel_#{System.unique_integer([:positive])}"

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "vagus_native_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
