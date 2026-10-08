defmodule Vagus.AppTest do
  # Seeds the global `Vagus.Addon.State` and briefly stops the global Registry.
  use ExUnit.Case, async: false

  alias Vagus.Addon.{Backend, Config, Registry, State}
  alias Vagus.App

  defp config(overrides \\ %{}) do
    slug = "app_test_#{System.unique_integer([:positive])}"

    {:ok, config} =
      %{
        "name" => "App Test",
        "version" => "1.0",
        "slug" => slug,
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "x/y",
        "host_network" => true
      }
      |> Map.merge(overrides)
      |> Config.parse()

    config
  end

  defp track(config) do
    :ok = State.put(config, :stopped)
    on_exit(fn -> State.delete(config.slug) end)
    config.slug
  end

  describe "set/2" do
    test "writes options and settings" do
      slug = track(config())

      assert :ok = App.set(slug, options: %{"a" => 1}, watchdog: true)
      assert {:ok, %{user_options: %{"a" => 1}, watchdog: true}} = State.get(slug)
    end

    test "an unknown key raises before anything is written" do
      slug = track(config())

      assert_raise ArgumentError, fn -> App.set(slug, watchdog: true, bogus: 1) end
      assert {:ok, %{watchdog: false}} = State.get(slug)
    end

    test "an untracked slug is :error" do
      assert :error = App.set("app_test_untracked", boot: "manual")
    end
  end

  describe "identity_for_token/1" do
    setup do
      token = "app-test-#{System.unique_integer([:positive])}"
      identity = Registry.identity_from_config(config())
      :ok = Registry.register(token, identity)
      on_exit(fn -> Registry.unregister_slug(identity.slug) end)
      %{token: token, identity: identity}
    end

    test "resolves a registered token", %{token: token, identity: identity} do
      assert {:ok, ^identity} = App.identity_for_token(token)
      assert :error = App.identity_for_token("app-test-unknown")
    end

    test "is :error while the Registry is not running", %{token: token} do
      :ok = Supervisor.terminate_child(Vagus.Supervisor, Registry)
      on_exit(fn -> {:ok, _pid} = Supervisor.restart_child(Vagus.Supervisor, Registry) end)

      assert :error = App.identity_for_token(token)
    end
  end

  describe "install/1" do
    setup do
      prev = Application.get_env(:vagus, :addon_backend)
      Application.put_env(:vagus, :addon_backend, Backend.Fake)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:vagus, :addon_backend, prev),
          else: Application.delete_env(:vagus, :addon_backend)
      end)
    end

    test "records the app as :stopped" do
      config = config()
      on_exit(fn -> State.delete(config.slug) end)

      assert :ok = App.install(config)
      assert {:ok, %{state: :stopped}} = State.get(config.slug)
    end

    test "a refused install records nothing" do
      config = %{config() | slug: "vagus"}

      assert {:error, {:reserved_slug, "vagus"}} = App.install(config)
      assert :error = State.get("vagus")
    end
  end

  describe "ingress_target/1" do
    # A host-network app is reached without a docker inspect.
    setup do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      on_exit(fn -> :gen_tcp.close(listen) end)
      {:ok, port} = :inet.port(listen)
      %{port: port}
    end

    test "the config's static port", %{port: port} do
      slug = track(config(%{"ingress" => true, "ingress_port" => port}))
      assert {:ok, {"127.0.0.1", ^port, false}} = App.ingress_target(slug)
    end

    test "the allocated port wins over the 0 sentinel", %{port: port} do
      slug = track(config(%{"ingress" => true, "ingress_port" => 0}))
      :ok = State.put_setting(slug, :ingress_port, port)

      assert {:ok, {"127.0.0.1", ^port, false}} = App.ingress_target(slug)
    end

    test "the 0 sentinel with nothing allocated has no target" do
      slug = track(config(%{"ingress" => true, "ingress_port" => 0}))
      assert {:error, :no_ingress_port} = App.ingress_target(slug)
    end

    test "carries ingress_stream", %{port: port} do
      slug =
        track(config(%{"ingress" => true, "ingress_port" => port, "ingress_stream" => true}))

      assert {:ok, {_ip, ^port, true}} = App.ingress_target(slug)
    end

    test "an untracked slug is not found" do
      assert {:error, :not_found} = App.ingress_target("app_test_untracked")
    end
  end
end
