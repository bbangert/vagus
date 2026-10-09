defmodule Vagus.AppCharacterisationTest.GatedBackend do
  @moduledoc false
  # The fake backend, except that an armed op parks its first caller until the
  # test sends `:release`, so a test can hold an operation mid-flight.

  @behaviour Vagus.Addon.Backend

  alias Vagus.Addon.Backend.Fake

  @key :app_characterisation_gates

  def arm(op), do: Application.put_env(:vagus, @key, Map.put(gates(), op, self()))
  def disarm_all, do: Application.delete_env(:vagus, @key)

  defp gates, do: Application.get_env(:vagus, @key, %{})

  defp gate(op) do
    case Map.pop(gates(), op) do
      {nil, _rest} ->
        :ok

      {test_pid, rest} ->
        Application.put_env(:vagus, @key, rest)
        send(test_pid, {:gate_entered, op, self()})

        # Runs in the parked caller: exiting fails this test loudly instead of
        # leaving a request wedged for the serial modules after it.
        receive do
          :release -> :ok
        after
          10_000 -> exit({:gate_never_released, op})
        end
    end
  end

  @impl true
  def pull(spec) do
    gate(:pull)
    Fake.pull(spec)
  end

  @impl true
  def create(spec), do: Fake.create(spec)

  @impl true
  def start(id) do
    gate(:start)
    Fake.start(id)
  end

  @impl true
  def stop(id, opts \\ []), do: Fake.stop(id, opts)

  @impl true
  def remove(id, opts \\ []), do: Fake.remove(id, opts)

  @impl true
  def remove_image(image, opts \\ []), do: Fake.remove_image(image, opts)

  @impl true
  def state(id), do: Fake.state(id)
end

defmodule Vagus.AppCharacterisationTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  import Vagus.AppFixtures

  alias Vagus.Addon.Backend.Fake
  alias Vagus.Addon.{Config, Store}
  alias Vagus.API.{Router, Token}
  alias Vagus.AppCharacterisationTest.GatedBackend
  alias Vagus.Backups

  @opts Router.init([])

  setup do
    restore = fn key, prev ->
      if is_nil(prev),
        do: Application.delete_env(:vagus, key),
        else: Application.put_env(:vagus, key, prev)
    end

    prev_backend = Application.get_env(:vagus, :addon_backend)
    Application.put_env(:vagus, :addon_backend, GatedBackend)

    data_root =
      Path.join(System.tmp_dir!(), "vagus-app-char-#{System.unique_integer([:positive])}")

    prev_root = Application.get_env(:vagus, :addon_data_root)
    Application.put_env(:vagus, :addon_data_root, data_root)

    on_exit(fn ->
      GatedBackend.disarm_all()
      restore.(:addon_backend, prev_backend)
      restore.(:addon_data_root, prev_root)
      File.rm_rf(data_root)
    end)

    %{data_root: data_root}
  end

  defp config(slug, extra \\ %{}) do
    {:ok, config} =
      %{
        "name" => "Test App",
        "version" => "1.0.0",
        "slug" => slug,
        "description" => "d",
        "arch" => ["aarch64", "amd64"],
        "image" => "homeassistant/{arch}-app-test",
        "host_network" => true,
        "options" => %{"greeting" => "hi"},
        "schema" => %{"greeting" => "str"}
      }
      |> Map.merge(extra)
      |> Config.parse()

    config
  end

  defp seed_store(%Config{slug: slug} = config) do
    catalog = Map.put(Store.catalog(), slug, %{config: config, repository: "core"})
    :ok = GenServer.call(Store, {:put_catalog, catalog})

    on_exit(fn ->
      GenServer.call(Store, {:put_catalog, Map.delete(Store.catalog(), slug)})
    end)
  end

  defp supervisor_call(method, path, body \\ nil) do
    conn = conn(method, path, body && Jason.encode!(body))
    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

    conn
    |> put_req_header("authorization", "Bearer #{Token.get()}")
    |> Router.call(@opts)
  end

  defp app_call(method, path, token, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp capture_discovery_pushes do
    prev = Application.get_env(:vagus, :discovery_push)
    test_pid = self()

    Application.put_env(:vagus, :discovery_push, fn method, message ->
      send(test_pid, {:discovery_push, method, message})
      :ok
    end)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:vagus, :discovery_push),
        else: Application.put_env(:vagus, :discovery_push, prev)
    end)
  end

  # Upstream refuses with "App <name> is already installed" before any pull; a
  # re-pull would rewrite the entry as a fresh `:stopped` install.
  test "installing an app that is already installed answers 400 on both routes" do
    installed = install_app(config("core_char_reinstall"), state: :started)
    seed_store(installed)
    Fake.reset_calls()

    for path <- [
          "/store/addons/core_char_reinstall/install",
          "/addons/core_char_reinstall/install"
        ] do
      conn = supervisor_call(:post, path)

      assert {path, conn.status, body(conn)["result"], body(conn)["message"]} ==
               {path, 400, "error", "App Test App is already installed"}
    end

    assert {:ok, %{state: :started}} = app_info("core_char_reinstall")
    refute Enum.any?(Fake.calls_for("addon_core_char_reinstall"), &match?({:pull, _}, &1))
  end

  # The options write lands after the update captured the old entry; committing
  # that capture with the new config silently reverts the user's save.
  @tag :known_failing
  test "options saved while an update is pulling survive the update" do
    slug = "core_char_updopts"
    installed = install_app(config(slug), options: %{"greeting" => "old"})
    seed_store(%{installed | version: "2.0.0"})

    GatedBackend.arm(:pull)
    update = Task.async(fn -> supervisor_call(:post, "/store/addons/#{slug}/update", %{}) end)
    assert_receive {:gate_entered, :pull, puller}, 5_000

    options =
      Task.async(fn ->
        supervisor_call(:post, "/addons/#{slug}/options", %{"options" => %{"greeting" => "new"}})
      end)

    # Today the write answers while the pull is held; a fix that queues it behind
    # the update answers only after the release, so this bound must not fail.
    answered_while_held = Task.yield(options, 2_000)

    send(puller, :release)
    assert Task.await(update).status == 200

    conn =
      case answered_while_held do
        {:ok, conn} -> conn
        nil -> Task.await(options)
      end

    assert conn.status == 200

    assert {:ok, %{config: %{version: "2.0.0"}, user_options: %{"greeting" => "new"}}} =
             app_info(slug)
  end

  # Upstream only restarts an app the update stopped; a backup of an app that
  # was not running must not start it either.
  test "update with backup of a stopped cold app backs it up and leaves it stopped",
       %{data_root: data_root} do
    slug = "core_char_coldupd"
    prev_dir = Backups.dir()
    :ok = Backups.set_dir(Path.join(data_root, "backup"))
    on_exit(fn -> Backups.set_dir(prev_dir) end)

    installed = install_app(config(slug, %{"backup" => "cold"}))
    File.mkdir_p!(Path.join([data_root, "addons", "data", slug]))
    seed_store(%{installed | version: "2.0.0"})
    Fake.reset_calls()

    conn = supervisor_call(:post, "/store/addons/#{slug}/update", %{"backup" => true})
    assert conn.status == 200, conn.resp_body

    assert [%{backup: backup}] = Backups.list()
    assert backup["name"] == "addon_#{slug}_1.0.0"
    assert backup["type"] == "partial"
    assert Enum.map(backup["addons"], & &1["slug"]) == [slug]

    assert {:ok, %{state: :stopped, config: %{version: "2.0.0"}}} = app_info(slug)
    calls = Fake.calls_for("addon_#{slug}")
    assert {:pull, "addon_#{slug}"} in calls
    refute Enum.any?(calls, &match?({:start, _}, &1))
  end

  # Core keeps a config flow alive until it is told the discovery is gone;
  # dropping the entry locally only reaches Core at its next boot-time pull.
  @tag :known_failing
  test "uninstall pushes a discovery DELETE to Core for each message the app posted" do
    capture_discovery_pushes()
    slug = "core_char_disc"
    installed = install_app(config(slug, %{"discovery" => ["mqtt"]}), state: :started)
    token = register_app_token(installed)

    conn = app_call(:post, "/discovery", token, %{"service" => "mqtt", "config" => %{"a" => 1}})
    assert conn.status == 200
    uuid = body(conn)["data"]["uuid"]
    assert_receive {:discovery_push, :post, %{uuid: ^uuid}}

    assert supervisor_call(:post, "/addons/#{slug}/uninstall").status == 200
    assert_receive {:discovery_push, :delete, %{uuid: ^uuid}}, 1_000
  end

  # Upstream's per-app job group rejects a second lifecycle job outright;
  # today it queues behind Manager's lock and then runs a second start.
  @tag :known_failing
  test "a start issued while a start is running answers 400 without waiting" do
    slug = "core_char_dblstart"
    install_app(config(slug))

    GatedBackend.arm(:start)
    first = Task.async(fn -> supervisor_call(:post, "/addons/#{slug}/start") end)
    assert_receive {:gate_entered, :start, starter}, 5_000

    second = Task.async(fn -> supervisor_call(:post, "/addons/#{slug}/start") end)
    # Only bounds the failure: the intended reply never waits on the first start.
    answered_while_held = Task.yield(second, 2_000)

    # Released before any assert so a still-parked second start can finish.
    send(starter, :release)
    assert Task.await(first).status == 200

    {held?, conn} =
      case answered_while_held do
        {:ok, conn} -> {true, conn}
        nil -> {false, Task.await(second)}
      end

    assert {held?, conn.status, body(conn)["message"]} ==
             {true, 400, "Another job is running for job group app_" <> slug}
  end
end
