defmodule Vagus.FlavorTest do
  use ExUnit.Case, async: false

  alias Vagus.Flavor

  setup do
    prev = Application.fetch_env(:vagus, :flavor)

    on_exit(fn ->
      case prev do
        {:ok, value} -> Application.put_env(:vagus, :flavor, value)
        :error -> Application.delete_env(:vagus, :flavor)
      end
    end)
  end

  test "get/0 is :default and agent?/0 false when the key is unset" do
    Application.delete_env(:vagus, :flavor)
    assert Flavor.get() == :default
    refute Flavor.agent?()
  end

  test "get/0 is :agent_dev_board and agent?/0 true when set to it" do
    Application.put_env(:vagus, :flavor, :agent_dev_board)
    assert Flavor.get() == :agent_dev_board
    assert Flavor.agent?()
  end

  test "agent?/0 is false when the key is explicitly :default" do
    Application.put_env(:vagus, :flavor, :default)
    assert Flavor.get() == :default
    refute Flavor.agent?()
  end
end
