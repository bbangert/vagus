defmodule Vagus.ServicesTest do
  use ExUnit.Case, async: true

  alias Vagus.Services

  setup do
    svc = start_supervised!({Services, name: :"svc_#{System.unique_integer([:positive])}"})
    %{svc: svc}
  end

  @mqtt %{"host" => "core-mosquitto", "port" => 1883, "ssl" => false, "protocol" => "3.1.1"}

  test "set then get returns the data with the provider under the addon key", %{svc: svc} do
    assert :ok = Services.set("mqtt", @mqtt, "core_mosquitto", svc)
    assert {:ok, data} = Services.get("mqtt", svc)
    assert data["host"] == "core-mosquitto"
    assert data["port"] == 1883
    assert data["addon"] == "core_mosquitto"
  end

  test "get an unprovided service is :error", %{svc: svc} do
    assert :error = Services.get("mqtt", svc)
  end

  test "double set is rejected (already provided)", %{svc: svc} do
    assert :ok = Services.set("mqtt", @mqtt, "core_mosquitto", svc)
    assert {:error, :already_provided} = Services.set("mqtt", @mqtt, "other", svc)
  end

  test "only the provider may delete; delete is idempotent", %{svc: svc} do
    assert :ok = Services.set("mqtt", @mqtt, "core_mosquitto", svc)
    assert {:error, :not_provider} = Services.delete("mqtt", "intruder", svc)
    assert :ok = Services.delete("mqtt", "core_mosquitto", svc)
    assert :error = Services.get("mqtt", svc)
    assert :ok = Services.delete("mqtt", "anyone", svc)
  end

  test "list reflects availability + providers", %{svc: svc} do
    assert [%{slug: "mqtt", available: false, providers: []}] = Services.list(svc)
    Services.set("mqtt", @mqtt, "core_mosquitto", svc)
    assert [%{slug: "mqtt", available: true, providers: ["core_mosquitto"]}] = Services.list(svc)
  end
end
