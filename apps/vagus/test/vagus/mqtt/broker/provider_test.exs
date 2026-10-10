defmodule Vagus.Mqtt.Broker.ProviderTest do
  # async: false — publishes into the application's app directory, where
  # `mqtt` is one key for every app.
  use ExUnit.Case, async: false

  import Vagus.AppFixtures

  alias Vagus.App
  alias Vagus.Mqtt.Broker.Provider

  @host "172.30.32.2"
  @port 1883

  setup do
    uniq = System.unique_integer([:positive])
    data_dir = Path.join(System.tmp_dir!(), "vagus-provider-#{uniq}")
    on_exit(fn -> File.rm_rf(data_dir) end)

    capture_discovery_pushes(:push)
    %{slug: "prov_#{uniq}", data_dir: data_dir}
  end

  defp start_provider(ctx, overrides \\ []) do
    opts =
      Keyword.merge(
        [
          slug: ctx.slug,
          host: @host,
          port: @port,
          data_dir: ctx.data_dir,
          name: :"provider_#{System.unique_integer([:positive])}"
        ],
        overrides
      )

    start_supervised!({Provider, opts}, id: opts[:name], restart: :temporary)
    opts[:name]
  end

  defp pin_password(ctx, password) do
    File.mkdir_p!(ctx.data_dir)

    File.write!(
      Path.join(ctx.data_dir, "broker_state.json"),
      ~s({"addons_password":"#{password}"})
    )
  end

  defp payload(password) do
    %{
      "host" => @host,
      "port" => @port,
      "ssl" => false,
      "protocol" => "3.1.1",
      "username" => "addons",
      "password" => password
    }
  end

  defp app_pid(slug) do
    [{pid, _value}] = Registry.lookup(Vagus.App.Directory, {:slug, slug})
    pid
  end

  test "publishes the mqtt service and discovery into its app's process", %{slug: slug} = ctx do
    install_app(app_config(slug))
    start_provider(ctx)
    # The publish runs in a continue; its push is the last step.
    assert_receive {:push, :post, %{service: "mqtt", addon: ^slug, uuid: uuid}}

    assert {:ok, ^slug, %{"username" => "addons", "host" => @host} = payload} =
             App.service("mqtt")

    assert payload["password"] != ""
    assert {:ok, [%{service: "mqtt", uuid: ^uuid}]} = App.ask(slug, :discovery_list)
  end

  test "the service login is the persisted password", ctx do
    pin_password(ctx, "pinned")

    assert Provider.service_login(data_dir: ctx.data_dir) == %{
             username: "addons",
             password: "pinned"
           }
  end

  test "a record its app process already holds is not pushed again", %{slug: slug} = ctx do
    install_app(app_config(slug))
    pin_password(ctx, "already-current")
    {:ok, %{uuid: uuid}, :new} = App.add_discovery(slug, "mqtt", payload("already-current"))
    assert_receive {:push, :post, %{uuid: ^uuid}}

    provider = start_provider(ctx)

    assert :sys.get_state(provider).uuid == uuid
    drain_discovery_pushes(:push)
    refute_received {:push, _method, _message}
  end

  test "a changed record keeps its uuid and is pushed", %{slug: slug} = ctx do
    install_app(app_config(slug))
    {:ok, %{uuid: uuid}, :new} = App.add_discovery(slug, "mqtt", %{"stale" => true})
    assert_receive {:push, :post, %{uuid: ^uuid}}

    start_provider(ctx)

    assert_receive {:push, :post, %{uuid: ^uuid}}
    assert {:ok, [%{uuid: ^uuid, config: %{"host" => @host}}]} = App.ask(slug, :discovery_list)
  end

  test "terminate withdraws the service and pushes the discovery delete", %{slug: slug} = ctx do
    install_app(app_config(slug))
    provider = start_provider(ctx)
    assert_receive {:push, :post, %{uuid: uuid}}

    :ok = stop_supervised!(provider)

    assert_receive {:push, :delete, %{uuid: ^uuid}}
    assert :error = App.service("mqtt")
    assert {:ok, []} = App.ask(slug, :discovery_list)
  end

  test "publishes again into the next app process after its own is killed",
       %{slug: slug} = ctx do
    install_app(app_config(slug))
    provider = start_provider(ctx)
    assert_receive {:push, :post, %{uuid: old}}
    # The POST is delivered before the app process replies; killed in between,
    # the provider never learns `old` and has no uuid to retire.
    assert :sys.get_state(provider).uuid == old

    old_pid = app_pid(slug)
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old_pid, :killed}

    assert_receive {:push, :post, %{uuid: new}}, 5_000
    refute new == old
    # Core's flow for the old uuid would otherwise stay beside the new one.
    assert_receive {:push, :delete, %{uuid: ^old}}, 5_000
    assert {:ok, ^slug, _payload} = App.service("mqtt")
    refute app_pid(slug) == old_pid
  end

  # The new process queues its POST, the provider (another sender) the DELETE:
  # Core told the old uuid is gone first would briefly have no mqtt flow.
  test "the re-post's POST reaches Core before the old uuid's DELETE", %{slug: slug} = ctx do
    install_app(app_config(slug))
    provider = start_provider(ctx)
    assert_receive {:push, :post, %{uuid: old}}
    assert :sys.get_state(provider).uuid == old

    pusher = hold_discovery_queue(:push)
    push = Process.whereis(Vagus.Discovery.Push)
    :erlang.trace(push, true, [:receive])
    old_pid = app_pid(slug)
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old_pid, :killed}

    assert_receive {:trace, ^push, :receive,
                    {:"$gen_call", _from, {:push, :delete, %{uuid: ^old}}}},
                   5_000

    :erlang.trace(push, false, [:receive])

    assert [{:post, new}, {:delete, ^old}] = release_discovery_queue(pusher, :push)
    refute new == old
  end

  test "keeps trying to publish until its app process exists", %{slug: slug} = ctx do
    start_provider(ctx, publish_retry: {500, 10})
    drain_discovery_pushes(:push)
    refute_received {:push, _method, _message}

    install_app(app_config(slug))

    assert_receive {:push, :post, %{addon: ^slug}}, 5_000
    assert {:ok, ^slug, _payload} = App.service("mqtt")
  end

  test "after the fast retries it keeps publishing on the slow cadence", %{slug: slug} = ctx do
    install_app(app_config(slug))
    :ok = Supervisor.terminate_child(Vagus.App.Supervisor, Vagus.App.Instances)
    on_exit(fn -> Supervisor.restart_child(Vagus.App.Supervisor, Vagus.App.Instances) end)

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        provider = start_provider(ctx, publish_retry: {3, 0}, publish_backoff_ms: 50)
        pid = Process.whereis(provider)
        :erlang.trace(pid, true, [:receive])
        # Three fast `:publish`es, then slow ones that must log nothing more.
        for _ <- 1..5, do: assert_receive({:trace, ^pid, :receive, :publish}, 1_000)
        assert :sys.get_state(provider).attempts == 0
        drain_discovery_pushes(:push)
        refute_received {:push, _method, _message}

        {:ok, _pid} = Supervisor.restart_child(Vagus.App.Supervisor, Vagus.App.Instances)
        assert_receive {:push, :post, %{addon: ^slug, service: "mqtt"}}, 1_000
        # The POST is delivered before the provider logs its success.
        _state = :sys.get_state(provider)
        :erlang.trace(pid, false, [:receive])
      end)

    assert {:ok, ^slug, _payload} = App.service("mqtt")
    assert length(String.split(log, "mqtt publish for #{slug} failed")) == 2
    assert log =~ "mqtt service published again"
  end

  test "the broker hands the provider its slow cadence", %{slug: slug} = ctx do
    install_app(app_config(slug))
    :ok = Supervisor.terminate_child(Vagus.App.Supervisor, Vagus.App.Instances)
    on_exit(fn -> Supervisor.restart_child(Vagus.App.Supervisor, Vagus.App.Instances) end)
    broker = :"broker_#{System.unique_integer([:positive])}"

    ExUnit.CaptureLog.capture_log(fn ->
      start_supervised!(
        {Vagus.Mqtt.Broker,
         name: broker,
         port: free_port(),
         ip: {127, 0, 0, 1},
         provider: [
           slug: slug,
           data_dir: ctx.data_dir,
           publish_retry: {3, 0},
           publish_backoff_ms: 50
         ]}
      )

      pid = Process.whereis(Module.concat(broker, "Provider"))
      :erlang.trace(pid, true, [:receive])
      # Two past the fast retries: the default 30 s cadence would not get there.
      for _ <- 1..5, do: assert_receive({:trace, ^pid, :receive, :publish}, 1_000)
      :erlang.trace(pid, false, [:receive])
    end)
  end

  test "its app's own earlier provide is no refusal", %{slug: slug} = ctx do
    install_app(app_config(slug))
    :ok = App.provide_service(slug, "mqtt", %{"stale" => true})

    start_provider(ctx, publish_retry: {1, 0})

    assert_receive {:push, :post, %{addon: ^slug, service: "mqtt"}}
    assert {:ok, ^slug, _payload} = App.service("mqtt")
  end

  test "another app holding mqtt is logged and retried until it lets go", %{slug: slug} = ctx do
    install_app(app_config(slug))
    other = "prov_other_#{System.unique_integer([:positive])}"
    install_app(app_config(other))
    :ok = App.provide_service(other, "mqtt", %{"host" => "elsewhere"})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        provider = start_provider(ctx, publish_retry: {500, 10})
        assert :sys.get_state(provider).uuid == nil
        drain_discovery_pushes(:push)
        refute_received {:push, _method, _message}
        # A failed attempt keeps no monitor on the app process. Suspended, so
        # no attempt is mid-flight while it is looked at.
        pid = Process.whereis(provider)
        :ok = :sys.suspend(pid)
        assert {:monitors, []} = Process.info(pid, :monitors)
        :ok = :sys.resume(pid)

        :ok = App.withdraw_service(other, "mqtt")
        assert_receive {:push, :post, %{addon: ^slug}}, 5_000
      end)

    assert log =~ "provided by app #{other}"
    assert {:ok, ^slug, _payload} = App.service("mqtt")
  end

  test "its status shows no password", %{slug: slug} = ctx do
    install_app(app_config(slug))
    pin_password(ctx, "pinned-secret")
    provider = start_provider(ctx)

    refute inspect(:sys.get_status(provider)) =~ "pinned-secret"
  end

  test "terminate with its app process gone drops the withdraw", %{slug: slug} = ctx do
    install_app(app_config(slug))

    {provider, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        provider = start_provider(ctx, publish_retry: {1, 0})
        assert_receive {:push, :post, _message}

        # Gone for good: without its entry nothing brings the process back.
        :ok = forget_app(slug)
        :sys.get_state(provider)
        provider
      end)

    :ok = stop_supervised!(provider)
    drain_discovery_pushes(:push)
    refute_received {:push, :delete, _message}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
