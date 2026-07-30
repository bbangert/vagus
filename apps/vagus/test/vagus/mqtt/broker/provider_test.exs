defmodule Vagus.Mqtt.Broker.ProviderTest do
  @moduledoc """
  M5 (MQ-P4-T1) — the native broker's service/discovery publisher. Runs against
  isolated `Vagus.Services`/`Vagus.Discovery` instances and a recording `push`
  fn (in place of `Vagus.Discovery.Push`, which would fire a real Core request),
  so the service registration, the Core discovery push, the crash-orphan
  idempotency (now `Vagus.Discovery.add/4`'s own `(slug, service)` dedup —
  audit B3, see `Vagus.Mqtt.Broker.Provider`'s moduledoc), and the terminate
  cleanup are all assertable without a broker or Core.
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

  test "reuses a slug's leftover discovery (crash leftover) instead of duplicating it", ctx do
    # Simulate a previous broker instance that crashed without terminating:
    # its discovery lingers in the registry (and in Core) under the same
    # (slug, service) pair, with a stale config.
    {:ok, %{uuid: stale}, :new} = Discovery.add(@slug, "mqtt", %{"stale" => true}, ctx.discovery)

    start_provider(ctx)

    # `Discovery.add/4`'s own dedup (audit B3) keeps the leftover's uuid and
    # updates `config` in place — never a delete, never a second entry.
    assert [%{uuid: ^stale, config: config}] = Discovery.list(ctx.discovery)
    assert config["host"] == @host
    assert_receive {:push, :post, %{uuid: ^stale}}
    refute_received {:push, :delete, _message}
  end

  test "publishing an already-current record pushes nothing", ctx do
    # Pin the password `load_or_generate_password/1` will read back, so the
    # payload the provider computes on `init` is fully deterministic —
    # standing in for "this exact record is already in the registry (and in
    # Core)", e.g. the discovery survived a supervisor restart that only
    # killed the provider process.
    password = "already-current-password"
    File.mkdir_p!(ctx.data_dir)

    File.write!(
      Path.join(ctx.data_dir, "broker_state.json"),
      Jason.encode!(%{"addons_password" => password})
    )

    payload = %{
      "host" => @host,
      "port" => @port,
      "ssl" => false,
      "protocol" => "3.1.1",
      "username" => "addons",
      "password" => password
    }

    {:ok, _message, :new} = Discovery.add(@slug, "mqtt", payload, ctx.discovery)

    start_provider(ctx)

    # `Discovery.add/4` reported `:existing` — same record, nothing changed —
    # so the provider must not re-push it (audit B3: an unchanged restart is
    # not a new discovery event for Core).
    assert [%{config: ^payload}] = Discovery.list(ctx.discovery)
    refute_received {:push, :post, _message}
    refute_received {:push, :delete, _message}
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
