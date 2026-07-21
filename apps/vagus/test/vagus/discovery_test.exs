defmodule Vagus.DiscoveryTest do
  @moduledoc "P4-T2: the discovery registry state machine."
  use ExUnit.Case, async: true

  alias Vagus.Discovery

  setup do
    {:ok, pid} = Discovery.start_link(name: nil)
    %{d: pid}
  end

  test "add mints a 32-char lowercase-hex uuid and stores the message", %{d: d} do
    {:ok, msg} = Discovery.add("core_mosquitto", "mqtt", %{"host" => "core-mosquitto"}, d)
    assert msg.addon == "core_mosquitto"
    assert msg.service == "mqtt"
    assert msg.config == %{"host" => "core-mosquitto"}
    assert msg.uuid =~ ~r/\A[0-9a-f]{32}\z/
    assert {:ok, ^msg} = Discovery.get(msg.uuid, d)
  end

  test "each add gets a distinct uuid", %{d: d} do
    {:ok, a} = Discovery.add("s", "mqtt", %{}, d)
    {:ok, b} = Discovery.add("s", "mqtt", %{}, d)
    refute a.uuid == b.uuid
    assert length(Discovery.list(d)) == 2
  end

  test "get on an unknown uuid is :error", %{d: d} do
    assert :error = Discovery.get("deadbeef", d)
  end

  test "delete is owner-only", %{d: d} do
    {:ok, msg} = Discovery.add("owner", "mqtt", %{}, d)
    assert {:error, :not_owner} = Discovery.delete(msg.uuid, "someone_else", d)
    assert {:ok, ^msg} = Discovery.get(msg.uuid, d)

    assert {:ok, ^msg} = Discovery.delete(msg.uuid, "owner", d)
    assert :error = Discovery.get(msg.uuid, d)
  end

  test "delete of an unknown uuid is :not_found", %{d: d} do
    assert {:error, :not_found} = Discovery.delete("nope", "owner", d)
  end

  test "delete_by_slug removes only that add-on's messages", %{d: d} do
    {:ok, a} = Discovery.add("a", "mqtt", %{}, d)
    {:ok, _b} = Discovery.add("b", "mqtt", %{}, d)
    {:ok, removed} = Discovery.delete_by_slug("a", d)
    assert removed == [a]
    assert [%{addon: "b"}] = Discovery.list(d)
  end
end
