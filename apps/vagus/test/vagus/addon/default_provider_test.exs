defmodule Vagus.Addon.DefaultProviderTest do
  # async: false — drives the app-global Native.Supervisor / State and binds a
  # real broker port.
  use ExUnit.Case, async: false

  alias Vagus.Addon.Backend.Native
  alias Vagus.Addon.{DefaultProvider, Manager, State}

  @slug "core_mqtt"

  setup do
    prev = %{
      port: Application.get_env(:vagus, :mqtt_broker_port),
      root: Application.get_env(:vagus, :addon_data_root),
      default: Application.get_env(:vagus, :default_native_addon)
    }

    dr = tmp_dir()
    Application.put_env(:vagus, :mqtt_broker_port, free_port())
    Application.put_env(:vagus, :addon_data_root, dr)
    Application.put_env(:vagus, :default_native_addon, @slug)

    on_exit(fn ->
      Manager.uninstall(@slug, data_root: dr)
      Vagus.Services.delete_by_slug(@slug)
      Vagus.Discovery.delete_by_slug(@slug)
      restore_env(:mqtt_broker_port, prev.port)
      restore_env(:addon_data_root, prev.root)
      restore_env(:default_native_addon, prev.default)
    end)

    :ok
  end

  test "auto-installs and boots the default native provider on start" do
    assert :error = State.get(@slug)

    name = :"dp_#{System.unique_integer([:positive])}"
    start_supervised!({DefaultProvider, name: name})
    # Barrier: the {:continue, :ensure} that installs + starts runs after init.
    :sys.get_state(name)

    assert {:ok, %{state: :started, config: %{backend: :native}}} = State.get(@slug)
    assert eventually(fn -> Native.running?("addon_#{@slug}") end)
  end

  test "is idempotent when the provider is already installed and running" do
    name = :"dp_#{System.unique_integer([:positive])}"
    start_supervised!({DefaultProvider, name: name})
    :sys.get_state(name)
    assert eventually(fn -> Native.running?("addon_#{@slug}") end)

    # A second ensurer must not crash or double-install.
    name2 = :"dp_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({DefaultProvider, name: name2}, id: name2))
    :sys.get_state(name2)
    assert {:ok, %{state: :started}} = State.get(@slug)
    assert eventually(fn -> Native.running?("addon_#{@slug}") end)
  end

  test "start_link/1 is :ignore without :default_native_addon" do
    Application.delete_env(:vagus, :default_native_addon)

    assert :ignore =
             DefaultProvider.start_link(name: :"dp_ignore_#{System.unique_integer([:positive])}")
  end

  # ---------- helpers ----------

  # `Native.running?` right after the `:sys.get_state` barrier can momentarily
  # read false: the barrier syncs the DefaultProvider's `:ensure` continue, not
  # the broker subtree's separate (re)start / Sentinel re-arm, which under a
  # loaded scheduler (busy CI runner) can lag that return. Poll briefly — a
  # genuinely-down broker still fails once the window elapses.
  defp eventually(fun, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(5)
        {:cont, false}
      end
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:vagus, key)
  defp restore_env(key, value), do: Application.put_env(:vagus, key, value)

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "vagus_dp_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
