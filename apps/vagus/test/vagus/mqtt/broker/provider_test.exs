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
  alias Vagus.Mqtt.Broker.Auth
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

  defp provider_opts(ctx, overrides) do
    Keyword.merge(
      [
        slug: @slug,
        host: @host,
        port: @port,
        services: ctx.services,
        discovery: ctx.discovery,
        push: ctx.push,
        data_dir: ctx.data_dir,
        name: :"provider_#{System.unique_integer([:positive])}"
      ],
      overrides
    )
  end

  defp start_provider(ctx, overrides \\ []) do
    opts = provider_opts(ctx, overrides)
    name = opts[:name]

    start_supervised!(
      {Provider, opts},
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

  describe "a registry that is absent" do
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
        # Apart from the test supervisor, which a provider waiting in `init/1`
        # would block from starting the registry it waits for.
        providers: start_supervised!({DynamicSupervisor, []}, id: :providers),
        slug: "absent_#{uniq}",
        services: elem(registries.services, 1),
        discovery: elem(registries.discovery, 1)
      }
    end

    defp start_provider_async(ctx, overrides) do
      spec = Supervisor.child_spec({Provider, provider_opts(ctx, overrides)}, restart: :temporary)
      Task.async(fn -> DynamicSupervisor.start_child(ctx.providers, spec) end)
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
      provider = start_provider(ctx, slug: slug, registry_retry: @slack_retry)
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
      provider = start_provider(ctx, slug: slug, registry_retry: @slack_retry)
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

    # A publish skipped here would leave the broker running with no service
    # entry, so its service credentials are refused for as long as it runs.
    test "init waits out a Services that is briefly absent, and the credentials authenticate",
         %{slug: slug} = ctx do
      :ok = stop_supervised!(:services)
      stub = dying_stub(ctx.services)
      start = start_provider_async(ctx, slug: slug, registry_retry: @slack_retry)

      assert_receive {:stub_call, _name, {:set, "mqtt", %{"password" => password}, ^slug}}, 5_000
      await_down(stub)
      start_registry(ctx.registries, :services)

      assert {:ok, _provider} = Task.await(start, 60_000)
      assert {:ok, %{"addon" => ^slug}} = Services.get("mqtt", ctx.services)
      assert :ok = Auth.authenticate("addons", password, Auth.config(services: ctx.services))

      :ok = stop_supervised!(:providers)
    end

    test "init waits out a Discovery that is briefly absent, and pushes the message once",
         %{slug: slug} = ctx do
      :ok = stop_supervised!(:discovery)
      stub = dying_stub(ctx.discovery)
      start = start_provider_async(ctx, slug: slug, registry_retry: @slack_retry)

      assert_receive {:stub_call, _name, {:add, ^slug, "mqtt", _config}}, 5_000
      await_down(stub)
      start_registry(ctx.registries, :discovery)

      assert {:ok, provider} = Task.await(start, 60_000)
      assert [%{uuid: uuid, addon: ^slug}] = Discovery.list(ctx.discovery)
      assert :sys.get_state(provider).uuid == uuid
      assert_receive {:push, :post, %{uuid: ^uuid}}
      refute_received {:push, :post, _message}

      :ok = stop_supervised!(:providers)
    end

    test "init still starts the provider when both stay absent, and logs it without the password",
         %{slug: slug} = ctx do
      password = "pw-#{System.unique_integer([:positive])}-must-not-print"

      File.write!(
        Path.join(ctx.data_dir, "broker_state.json"),
        Jason.encode!(%{"addons_password" => password})
      )

      :ok = stop_supervised!(:services)
      :ok = stop_supervised!(:discovery)

      {provider, log} =
        ExUnit.CaptureLog.with_log(fn ->
          start_provider(ctx, slug: slug, registry_retry: @tiny_retry)
        end)

      assert :sys.get_state(provider).uuid == nil

      assert log =~
               "[error] Vagus.Mqtt.Broker.Provider: Services publish for #{slug} failed (noproc)"

      assert log =~
               "[error] Vagus.Mqtt.Broker.Provider: Discovery publish for #{slug} failed (noproc)"

      refute log =~ password

      # Stopped here so its Services delete, absent too, logs inside a capture.
      ExUnit.CaptureLog.capture_log(fn -> :ok = stop_supervised!(provider) end)
    end

    # The held call sets these tests' duration; the other registry has the
    # same timeout to answer in, checkpoint save included.
    @hold_timeout 400

    test "a Services that holds the call costs one call timeout, and Discovery is still deleted",
         %{slug: slug} = ctx do
      provider = start_provider(ctx, slug: slug, deregister_call_timeout: @hold_timeout)
      assert [%{uuid: uuid}] = Discovery.list(ctx.discovery)

      :ok = stop_supervised!(:services)
      holding_stub(ctx.services)

      stop =
        Task.async(fn ->
          ExUnit.CaptureLog.with_log(fn -> GenServer.stop(provider, :shutdown) end)
        end)

      # Half a default call timeout: the injected one reached the call.
      assert {:ok, {:ok, log}} = Task.yield(stop, 2_500) || Task.shutdown(stop, :brutal_kill)
      assert_receive {:held, {:delete, "mqtt", ^slug}}
      assert log =~ "Services delete for #{slug} failed (timeout)"
      assert [] = Discovery.list(ctx.discovery)
      assert_receive {:push, :delete, %{uuid: ^uuid}}
    end

    test "a Discovery that holds the call costs one call timeout", %{slug: slug} = ctx do
      provider = start_provider(ctx, slug: slug, deregister_call_timeout: @hold_timeout)
      assert [%{uuid: uuid}] = Discovery.list(ctx.discovery)

      :ok = stop_supervised!(:discovery)
      holding_stub(ctx.discovery)

      stop =
        Task.async(fn ->
          ExUnit.CaptureLog.with_log(fn -> GenServer.stop(provider, :shutdown) end)
        end)

      assert {:ok, {:ok, log}} = Task.yield(stop, 2_500) || Task.shutdown(stop, :brutal_kill)
      assert_receive {:held, {:delete, ^uuid, ^slug}}
      assert log =~ "Discovery delete for #{slug} failed (timeout)"
      assert :error = Services.get("mqtt", ctx.services)
    end

    # The module's own budget and call timeout, under the shutdown its child
    # spec gets in the broker: a provider still on its Services delete when
    # that runs out is killed before it deletes the discovery.
    defp start_as_in_production(ctx) do
      opts = provider_opts(ctx, slug: ctx.slug)

      start_supervised!(%{
        id: :production_spec,
        type: :supervisor,
        start: {Supervisor, :start_link, [[{Provider, opts}], [strategy: :one_for_one]]}
      })
    end

    test "the default call timeout leaves a held Services call time for the Discovery delete",
         %{slug: slug} = ctx do
      sup = start_as_in_production(ctx)
      assert [%{uuid: uuid}] = Discovery.list(ctx.discovery)

      :ok = stop_supervised!(:services)
      holding_stub(ctx.services)

      {result, log} =
        ExUnit.CaptureLog.with_log(fn -> Supervisor.terminate_child(sup, Provider) end)

      assert result == :ok
      assert log =~ "Services delete for #{slug} failed (timeout)"
      assert [] = Discovery.list(ctx.discovery)
      assert_receive {:push, :delete, %{uuid: ^uuid}}
    end

    test "the default budget leaves an absent Services time for the Discovery delete",
         %{slug: slug} = ctx do
      sup = start_as_in_production(ctx)
      assert [%{uuid: uuid}] = Discovery.list(ctx.discovery)

      :ok = stop_supervised!(:services)

      {result, log} =
        ExUnit.CaptureLog.with_log(fn -> Supervisor.terminate_child(sup, Provider) end)

      assert result == :ok
      assert log =~ "Services delete for #{slug} failed (noproc)"
      assert [] = Discovery.list(ctx.discovery)
      assert_receive {:push, :delete, %{uuid: ^uuid}}
    end

    test "terminate still completes when both stay absent, and logs what it left",
         %{slug: slug} = ctx do
      provider = start_provider(ctx, slug: slug, registry_retry: @tiny_retry)

      :ok = stop_supervised!(:services)
      :ok = stop_supervised!(:discovery)

      {result, log} = ExUnit.CaptureLog.with_log(fn -> GenServer.stop(provider, :shutdown) end)

      assert result == :ok

      assert log =~
               "[error] Vagus.Mqtt.Broker.Provider: Services delete for #{slug} failed (noproc)"

      assert log =~
               "[error] Vagus.Mqtt.Broker.Provider: Discovery delete for #{slug} failed (noproc)"

      refute_received {:push, :delete, _message}
    end
  end
end
