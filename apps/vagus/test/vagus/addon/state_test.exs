defmodule Vagus.Addon.StateTest do
  @moduledoc "Add-on state store (slug → config + lifecycle state + user options)."
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

  test "put/get round-trips the config + state, defaulting user_options to %{}", %{
    config: c,
    s: s
  } do
    :ok = State.put(c, :started, server: s)

    assert {:ok, %{config: ^c, state: :started, user_options: %{}}} =
             State.get("core_mosquitto", s)
  end

  test "get on an unknown slug is :error", %{s: s} do
    assert :error = State.get("nope", s)
  end

  test "put replaces prior entry for the slug", %{config: c, s: s} do
    :ok = State.put(c, :started, server: s)
    :ok = State.put(c, :stopped, server: s)
    assert {:ok, %{state: :stopped}} = State.get("core_mosquitto", s)
  end

  test "put with :user_options sets it explicitly", %{config: c, s: s} do
    :ok = State.put(c, :started, server: s, user_options: %{"greeting" => "hi"})
    assert {:ok, %{user_options: %{"greeting" => "hi"}}} = State.get("core_mosquitto", s)
  end

  test "a start/stop transition without :user_options preserves previously-stored options", %{
    config: c,
    s: s
  } do
    :ok = State.put(c, :started, server: s, user_options: %{"greeting" => "hi"})
    :ok = State.put(c, :stopped, server: s)

    assert {:ok, %{state: :stopped, user_options: %{"greeting" => "hi"}}} =
             State.get("core_mosquitto", s)

    :ok = State.put(c, :started, server: s)

    assert {:ok, %{state: :started, user_options: %{"greeting" => "hi"}}} =
             State.get("core_mosquitto", s)
  end

  test "put_options replaces the stored user options for an installed slug", %{config: c, s: s} do
    :ok = State.put(c, :started, server: s)
    assert :ok = State.put_options("core_mosquitto", %{"a" => 1}, s)
    assert {:ok, %{user_options: %{"a" => 1}}} = State.get("core_mosquitto", s)
  end

  test "put_options on an unknown slug is :error", %{s: s} do
    assert :error = State.put_options("nope", %{"a" => 1}, s)
  end

  test "delete removes the entry", %{config: c, s: s} do
    :ok = State.put(c, :started, server: s)
    :ok = State.delete("core_mosquitto", s)
    assert :error = State.get("core_mosquitto", s)
    assert State.list(s) == []
  end
end
