defmodule Vagus.Addon.StateTest do
  @moduledoc "Add-on state store (slug → config + lifecycle state)."
  use ExUnit.Case, async: true

  alias Vagus.Addon.{Config, State}

  setup do
    {:ok, c} =
      Config.parse(%{
        "name" => "Mosquitto broker",
        "version" => "7.1.0",
        "slug" => "core_mosquitto",
        "description" => "An Open Source MQTT broker",
        "arch" => ["aarch64"]
      })

    pid = start_supervised!({State, name: nil})
    %{config: c, s: pid}
  end

  test "put/get round-trips the config + state", %{config: c, s: s} do
    :ok = State.put(c, :started, s)
    assert {:ok, %{config: ^c, state: :started}} = State.get("core_mosquitto", s)
  end

  test "get on an unknown slug is :error", %{s: s} do
    assert :error = State.get("nope", s)
  end

  test "put replaces prior entry for the slug", %{config: c, s: s} do
    :ok = State.put(c, :started, s)
    :ok = State.put(c, :stopped, s)
    assert {:ok, %{state: :stopped}} = State.get("core_mosquitto", s)
  end

  test "delete removes the entry", %{config: c, s: s} do
    :ok = State.put(c, :started, s)
    :ok = State.delete("core_mosquitto", s)
    assert :error = State.get("core_mosquitto", s)
    assert State.list(s) == []
  end
end
