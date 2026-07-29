defmodule Vagus.API.AuthTierGateTest do
  @moduledoc """
  End-to-end proof that `Vagus.API.Tiers` is actually applied, through the
  real `Vagus.API.Router` pipeline.

  `Vagus.API.TiersTest` pins the table; this file pins that the table *runs*.
  The 2026-07-29 audit's root cause was not a wrong table — there was no table,
  and `supervisor_only/2` was applied by hand to some routes and not others. A
  table nobody consults would reproduce that exactly, so the assertions here
  go through `Router.call/2` rather than calling `Tiers` directly.

  `async: true`: every helper registers a token under a slug unique to this
  file and unregisters on exit, and nothing here asserts on shared state.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Vagus.Addon.Registry
  alias Vagus.API.{Router, Token}

  @opts Router.init([])

  # The 26 routes the audit found admin-tier to any installed add-on (F1-F7),
  # plus the two `/core|/homeassistant` options writes (F2) and `/store/reload`
  # (F6). Every one answered 200 to a throwaway add-on token on the device.
  #
  # Safe to sweep as a refusal test even where the verb is destructive: the
  # gate halts in `Vagus.API.Auth`, before `:match`, so no handler runs. That
  # is the property being asserted.
  @previously_open [
    {:get, "/addons"},
    {:post, "/core/options"},
    {:post, "/homeassistant/options"},
    {:post, "/host/reboot"},
    {:post, "/host/shutdown"},
    {:post, "/network/interface/eth0/update"},
    {:get, "/network/interface/eth0/accesspoints"},
    {:get, "/store"},
    {:get, "/store/addons"},
    {:get, "/store/addons/core_mqtt"},
    {:post, "/store/reload"},
    {:get, "/mounts"},
    {:get, "/core/stats"},
    {:get, "/supervisor/stats"},
    {:get, "/available_updates"},
    {:get, "/ingress/panels"},
    {:get, "/core/logs"},
    {:get, "/core/logs/latest"},
    {:get, "/core/logs/follow"},
    {:get, "/supervisor/logs"},
    {:get, "/supervisor/logs/latest"},
    {:get, "/supervisor/logs/follow"},
    {:get, "/host/logs"},
    {:get, "/host/logs/latest"},
    {:get, "/host/logs/follow"},
    {:get, "/host/logs/boots"},
    {:get, "/host/logs/identifiers"},
    {:get, "/homeassistant/logs"},
    {:get, "/supervisor/options"},
    {:post, "/supervisor/reload"},
    {:post, "/refresh_updates"},
    {:post, "/reload_updates"}
  ]

  # Reads Core polls on every coordinator tick. If the gate ever refuses one of
  # these, `hassio` reports a vague setup failure and every entity goes
  # unavailable — the silent failure mode the plan calls out as this phase's
  # real risk.
  @core_reads [
    "/info",
    "/supervisor/info",
    "/core/info",
    "/os/info",
    "/host/info",
    "/hardware/info",
    "/network/info",
    "/store",
    "/mounts",
    "/resolution/info",
    "/jobs/info",
    "/addons",
    "/core/stats",
    "/supervisor/stats",
    "/available_updates",
    "/ingress/panels",
    "/supervisor/ping"
  ]

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

  defp call(method, path, token) do
    conn(method, path)
    |> put_req_header("x-supervisor-token", token)
    |> Router.call(@opts)
  end

  defp call_as_core(method, path) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer " <> Token.get())
    |> Router.call(@opts)
  end

  describe "the 26 previously-open routes" do
    test "a plain add-on token is refused on every one of them" do
      token = addon_token("tier_gate_plain")

      for {method, path} <- @previously_open do
        conn = call(method, path, token)

        assert conn.status == 403,
               "#{method |> to_string() |> String.upcase()} #{path} answered " <>
                 "#{conn.status} to an add-on that declared no hassio_api"
      end
    end

    test "an add-on with hassio_api but only the default role is refused too" do
      token = addon_token("tier_gate_default", %{hassio_api: true, hassio_role: "default"})

      for {method, path} <- @previously_open do
        conn = call(method, path, token)
        assert conn.status == 403, "#{path} answered #{conn.status} to a default-role add-on"
      end
    end

    test "the refusal is halted before dispatch, so no handler ran" do
      token = addon_token("tier_gate_halt")
      conn = call(:post, "/host/reboot", token)

      assert conn.halted
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body) == %{"result" => "error", "message" => "unauthorized"}
    end
  end

  describe "Core keeps everything" do
    test "every read the hassio coordinator polls is still reachable" do
      for path <- @core_reads do
        conn = call_as_core(:get, path)

        refute conn.status == 403, "Core was refused #{path} — this breaks the config entry"
        assert conn.status == 200, "#{path} answered #{conn.status} to Core"
      end
    end

    test "the supervisor tier clears a supervisor-only route's gate" do
      # Reaches the handler: 404 for an unknown slug, never 403.
      conn = call_as_core(:post, "/addons/does_not_exist_here/start")
      refute conn.status == 403
    end
  end

  describe "tier reachability" do
    test "a manager-role add-on reaches the manager reads a default one cannot" do
      manager = addon_token("tier_gate_manager", %{hassio_api: true, hassio_role: "manager"})
      plain = addon_token("tier_gate_plain_2", %{hassio_api: true, hassio_role: "default"})

      for path <- ["/store", "/mounts", "/available_updates", "/supervisor/stats"] do
        assert call(:get, path, manager).status == 200, "manager was refused #{path}"
        assert call(:get, path, plain).status == 403, "default role reached #{path}"
      end
    end

    test "a backup-role add-on reaches /backups but not the manager surface" do
      backup = addon_token("tier_gate_backup", %{hassio_api: true, hassio_role: "backup"})

      assert call(:get, "/backups", backup).status == 200
      assert call(:get, "/backups/info", backup).status == 200
      assert call(:get, "/store", backup).status == 403
      assert call(:get, "/core/logs", backup).status == 403
    end

    test "a homeassistant-role add-on reaches /core but not /backups" do
      ha = addon_token("tier_gate_ha", %{hassio_api: true, hassio_role: "homeassistant"})

      assert call(:get, "/backups", ha).status == 403
      assert call(:get, "/store", ha).status == 403
      # Reaches the handler rather than the gate — the point is it is not 403.
      refute call(:post, "/core/options", ha).status == 403
    end

    test "a default-role add-on still reads the /.+/info surface" do
      plain = addon_token("tier_gate_info", %{hassio_api: true, hassio_role: "default"})

      for path <- ["/supervisor/info", "/core/info", "/os/info", "/host/info", "/hardware/info"] do
        assert call(:get, path, plain).status == 200, "default role was refused #{path}"
      end
    end

    test "every add-on reaches the api_bypass surface, hassio_api or not" do
      plain = addon_token("tier_gate_bypass")

      assert call(:get, "/info", plain).status == 200
      assert call(:get, "/services", plain).status == 200
      assert call(:get, "/supervisor/ping", plain).status == 200
    end
  end

  describe "ordering" do
    test "a missing token is still 401, decided before any tier is computed" do
      conn = conn(:get, "/store") |> Router.call(@opts)
      assert conn.status == 401
    end

    test "an unknown path is 403 for a caller that cannot reach it, not 404" do
      token = addon_token("tier_gate_unknown")
      assert call(:get, "/no/such/route", token).status == 403
      # Core sees the honest 404.
      assert call_as_core(:get, "/no/such/route").status == 404
    end

    test "the icon/logo exemption still runs ahead of the gate" do
      # No token at all, and no tier — `Vagus.API.Auth.unauthenticated?/1`
      # short-circuits before the table is consulted. Absent asset ⇒ upstream's
      # 400, which is proof the handler ran.
      conn = conn(:get, "/addons/core_mqtt/icon") |> Router.call(@opts)
      refute conn.status in [401, 403]
    end
  end
end
