defmodule Vagus.API.IngressRouterTest do
  @moduledoc """
  IW-P2-T1: `POST /ingress/session` and `POST /ingress/validate_session`
  (`docs/contract-2026.7-m4b-ingress-watchdog.md` §B1.1/B1.2) — the two
  Core-only ingress session routes.

  `Vagus.Ingress` isn't in the application's supervision tree yet (a later
  task wires it in), so this file starts the default-named global instance
  itself via `start_supervised!/1` — matching how the router calls it
  (`Vagus.Ingress.create_session/0`, no explicit `server` arg).
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vagus.Addon.{Config, Registry, State}
  alias Vagus.API.{Router, Token}

  @opts Router.init([])

  setup do
    start_supervised!({Vagus.Ingress, []})
    :ok
  end

  # `grants` defaults to the closed shape a plain add-on registers with
  # (`hassio_api: false`); pass `%{hassio_api: true, hassio_role: "admin"}` to
  # exercise a caller that clears `Vagus.API.Tiers`' gate and reaches the
  # handler's own guard.
  defp addon_token(slug, grants \\ %{}) do
    token = "tok-#{System.unique_integer([:positive])}"

    identity =
      Map.merge(
        %{
          slug: slug,
          services_role: %{},
          auth_api: false,
          discovery: [],
          hassio_api: false,
          hassio_role: "default"
        },
        grants
      )

    :ok = Registry.register(token, identity)

    on_exit(fn -> Registry.unregister_slug(slug) end)

    token
  end

  defp call(method, path, token, body \\ nil) do
    conn = conn(method, path, body && Jason.encode!(body))
    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  describe "POST /ingress/session" do
    test "supervisor caller gets a 128-hex session token" do
      conn = call(:post, "/ingress/session", Token.get())
      assert conn.status == 200
      session = body(conn)["data"]["session"]
      assert session =~ ~r/\A[0-9a-f]{128}\z/
    end

    # Two layers, two statuses — upstream's order, not a contradiction:
    # `/ingress/…` appears in no role below `role_access[admin]`, so a
    # non-admin add-on never reaches the handler and the middleware's
    # `HTTPForbidden` (403) is what it sees. An admin-role add-on clears that
    # and then meets `@require_home_assistant`, which raises
    # `HTTPUnauthorized` — the one place a wrong-caller rejection is a 401.
    test "an admin-tier add-on caller gets 401 (Core-only)" do
      token = addon_token("core_esphome", %{hassio_api: true, hassio_role: "admin"})
      conn = call(:post, "/ingress/session", token)
      assert conn.status == 401
    end

    test "a plain add-on caller gets 403 from the tier gate, before the handler" do
      token = addon_token("core_esphome_plain")
      conn = call(:post, "/ingress/session", token)
      assert conn.status == 403
    end

    # Core sends the requesting user under the wire key `user_id` — the
    # `ATTR_SESSION_DATA_USER_ID` constant's *value*
    # (`homeassistant/components/hassio/const.py`), not its name. Recorded on
    # the session because it is the only identity a later proxied ingress
    # request carries (`Vagus.API.AdminPanel` gates on it).
    test "Core's user_id is recorded on the session" do
      conn = call(:post, "/ingress/session", Token.get(), %{"user_id" => "some-user"})

      assert conn.status == 200
      session = body(conn)["data"]["session"]

      assert {:ok, "some-user"} = Vagus.Ingress.session_user(session)
    end

    # The constant's *name* as a wire key: never sent by Core, accepted as a
    # compatibility alias only.
    test "session_data_user_id is accepted as an alias and also recorded" do
      conn =
        call(:post, "/ingress/session", Token.get(), %{"session_data_user_id" => "some-user"})

      assert conn.status == 200
      session = body(conn)["data"]["session"]

      assert {:ok, "some-user"} = Vagus.Ingress.session_user(session)
    end

    test "user_id wins when both keys are present" do
      conn =
        call(:post, "/ingress/session", Token.get(), %{
          "user_id" => "real-user",
          "session_data_user_id" => "alias-user"
        })

      assert {:ok, "real-user"} = Vagus.Ingress.session_user(body(conn)["data"]["session"])
    end

    test "a body without either key still gets a session, carrying no user" do
      conn = call(:post, "/ingress/session", Token.get(), %{})

      assert conn.status == 200
      session = body(conn)["data"]["session"]

      assert session =~ ~r/\A[0-9a-f]{128}\z/
      assert {:ok, nil} = Vagus.Ingress.session_user(session)
    end
  end

  describe "POST /ingress/validate_session" do
    test "round-trips: create then validate → 200" do
      session = body(call(:post, "/ingress/session", Token.get()))["data"]["session"]

      conn =
        call(:post, "/ingress/validate_session", Token.get(), %{"session" => session})

      assert conn.status == 200
      assert body(conn)["data"] == %{}
    end

    test "an unknown/bad session → 401 with the upstream-matching message" do
      conn =
        call(:post, "/ingress/validate_session", Token.get(), %{"session" => "not-a-real-token"})

      assert conn.status == 401
      assert body(conn)["message"] == "Session does not exist"
    end

    test "a missing session key → 400" do
      conn = call(:post, "/ingress/validate_session", Token.get(), %{})
      assert conn.status == 400
    end

    test "an admin-tier add-on caller gets 401 (Core-only)" do
      token = addon_token("core_esphome", %{hassio_api: true, hassio_role: "admin"})

      conn =
        call(:post, "/ingress/validate_session", token, %{"session" => "whatever"})

      assert conn.status == 401
    end

    test "a plain add-on caller gets 403 from the tier gate, before the handler" do
      token = addon_token("core_esphome_plain")

      conn =
        call(:post, "/ingress/validate_session", token, %{"session" => "whatever"})

      assert conn.status == 403
    end
  end

  # IW-P2-T3 (§B4.1/§B4.4). `Vagus.Ingress.Panels`'s own unit tests
  # (`test/vagus/ingress/panels_test.exs`) cover `list/1`'s field mapping and
  # `update_hass_panel/2`'s actual POST/DELETE push against a fake Core —
  # these router tests only need to prove the route is wired to that module
  # and that the options-change hook actually calls it (observed via the
  # persisted `State` change, same as `addon_lifecycle_router_test.exs`'s
  # "ingress_panel is persisted" test) — wiring a full fake-Core fixture
  # through this router test too would be redundant with panels_test.exs.
  describe "GET /ingress/panels (§B4.1)" do
    defp ingress_config(slug, opts) do
      {:ok, config} =
        Config.parse(%{
          "name" => Keyword.get(opts, :name, "ESPHome"),
          "version" => "1",
          "slug" => slug,
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "homeassistant/{arch}-addon-esphome",
          "ingress" => true,
          "panel_title" => Keyword.get(opts, :panel_title),
          "panel_icon" => Keyword.get(opts, :panel_icon, "mdi:puzzle"),
          "panel_admin" => Keyword.get(opts, :panel_admin, true)
        })

      config
    end

    test "lists every ingress-capable add-on, enable reflecting the ingress_panel toggle" do
      enabled = ingress_config("core_esphome_panels", panel_title: "ESPHome")
      :ok = State.put(enabled, :started)
      :ok = State.put_setting("core_esphome_panels", :ingress_panel, true)
      on_exit(fn -> State.delete("core_esphome_panels") end)

      disabled = ingress_config("core_other_panels", panel_title: nil, panel_icon: "mdi:cog")
      :ok = State.put(disabled, :started)
      on_exit(fn -> State.delete("core_other_panels") end)

      conn = call(:get, "/ingress/panels", Token.get())
      assert conn.status == 200
      panels = body(conn)["data"]["panels"]

      assert panels["core_esphome_panels"] == %{
               "title" => "ESPHome",
               "icon" => "mdi:puzzle",
               "admin" => true,
               "enable" => true
             }

      assert panels["core_other_panels"] == %{
               "title" => "ESPHome",
               "icon" => "mdi:cog",
               "admin" => true,
               "enable" => false
             }
    end

    test "a non-ingress add-on never appears" do
      {:ok, plain} =
        Config.parse(%{
          "name" => "Plain",
          "version" => "1",
          "slug" => "plain_panels",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "x/y",
          "ingress" => false
        })

      :ok = State.put(plain, :started)
      on_exit(fn -> State.delete("plain_panels") end)

      conn = call(:get, "/ingress/panels", Token.get())
      assert conn.status == 200
      refute Map.has_key?(body(conn)["data"]["panels"], "plain_panels")
    end

    # Audit A5. `no_security_check` exempts only the proxy path
    # `/ingress/[-_A-Za-z0-9]+/.*`, so `/ingress/panels` falls through to the
    # role table — where no role below `role_access[admin]` lists an
    # `/ingress/…` alternative. Vagus served it to every installed add-on,
    # which is an inventory of the others.
    test "a plain add-on caller is refused — the route is admin-tier upstream" do
      token = addon_token("core_esphome_panels_reader")
      conn = call(:get, "/ingress/panels", token)
      assert conn.status == 403
    end

    test "an admin-tier add-on caller may read it" do
      token =
        addon_token("core_esphome_panels_admin", %{hassio_api: true, hassio_role: "admin"})

      conn = call(:get, "/ingress/panels", token)
      assert conn.status == 200
    end
  end

  describe "POST /addons/:slug/options ingress_panel -> panel push hook (§B4.4)" do
    test "persists the toggle and fires the push (push itself unit-tested in panels_test.exs)" do
      {:ok, config} =
        Config.parse(%{
          "name" => "ESPHome",
          "version" => "1",
          "slug" => "core_esphome_push",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "homeassistant/{arch}-addon-esphome",
          "ingress" => true
        })

      :ok = State.put(config, :stopped)
      on_exit(fn -> State.delete("core_esphome_push") end)

      conn =
        call(:post, "/addons/core_esphome_push/options", Token.get(), %{"ingress_panel" => true})

      assert conn.status == 200
      assert {:ok, %{ingress_panel: true}} = State.get("core_esphome_push")
    end
  end
end
