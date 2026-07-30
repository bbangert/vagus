defmodule Vagus.DiscoveryTest do
  @moduledoc "P4-T2: the discovery registry state machine."
  use ExUnit.Case, async: true

  alias Vagus.Discovery

  setup do
    {:ok, pid} = Discovery.start_link(name: nil)
    %{d: pid}
  end

  test "add mints a 32-char lowercase-hex uuid and stores the message", %{d: d} do
    {:ok, msg, :new} = Discovery.add("core_mosquitto", "mqtt", %{"host" => "core-mosquitto"}, d)
    assert msg.addon == "core_mosquitto"
    assert msg.service == "mqtt"
    assert msg.config == %{"host" => "core-mosquitto"}
    assert msg.uuid =~ ~r/\A[0-9a-f]{32}\z/
    assert {:ok, ^msg} = Discovery.get(msg.uuid, d)
  end

  test "distinct (addon, service) pairs each get their own uuid", %{d: d} do
    {:ok, a, :new} = Discovery.add("s", "mqtt", %{}, d)
    {:ok, b, :new} = Discovery.add("other", "mqtt", %{}, d)
    {:ok, c, :new} = Discovery.add("s", "other_service", %{}, d)
    refute a.uuid == b.uuid
    refute a.uuid == c.uuid
    assert length(Discovery.list(d)) == 3
  end

  test "a repeat add for the same (addon, service) with identical config is a no-op :existing",
       %{d: d} do
    {:ok, first, :new} = Discovery.add("s", "mqtt", %{"host" => "h"}, d)
    {:ok, second, :existing} = Discovery.add("s", "mqtt", %{"host" => "h"}, d)

    assert second == first
    assert length(Discovery.list(d)) == 1
  end

  test "a repeat add for the same (addon, service) with a changed config keeps the uuid and reports :updated",
       %{d: d} do
    {:ok, first, :new} = Discovery.add("s", "mqtt", %{"host" => "h1"}, d)
    {:ok, second, :updated} = Discovery.add("s", "mqtt", %{"host" => "h2"}, d)

    assert second.uuid == first.uuid
    assert second.config == %{"host" => "h2"}
    assert length(Discovery.list(d)) == 1
    assert {:ok, ^second} = Discovery.get(first.uuid, d)
  end

  test "get on an unknown uuid is :error", %{d: d} do
    assert :error = Discovery.get("deadbeef", d)
  end

  test "delete is owner-only", %{d: d} do
    {:ok, msg, :new} = Discovery.add("owner", "mqtt", %{}, d)
    assert {:error, :not_owner} = Discovery.delete(msg.uuid, "someone_else", d)
    assert {:ok, ^msg} = Discovery.get(msg.uuid, d)

    assert {:ok, ^msg} = Discovery.delete(msg.uuid, "owner", d)
    assert :error = Discovery.get(msg.uuid, d)
  end

  test "delete of an unknown uuid is :not_found", %{d: d} do
    assert {:error, :not_found} = Discovery.delete("nope", "owner", d)
  end

  test "delete_by_slug removes only that add-on's messages", %{d: d} do
    {:ok, a, :new} = Discovery.add("a", "mqtt", %{}, d)
    {:ok, _b, :new} = Discovery.add("b", "mqtt", %{}, d)
    {:ok, removed} = Discovery.delete_by_slug("a", d)
    assert removed == [a]
    assert [%{addon: "b"}] = Discovery.list(d)
  end
end
