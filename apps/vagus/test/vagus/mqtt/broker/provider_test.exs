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

  defp start_provider(ctx, overrides \\ []) do
    name = :"provider_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Provider,
       Keyword.merge(
         [
           slug: @slug,
           host: @host,
           port: @port,
           services: ctx.services,
           discovery: ctx.discovery,
           push: ctx.push,
           data_dir: ctx.data_dir,
           name: name
         ],
         overrides
       )},
      id: name,
      # The absent-registry tests stop it themselves; a restart would
      # publish again.
      restart: :temporary
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

  describe "terminate with a registry that is absent" do
    # Wide enough that bringing the registry back always lands inside it.
    @slack_retry {2_000, 5}
    @tiny_retry {2, 1}

    # Named and checkpointed, so a restart under the same name reloads what
    # the provider published, as the application's registries do.
    setup ctx do
      uniq = System.unique_integer([:positive])
      File.mkdir_p!(ctx.data_dir)

      registries = %{
        services: {Services, :"services_named_#{uniq}", Path.join(ctx.data_dir, "services.term")},
        discovery:
          {Discovery, :"discovery_named_#{uniq}", Path.join(ctx.data_dir, "discovery.term")}
      }

      Enum.each(registries, fn {id, _spec} -> start_registry(registries, id) end)

      %{
        registries: registries,
        slug: "absent_#{uniq}",
        services: elem(registries.services, 1),
        discovery: elem(registries.discovery, 1)
      }
    end

    defp start_registry(registries, id) do
      {module, name, path} = Map.fetch!(registries, id)
      start_supervised!({module, name: name, path: path}, id: id)
    end

    # Holds `name` like a registry that goes down on the first call it gets.
    defp dying_stub(name) do
      test = self()

      pid =
        spawn(fn ->
          receive do
            {:"$gen_call", _from, request} ->
              send(test, {:stub_call, name, request})
              exit(:shutdown)
          end
        end)

      Process.register(pid, name)
      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end

    # Holds `name` like a registry that is alive and never answers.
    defp holding_stub(name) do
      test = self()

      pid =
        spawn(fn ->
          receive do
            {:"$gen_call", _from, request} -> send(test, {:held, request})
          end

          Process.sleep(:infinity)
        end)

      Process.register(pid, name)
      on_exit(fn -> Process.exit(pid, :kill) end)
    end

    # A dead process has released its name by the time its monitor fires.
    defp await_down(pid) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    end

    test "waits out a Services that is briefly absent, and the service stays deregistered",
         %{slug: slug} = ctx do
      provider = start_provider(ctx, slug: slug, deregister_retry: @slack_retry)
      assert {:ok, %{"addon" => ^slug}} = Services.get("mqtt", ctx.services)

      :ok = stop_supervised!(:services)
      stub = dying_stub(ctx.services)
      stop = Task.async(fn -> GenServer.stop(provider, :shutdown) end)

      assert_receive {:stub_call, _name, {:delete, "mqtt", ^slug}}, 5_000
      await_down(stub)
      # Comes back holding the entry: its checkpoint predates the delete.
      start_registry(ctx.registries, :services)

      assert :ok = Task.await(stop, 60_000)
      assert :error = Services.get("mqtt", ctx.services)
    end

    test "waits out a Discovery that is briefly absent, and the delete still reaches Core",
         %{slug: slug} = ctx do
      provider = start_provider(ctx, slug: slug, deregister_retry: @slack_retry)
      assert [%{uuid: uuid}] = Discovery.list(ctx.discovery)

      :ok = stop_supervised!(:discovery)
      stub = dying_stub(ctx.discovery)
      stop = Task.async(fn -> GenServer.stop(provider, :shutdown) end)

      assert_receive {:stub_call, _name, {:delete, ^uuid, ^slug}}, 5_000
      await_down(stub)
      # Comes back holding the message: its checkpoint predates the delete.
      start_registry(ctx.registries, :discovery)

      assert :ok = Task.await(stop, 60_000)
      assert [] = Discovery.list(ctx.discovery)
      assert_receive {:push, :delete, %{uuid: ^uuid}}
    end

    # A registry that holds the first call for the whole shutdown timeout
    # would get the provider killed before it reaches the second.
    test "a Services that holds the call costs one call timeout, and Discovery is still deleted",
         %{slug: slug} = ctx do
      provider = start_provider(ctx, slug: slug, deregister_call_timeout: 50)
      assert [%{uuid: uuid}] = Discovery.list(ctx.discovery)

      :ok = stop_supervised!(:services)
      holding_stub(ctx.services)

      stop =
        Task.async(fn ->
          ExUnit.CaptureLog.with_log(fn -> GenServer.stop(provider, :shutdown) end)
        end)

      # Well under one default call timeout.
      assert {:ok, {:ok, log}} = Task.yield(stop, 2_500) || Task.shutdown(stop, :brutal_kill)
      assert_received {:held, {:delete, "mqtt", ^slug}}
      assert log =~ "Services delete for #{slug} failed (timeout)"
      assert [] = Discovery.list(ctx.discovery)
      assert_received {:push, :delete, %{uuid: ^uuid}}
    end

    test "a Discovery that holds the call costs one call timeout", %{slug: slug} = ctx do
      provider = start_provider(ctx, slug: slug, deregister_call_timeout: 50)
      assert [%{uuid: uuid}] = Discovery.list(ctx.discovery)

      :ok = stop_supervised!(:discovery)
      holding_stub(ctx.discovery)

      stop =
        Task.async(fn ->
          ExUnit.CaptureLog.with_log(fn -> GenServer.stop(provider, :shutdown) end)
        end)

      assert {:ok, {:ok, log}} = Task.yield(stop, 2_500) || Task.shutdown(stop, :brutal_kill)
      assert_received {:held, {:delete, ^uuid, ^slug}}
      assert log =~ "Discovery delete for #{slug} failed (timeout)"
      assert :error = Services.get("mqtt", ctx.services)
    end

    test "a registry that goes down on init's call is logged by tag, without the password",
         %{slug: slug} = ctx do
      password = "pw-#{System.unique_integer([:positive])}-must-not-print"

      File.write!(
        Path.join(ctx.data_dir, "broker_state.json"),
        Jason.encode!(%{"addons_password" => password})
      )

      :ok = stop_supervised!(:services)
      stub = dying_stub(ctx.services)

      {_provider, log} =
        ExUnit.CaptureLog.with_log(fn -> start_provider(ctx, slug: slug) end)

      assert_received {:stub_call, _name, {:set, "mqtt", %{"password" => ^password}, ^slug}}
      await_down(stub)
      assert log =~ "Vagus.Mqtt.Broker.Provider: registry call skipped (exit shutdown)"
      refute log =~ password
    end

    test "still terminates when both stay absent, and logs what it left without the password",
         %{slug: slug} = ctx do
      provider = start_provider(ctx, slug: slug, deregister_retry: @tiny_retry)
      {:ok, %{"password" => password}} = Services.get("mqtt", ctx.services)

      :ok = stop_supervised!(:services)
      :ok = stop_supervised!(:discovery)

      {result, log} = ExUnit.CaptureLog.with_log(fn -> GenServer.stop(provider, :shutdown) end)

      assert result == :ok

      assert log =~
               "[error] Vagus.Mqtt.Broker.Provider: Services delete for #{slug} failed (noproc)"

      assert log =~
               "[error] Vagus.Mqtt.Broker.Provider: Discovery delete for #{slug} failed (noproc)"

      refute log =~ password
      refute_received {:push, :delete, _message}
    end
  end
end
