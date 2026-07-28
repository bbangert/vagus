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

  alias Vagus.Addon.{Config, Registry, State, Store}
  alias Vagus.API.{Router, Token}

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

  describe "POST /addons/:slug/options with a network key (the Network card)" do
    # The card posts to the same options endpoint. `network` used to land in
    # the accept-and-ignore bucket with the unmodeled SCHEMA_OPTIONS keys, so
    # the save returned 200 and the port never moved.
    setup do
      {:ok, config} =
        Config.parse(%{
          "name" => "Test Addon",
          "version" => "3",
          "slug" => "core_netopts",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "homeassistant/{arch}-addon-test",
          "ports" => %{"22/tcp" => nil, "80/tcp" => 8080}
        })

      :ok = State.put(config, :stopped)
      on_exit(fn -> State.delete("core_netopts") end)
      %{config: config}
    end

    test "a posted port is persisted and reported back as the effective map" do
      conn =
        supervisor_call(:post, "/addons/core_netopts/options", %{
          "network" => %{"22/tcp" => 2222, "80/tcp" => 8080}
        })

      assert conn.status == 200
      assert {:ok, %{ports: %{"22/tcp" => 2222}}} = State.get("core_netopts")

      # The info payload is what the card re-renders from — a default here
      # would look to the user like the save silently reverted.
      info = body(supervisor_call(:get, "/addons/core_netopts/info"))["data"]
      assert info["network"] == %{"22/tcp" => 2222, "80/tcp" => 8080}
    end

    test "network: null resets to the config's declared defaults" do
      :ok = State.put_setting("core_netopts", :ports, %{"22/tcp" => 2222})

      conn = supervisor_call(:post, "/addons/core_netopts/options", %{"network" => nil})

      assert conn.status == 200
      assert {:ok, %{ports: %{}}} = State.get("core_netopts")

      info = body(supervisor_call(:get, "/addons/core_netopts/info"))["data"]
      assert info["network"] == %{"22/tcp" => nil, "80/tcp" => 8080}
    end

    test "a value that isn't a port is a 400, and nothing is written" do
      conn =
        supervisor_call(:post, "/addons/core_netopts/options", %{
          "network" => %{"22/tcp" => "2222"}
        })

      assert conn.status == 400
      assert body(conn)["message"] =~ "22/tcp"
      assert {:ok, %{ports: %{}}} = State.get("core_netopts")
    end

    test "a bad network key rejects the whole body — options must not half-apply" do
      conn =
        supervisor_call(:post, "/addons/core_netopts/options", %{
          "options" => %{"greeting" => "hey"},
          "network" => %{"22/tcp" => "nope"}
        })

      assert conn.status == 400
      assert {:ok, %{user_options: %{}, ports: %{}}} = State.get("core_netopts")
    end
  end

  describe "POST /addons/:slug/options/validate" do
    # The config page pre-flights every save through this and throws on
    # anything but `valid: true`, so a missing route makes Save fail for every
    # add-on regardless of what the options endpoint does.
    setup do
      config = fixture_config("vopts") |> Map.put(:slug, "core_vopts")
      :ok = State.put(config, :stopped)
      on_exit(fn -> State.delete("core_vopts") end)
      %{config: config}
    end

    test "valid options report valid: true with an empty message" do
      conn =
        supervisor_call(:post, "/addons/core_vopts/options/validate", %{"greeting" => "hey"})

      assert conn.status == 200
      assert body(conn)["data"] == %{"valid" => true, "message" => "", "pwned" => false}
    end

    test "invalid options are a 200 with valid: false, not an error status" do
      # Upstream returns the verdict as data; a non-200 would surface in the
      # frontend as a transport failure rather than a validation message.
      conn = supervisor_call(:post, "/addons/core_vopts/options/validate", %{"greeting" => 5})

      assert conn.status == 200
      data = body(conn)["data"]
      assert data["valid"] == false
      assert data["message"] != ""
      assert data["pwned"] == false
    end

    test "the body is the options map itself, not wrapped in an options key" do
      # The *save* shape, carrying an inner value this schema rejects. Read
      # directly (upstream's behaviour) the outer "options" key is unknown and
      # dropped, the defaults stand, and the verdict is `true`. A handler that
      # unwrapped `"options"` would see `greeting: 5` and answer `false` — so
      # `true` here is what proves the body is taken as-is.
      conn =
        supervisor_call(:post, "/addons/core_vopts/options/validate", %{
          "options" => %{"greeting" => 5}
        })

      assert conn.status == 200
      assert body(conn)["data"]["valid"] == true
    end

    test "an empty body validates the add-on's stored options" do
      conn = supervisor_call(:post, "/addons/core_vopts/options/validate", %{})

      assert conn.status == 200
      assert body(conn)["data"]["valid"] == true
    end

    test "the verdict matches what the save path actually does" do
      # The two must never disagree: a `valid: true` followed by a 400 on save
      # is exactly the failure this endpoint exists to prevent.
      for options <- [%{"greeting" => "hey"}, %{"greeting" => 5}] do
        verdict =
          body(supervisor_call(:post, "/addons/core_vopts/options/validate", options))["data"][
            "valid"
          ]

        saved =
          supervisor_call(:post, "/addons/core_vopts/options", %{"options" => options}).status ==
            200

        assert verdict == saved
      end
    end

    test "a never-installed slug is a 404" do
      conn = supervisor_call(:post, "/addons/never_installed/options/validate", %{})
      assert conn.status == 404
    end

    test "an add-on caller is refused with 403" do
      conn = addon_call(:post, "/addons/core_vopts/options/validate", "some_other_addon")
      assert conn.status == 403
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

    test "a saved option is what the info payload reports back" do
      # The Configuration page re-renders from `info.options` the moment a
      # save returns. Reporting the config defaults here is what made a saved
      # password look like it had cleared itself — the value was in State the
      # whole time.
      assert supervisor_call(:post, "/addons/core_opts/options", %{
               "options" => %{"greeting" => "secret-value"}
             }).status == 200

      info = body(supervisor_call(:get, "/addons/core_opts/info"))["data"]
      assert info["options"]["greeting"] == "secret-value"

      # ...and through the list route, which renders by a different path.
      listed =
        body(supervisor_call(:get, "/addons"))["data"]["addons"]
        |> Enum.find(&(&1["slug"] == "core_opts"))

      assert listed["options"]["greeting"] == "secret-value"
    end

    test "options the user never touched keep their config defaults" do
      {:ok, config} =
        Config.parse(%{
          "name" => "Test Addon",
          "version" => "3",
          "slug" => "core_partialopts",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "homeassistant/{arch}-addon-test",
          "options" => %{"greeting" => "hi", "untouched" => true},
          "schema" => %{"greeting" => "str", "untouched" => "bool"}
        })

      :ok = State.put(config, :stopped)
      on_exit(fn -> State.delete("core_partialopts") end)

      assert supervisor_call(:post, "/addons/core_partialopts/options", %{
               "options" => %{"greeting" => "hey"}
             }).status == 200

      info = body(supervisor_call(:get, "/addons/core_partialopts/info"))["data"]
      assert info["options"] == %{"greeting" => "hey", "untouched" => true}
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

    test "watchdog: true is persisted" do
      conn = supervisor_call(:post, "/addons/core_opts/options", %{"watchdog" => true})
      assert conn.status == 200
      assert {:ok, %{watchdog: true}} = State.get("core_opts")
    end

    test "watchdog: false is persisted" do
      :ok = State.put_setting("core_opts", :watchdog, true)
      conn = supervisor_call(:post, "/addons/core_opts/options", %{"watchdog" => false})
      assert conn.status == 200
      assert {:ok, %{watchdog: false}} = State.get("core_opts")
    end

    test "watchdog: true on a startup: once add-on is silently ignored (200, stays false)" do
      config = fixture_config("once") |> Map.put(:slug, "core_once") |> Map.put(:startup, "once")
      :ok = State.put(config, :stopped)
      on_exit(fn -> State.delete("core_once") end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = supervisor_call(:post, "/addons/core_once/options", %{"watchdog" => true})
          assert conn.status == 200
        end)

      assert log =~ "ignoring watchdog=true"
      assert {:ok, %{watchdog: false}} = State.get("core_once")
    end

    test "ingress_panel is persisted" do
      conn = supervisor_call(:post, "/addons/core_opts/options", %{"ingress_panel" => true})
      assert conn.status == 200
      assert {:ok, %{ingress_panel: true}} = State.get("core_opts")
    end

    test "a non-boolean watchdog -> 400, nothing persisted" do
      conn = supervisor_call(:post, "/addons/core_opts/options", %{"watchdog" => "yes"})
      assert conn.status == 400
      assert body(conn)["message"] =~ "watchdog must be a boolean"
      assert {:ok, %{watchdog: false}} = State.get("core_opts")
    end

    test "a non-boolean ingress_panel -> 400, nothing persisted" do
      conn = supervisor_call(:post, "/addons/core_opts/options", %{"ingress_panel" => "yes"})
      assert conn.status == 400
      assert body(conn)["message"] =~ "ingress_panel must be a boolean"
      assert {:ok, %{ingress_panel: false}} = State.get("core_opts")
    end

    test "a body with only watchdog (no options key) succeeds" do
      conn = supervisor_call(:post, "/addons/core_opts/options", %{"watchdog" => true})
      assert conn.status == 200
      assert {:ok, %{watchdog: true, user_options: %{}}} = State.get("core_opts")
    end

    test "a bad watchdog alongside a valid options map -> 400, options NOT applied" do
      conn =
        supervisor_call(:post, "/addons/core_opts/options", %{
          "watchdog" => "yes",
          "options" => %{"greeting" => "hey"}
        })

      assert conn.status == 400
      assert {:ok, %{user_options: %{}, watchdog: false}} = State.get("core_opts")
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
      # `Vagus.Addon.State` is a global singleton other tests seed; this file is
      # async: false, so nothing runs concurrently and we can reset it to a
      # genuinely empty state here rather than assuming a stale entry from an
      # earlier test isn't lingering (the source of a rare CI flake). `delete/1`
      # is pure state removal — no backend call.
      for %{config: %{slug: slug}} <- State.list(), do: State.delete(slug)

      conn = supervisor_call(:get, "/addons")
      assert conn.status == 200
      assert body(conn)["data"]["addons"] == []
    end
  end

  describe "GET /addons/:slug/info falls back to the store (V1 legacy routing)" do
    # This one endpoint backs BOTH add-on pages in the frontend: opening a card
    # from the store navigates to `/config/app/{slug}/info?store=true`, whose
    # only fetch is this route. 404 here means every store card opens an
    # "Error loading app" screen. Upstream serves it with a V1-only shim
    # (`api/__init__.py::apps_app_info`) that falls through to the store detail
    # payload plus `state`/`options`.

    test "an uninstalled store add-on returns its store detail, not a 404" do
      config = fixture_config("browsable")
      seed_store("core_browsable", config)

      conn = supervisor_call(:get, "/addons/core_browsable/info")
      assert conn.status == 200

      info = json(conn)["data"]
      assert info["slug"] == "core_browsable"
      assert info["name"] == config.name
      assert info["installed"] == false
      assert info["version_latest"] == config.version

      # The field the page switches on: nil means "not installed", which is
      # what makes it render the Install button instead of the controls card.
      assert info["version"] == nil

      # The two fields the store shape doesn't carry, grafted on by the shim.
      assert info["state"] == "unknown"
      assert info["options"] == config.options

      # Store-detail extras the info page renders.
      assert info["detached"] == false
      assert Map.has_key?(info, "hassio_role")
    end

    test "an installed add-on still gets the installed shape, not the store's" do
      config = fixture_config("realinstall")
      seed_store("core_realinstall", config)
      assert supervisor_call(:post, "/store/addons/core_realinstall/install").status == 200

      info = json(supervisor_call(:get, "/addons/core_realinstall/info"))["data"]
      assert info["state"] == "stopped"
      # `hostname` only exists on the installed shape — proof of which branch ran.
      assert info["hostname"] == "core-realinstall"
    end

    test "a slug in neither the store nor the install set is still a 404" do
      conn = supervisor_call(:get, "/addons/core_nowhere/info")
      assert conn.status == 404
      assert json(conn)["result"] == "error"
    end
  end

  describe "version tracking on the wire (P2-A P2)" do
    # Before this phase, `version`, `version_latest` and `update_available`
    # were hardcoded (version == version_latest, update_available always
    # false), so the frontend's update button could never appear.

    test "a store version bump makes update_available true without touching the install" do
      installed = fixture_config("verbump")
      seed_store("core_verbump", installed)

      conn = supervisor_call(:post, "/store/addons/core_verbump/install")
      assert conn.status == 200

      # Installed and store agree: nothing to update.
      before = json(supervisor_call(:get, "/store/addons/core_verbump"))["data"]
      assert before["version"] == installed.version
      assert before["version_latest"] == installed.version
      assert before["update_available"] == false

      # The repository publishes a new version. Only the catalog moves.
      seed_store("core_verbump", %{installed | version: "9.9.9"})

      after_bump = json(supervisor_call(:get, "/store/addons/core_verbump"))["data"]
      assert after_bump["version"] == installed.version
      assert after_bump["version_latest"] == "9.9.9"
      assert after_bump["update_available"] == true

      # The installed add-on's own info route agrees.
      info = json(supervisor_call(:get, "/addons/core_verbump/info"))["data"]
      assert info["version"] == installed.version
      assert info["version_latest"] == "9.9.9"
      assert info["update_available"] == true

      # And so does the list route, which renders through a different path.
      listed =
        json(supervisor_call(:get, "/store/addons"))["data"]["addons"]
        |> Enum.find(&(&1["slug"] == "core_verbump"))

      assert listed["version"] == installed.version
      assert listed["version_latest"] == "9.9.9"
      assert listed["update_available"] == true
    end

    test "an add-on detached from the store reports no update, not an error" do
      installed = fixture_config("detached")
      seed_store("core_detached", installed)
      assert supervisor_call(:post, "/store/addons/core_detached/install").status == 200

      # First move the store ahead, so the "no update" below can only be
      # caused by detachment — not by the store happening to match.
      seed_store("core_detached", %{installed | version: "9.9.9"})
      bumped = json(supervisor_call(:get, "/addons/core_detached/info"))["data"]
      assert bumped["version_latest"] == "9.9.9"
      assert bumped["update_available"] == true

      # The repository drops it entirely — installed, but no store entry.
      :ok = GenServer.call(Store, {:put_catalog, Map.delete(Store.catalog(), "core_detached")})

      info = json(supervisor_call(:get, "/addons/core_detached/info"))["data"]
      assert info["version"] == installed.version
      assert info["version_latest"] == installed.version
      assert info["update_available"] == false
    end

    test "a real stop/start never adopts the store's version" do
      # THE test standing in for the dropped `installed_version` field.
      #
      # Deriving the installed version from `entry.config.version` is only
      # safe while no lifecycle path re-reads config from the store catalog.
      # Asserting that by calling `State.put/3` by hand proves nothing about
      # `Manager` — so this drives the REAL routes, with the store parked on
      # a different version than the install, and checks what got persisted.
      # Rewire `Manager.do_start_slug/2` to source config from `Store` and
      # this fails; the hand-driven `State` tests would not notice.
      installed = fixture_config("lifecycleversion")
      seed_store("core_lifecycleversion", installed)
      assert supervisor_call(:post, "/store/addons/core_lifecycleversion/install").status == 200

      seed_store("core_lifecycleversion", %{installed | version: "9.9.9"})

      assert supervisor_call(:post, "/addons/core_lifecycleversion/stop").status == 200
      assert {:ok, %{config: %{version: after_stop}}} = State.get("core_lifecycleversion")
      assert after_stop == installed.version

      assert supervisor_call(:post, "/addons/core_lifecycleversion/start").status == 200
      assert {:ok, %{config: %{version: after_start}}} = State.get("core_lifecycleversion")
      assert after_start == installed.version

      # ...and the wire still separates the two cleanly.
      info = json(supervisor_call(:get, "/addons/core_lifecycleversion/info"))["data"]
      assert info["version"] == installed.version
      assert info["version_latest"] == "9.9.9"
      assert info["update_available"] == true
    end

    test "an uninstalled store entry has no version, only a version_latest" do
      config = fixture_config("notinstalled")
      seed_store("core_notinstalled", config)

      data = json(supervisor_call(:get, "/store/addons/core_notinstalled"))["data"]

      assert data["installed"] == false
      # This used to assert `version == version_latest`, which matched the
      # implementation and broke the UI: the frontend's add-on page treats a
      # non-nil `version` as "installed" and renders the controls card instead
      # of the Install button. Upstream sends `installed.version if installed
      # else None`.
      assert data["version"] == nil
      assert data["version_latest"] == config.version
      assert data["update_available"] == false
    end
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  describe "POST .../update (P2-A P3)" do
    test "updates an installed add-on and reports the new version on the wire" do
      installed = fixture_config("updrt")
      seed_store("core_updrt", installed)
      assert supervisor_call(:post, "/store/addons/core_updrt/install").status == 200

      seed_store("core_updrt", %{installed | version: "9.9.9"})

      conn = supervisor_call(:post, "/store/addons/core_updrt/update", %{})
      assert conn.status == 200

      info = json(supervisor_call(:get, "/addons/core_updrt/info"))["data"]
      assert info["version"] == "9.9.9"
      assert info["update_available"] == false
    end

    test "the legacy /addons/... alias and the ignored /version segment both work" do
      # The legacy `/addons/...` alias has no `/version` form — only the
      # `/store/addons/...` path does, matching upstream's route table.
      for {slug, path} <- [
            {"core_updalias", "/addons/core_updalias/update"},
            {"core_updver", "/store/addons/core_updver/update/1.2.3"}
          ] do
        installed = fixture_config(slug)
        seed_store(slug, installed)
        assert supervisor_call(:post, "/store/addons/#{slug}/install").status == 200
        seed_store(slug, %{installed | version: "9.9.9"})

        # Upstream registers `/update/{version}` and never reads the segment —
        # it always goes to the store's current version, which is what the
        # 9.9.9 assertion below pins.
        conn = supervisor_call(:post, path, %{})
        assert conn.status == 200

        assert json(supervisor_call(:get, "/addons/#{slug}/info"))["data"]["version"] == "9.9.9"
      end
    end

    test "background: true is refused honestly rather than faked" do
      installed = fixture_config("updbg")
      seed_store("core_updbg", installed)
      assert supervisor_call(:post, "/store/addons/core_updbg/install").status == 200
      seed_store("core_updbg", %{installed | version: "9.9.9"})

      conn = supervisor_call(:post, "/store/addons/core_updbg/update", %{"background" => true})

      assert conn.status == 400
      assert json(conn)["message"] =~ "background"
      # Refused BEFORE doing anything: still on the old version.
      assert json(supervisor_call(:get, "/addons/core_updbg/info"))["data"]["version"] ==
               installed.version
    end

    test "background: false and an absent body both proceed" do
      installed = fixture_config("updbgfalse")
      seed_store("core_updbgfalse", installed)
      assert supervisor_call(:post, "/store/addons/core_updbgfalse/install").status == 200
      seed_store("core_updbgfalse", %{installed | version: "9.9.9"})

      conn =
        supervisor_call(:post, "/store/addons/core_updbgfalse/update", %{"background" => false})

      assert conn.status == 200
    end

    test "unknown body keys are ignored (aiohttp tolerance)" do
      installed = fixture_config("updunknown")
      seed_store("core_updunknown", installed)
      assert supervisor_call(:post, "/store/addons/core_updunknown/install").status == 200
      seed_store("core_updunknown", %{installed | version: "9.9.9"})

      conn =
        supervisor_call(:post, "/store/addons/core_updunknown/update", %{"nonsense" => "ignored"})

      assert conn.status == 200
    end

    test "an add-on with no update available is a 400, not a silent success" do
      installed = fixture_config("updsame")
      seed_store("core_updsame", installed)
      assert supervisor_call(:post, "/store/addons/core_updsame/install").status == 200

      conn = supervisor_call(:post, "/store/addons/core_updsame/update", %{})

      assert conn.status == 400
      assert json(conn)["message"] =~ "No update available"
    end

    test "an uninstalled slug is 404" do
      seed_store("core_updghost", fixture_config("updghost"))

      conn = supervisor_call(:post, "/store/addons/core_updghost/update", %{})

      assert conn.status == 404
      assert json(conn)["message"] =~ "not installed"
    end

    test "a detached add-on is 404, naming the store rather than the install" do
      installed = fixture_config("upddetached")
      seed_store("core_upddetached", installed)
      assert supervisor_call(:post, "/store/addons/core_upddetached/install").status == 200
      :ok = GenServer.call(Store, {:put_catalog, Map.delete(Store.catalog(), "core_upddetached")})

      conn = supervisor_call(:post, "/store/addons/core_upddetached/update", %{})

      assert conn.status == 404
      assert json(conn)["message"] =~ "no longer available in the store"
    end

    test "a non-supervisor caller is refused" do
      conn =
        :post
        |> conn("/store/addons/core_whatever/update", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 401
    end
  end
end
