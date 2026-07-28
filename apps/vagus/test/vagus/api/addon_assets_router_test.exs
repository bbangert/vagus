defmodule Vagus.API.AddonAssetsRouterTest do
  @moduledoc """
  P2-A P4: the four store asset endpoints — `GET .../icon|logo`
  (unauthenticated) and `GET .../changelog|documentation` (`supervisor_only`)
  — in both the `/store/addons/...` and legacy `/addons/...` forms.

  Storage-mode equivalence (`:memory` vs `:disk`) is proven exhaustively in
  `Vagus.Addon.Store.AssetsTest` and `Vagus.Addon.StoreTest` (150+ tests
  parameterized across both modes) — the router never consults the mode, only
  `Vagus.Addon.Store.assets/1` + `Vagus.Addon.Store.Assets.get/3`, so nothing
  here is mode-specific. `config/test.exs` pins the app's singleton `Store` to
  `:memory`, which this file seeds directly (the same seam
  `Vagus.API.AddonLifecycleRouterTest`'s `seed_store/3` uses for the catalog).

  `async: false`: it mutates the singleton `Vagus.Addon.Store`'s catalog and
  ETS-backed asset table, same as the lifecycle router tests.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vagus.Addon.{Config, Registry, State, Store}
  alias Vagus.Addon.Store.Assets
  alias Vagus.API.{Router, Token}

  @opts Router.init([])

  # 1x1 PNG header — real bytes, so a test that accidentally round-trips
  # through a text path fails loudly.
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>
  @logo <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 76, 79, 71, 79>>

  defp fixture_config(slug) do
    {:ok, config} =
      Config.parse(%{
        "name" => "Test Addon",
        "version" => "1",
        "slug" => slug,
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "homeassistant/{arch}-addon-test"
      })

    config
  end

  # Seeds the running singleton `Vagus.Addon.Store` catalog directly, exactly
  # like `Vagus.API.AddonLifecycleRouterTest.seed_store/3` — there's no
  # network-fetching path to exercise here.
  defp seed_store(store_slug, repo_slug \\ "core", addon_slug \\ nil) do
    addon_slug = addon_slug || store_slug
    entry = %{config: fixture_config(addon_slug), repository: repo_slug}
    catalog = Map.put(Store.catalog(), store_slug, entry)
    :ok = GenServer.call(Store, {:put_catalog, catalog})

    on_exit(fn ->
      GenServer.call(Store, {:put_catalog, Map.delete(Store.catalog(), store_slug)})
    end)

    Assets.id(entry)
  end

  defp put_asset(id, kind, binary) do
    :ok = Assets.put(id, kind, binary, Store.assets())
    on_exit(fn -> Assets.delete(id, kind, Store.assets()) end)
  end

  defp unauth_call(method, path), do: Router.call(conn(method, path), @opts)

  defp supervisor_call(method, path) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer #{Token.get()}")
    |> Router.call(@opts)
  end

  defp addon_call(method, path, slug) do
    token = "tok-#{System.unique_integer([:positive])}"

    :ok =
      Registry.register(token, %{slug: slug, services_role: %{}, auth_api: false, discovery: []})

    on_exit(fn -> Registry.unregister_slug(slug) end)

    conn(method, path) |> put_req_header("x-supervisor-token", token) |> Router.call(@opts)
  end

  describe "icon/logo are unauthenticated" do
    test "GET .../icon round-trips the PNG bytes with no token, both path forms" do
      id = seed_store("core_iconaddon")
      put_asset(id, :icon, @png)

      for path <- ["/store/addons/core_iconaddon/icon", "/addons/core_iconaddon/icon"] do
        conn = unauth_call(:get, path)

        assert conn.status == 200
        assert conn.resp_body == @png
        assert get_resp_header(conn, "content-type") == ["image/png"]
        assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

        assert get_resp_header(conn, "content-security-policy") == [
                 "default-src 'none'; sandbox"
               ]
      end
    end

    test "GET .../logo round-trips separately from icon, both path forms" do
      id = seed_store("core_logoaddon")
      put_asset(id, :icon, @png)
      put_asset(id, :logo, @logo)

      for path <- ["/store/addons/core_logoaddon/logo", "/addons/core_logoaddon/logo"] do
        conn = unauth_call(:get, path)
        assert conn.status == 200
        assert conn.resp_body == @logo
        assert get_resp_header(conn, "content-type") == ["image/png"]
      end
    end

    test "a missing icon -> 400, application/octet-stream, upstream's exact message" do
      seed_store("core_noicon")

      conn = unauth_call(:get, "/addons/core_noicon/icon")
      assert conn.status == 400
      assert conn.resp_body == "No icon found for addon core_noicon!"
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "a missing logo -> 400, application/octet-stream, its own message" do
      seed_store("core_nologo")

      conn = unauth_call(:get, "/store/addons/core_nologo/logo")
      assert conn.status == 400
      assert conn.resp_body == "No logo found for addon core_nologo!"
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
    end

    test "an unknown slug is absent, not an error — never a 404 or 500" do
      conn = unauth_call(:get, "/addons/never_heard_of_it/icon")
      assert conn.status == 400
      assert conn.resp_body == "No icon found for addon never_heard_of_it!"
    end

    test "a non-GET method on the icon path is NOT bypassed — 401 with no token" do
      seed_store("core_postattempt")

      for method <- [:post, :put, :delete] do
        conn = unauth_call(method, "/addons/core_postattempt/icon")
        assert conn.status == 401
      end
    end

    test "an unauthenticated GET with a traversal-shaped slug is refused auth, not bypassed" do
      # `valid_slug?/1` (used by the pre-auth plug) rejects "..", so this
      # never reaches the bypass and falls through to normal auth — 401, not
      # a 400 "absent" answer that would imply the route ran unauthenticated.
      conn = unauth_call(:get, "/addons/../icon")
      assert conn.status == 401
    end

    test "a traversal-shaped slug never reaches Assets, even when authenticated" do
      # `resolve_asset_id/1` only calls `Store.get/1`; a traversal string is
      # never a real catalog key, so this is an honest "absent" — not a crash,
      # not a filesystem read, not a 200.
      conn = supervisor_call(:get, "/addons/../icon")
      assert conn.status == 400
      assert conn.resp_body == "No icon found for addon ..!"
    end

    test "a detached add-on (installed, no longer in the store) reports absent" do
      id = seed_store("core_detachedicon")
      put_asset(id, :icon, @png)
      :ok = State.put(fixture_config("core_detachedicon"), :stopped)
      on_exit(fn -> State.delete("core_detachedicon") end)

      # The repository drops it entirely — installed, but no store entry.
      :ok =
        GenServer.call(Store, {:put_catalog, Map.delete(Store.catalog(), "core_detachedicon")})

      conn = unauth_call(:get, "/addons/core_detachedicon/icon")
      assert conn.status == 400
      assert conn.resp_body == "No icon found for addon core_detachedicon!"
    end

    test "a non-PNG icon was refused at put/4, so it reads back as absent" do
      id = seed_store("core_htmlicon")
      # Not `put_asset/3` — asserting the write itself is refused is the point.
      assert {:error, :invalid_content} =
               Assets.put(id, :icon, "<script>alert(1)</script>", Store.assets())

      conn = unauth_call(:get, "/addons/core_htmlicon/icon")
      assert conn.status == 400
      assert conn.resp_body == "No icon found for addon core_htmlicon!"
    end
  end

  describe "changelog/documentation are supervisor_only" do
    test "GET .../changelog round-trips text/plain, both path forms" do
      id = seed_store("core_changelogaddon")
      put_asset(id, :changelog, "## 1.0.0\nInitial release\n")

      for path <- [
            "/store/addons/core_changelogaddon/changelog",
            "/addons/core_changelogaddon/changelog"
          ] do
        conn = supervisor_call(:get, path)
        assert conn.status == 200
        assert conn.resp_body == "## 1.0.0\nInitial release\n"
        assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
        assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
        # No CSP on the text kinds — only icon/logo get one.
        assert get_resp_header(conn, "content-security-policy") == []
      end
    end

    test "GET .../documentation round-trips separately from changelog" do
      id = seed_store("core_docsaddon")
      put_asset(id, :documentation, "# Docs\n")

      conn = supervisor_call(:get, "/store/addons/core_docsaddon/documentation")
      assert conn.status == 200
      assert conn.resp_body == "# Docs\n"
    end

    test "a missing changelog is ALWAYS 200, upstream's exact message" do
      seed_store("core_nochangelog")

      conn = supervisor_call(:get, "/addons/core_nochangelog/changelog")
      assert conn.status == 200
      assert conn.resp_body == "No changelog found for addon core_nochangelog!"
      assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    end

    test "a missing documentation is ALWAYS 200, its own message" do
      seed_store("core_nodocs")

      conn = supervisor_call(:get, "/store/addons/core_nodocs/documentation")
      assert conn.status == 200
      assert conn.resp_body == "No documentation found for addon core_nodocs!"
    end

    test "an unknown slug is a 200 'absent' answer, never 404 or 500" do
      conn = supervisor_call(:get, "/addons/never_heard_of_it/changelog")
      assert conn.status == 200
      assert conn.resp_body == "No changelog found for addon never_heard_of_it!"
    end

    test "a detached add-on reports absent, not an error" do
      id = seed_store("core_detachedlog")
      put_asset(id, :changelog, "old news")
      :ok = State.put(fixture_config("core_detachedlog"), :stopped)
      on_exit(fn -> State.delete("core_detachedlog") end)

      :ok = GenServer.call(Store, {:put_catalog, Map.delete(Store.catalog(), "core_detachedlog")})

      conn = supervisor_call(:get, "/addons/core_detachedlog/changelog")
      assert conn.status == 200
      assert conn.resp_body == "No changelog found for addon core_detachedlog!"
    end

    test "an unauthenticated GET is still 401 — no bypass for changelog/documentation" do
      seed_store("core_authrequired")

      assert unauth_call(:get, "/addons/core_authrequired/changelog").status == 401
      assert unauth_call(:get, "/store/addons/core_authrequired/documentation").status == 401
    end

    test "an add-on caller (not the supervisor) is refused with 403" do
      seed_store("core_addonrefused")

      conn = addon_call(:get, "/addons/core_addonrefused/changelog", "some_other_addon")
      assert conn.status == 403
    end
  end

  describe "README.md as long_description (the body of the store page)" do
    # Unlike the other four assets this one has no route: it is read for its
    # content and rendered into the detail payload, which is where the
    # frontend gets the markdown it shows under the install card.

    test "the store detail carries the README's text" do
      id = seed_store("core_readmeful")
      readme = "# Test Addon\n\nEverything you never wanted to know.\n"
      put_asset(id, :readme, readme)

      data =
        Jason.decode!(supervisor_call(:get, "/store/addons/core_readmeful").resp_body)["data"]

      assert data["long_description"] == readme
    end

    test "a README with invalid UTF-8 is scrubbed, not a 500" do
      # The bytes come from a third-party repository tarball and this field is
      # JSON-encoded, so an add-on shipping a Latin-1 README would otherwise
      # raise in `Jason.encode!/1` and 500 its own store page. Upstream reads
      # with `errors="replace"`, so the page still renders.
      id = seed_store("core_latin1readme")
      put_asset(id, :readme, <<"# Caf", 0xE9, "\n\nBody.\n">>)

      conn = supervisor_call(:get, "/store/addons/core_latin1readme")
      assert conn.status == 200

      assert Jason.decode!(conn.resp_body)["data"]["long_description"] ==
               "# Caf�\n\nBody.\n"
    end

    test "a valid multi-byte README is passed through untouched" do
      id = seed_store("core_utf8readme")
      readme = "# Café ☕\n\nEmoji: 🎛️\n"
      put_asset(id, :readme, readme)

      data =
        Jason.decode!(supervisor_call(:get, "/store/addons/core_utf8readme").resp_body)["data"]

      assert data["long_description"] == readme
    end

    test "an add-on shipping no README reports null, not an empty string" do
      seed_store("core_readmeless")

      data =
        Jason.decode!(supervisor_call(:get, "/store/addons/core_readmeless").resp_body)["data"]

      assert data["long_description"] == nil
    end

    test "the uninstalled-add-on info page gets it too — that page IS the store page" do
      id = seed_store("core_readmeinfo")
      readme = "# Readme Info\n"
      put_asset(id, :readme, readme)

      data =
        Jason.decode!(supervisor_call(:get, "/addons/core_readmeinfo/info").resp_body)["data"]

      assert data["long_description"] == readme
      assert data["state"] == "unknown"
    end
  end
end
