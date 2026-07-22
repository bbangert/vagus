defmodule Vagus.Mqtt.Broker.ProviderTest do
  @moduledoc """
  M5 (MQ-P4-T1) — the native broker's service/discovery publisher. Runs against
  isolated `Vagus.Services`/`Vagus.Discovery` instances and a recording `push`
  fn (in place of `Vagus.Discovery.Push`, which would fire a real Core request),
  so the service registration, the Core discovery push, the crash-orphan dedup,
  and the terminate cleanup are all assertable without a broker or Core.
  """
  use ExUnit.Case, async: true

  alias Vagus.Discovery
  alias Vagus.Mqtt.Broker.Provider
  alias Vagus.Services

  @slug "core_mqtt"
  @host "172.30.32.2"
  @port 1883

  setup do
    uniq = System.unique_integer([:positive])
    services = start_supervised!({Services, name: :"services_#{uniq}"})
    discovery = start_supervised!({Discovery, name: :"discovery_#{uniq}"})
    data_dir = Path.join(System.tmp_dir!(), "vagus-provider-#{uniq}")
    on_exit(fn -> File.rm_rf(data_dir) end)

    parent = self()

    push = fn method, message ->
      send(parent, {:push, method, message})
      :ok
    end

    %{services: services, discovery: discovery, data_dir: data_dir, push: push}
  end

  defp start_provider(ctx) do
    name = :"provider_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Provider,
       [
         slug: @slug,
         host: @host,
         port: @port,
         services: ctx.services,
         discovery: ctx.discovery,
         push: ctx.push,
         data_dir: ctx.data_dir,
         name: name
       ]},
      id: name
    )

    name
  end

  test "registers the mqtt service and pushes the discovery to Core", ctx do
    start_provider(ctx)

    assert {:ok, %{"username" => "addons", "host" => @host, "port" => @port} = payload} =
             Services.get("mqtt", ctx.services)

    assert is_binary(payload["password"]) and payload["password"] != ""

    assert [%{service: "mqtt", addon: @slug, uuid: uuid}] = Discovery.list(ctx.discovery)
    assert_receive {:push, :post, %{service: "mqtt", addon: @slug, uuid: ^uuid}}
  end

  test "clears a slug's orphaned discovery (crash leftover) before publishing a fresh one", ctx do
    # Simulate a previous broker instance that crashed without terminating:
    # its discovery lingers in the registry (and in Core).
    {:ok, %{uuid: stale}} = Discovery.add(@slug, "mqtt", %{"stale" => true}, ctx.discovery)

    start_provider(ctx)

    # The stale entry is deleted (with a Core delete push) and exactly one fresh
    # entry remains — never a duplicate.
    assert_receive {:push, :delete, %{uuid: ^stale}}
    assert [%{uuid: fresh}] = Discovery.list(ctx.discovery)
    assert fresh != stale
    assert_receive {:push, :post, %{uuid: ^fresh}}
  end

  test "terminate deregisters the service and pushes a discovery delete", ctx do
    name = start_provider(ctx)
    assert [%{uuid: uuid}] = Discovery.list(ctx.discovery)
    assert {:ok, _} = Services.get("mqtt", ctx.services)

    :ok = stop_supervised!(name)

    assert_receive {:push, :delete, %{uuid: ^uuid}}
    assert Discovery.list(ctx.discovery) == []
    assert Services.get("mqtt", ctx.services) == :error
  end
end
