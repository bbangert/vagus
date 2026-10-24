defmodule Vagus.Memory.NativeAppTest do
  # Starts the real subtree under the app-global Native.Supervisor.
  use ExUnit.Case, async: false

  alias Vagus.Addon.Backend.Native

  @id "addon_vagus_memory"

  test "the native backend runs the memory subtree, which answers db_unavailable without Postgres" do
    on_exit(fn -> Native.stop(@id) end)

    assert Native.start(@id) == :ok
    assert Native.state(@id) == {:ok, :running}
    assert is_pid(Process.whereis(Module.concat(Vagus.Memory, @id)))

    assert Vagus.Memory.recall("kettle") == {:error, :db_unavailable}
    assert Vagus.Memory.remember("fact", nil, "the kettle boils") == {:error, :db_unavailable}

    assert Native.stop(@id) == :ok
    assert Native.state(@id) == {:ok, :stopped}
    assert Vagus.Memory.recall("kettle") == {:error, :unavailable}
  end
end
