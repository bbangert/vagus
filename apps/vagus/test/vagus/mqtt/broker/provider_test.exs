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

    parent = self()

    push = fn method, message ->
      send(parent, {:push, method, message})
      :ok
    end

    %{slug: "prov_#{uniq}", data_dir: data_dir, push: push}
  end

  defp start_provider(ctx, overrides \\ []) do
    opts =
      Keyword.merge(
        [
          slug: ctx.slug,
          host: @host,
          port: @port,
          push: ctx.push,
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

    assert {:ok, ^slug, %{"username" => "addons", "host" => @host} = payload} =
             App.service("mqtt")

    assert payload["password"] != ""
    assert {:ok, [%{service: "mqtt", uuid: uuid}]} = App.ask(slug, :discovery_list)
    assert_receive {:push, :post, %{service: "mqtt", addon: ^slug, uuid: ^uuid}}
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

    provider = start_provider(ctx)

    assert :sys.get_state(provider).uuid == uuid
    refute_received {:push, _method, _message}
  end

  test "a changed record keeps its uuid and is pushed", %{slug: slug} = ctx do
    install_app(app_config(slug))
    {:ok, %{uuid: uuid}, :new} = App.add_discovery(slug, "mqtt", %{"stale" => true})

    start_provider(ctx)

    assert_receive {:push, :post, %{uuid: ^uuid, config: %{"host" => @host}}}
    assert {:ok, [%{uuid: ^uuid}]} = App.ask(slug, :discovery_list)
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
    start_provider(ctx)
    assert_receive {:push, :post, %{uuid: old}}

    old_pid = app_pid(slug)
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old_pid, :killed}

    assert_receive {:push, :post, %{uuid: new}}, 5_000
    refute new == old
    # Core's flow for the old uuid would otherwise stay beside the new one.
    assert_receive {:push, :delete, %{uuid: ^old}}
    assert {:ok, ^slug, _payload} = App.service("mqtt")
    refute app_pid(slug) == old_pid
  end

  test "keeps trying to publish until its app process exists", %{slug: slug} = ctx do
    start_provider(ctx, publish_retry: {500, 10})
    refute_received {:push, _method, _message}

    install_app(app_config(slug))

    assert_receive {:push, :post, %{addon: ^slug}}, 5_000
    assert {:ok, ^slug, _payload} = App.service("mqtt")
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
    refute_received {:push, :delete, _message}
  end
end
