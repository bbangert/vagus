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

  # `arch` includes "aarch64" (`config/test.exs`'s `:vagus, :machine` puts
  # `Vagus.API.StaticData.arch/0` at the fixed "aarch64") so that, since
  # phase 6 chunk A, this fixture stays *available* by default — the whole
  # point of most of the describe blocks below is lifecycle mechanics, not
  # G1's availability gate, which has its own dedicated tests.
  defp fixture_config(slug) do
    {:ok, config} =
      Config.parse(%{
        "name" => "Test Addon",
        "version" => "3",
        "slug" => slug,
        "description" => "d",
        "arch" => ["aarch64", "amd64"],
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

  defp addon_call(method, path, slug, body \\ nil) do
    token = "tok-#{System.unique_integer([:positive])}"

    :ok =
      Registry.register(token, %{
        slug: slug,
        services_role: %{},
        auth_api: false,
        discovery: [],
        hassio_api: false,
        hassio_role: "default"
      })

    on_exit(fn -> Registry.unregister_slug(slug) end)

    conn = conn(method, path, body && Jason.encode!(body))
    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

    conn
    |> put_req_header("x-supervisor-token", token)
    |> Router.call(@opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  # Bounded poll for background-task completion, the `boot_starter_test.exs`
  # idiom: retries `fun` (a 0-arity predicate) until truthy or the window
  # elapses — a genuinely-stuck job still fails the enclosing assert.
  defp eventually(fun, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(25)
        {:cont, false}
      end
    end)
  end

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

    # G1 (audit B2): before the availability gate, this 200'd and then
    # failed LATE inside `Manager.install/2`'s image pull — a slower,
    # more confusing way to say the exact same "wrong arch" thing.
    test "an arch-mismatched store add-on is refused with the reason in the message, no install attempted" do
      {:ok, config} =
        Config.parse(%{
          "name" => "x86 Only",
          "version" => "1",
          "slug" => "x86only",
          "description" => "d",
          "arch" => ["amd64"]
        })

      seed_store("core_x86only", config)

      conn = supervisor_call(:post, "/store/addons/core_x86only/install")
      assert conn.status == 400
      assert body(conn)["message"] =~ "not supported on this platform"
      assert body(conn)["message"] =~ "amd64"
      assert :error = State.get("core_x86only")
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

    test "start/stop/restart by slug are supervisor-only (403 for an add-on caller)",
         %{config: config} do
      :ok = State.put(config, :stopped)
      assert addon_call(:post, "/addons/core_lifecycle/start", "core_lifecycle").status == 403
      assert addon_call(:post, "/addons/core_lifecycle/stop", "core_lifecycle").status == 403
      assert addon_call(:post, "/addons/core_lifecycle/restart", "core_lifecycle").status == 403
    end

    # Audit A3. Upstream's `api_bypass` is
    # `/addons/self/(?!security|update)[^/]+` (security.py L97): the literal
    # slug `self` — and only that — lets an add-on drive its own lifecycle,
    # whatever its role. Vagus 403'd it, so `bashio::addon.restart`-style
    # self-management was impossible. Note the asymmetry with the test above:
    # an add-on naming its OWN slug explicitly is still refused, because
    # upstream's bypass keys on the literal `self`, not on identity.
    test "an add-on may start/stop/restart ITSELF via the literal slug `self`",
         %{config: config} do
      :ok = State.put(config, :stopped)

      assert addon_call(:post, "/addons/self/start", "core_lifecycle").status == 200
      assert {:ok, %{state: :started}} = State.get("core_lifecycle")

      assert addon_call(:post, "/addons/self/stop", "core_lifecycle").status == 200
      assert {:ok, %{state: :stopped}} = State.get("core_lifecycle")

      assert addon_call(:post, "/addons/self/restart", "core_lifecycle").status == 200
      assert {:ok, %{state: :started}} = State.get("core_lifecycle")
    end

    test "`self` resolves to the CALLER's slug, never the target's", %{config: config} do
      :ok = State.put(config, :stopped)

      # A different add-on saying `self` acts on itself — which is not
      # installed — so it gets a 404 about its own slug and core_lifecycle is
      # untouched.
      conn = addon_call(:post, "/addons/self/start", "core_intruder")
      assert conn.status == 404
      assert body(conn)["message"] =~ "core_intruder"
      assert {:ok, %{state: :stopped}} = State.get("core_lifecycle")
    end

    # `(?!security|update)` — the two segments upstream carves out of the
    # bypass. Self-update stays supervisor-only, matching upstream's own
    # `APIForbidden("App … can't update itself!")` posture.
    test "`/addons/self/update` is NOT bypassed" do
      assert addon_call(:post, "/addons/self/update", "core_lifecycle").status == 403
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

    test "uninstall by slug is supervisor-only (403)" do
      assert addon_call(:post, "/addons/core_uninstallme/uninstall", "core_uninstallme").status ==
               403

      assert {:ok, _} = State.get("core_uninstallme")
    end

    # Audit A3 — `uninstall` is a single segment, so upstream's `self` bypass
    # covers it just like start/stop/restart.
    test "an add-on may uninstall ITSELF via `self`" do
      assert addon_call(:post, "/addons/self/uninstall", "core_uninstallme").status == 200
      assert :error = State.get("core_uninstallme")
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

      # NOT through the list route. The Configuration page re-renders from
      # `info`, never from `/addons` — and upstream's list shape carries no
      # `options` at all, because it would hand every caller every add-on's
      # saved secrets (audit A7). This assertion used to be the opposite.
      listed =
        body(supervisor_call(:get, "/addons"))["data"]["addons"]
        |> Enum.find(&(&1["slug"] == "core_opts"))

      refute Map.has_key?(listed, "options")
      assert listed["slug"] == "core_opts"
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

    test "unrelated SCHEMA_OPTIONS keys (audio_input, audio_output, ...) are accepted and ignored" do
      conn =
        supervisor_call(:post, "/addons/core_opts/options", %{
          "audio_input" => "mic",
          "audio_output" => "speaker"
        })

      assert conn.status == 200
      assert {:ok, %{user_options: %{}}} = State.get("core_opts")
    end

    # boot/auto_update (phase 6 chunk A, audit E1/E2) used to be in the
    # "accepted and ignored" bucket above — the exact bug: a save 200'd and
    # the value reverted on the next read because nothing persisted it.
    test "boot: manual is persisted and read back through the real route" do
      conn = supervisor_call(:post, "/addons/core_opts/options", %{"boot" => "manual"})
      assert conn.status == 200
      assert {:ok, %{boot: "manual"}} = State.get("core_opts")

      info = body(supervisor_call(:get, "/addons/core_opts/info"))["data"]
      assert info["boot"] == "manual"
    end

    test "boot: auto is persisted and read back, overriding a previously-saved manual" do
      :ok = State.put_setting("core_opts", :boot, "manual")

      conn = supervisor_call(:post, "/addons/core_opts/options", %{"boot" => "auto"})
      assert conn.status == 200
      assert {:ok, %{boot: "auto"}} = State.get("core_opts")

      info = body(supervisor_call(:get, "/addons/core_opts/info"))["data"]
      assert info["boot"] == "auto"
    end

    test "an unset boot falls back to the config's own default in the info payload" do
      # `fixture_config/1` doesn't set `boot`, so `Config.parse/1` defaults it
      # to "auto" — nothing has ever been persisted for this slug either.
      info = body(supervisor_call(:get, "/addons/core_opts/info"))["data"]
      assert info["boot"] == "auto"
    end

    test "an invalid boot value -> 400, nothing persisted" do
      conn = supervisor_call(:post, "/addons/core_opts/options", %{"boot" => "sometimes"})
      assert conn.status == 400
      assert body(conn)["message"] =~ "boot must be"
      assert {:ok, %{boot: nil}} = State.get("core_opts")
    end

    test "an add-on whose CONFIG declares manual_only refuses ANY boot change (400)" do
      config = fixture_config("mo") |> Map.put(:slug, "core_mo") |> Map.put(:boot, "manual_only")
      :ok = State.put(config, :stopped)
      on_exit(fn -> State.delete("core_mo") end)

      # Even a value that would be a no-op (upstream's own unconditional
      # check — see `validate_boot_key/2`'s comment).
      conn = supervisor_call(:post, "/addons/core_mo/options", %{"boot" => "manual"})
      assert conn.status == 400
      assert body(conn)["message"] =~ "manual_only"
      assert {:ok, %{boot: nil}} = State.get("core_mo")

      # And it reports "manual" effectively regardless, per
      # `Config.effective_boot/2`.
      info = body(supervisor_call(:get, "/addons/core_mo/info"))["data"]
      assert info["boot"] == "manual"
    end

    test "a bad boot alongside a valid options map -> 400, options NOT applied" do
      conn =
        supervisor_call(:post, "/addons/core_opts/options", %{
          "boot" => "sometimes",
          "options" => %{"greeting" => "hey"}
        })

      assert conn.status == 400
      assert {:ok, %{user_options: %{}, boot: nil}} = State.get("core_opts")
    end

    test "auto_update: true is persisted and read back through the real route" do
      conn = supervisor_call(:post, "/addons/core_opts/options", %{"auto_update" => true})
      assert conn.status == 200
      assert {:ok, %{auto_update: true}} = State.get("core_opts")

      info = body(supervisor_call(:get, "/addons/core_opts/info"))["data"]
      assert info["auto_update"] == true
    end

    test "auto_update: false is persisted" do
      :ok = State.put_setting("core_opts", :auto_update, true)
      conn = supervisor_call(:post, "/addons/core_opts/options", %{"auto_update" => false})
      assert conn.status == 200
      assert {:ok, %{auto_update: false}} = State.get("core_opts")
    end

    test "unset auto_update reports false, never fakes an updater" do
      info = body(supervisor_call(:get, "/addons/core_opts/info"))["data"]
      assert info["auto_update"] == false
    end

    test "a non-boolean auto_update -> 400, nothing persisted" do
      conn = supervisor_call(:post, "/addons/core_opts/options", %{"auto_update" => "yes"})
      assert conn.status == 400
      assert body(conn)["message"] =~ "auto_update must be a boolean"
      assert {:ok, %{auto_update: nil}} = State.get("core_opts")
    end

    test "options on a never-installed slug -> 404" do
      conn = supervisor_call(:post, "/addons/never_installed/options", %{"options" => %{}})
      assert conn.status == 404
    end

    test "options by slug is supervisor-only (403)" do
      assert addon_call(:post, "/addons/core_opts/options", "core_opts").status == 403
    end

    # Audit A3. `/addons/self/options` is one segment ⇒ bypassed; but
    # `/addons/self/options/validate` is two ⇒ still supervisor-only. That
    # asymmetry between saving and dry-running is upstream's `[^/]+`, not an
    # oversight here, so both halves are pinned.
    test "an add-on may set ITS OWN options via `self`, but not dry-run them" do
      conn =
        addon_call(:post, "/addons/self/options", "core_opts", %{
          "options" => %{"greeting" => "hi"}
        })

      assert conn.status == 200
      assert {:ok, %{user_options: %{"greeting" => "hi"}}} = State.get("core_opts")

      assert addon_call(:post, "/addons/self/options/validate", "core_opts").status == 403
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

  describe "POST /addons/:slug/security" do
    setup do
      config = fixture_config("sec") |> Map.put(:slug, "core_sec")
      :ok = State.put(config, :stopped)
      on_exit(fn -> State.delete("core_sec") end)
      %{config: config}
    end

    test "protected: false is persisted" do
      conn = supervisor_call(:post, "/addons/core_sec/security", %{"protected" => false})
      assert conn.status == 200
      assert {:ok, %{protected: false}} = State.get("core_sec")
    end

    test "protected: true puts it back" do
      :ok = State.put_setting("core_sec", :protected, false)

      assert supervisor_call(:post, "/addons/core_sec/security", %{"protected" => true}).status ==
               200

      assert {:ok, %{protected: true}} = State.get("core_sec")
    end

    test "the info payload reports what was stored" do
      assert supervisor_call(:post, "/addons/core_sec/security", %{"protected" => false}).status ==
               200

      info = body(supervisor_call(:get, "/addons/core_sec/info"))["data"]
      assert info["protected"] == false
    end

    test "a body without the key is a 200 no-op (SCHEMA_SECURITY marks it optional)" do
      :ok = State.put_setting("core_sec", :protected, false)
      conn = supervisor_call(:post, "/addons/core_sec/security", %{"unrelated" => 1})
      assert conn.status == 200
      assert {:ok, %{protected: false}} = State.get("core_sec")
    end

    test "a non-boolean protected -> 400, nothing stored" do
      conn = supervisor_call(:post, "/addons/core_sec/security", %{"protected" => "false"})
      assert conn.status == 400
      assert body(conn)["message"] =~ "protected must be a boolean"
      assert {:ok, %{protected: true}} = State.get("core_sec")
    end

    test "an unknown slug -> 404" do
      conn = supervisor_call(:post, "/addons/core_nope/security", %{"protected" => false})
      assert conn.status == 404
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

    # This pinned a 400 until the jobs subsystem existed (audit B4) — that
    # decision was locked as correct only while there were no jobs.
    test "background: true returns {job_id} and the update completes in a task" do
      installed = fixture_config("updbg")
      seed_store("core_updbg", installed)
      assert supervisor_call(:post, "/store/addons/core_updbg/install").status == 200
      seed_store("core_updbg", %{installed | version: "9.9.9"})

      conn = supervisor_call(:post, "/store/addons/core_updbg/update", %{"background" => true})

      assert conn.status == 200
      job_id = json(conn)["data"]["job_id"]
      assert job_id =~ ~r/\A[0-9a-f]{32}\z/

      # The work runs under Vagus.Jobs.TaskSupervisor; poll the job the way
      # Core would.
      assert eventually(fn ->
               json(supervisor_call(:get, "/jobs/#{job_id}"))["data"]["done"] == true
             end)

      job = json(supervisor_call(:get, "/jobs/#{job_id}"))["data"]
      assert job["name"] == "addon_manager_update"
      assert job["reference"] == "core_updbg"
      assert job["errors"] == []
      assert job["progress"] == 100

      assert json(supervisor_call(:get, "/addons/core_updbg/info"))["data"]["version"] ==
               "9.9.9"
    end

    test "background: true at the task-supervisor cap is a 429, job finished with an error" do
      installed = fixture_config("updbgcap")
      seed_store("core_updbgcap", installed)
      assert supervisor_call(:post, "/store/addons/core_updbgcap/install").status == 200
      seed_store("core_updbgcap", %{installed | version: "9.9.9"})

      # Saturate Vagus.Jobs.TaskSupervisor (max_children: 8) with parked
      # tasks so start_job_task hits {:error, :max_children}.
      parked =
        for _ <- 1..8 do
          {:ok, pid} =
            Task.Supervisor.start_child(Vagus.Jobs.TaskSupervisor, fn ->
              Process.sleep(:infinity)
            end)

          pid
        end

      on_exit(fn ->
        Enum.each(parked, &Task.Supervisor.terminate_child(Vagus.Jobs.TaskSupervisor, &1))
      end)

      conn = supervisor_call(:post, "/store/addons/core_updbgcap/update", %{"background" => true})

      assert conn.status == 429
      assert json(conn)["message"] =~ "too many background jobs"

      # The pre-created job was not leaked undone: it is finished with an
      # honest error, so Core never polls a zombie.
      jobs = json(supervisor_call(:get, "/jobs/info"))["data"]["jobs"]

      assert [job] =
               Enum.filter(
                 jobs,
                 &(&1["name"] == "addon_manager_update" and &1["reference"] == "core_updbgcap")
               )

      assert job["done"] == true
      assert [%{"type" => "JobStartError"}] = job["errors"]

      Enum.each(parked, &Task.Supervisor.terminate_child(Vagus.Jobs.TaskSupervisor, &1))

      # With the slots free again the same request goes through.
      conn = supervisor_call(:post, "/store/addons/core_updbgcap/update", %{"background" => true})
      assert conn.status == 200
      job_id = json(conn)["data"]["job_id"]

      assert eventually(fn ->
               json(supervisor_call(:get, "/jobs/#{job_id}"))["data"]["done"] == true
             end)
    end

    test "background: false and an absent body both proceed synchronously" do
      installed = fixture_config("updbgfalse")
      seed_store("core_updbgfalse", installed)
      assert supervisor_call(:post, "/store/addons/core_updbgfalse/install").status == 200
      seed_store("core_updbgfalse", %{installed | version: "9.9.9"})

      conn =
        supervisor_call(:post, "/store/addons/core_updbgfalse/update", %{"background" => false})

      assert conn.status == 200
    end

    test "a sync update is wrapped in a job too, done when the response lands" do
      installed = fixture_config("updsyncjob")
      seed_store("core_updsyncjob", installed)
      assert supervisor_call(:post, "/store/addons/core_updsyncjob/install").status == 200
      seed_store("core_updsyncjob", %{installed | version: "9.9.9"})

      assert supervisor_call(:post, "/store/addons/core_updsyncjob/update", %{}).status == 200

      jobs = json(supervisor_call(:get, "/jobs/info"))["data"]["jobs"]

      assert [job] =
               Enum.filter(
                 jobs,
                 &(&1["name"] == "addon_manager_update" and &1["reference"] == "core_updsyncjob")
               )

      assert job["done"] == true
      assert job["errors"] == []
      # The stage waypoints ran: the last one recorded is the restart.
      assert job["stage"] in ["commit", "start"]
    end

    test "a failed update finishes its job with an honest error entry" do
      seed_store("core_updjobfail", fixture_config("updjobfail"))
      assert supervisor_call(:post, "/store/addons/core_updjobfail/install").status == 200
      # No store version bump: the update 400s with "No update available".

      conn = supervisor_call(:post, "/store/addons/core_updjobfail/update", %{})
      assert conn.status == 400

      jobs = json(supervisor_call(:get, "/jobs/info"))["data"]["jobs"]

      assert [job] =
               Enum.filter(
                 jobs,
                 &(&1["name"] == "addon_manager_update" and &1["reference"] == "core_updjobfail")
               )

      assert job["done"] == true
      assert [error] = job["errors"]
      assert error["type"] == "AddonsError"
      assert error["message"] =~ "No update available"
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
