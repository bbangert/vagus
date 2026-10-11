defmodule Vagus.API.AuthTierGateTest do
  @moduledoc """
  End-to-end proof that `Vagus.API.Tiers` is actually applied, through the
  real `Vagus.API.Router` pipeline.

  `Vagus.API.TiersTest` pins the table; this file pins that the table *runs*.
  The 2026-07-29 audit's root cause was not a wrong table — there was no table,
  and `supervisor_only/2` was applied by hand to some routes and not others. A
  table nobody consults would reproduce that exactly, so the assertions here
  go through `Router.call/2` rather than calling `Tiers` directly.

  `async: false`: `GET /addons` reads the global state other files seed.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import Vagus.AppFixtures

  alias Vagus.Addon.Config
  alias Vagus.API.{Auth, Router, Token}

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

  defp addon_token(slug, grants \\ %{}),
    do: register_app_token(app_config(slug), identity: grants)

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

  describe "a tier refusal is counted, never logged with the caller's bytes" do
    import ExUnit.CaptureLog

    @marker "zz-authz-marker"

    test "off device, one line naming the tier the path demands and not the path" do
      token = addon_token("tier_gate_count_host")

      log = capture_log(fn -> assert call(:get, "/store/#{@marker}", token).status == 403 end)

      assert log =~ "authz/manager"
      refute log =~ @marker

      log = capture_log(fn -> assert call(:post, "/#{@marker}/x", token).status == 403 end)

      assert log =~ "authz/admin"
      refute log =~ @marker
    end

    test "on device, it is cast to the guard's authz bucket and logs nothing per request" do
      prev = Application.get_env(:vagus, :api_source_guard)
      Application.put_env(:vagus, :api_source_guard, true)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:vagus, :api_source_guard),
          else: Application.put_env(:vagus, :api_source_guard, prev)
      end)

      # The test stands in for the guard: the real one reports and resets on
      # a timer, so its state is not something to assert on.
      Process.register(self(), Vagus.API.SourceGuard)
      token = addon_token("tier_gate_count_device")

      log =
        capture_log(fn ->
          for _ <- 1..3, do: assert(call(:get, "/store/#{@marker}", token).status == 403)
        end)

      refute log =~ "authz/"

      for _ <- 1..3 do
        assert_received {:"$gen_cast", {:filtered, :authz, "authz/manager"}}
      end

      refute_received {:"$gen_cast", _other}
    end

    test "a permitted request counts nothing" do
      log = capture_log(fn -> assert call_as_core(:get, "/info").status == 200 end)
      refute log =~ "authz/"
    end
  end

  # `Plug.Router` matches percent-decoded segments. Graded on the raw path
  # alone, `/core/%72estart` is the `/core/.+` family and only the handler's
  # own guard stands between a homeassistant-role app and a Core restart.
  describe "an encoded spelling of a route" do
    import ExUnit.CaptureLog

    @principals ~w(none default homeassistant backup manager admin)

    defp refused_at_the_gate(method, path, token) do
      {conn, log} = with_log(fn -> call(method, path, token) end)

      assert conn.status == 403, "#{path} answered #{conn.status}"
      assert log =~ "authz/", "#{path} was refused by its handler, not the gate"
      refute Map.has_key?(conn.private, :plug_route), "#{path} reached :match"
      log
    end

    test "is refused by the gate, before the router matches it" do
      ha = addon_token("enc_gate_ha", %{hassio_api: true, hassio_role: "homeassistant"})
      manager = addon_token("enc_gate_manager", %{hassio_api: true, hassio_role: "manager"})
      admin = addon_token("enc_gate_admin", %{hassio_api: true, hassio_role: "admin"})

      assert refused_at_the_gate(:post, "/core/%72estart", ha) =~ "authz/supervisor"
      assert refused_at_the_gate(:post, "/c%6Fre/restart", admin) =~ "authz/supervisor"
      assert refused_at_the_gate(:post, "/addons/core_mqtt/%73ecurity", manager) =~ "authz/admin"
      assert refused_at_the_gate(:post, "/addons/core_mqtt/s%74art", admin) =~ "authz/supervisor"
      assert refused_at_the_gate(:get, "/os/datadisk/%6Cist", manager) =~ "authz/supervisor"
    end

    test "still reaches its handler for a caller the plain spelling admits" do
      assert call_as_core(:get, "/supervisor/%69nfo").status == 200
    end

    test "of a blacklisted path is refused as blacklisted, token or not" do
      for path <- ["/core/api/%68assio/x", "/homeassistant/%61pi/hassio_auth"] do
        log =
          capture_log(fn ->
            assert call_as_core(:get, path).status == 403
            assert (conn(:get, path) |> Router.call(@opts)).status == 403
          end)

        assert log =~ "refused a blacklisted"
      end
    end

    test "of a token-free path is not token-free" do
      for path <- ["/supervisor/%70ing", "/addons/core_mqtt/%69con", "/%73upervisor/ping"] do
        assert (conn(:get, path) |> Router.call(@opts)).status == 401, path
      end
    end

    defp spellings(route, path) do
      patterns = String.split(route, "/", trim: true)
      segments = String.split(path, "/", trim: true)

      for {{pattern, segment}, index} <- Enum.with_index(Enum.zip(patterns, segments)),
          # A parameter has no spelling the table knows; its first byte will do.
          last = if(String.starts_with?(pattern, ":"), do: 0, else: byte_size(segment) - 1),
          at <- 0..last do
        <<head::binary-size(at), byte, tail::binary>> = segment
        encoded = head <> "%" <> Base.encode16(<<byte>>) <> tail
        "/" <> Enum.join(List.replace_at(segments, index, encoded), "/")
      end
    end

    defp gate(method, path, token) do
      conn = conn(method, path)
      conn = if token, do: put_req_header(conn, "x-supervisor-token", token), else: conn
      Vagus.API.Auth.call(conn, []).halted
    end

    # Every route, every byte of every literal segment, every principal.
    test "is never graded more leniently than the plain spelling" do
      tokens =
        [nil, Token.get(), addon_token("enc_prop_none", %{hassio_role: "admin"})] ++
          for role <- tl(@principals) do
            addon_token("enc_prop_#{role}", %{hassio_api: true, hassio_role: role})
          end

      cases =
        for {method, route, path} <- Vagus.RouterRoutes.instances(),
            encoded <- spellings(route, path),
            do: {method |> String.downcase() |> String.to_existing_atom(), path, encoded}

      assert length(cases) > 2000

      lenient =
        for {method, path, encoded} <- cases,
            token <- tokens,
            gate(method, path, token) and not gate(method, encoded, token),
            do: {method, encoded}

      assert Enum.uniq(lenient) == []
    end
  end

  # The grants a handler used to decide alone. The handler's guard is still
  # there; what is pinned here is that the table refuses first, with the
  # status and message the handler gives.
  describe "a predicate refuses at the gate, before the handler" do
    import ExUnit.CaptureLog

    defp gate_refusal(method, path, token) do
      {conn, log} = with_log(fn -> call(method, path, token) end)

      refute Map.has_key?(conn.private, :plug_route), "#{path} reached :match"
      [_line, label] = Regex.run(~r/refused a request \(([^)]*)\)/, log)
      {conn.status, Jason.decode!(conn.resp_body), label}
    end

    defp refused(message), do: %{"result" => "error", "message" => message}

    setup do
      install_app(app_config("pred_gate_theirs"))
      :ok
    end

    test "another app's info, stats and logs" do
      default = addon_token("pred_gate_default", %{hassio_api: true, hassio_role: "default"})
      manager = addon_token("pred_gate_manager", %{hassio_api: true, hassio_role: "manager"})
      not_yours = refused("Not authorized for this add-on")

      assert gate_refusal(:get, "/addons/pred_gate_theirs/info", default) ==
               {403, not_yours, "authz/default+subject"}

      for tail <- ~w(stats logs logs/latest logs/follow logs/boots/0 logs/boots/0/follow) do
        assert gate_refusal(:get, "/addons/pred_gate_theirs/#{tail}", manager) ==
                 {403, not_yours, "authz/manager+subject"},
               tail
      end
    end

    test "the reserved panel slug's info" do
      admin = addon_token("pred_gate_admin", %{hassio_api: true, hassio_role: "admin"})

      assert gate_refusal(:get, "/addons/vagus/info", admin) ==
               {403, refused("Not authorized for this add-on"), "authz/default+caller"}
    end

    test "another app's effective options" do
      manager = addon_token("pred_gate_manager", %{hassio_api: true, hassio_role: "manager"})

      assert gate_refusal(:get, "/addons/pred_gate_theirs/options/config", manager) ==
               {403, refused("This can be only read by the app itself!"), "authz/manager+subject"}
    end

    test "an admin app setting protection, its own included" do
      admin = addon_token("pred_gate_admin", %{hassio_api: true, hassio_role: "admin"})

      for slug <- ~w(pred_gate_admin pred_gate_theirs) do
        assert gate_refusal(:post, "/addons/#{slug}/security", admin) ==
                 {403, refused("unauthorized"), "authz/admin+caller"}
      end

      assert {:ok, %{protected: true}} = app_info("pred_gate_admin")
    end

    # 401, as upstream's `require_home_assistant` answers.
    test "an admin app opening or validating an ingress session" do
      admin = addon_token("pred_gate_admin", %{hassio_api: true, hassio_role: "admin"})

      for path <- ~w(/ingress/session /ingress/validate_session) do
        assert gate_refusal(:post, path, admin) ==
                 {401, refused("unauthorized"), "authz/admin+caller"}
      end
    end

    test "the auth API without auth_api, Core included" do
      admin = addon_token("pred_gate_admin", %{hassio_api: true, hassio_role: "admin"})

      answer =
        {403, refused("Caller is not allowed to access the auth API"), "authz/bypass+requires"}

      for method <- [:get, :post], token <- [admin, Token.get()] do
        assert gate_refusal(method, "/auth", token) == answer
      end
    end

    test "a service the app declares no role for" do
      manager = addon_token("pred_gate_manager", %{hassio_api: true, hassio_role: "manager"})

      for {method, message} <- [
            get: "Caller not authorized for 'mqtt'",
            post: "Caller may not provide 'mqtt'",
            delete: "Caller may not delete 'mqtt'"
          ] do
        assert gate_refusal(method, "/services/mqtt", manager) ==
                 {403, refused(message), "authz/bypass+requires"}
      end
    end

    # The predicate refuses whatever the method; the answer is the router's.
    test "a method the route does not serve is still a 404" do
      manager = addon_token("pred_gate_manager", %{hassio_api: true, hassio_role: "manager"})

      for {method, path, label} <- [
            {:post, "/addons/pred_gate_theirs/info", "authz/default+subject"},
            {:get, "/addons/pred_gate_theirs/security", "authz/admin+caller"},
            {:put, "/services/mqtt", "authz/bypass+requires"}
          ] do
        token =
          if path =~ "security",
            do: addon_token("pred_gate_admin", %{hassio_api: true, hassio_role: "admin"}),
            else: manager

        assert gate_refusal(method, path, token) == {404, refused("not found"), label}
      end
    end

    test "an encoded spelling of another app's slug, or of the route" do
      default = addon_token("pred_gate_default", %{hassio_api: true, hassio_role: "default"})
      manager = addon_token("pred_gate_manager", %{hassio_api: true, hassio_role: "manager"})
      not_yours = refused("Not authorized for this add-on")

      assert gate_refusal(:get, "/addons/%70red_gate_theirs/info", default) ==
               {403, not_yours, "authz/default+subject"}

      # Raw, this is the manager family, which a default app does not reach.
      assert gate_refusal(:get, "/addons/pred_gate_theirs/%69nfo", default) ==
               {403, refused("unauthorized"), "authz/manager+subject"}

      assert gate_refusal(:get, "/addons/pred_gate_theirs/%69nfo", manager) ==
               {403, not_yours, "authz/manager+subject"}
    end

    test "an encoded spelling of the caller's own slug still reaches its handler" do
      default = addon_token("pred_gate_default", %{hassio_api: true, hassio_role: "default"})

      for path <- ["/addons/%70red_gate_default/info", "/addons/%73elf/info"] do
        conn = call(:get, path, default)

        assert conn.status == 200, path
        assert {"/addons/:slug/info", _handler} = conn.private.plug_route
      end
    end

    test "on device, the refusal is cast to the guard's authz bucket" do
      prev = Application.get_env(:vagus, :api_source_guard)
      Application.put_env(:vagus, :api_source_guard, true)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:vagus, :api_source_guard),
          else: Application.put_env(:vagus, :api_source_guard, prev)
      end)

      Process.register(self(), Vagus.API.SourceGuard)
      manager = addon_token("pred_gate_device", %{hassio_api: true, hassio_role: "manager"})

      log =
        capture_log(fn ->
          assert call(:get, "/addons/pred_gate_theirs/stats", manager).status == 403
        end)

      refute log =~ "authz/"
      assert_received {:"$gen_cast", {:filtered, :authz, "authz/manager+subject"}}
      refute_received {:"$gen_cast", _other}
    end

    test "a caller holding the grant reaches the handler, and nothing is counted" do
      default =
        addon_token("pred_gate_holder", %{
          hassio_api: true,
          hassio_role: "default",
          auth_api: true,
          services_role: %{"mqtt" => "want"}
        })

      for {method, path} <- [
            get: "/addons/pred_gate_holder/info",
            get: "/addons/self/info",
            get: "/auth",
            get: "/services/mqtt"
          ] do
        {conn, log} = with_log(fn -> call(method, path, default) end)

        assert {_route, _handler} = conn.private.plug_route
        refute log =~ "authz/", path
      end

      {conn, log} = with_log(fn -> call_as_core(:get, "/addons/pred_gate_theirs/info") end)
      assert conn.status == 200
      refute log =~ "authz/"
    end

    # Neither the service a body names nor a message's owner is in the path.
    test "the discovery rows are left to the handler" do
      owner =
        addon_token("pred_gate_disc_owner", %{
          hassio_api: true,
          hassio_role: "default",
          discovery: ["mqtt"]
        })

      admin = addon_token("pred_gate_admin", %{hassio_api: true, hassio_role: "admin"})
      message = Jason.encode!(%{service: "mqtt", config: %{}})

      discovery = fn method, path, body, token ->
        with_log(fn ->
          conn(method, path, body)
          |> put_req_header("content-type", "application/json")
          |> put_req_header("x-supervisor-token", token)
          |> Router.call(@opts)
        end)
      end

      {created, _log} = discovery.(:post, "/discovery", message, owner)
      assert %{"data" => %{"uuid" => uuid}} = Jason.decode!(created.resp_body)

      for {method, path, body, status, said} <- [
            {:get, "/discovery", nil, 401, "unauthorized"},
            {:get, "/discovery/#{uuid}", nil, 401, "unauthorized"},
            {:post, "/discovery", message, 403, "Caller may not provide this discovery"},
            {:delete, "/discovery/#{uuid}", nil, 403, "Caller does not own this discovery"}
          ] do
        {conn, log} = discovery.(method, path, body, admin)

        assert {conn.status, Jason.decode!(conn.resp_body)} == {status, refused(said)},
               "#{method} #{path}"

        assert {_route, _handler} = conn.private.plug_route
        refute log =~ "authz/", path
      end

      {deleted, _log} = discovery.(:delete, "/discovery/#{uuid}", nil, owner)
      assert deleted.status == 200
    end

    # The message would otherwise carry bytes JSON cannot hold, and the
    # envelope raised: a 500 from the gate and from the handler alike.
    test "a service name that is not UTF-8 is refused, by the gate and by the handler" do
      manager = addon_token("pred_gate_manager", %{hassio_api: true, hassio_role: "manager"})

      for {method, message} <- [
            get: "Caller not authorized for this service",
            post: "Caller may not provide this service",
            delete: "Caller may not delete this service"
          ] do
        assert gate_refusal(method, "/services/zz%FFmarker", manager) ==
                 {403, refused(message), "authz/bypass+requires"}
      end

      # Core may read any service, so only the handler refuses it a write.
      for {method, message} <- [
            post: "Caller may not provide this service",
            delete: "Caller may not delete this service"
          ] do
        {conn, log} = with_log(fn -> call_as_core(method, "/services/zz%FFmarker") end)

        assert {conn.status, Jason.decode!(conn.resp_body)} == {403, refused(message)}
        assert {"/services/:service", _handler} = conn.private.plug_route
        refute log =~ "marker"
      end

      {_conn, log} = with_log(fn -> call(:get, "/services/zz%FFmarker", manager) end)
      refute log =~ "marker"
    end
  end

  describe "Core keeps everything" do
    @fixture Path.expand("../../fixtures/vagus-authz-table.json", __DIR__)
             |> File.read!()
             |> Jason.decode!()
             |> Map.fetch!("routes")

    # `Router.match/2` records the route it chose without running it, so
    # this tells a real route from the catch-all without a handler's own 404
    # getting in the way, and without restarting Core or the host.
    #
    # The auth API's two routes are the exception: `auth_api` is an app's
    # grant, and their handler refused Core before the table did.
    test "every fixture row passes the gate and matches the route it names" do
      for row <- @fixture do
        conn =
          row["method"]
          |> String.downcase()
          |> String.to_existing_atom()
          |> conn(row["path"])
          |> put_req_header("authorization", "Bearer " <> Token.get())

        gated = Vagus.API.Auth.call(conn, [])

        if row["predicates"] == %{"requires" => "auth_api"} do
          assert row["path"] == "/auth"
          assert gated.status == 403
        else
          refute gated.halted, "Core was refused #{row["method"]} #{row["path"]}"
        end

        assert {route, _handler} = Router.match(conn, []).private.plug_route
        assert route == row["route"], "#{row["method"]} #{row["path"]} matched #{route}"
      end
    end

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

  # `protected` is what gates `full_access`/`host_pid`/`docker_api`, so an
  # add-on that could clear its own would be escalating, not configuring. Two
  # independent guards say no, and both are pinned here: `Tiers` refuses the
  # `self` spelling for any add-on, and `handle_addon_security/2` is
  # supervisor-only — which is what closes the by-own-slug spelling an
  # `hassio_role: admin` add-on otherwise clears the table with.
  describe "POST /addons/:slug/security is unreachable from an add-on token" do
    setup do
      {:ok, config} =
        Config.parse(%{
          "name" => "Sec",
          "version" => "1",
          "slug" => "tier_gate_sec_admin",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "x/y"
        })

      install_app(config)
      :ok
    end

    test "an admin-role add-on is refused on both spellings, and nothing is stored" do
      token =
        addon_token("tier_gate_sec_admin", %{hassio_api: true, hassio_role: "admin"})

      assert call(:post, "/addons/self/security", token).status == 403
      assert call(:post, "/addons/tier_gate_sec_admin/security", token).status == 403
      assert {:ok, %{protected: true}} = app_info("tier_gate_sec_admin")
    end

    test "a plain add-on is refused too" do
      token = addon_token("tier_gate_sec_plain")

      assert call(:post, "/addons/self/security", token).status == 403
      assert call(:post, "/addons/tier_gate_sec_admin/security", token).status == 403
    end
  end

  # Audit A7. The tier gate (phase 1) closed `GET /addons` to a default-role
  # add-on, but a `hassio_role: manager` one legitimately reaches it — so the
  # payload itself must not carry secrets. `_list_apps_data/0` upstream emits
  # none of these three to any caller.
  # Both the Supervisor API and the Core proxy name their caller with this.
  describe "principal/1" do
    test "the supervisor's token, an app's token, and nothing else" do
      app = addon_token("tier_gate_principal", %{hassio_role: "manager"})
      supervisor = Token.get()

      assert Auth.principal(supervisor) == :supervisor

      assert {:addon, %{slug: "tier_gate_principal", hassio_role: "manager"}} =
               Auth.principal(app)

      strangers =
        [nil, "", "garbage", "Bearer " <> supervisor, "Bearer " <> app] ++
          for token <- [supervisor, app],
              stranger <- [
                binary_part(token, 0, byte_size(token) - 1),
                binary_part(token, 1, byte_size(token) - 1),
                token <> "x",
                token <> " ",
                String.upcase(token) <> String.downcase(token)
              ],
              do: stranger

      for stranger <- strangers do
        assert Auth.principal(stranger) == :anonymous
      end
    end

    test "the router answers each of them as before" do
      app = addon_token("tier_gate_principal_route", %{hassio_api: true, hassio_role: "manager"})

      assert call(:get, "/store", Token.get()).status == 200
      assert call(:get, "/store", app).status == 200
      assert call(:get, "/store", "").status == 401
      assert call(:get, "/store", app <> "x").status == 401
      assert call(:get, "/store", binary_part(app, 0, byte_size(app) - 1)).status == 401
      assert conn(:get, "/store") |> Router.call(@opts) |> Map.fetch!(:status) == 401
    end
  end

  describe "GET /addons carries no secrets (A7)" do
    setup do
      {:ok, config} =
        Config.parse(%{
          "name" => "Secretful",
          "version" => "1",
          "slug" => "core_secretful",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "x/y",
          "ingress" => true,
          "options" => %{"api_key" => "default"},
          "schema" => %{"api_key" => "str"}
        })

      install_app(config, state: :started, options: %{"api_key" => "s3cr3t"})
      :ok
    end

    test "a manager add-on reading the list sees no options and no ingress token" do
      token = addon_token("tier_gate_list", %{hassio_api: true, hassio_role: "manager"})
      conn = call(:get, "/addons", token)

      assert conn.status == 200

      entry =
        Enum.find(
          Jason.decode!(conn.resp_body)["data"]["addons"],
          &(&1["slug"] == "core_secretful")
        )

      refute Map.has_key?(entry, "options")
      refute Map.has_key?(entry, "ingress_entry")
      refute Map.has_key?(entry, "ingress_url")

      # The whole body, not just the one entry — the token must not appear
      # anywhere, and neither must the option value.
      refute conn.resp_body =~ "s3cr3t"
      {:ok, state} = app_info("core_secretful")
      refute conn.resp_body =~ state.ingress_token
    end

    test "Core is subject to the same list shape — the rule is unconditional" do
      conn = call_as_core(:get, "/addons")

      assert conn.status == 200
      refute conn.resp_body =~ "s3cr3t"
    end

    test "the list still carries what the dashboard renders from" do
      # Guards the trim: dropping three keys must not gut the entry.
      conn = call_as_core(:get, "/addons")

      entry =
        Enum.find(
          Jason.decode!(conn.resp_body)["data"]["addons"],
          &(&1["slug"] == "core_secretful")
        )

      for key <- ~w(name slug version state icon logo repository update_available) do
        assert Map.has_key?(entry, key), "the list lost #{key}"
      end
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

    # Audit B1 (phase 8). `/supervisor/ping` is now exempted the same way the
    # icon/logo GETs are — no token, no tier — because upstream's
    # `no_security_check` answers it before `token_validation` runs at all.
    test "the ping exemption runs ahead of the gate with no token at all" do
      conn = conn(:get, "/supervisor/ping") |> Router.call(@opts)
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["result"] == "ok"
    end

    test "ping does not grade even a token that IS present" do
      # Exactly upstream's `request[REQUEST_FROM] = None` on this path: the
      # short-circuit happens BEFORE token handling, so a caller that does
      # carry a token — genuine or garbage — still isn't graded. Looks wrong
      # at a glance; it is what upstream does.
      assert call(:get, "/supervisor/ping", Token.get()).status == 200
      assert call(:get, "/supervisor/ping", "not-a-real-token").status == 200
      assert call_as_core(:get, "/supervisor/ping").status == 200
    end

    # The table's anonymous rows carry no method, so a token of any tier
    # clears the gate on these paths. Nothing but the GET is routed there.
    test "a token-bearing non-GET on a token-free path finds no handler" do
      token = addon_token("tier_gate_anon_row")

      for method <- [:post, :delete], path <- ["/supervisor/ping", "/addons/core_mqtt/icon"] do
        assert call(method, path, token).status == 404
      end
    end

    test "the root path is admin, like any path with no row" do
      manager = addon_token("tier_gate_root", %{hassio_api: true, hassio_role: "manager"})

      assert call(:get, "/", manager).status == 403
      assert call_as_core(:get, "/").status == 404
    end

    test "a non-GET on the same path is NOT carved out" do
      # Method IS consulted for the carve-out itself (unlike `Tiers.required/1`
      # over the table) — `unauthenticated?/1` matches `method: "GET"`
      # explicitly, mirroring the icon/logo exemption's same restriction.
      conn = conn(:post, "/supervisor/ping") |> Router.call(@opts)
      assert conn.status == 401
    end
  end

  # Security review finding (phase 8, NEW — not from the 2026-07-29 audit).
  # Upstream's `BLACKLIST` in `security.py` refuses these paths for every
  # caller, Core included, before a token is even read. Vagus has no
  # Core-API proxy yet, so nothing serves them today; the deny must predate
  # the feature landing, or `Tiers.required/1`'s `:admin` catch-all would let
  # an admin-role add-on reach a proxy hop that comes back as Core.
  describe "BLACKLIST" do
    @blacklisted ["/core/api/hassio/anything", "/homeassistant/api/hassio/x"]

    test "refused with a supervisor token" do
      for path <- @blacklisted do
        assert call_as_core(:get, path).status == 403, "#{path} was reachable by Core"
      end
    end

    test "refused with an add-on token" do
      token = addon_token("blacklist_addon", %{hassio_api: true, hassio_role: "admin"})

      for path <- @blacklisted do
        assert call(:get, path, token).status == 403, "#{path} was reachable by an add-on"
      end
    end

    test "refused with NO token — proof it runs before token validation" do
      # The property that matters: an unauthenticated request to any other
      # path gets 401 (see "a missing token is still 401" above). Getting
      # 403 here instead, not 401, is the evidence that `Vagus.API.Auth.call/2`
      # checked `Tiers.blacklisted?/1` before it ever tried to resolve a
      # caller.
      for path <- @blacklisted do
        conn = conn(:get, path) |> Router.call(@opts)
        assert conn.status == 403, "#{path} answered #{conn.status} with no token"
      end
    end

    test "a near-miss is not blacklisted, with or without a token" do
      for path <- ["/core/api/other", "/core/apixhassio"] do
        refute call_as_core(:get, path).status == 403, "#{path} was wrongly blacklisted for Core"

        conn = conn(:get, path) |> Router.call(@opts)
        refute conn.status == 403, "#{path} was wrongly blacklisted with no token"
      end
    end
  end
end
