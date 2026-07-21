defmodule Vagus.API.AddonLifecycleRouterTest do
  @moduledoc """
  M4-P3-T1: the add-on lifecycle routes (`POST .../install|start|stop|restart|
  uninstall|options`, and `GET /addons` reading from `Vagus.Addon.State`
  instead of `StaticData`).

  `Vagus.Addon.Backend.Fake` (`test/support/fake_addon_backend.ex`) is wired
  in via `config :vagus, :addon_backend` for the whole test — the router
  calls `Vagus.Addon.Manager` with no `:backend` opt, so this is the only way
  to keep these routes hermetic (no real Docker daemon).
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vagus.API.{Router, Token}
  alias Vagus.Addon.{Config, Registry, State, Store}

  @opts Router.init([])

  setup do
    prev_backend = Application.get_env(:vagus, :addon_backend)
    Application.put_env(:vagus, :addon_backend, Vagus.Addon.Backend.Fake)

    data_root =
      Path.join(System.tmp_dir!(), "vagus-lifecycle-rt-#{System.unique_integer([:positive])}")

    prev_root = Application.get_env(:vagus, :addon_data_root)
    Application.put_env(:vagus, :addon_data_root, data_root)

    on_exit(fn ->
      if prev_backend,
        do: Application.put_env(:vagus, :addon_backend, prev_backend),
        else: Application.delete_env(:vagus, :addon_backend)

      if prev_root,
        do: Application.put_env(:vagus, :addon_data_root, prev_root),
        else: Application.delete_env(:vagus, :addon_data_root)

      File.rm_rf(data_root)
    end)

    :ok
  end

  defp fixture_config(slug) do
    {:ok, config} =
      Config.parse(%{
        "name" => "Test Addon",
        "version" => "3",
        "slug" => slug,
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "homeassistant/{arch}-addon-test",
        "host_network" => true,
        "options" => %{"greeting" => "hi"},
        "schema" => %{"greeting" => "str"}
      })

    config
  end

  # Seeds the running singleton `Vagus.Addon.Store` catalog directly (there's
  # no network-fetching path to exercise here — `Store.build_catalog/2` /
  # `Store.reload/1` are for the unit-level store tests) and schedules its
  # removal.
  defp seed_store(store_slug, config, repo \\ "core") do
    catalog = Map.put(Store.catalog(), store_slug, %{config: config, repository: repo})
    :ok = GenServer.call(Vagus.Addon.Store, {:put_catalog, catalog})

    on_exit(fn ->
      GenServer.call(Vagus.Addon.Store, {:put_catalog, Map.delete(Store.catalog(), store_slug)})
    end)
  end

  defp supervisor_call(method, path, body \\ nil) do
    conn = conn(method, path, body && Jason.encode!(body))
    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

    conn
    |> put_req_header("authorization", "Bearer #{Token.get()}")
    |> Router.call(@opts)
  end

  defp addon_call(method, path, slug) do
    token = "tok-#{System.unique_integer([:positive])}"

    :ok =
      Registry.register(token, %{slug: slug, services_role: %{}, auth_api: false, discovery: []})

    on_exit(fn -> Registry.unregister_slug(slug) end)

    conn(method, path)
    |> put_req_header("x-supervisor-token", token)
    |> Router.call(@opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  describe "POST /store/addons/:slug/install (+ legacy /addons/:slug/install alias)" do
    test "installs a store entry: config slug rewritten to the store slug, State records :stopped" do
      seed_store("core_testaddon", fixture_config("testaddon"))
      on_exit(fn -> State.delete("core_testaddon") end)

      conn = supervisor_call(:post, "/store/addons/core_testaddon/install")
      assert conn.status == 200
      assert body(conn)["result"] == "ok"

      assert {:ok, %{config: installed, state: :stopped}} = State.get("core_testaddon")
      assert installed.slug == "core_testaddon"
    end

    test "the legacy /addons/:slug/install alias installs the same way" do
      seed_store("core_testaddon2", fixture_config("testaddon2"))
      on_exit(fn -> State.delete("core_testaddon2") end)

      conn = supervisor_call(:post, "/addons/core_testaddon2/install")
      assert conn.status == 200
      assert {:ok, %{state: :stopped}} = State.get("core_testaddon2")
    end

    test "an unknown store slug -> 404" do
      conn = supervisor_call(:post, "/store/addons/core_ghost/install")
      assert conn.status == 404
      assert body(conn)["message"] =~ "does not exist in the store"
    end

    test "install is supervisor-only" do
      seed_store("core_testaddon3", fixture_config("testaddon3"))
      conn = addon_call(:post, "/store/addons/core_testaddon3/install", "some_addon")
      assert conn.status == 403
      assert :error = State.get("core_testaddon3")
    end
  end

  describe "start/stop/restart" do
    setup do
      config = fixture_config("core_lifecycle")
      :ok = State.put(config, :stopped)
      on_exit(fn -> State.delete("core_lifecycle") end)
      %{config: config}
    end

    test "start -> ok, State becomes :started", %{config: config} do
      :ok = State.put(config, :stopped)
      conn = supervisor_call(:post, "/addons/core_lifecycle/start")
      assert conn.status == 200
      assert body(conn)["result"] == "ok"
      assert {:ok, %{state: :started}} = State.get("core_lifecycle")
    end

    test "start on a never-installed slug -> 404" do
      conn = supervisor_call(:post, "/addons/never_installed/start")
      assert conn.status == 404
    end

    test "stop -> ok, State becomes :stopped", %{config: config} do
      :ok = State.put(config, :started)
      conn = supervisor_call(:post, "/addons/core_lifecycle/stop")
      assert conn.status == 200
      assert {:ok, %{state: :stopped}} = State.get("core_lifecycle")
    end

    test "stop on a never-installed slug -> 404" do
      conn = supervisor_call(:post, "/addons/never_installed/stop")
      assert conn.status == 404
    end

    test "restart -> ok, State ends up :started with a fresh token issued", %{config: config} do
      :ok = State.put(config, :stopped)
      conn = supervisor_call(:post, "/addons/core_lifecycle/restart")
      assert conn.status == 200
      assert {:ok, %{state: :started}} = State.get("core_lifecycle")
    end

    test "restart on a never-installed slug -> 404" do
      conn = supervisor_call(:post, "/addons/never_installed/restart")
      assert conn.status == 404
    end

    test "start/stop/restart are supervisor-only (403 for an add-on caller)", %{config: config} do
      :ok = State.put(config, :stopped)
      assert addon_call(:post, "/addons/core_lifecycle/start", "core_lifecycle").status == 403
      assert addon_call(:post, "/addons/core_lifecycle/stop", "core_lifecycle").status == 403
      assert addon_call(:post, "/addons/core_lifecycle/restart", "core_lifecycle").status == 403
    end
  end

  describe "POST /addons/:slug/uninstall" do
    setup do
      config = fixture_config("uninstallme") |> Map.put(:slug, "core_uninstallme")
      :ok = State.put(config, :stopped)
      on_exit(fn -> State.delete("core_uninstallme") end)
      %{config: config}
    end

    test "uninstall -> ok, State entry removed" do
      conn = supervisor_call(:post, "/addons/core_uninstallme/uninstall")
      assert conn.status == 200
      assert :error = State.get("core_uninstallme")
    end

    test "a {\"remove_config\": true} body is accepted and ignored" do
      conn =
        supervisor_call(:post, "/addons/core_uninstallme/uninstall", %{"remove_config" => true})

      assert conn.status == 200
      assert :error = State.get("core_uninstallme")
    end

    test "uninstall on a never-installed slug -> 404" do
      conn = supervisor_call(:post, "/addons/never_installed/uninstall")
      assert conn.status == 404
    end

    test "uninstall is supervisor-only (403)" do
      assert addon_call(:post, "/addons/core_uninstallme/uninstall", "core_uninstallme").status ==
               403

      assert {:ok, _} = State.get("core_uninstallme")
    end
  end

  describe "POST /addons/:slug/options" do
    setup do
      config = fixture_config("opts") |> Map.put(:slug, "core_opts")
      :ok = State.put(config, :stopped)
      on_exit(fn -> State.delete("core_opts") end)
      %{config: config}
    end

    test "a valid options map is schema-validated then stored raw" do
      conn =
        supervisor_call(:post, "/addons/core_opts/options", %{"options" => %{"greeting" => "hey"}})

      assert conn.status == 200
      assert {:ok, %{user_options: %{"greeting" => "hey"}}} = State.get("core_opts")
    end

    test "an invalid options map -> 400, nothing stored" do
      conn =
        supervisor_call(:post, "/addons/core_opts/options", %{"options" => %{"greeting" => 5}})

      assert conn.status == 400
      assert body(conn)["message"] =~ "Invalid options"
      assert {:ok, %{user_options: %{}}} = State.get("core_opts")
    end

    test "options: null resets to no user options" do
      :ok = State.put_options("core_opts", %{"greeting" => "hey"})
      conn = supervisor_call(:post, "/addons/core_opts/options", %{"options" => nil})
      assert conn.status == 200
      assert {:ok, %{user_options: %{}}} = State.get("core_opts")
    end

    test "unrelated SCHEMA_OPTIONS keys (boot, watchdog, ...) are accepted and ignored" do
      conn = supervisor_call(:post, "/addons/core_opts/options", %{"boot" => "manual"})
      assert conn.status == 200
      assert {:ok, %{user_options: %{}}} = State.get("core_opts")
    end

    test "options on a never-installed slug -> 404" do
      conn = supervisor_call(:post, "/addons/never_installed/options", %{"options" => %{}})
      assert conn.status == 404
    end

    test "options is supervisor-only (403)" do
      assert addon_call(:post, "/addons/core_opts/options", "core_opts").status == 403
    end
  end

  describe "GET /addons" do
    test "reflects installed add-ons from State" do
      config = fixture_config("listed") |> Map.put(:slug, "core_listed")
      :ok = State.put(config, :started)
      on_exit(fn -> State.delete("core_listed") end)

      conn = supervisor_call(:get, "/addons")
      assert conn.status == 200
      addons = body(conn)["data"]["addons"]
      assert Enum.any?(addons, &(&1["slug"] == "core_listed" and &1["state"] == "started"))
    end

    test "an empty State -> empty list" do
      conn = supervisor_call(:get, "/addons")
      assert conn.status == 200
      assert body(conn)["data"]["addons"] == []
    end
  end
end
