defmodule Vagus.API.RouterTest do
  # async: true is required here: the whole suite runs under `Mox.set_mox_global()`
  # (test_helper), and this file only ever OBSERVES the global backend stubs —
  # forcing async: false makes ExUnit run it in the sync phase where those global
  # stubs aren't in scope (Mox.UnexpectedCallError). It only ever READS singleton
  # data (never registers tokens/services).
  #
  # It used to also claim the race against those globals "does not actually
  # occur", because ExUnit finished the async phase before the `async: false`
  # sibling router tests mutated them. That is no longer true — later phases
  # added *async* files that install add-ons, and the idle-list assertion below
  # duly failed on a full-suite run. So: assert SHAPE here, never global
  # emptiness. See that test's own comment.
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Vagus.API.{Router, Token}

  @opts Router.init([])

  # Field lists pinned independently from `Vagus.API.Models.*`, transcribed
  # directly from `docs/contract-2026.7.md` §6/§10-21 — this is what
  # catches drift between the model modules and the actual contract, not
  # just drift between the router and the model modules.
  @root_info_keys ~w(supervisor homeassistant hassos docker hostname operating_system
                     features machine machine_id arch state supported_arch supported
                     channel logging timezone)

  @supervisor_info_keys ~w(version version_latest update_available channel arch supported
                           healthy ip_address timezone logging debug debug_block diagnostics
                           auto_update country detect_blocking_io feature_flags)

  @core_info_keys ~w(version version_latest update_available machine ip_address arch image
                     boot port ssl watchdog audio_input audio_output backups_exclude_database
                     duplicate_log_file)

  @os_info_keys ~w(version version_latest version_pending update_available board boot data_disk
                   boot_slots)

  @host_info_keys ~w(agent_version apparmor_version chassis virtualization cpe deployment
                     disk_free disk_total disk_used disk_life_time features hostname
                     llmnr_hostname kernel operating_system timezone dt_utc dt_synchronized
                     use_ntp startup_time boot_timestamp broadcast_llmnr broadcast_mdns)

  @network_info_keys ~w(interfaces docker host_internet supervisor_internet)
  @network_interface_keys ~w(interface type enabled connected primary mac ipv4 ipv6 wifi vlan
                             mdns llmnr)

  @resolution_info_keys ~w(suggestions unsupported unhealthy issues checks)
  @jobs_info_keys ~w(ignore_conditions jobs)
  @addons_list_keys ~w(addons)
  @core_stats_keys ~w(cpu_percent memory_usage memory_limit memory_percent network_rx
                      network_tx blk_read blk_write)
  @store_info_keys ~w(addons repositories)
  @mounts_info_keys ~w(default_backup_mount mounts)
  @available_updates_keys ~w(available_updates)

  # {method, path, pinned key list for the "data" map}
  @get_endpoints [
    {:get, "/info", @root_info_keys},
    {:get, "/supervisor/info", @supervisor_info_keys},
    {:get, "/core/info", @core_info_keys},
    {:get, "/os/info", @os_info_keys},
    {:get, "/host/info", @host_info_keys},
    {:get, "/network/info", @network_info_keys},
    {:get, "/store", @store_info_keys},
    {:get, "/mounts", @mounts_info_keys},
    {:get, "/resolution/info", @resolution_info_keys},
    {:get, "/jobs/info", @jobs_info_keys},
    {:get, "/addons", @addons_list_keys},
    {:get, "/core/stats", @core_stats_keys},
    {:get, "/supervisor/stats", @core_stats_keys},
    {:get, "/available_updates", @available_updates_keys}
  ]

  # POST endpoints that are honest no-ops: accepted, ok envelope, empty data.
  @noop_endpoints [
    "/supervisor/options",
    "/supervisor/reload",
    "/refresh_updates",
    "/reload_updates",
    "/store/reload",
    "/core/options"
  ]

  # POST endpoints that are honest errors: not supported yet.
  @unsupported_endpoints [
    "/supervisor/restart",
    "/supervisor/update"
  ]

  defp call(conn), do: Router.call(conn, @opts)

  defp authed(conn) do
    put_req_header(conn, "authorization", "Bearer " <> Token.get())
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp keys(map), do: map |> Map.keys() |> MapSet.new()

  describe "GET endpoints (envelope + exact key-set match against the contract)" do
    for {method, path, expected_keys} <- @get_endpoints do
      test "#{method} #{path} returns an ok envelope with exactly the pinned field set" do
        conn = conn(unquote(method), unquote(path)) |> authed() |> call()

        assert conn.status == 200
        body = json_body(conn)

        assert body["result"] == "ok"
        assert Map.has_key?(body, "data")
        assert keys(body["data"]) == MapSet.new(unquote(expected_keys))
      end
    end
  end

  describe "board identity on the wire" do
    # The key-set tests above only prove `machine` is PRESENT. This pins the
    # value, so a board that ships the wrong identity fails the contract
    # test too — not just StaticData's unit test. Reads the configured value
    # rather than a literal: config/<target>.exs owns it per board
    # ("raspberrypi3-64" on rpi3_64, "generic-aarch64" on dragon_q6a) and
    # config/test.exs pins it for the suite.
    for path <- ["/info", "/core/info"] do
      test "GET #{path} reports the configured machine" do
        conn = conn(:get, unquote(path)) |> authed() |> call()

        assert json_body(conn)["data"]["machine"] ==
                 Application.get_env(:vagus, :machine)
      end
    end
  end

  describe "GET /network/info nested NetworkInterface shape" do
    test "each interface entry matches the pinned NetworkInterface key set" do
      conn = conn(:get, "/network/info") |> authed() |> call()
      body = json_body(conn)

      interfaces = body["data"]["interfaces"]
      assert is_list(interfaces)
      assert interfaces != []

      for interface <- interfaces do
        assert keys(interface) == MapSet.new(@network_interface_keys)
      end
    end

    test "the docker field is present with DockerNetwork's four keys" do
      conn = conn(:get, "/network/info") |> authed() |> call()
      body = json_body(conn)

      assert keys(body["data"]["docker"]) == MapSet.new(~w(interface address gateway dns))
    end
  end

  describe "GET /os/info nested BootSlot shape (P4-T2)" do
    test "boot_slots has both A and B, each matching the pinned BootSlot key set" do
      conn = conn(:get, "/os/info") |> authed() |> call()
      boot_slots = json_body(conn)["data"]["boot_slots"]

      assert Map.keys(boot_slots) |> Enum.sort() == ["A", "B"]

      for {_slot, attrs} <- boot_slots do
        assert keys(attrs) == MapSet.new(~w(state status version))
      end
    end
  end

  describe "idle list-type fields are [] never null" do
    test "resolution/info's list fields are all empty lists" do
      conn = conn(:get, "/resolution/info") |> authed() |> call()
      data = json_body(conn)["data"]

      for field <- @resolution_info_keys do
        assert data[field] == []
      end
    end

    # The bug class this guards is a list-typed field serialising as `null`
    # instead of `[]` — which crashed Core's hassio coordinator once already
    # (`/store`'s missing `installed`, session 6). `is_list/1` pins exactly
    # that, and unlike `== []` it is race-free: every path below except
    # `/mounts` projects SHARED singleton state (`Vagus.Addon.State`, the
    # jobs registry) that concurrent async test files legitimately write to.
    #
    # This file's async-required header used to claim that race "does not
    # actually occur" because the async phase finished before the
    # `async: false` siblings ran. That stopped being true once later phases
    # added async tests which install add-ons — this assertion failed on a
    # full-suite run with a non-empty `/addons`. Same resolution the
    # `/ingress/panels` and `/discovery` assertions in this file already
    # took: global emptiness is not assertable here; content coverage lives
    # in the per-family test files with controlled slugs.
    test "jobs/info, addons, store, mounts, available_updates idle lists are lists" do
      for {path, field} <- [
            {"/jobs/info", "jobs"},
            {"/addons", "addons"},
            {"/store", "addons"},
            {"/mounts", "mounts"},
            {"/available_updates", "available_updates"}
          ] do
        conn = conn(:get, path) |> authed() |> call()
        assert is_list(json_body(conn)["data"][field]), "#{path} -> #{field} must be a list"
      end
    end

    # `/mounts` owns no mutable state — Vagus never mounts anything — so it
    # is the one path here whose emptiness IS stable enough to pin.
    test "mounts is honestly empty, not merely list-shaped" do
      conn = conn(:get, "/mounts") |> authed() |> call()
      assert json_body(conn)["data"]["mounts"] == []
    end
  end

  describe "GET /supervisor/ping" do
    test "returns an ok envelope" do
      conn = conn(:get, "/supervisor/ping") |> authed() |> call()
      assert conn.status == 200
      assert json_body(conn)["result"] == "ok"
    end
  end

  describe "GET /ingress/panels" do
    # Global emptiness cannot be asserted here: this file is async and the
    # panels map projects the SHARED `Vagus.Addon.State`, which concurrent
    # test files legitimately install add-ons into (seed-6 interleaving
    # with auth_tier_gate_test's `core_secretful`, 2026-07-30). Content
    # mapping is pinned with controlled slugs in ingress_router_test.exs
    # and panels_test.exs; this test only guards route + envelope shape.
    test "returns the ok envelope with a panels map" do
      conn = conn(:get, "/ingress/panels") |> authed() |> call()
      assert conn.status == 200
      assert json_body(conn)["result"] == "ok"
      assert is_map(json_body(conn)["data"]["panels"])
    end
  end

  describe "GET /discovery" do
    # Same async-vs-shared-state constraint as /ingress/panels above:
    # discovery messages live in a shared store that discovery_router_test
    # populates concurrently, so only route + shape are asserted here.
    test "returns the ok envelope with a discovery list + services index" do
      conn = conn(:get, "/discovery") |> authed() |> call()
      assert conn.status == 200
      assert json_body(conn)["result"] == "ok"
      assert is_list(json_body(conn)["data"]["discovery"])
      assert is_map(json_body(conn)["data"]["services"])
    end
  end

  describe "GET /store/addons (P2-T3)" do
    test "empty catalog → empty addons list" do
      conn = conn(:get, "/store/addons") |> authed() |> call()
      assert conn.status == 200
      assert json_body(conn)["data"] == %{"addons" => []}
    end

    test "unknown store slug → 404" do
      conn = conn(:get, "/store/addons/core_ghost") |> authed() |> call()
      assert conn.status == 404
      assert json_body(conn)["result"] == "error"
    end
  end

  describe "GET /backups and /backups/info" do
    test "returns an empty BackupList" do
      conn = conn(:get, "/backups") |> authed() |> call()
      assert conn.status == 200
      assert json_body(conn)["data"] == %{"backups" => []}
    end

    test "returns an empty BackupsInfo with days_until_stale" do
      conn = conn(:get, "/backups/info") |> authed() |> call()
      assert conn.status == 200
      assert json_body(conn)["data"] == %{"backups" => [], "days_until_stale" => 30}
    end
  end

  describe "honest no-op POST endpoints" do
    for path <- @noop_endpoints do
      test "POST #{path} returns an ok envelope and does nothing" do
        conn = conn(:post, unquote(path), Jason.encode!(%{})) |> authed() |> req_json() |> call()

        assert conn.status == 200
        assert json_body(conn)["result"] == "ok"
        assert json_body(conn)["data"] == %{}
      end
    end

    test "POST /store/reload sends the whole envelope and nothing else" do
      # `Store.reload/1` also reports which repositories failed to fetch.
      # None of that is on the wire: upstream's `POST /store/reload` answers
      # with a bare ok envelope whether or not every repository came down,
      # and Core's client parses exactly that.
      conn = conn(:post, "/store/reload", Jason.encode!(%{})) |> authed() |> req_json() |> call()

      assert conn.status == 200
      assert json_body(conn) == %{"result" => "ok", "data" => %{}}
    end
  end

  describe "honest error POST endpoints (not supported yet)" do
    for path <- @unsupported_endpoints do
      test "POST #{path} returns a 400 error envelope" do
        conn = conn(:post, unquote(path), Jason.encode!(%{})) |> authed() |> req_json() |> call()

        assert conn.status == 400
        body = json_body(conn)
        assert body["result"] == "error"
        assert is_binary(body["message"])
      end
    end
  end

  describe "bodyless POST with an unparseable content-type reaches its route (P2-T6 regression)" do
    # Core's Supervisor client (aiohasupervisor via aiohttp) sends bodyless
    # action POSTs — e.g. `supervisor/update` during entry setup while not
    # yet onboarded — with `Content-Type: application/octet-stream,
    # Content-Length: 0`. `Plug.Parsers` must pass these through (`pass:
    # ["*/*"]`) rather than 415, or the route's honest 400 never runs and
    # `hassio` wedges in ConfigEntryNotReady (mapped by the client to a
    # generic "internal server error"). Regression for the host dev-loop gate.
    test "POST /supervisor/update (octet-stream, empty body) -> route's 400, not 415" do
      conn =
        conn(:post, "/supervisor/update", "")
        |> put_req_header("content-type", "application/octet-stream")
        |> authed()
        |> call()

      assert conn.status == 400
      body = json_body(conn)
      assert body["result"] == "error"
      assert body["message"] =~ "not supported"
    end

    test "POST /supervisor/reload (octet-stream, empty body) -> route's 200 ok, not 415" do
      conn =
        conn(:post, "/supervisor/reload", "")
        |> put_req_header("content-type", "application/octet-stream")
        |> authed()
        |> call()

      assert conn.status == 200
      assert json_body(conn)["result"] == "ok"
    end
  end

  describe "network-interface + host-action routes (P4-T3/T4), against the default host-stub backends" do
    test "GET /network/interface/eth-host/info matches the pinned NetworkInterface key set" do
      conn = conn(:get, "/network/interface/eth-host/info") |> authed() |> call()

      assert conn.status == 200
      assert keys(json_body(conn)["data"]) == MapSet.new(@network_interface_keys)
    end

    test "GET /network/interface/:ifname/info for an unknown interface -> 404 error envelope" do
      conn = conn(:get, "/network/interface/bogus0/info") |> authed() |> call()

      assert conn.status == 404
      body = json_body(conn)
      assert body["result"] == "error"
      assert body["message"] == "Interface bogus0 does not exist"
    end

    test "GET /network/interface/eth-host/accesspoints -> 400 (eth-host isn't wireless)" do
      conn = conn(:get, "/network/interface/eth-host/accesspoints") |> authed() |> call()

      assert conn.status == 400
      assert json_body(conn)["message"] =~ "not a wireless interface"
    end

    test "GET /network/interface/wlan0/accesspoints -> 404 (no wlan interface in the host stub)" do
      conn = conn(:get, "/network/interface/wlan0/accesspoints") |> authed() |> call()

      assert conn.status == 404
      assert json_body(conn)["message"] == "Interface wlan0 does not exist"
    end

    test "POST /network/interface/eth-host/update with a supported field -> 200 ok, empty data" do
      conn =
        conn(
          :post,
          "/network/interface/eth-host/update",
          Jason.encode!(%{"ipv4" => %{"method" => "auto"}})
        )
        |> authed()
        |> req_json()
        |> call()

      assert conn.status == 200
      assert json_body(conn)["result"] == "ok"
      assert json_body(conn)["data"] == %{}
    end

    test "POST /network/interface/eth-host/update with an unsupported field -> 400 listing it" do
      conn =
        conn(
          :post,
          "/network/interface/eth-host/update",
          Jason.encode!(%{"vlan" => %{"id" => 1}})
        )
        |> authed()
        |> req_json()
        |> call()

      assert conn.status == 400
      assert json_body(conn)["message"] =~ "vlan"
    end

    test "POST /network/interface/:ifname/update for an unknown interface -> 404 error envelope" do
      conn =
        conn(
          :post,
          "/network/interface/bogus0/update",
          Jason.encode!(%{"ipv4" => %{"method" => "auto"}})
        )
        |> authed()
        |> req_json()
        |> call()

      assert conn.status == 404
      assert json_body(conn)["message"] == "Interface bogus0 does not exist"
    end

    test ~S(GET /network/interface/default/info resolves to "eth-host") do
      conn = conn(:get, "/network/interface/default/info") |> authed() |> call()

      assert conn.status == 200
      assert json_body(conn)["data"]["interface"] == "eth-host"
    end

    test "POST /network/interface/eth-host/update with a literal {} body -> 400 the upstream empty-body message" do
      conn =
        conn(:post, "/network/interface/eth-host/update", Jason.encode!(%{}))
        |> authed()
        |> req_json()
        |> call()

      assert conn.status == 400
      assert json_body(conn)["message"] == "You need to supply at least one option to update"
    end

    test "POST /network/interface/eth-host/update with a wifi body -> 400 (eth-host isn't wireless)" do
      conn =
        conn(
          :post,
          "/network/interface/eth-host/update",
          Jason.encode!(%{
            "wifi" => %{"ssid" => "X", "mode" => "infrastructure", "auth" => "open"}
          })
        )
        |> authed()
        |> req_json()
        |> call()

      assert conn.status == 400
      assert json_body(conn)["message"] == "eth-host is not a wireless interface"
    end

    test "POST /host/reboot returns an ok envelope" do
      conn = conn(:post, "/host/reboot") |> authed() |> call()

      assert conn.status == 200
      assert json_body(conn)["result"] == "ok"
    end

    test "POST /host/shutdown returns an ok envelope" do
      conn = conn(:post, "/host/shutdown") |> authed() |> call()

      assert conn.status == 200
      assert json_body(conn)["result"] == "ok"
    end
  end

  describe "malformed request body -> 400 error envelope, not a bare Plug error page" do
    # `Plug.ErrorHandler` sends the response via `handle_errors/2` and then
    # unconditionally re-raises (see its `__catch__/6`) — that's fine
    # against a real adapter (Bandit swallows the reraise once the
    # response is already sent), but under `Plug.Test`'s direct `call/2`
    # there's no adapter to swallow it, so the test itself must catch the
    # reraise and read the response Plug.Test already delivered to this
    # process's mailbox (`{ref, {status, headers, body}}`).
    test "POST /core/options with invalid JSON returns a 400 error envelope" do
      conn =
        conn(:post, "/core/options", "{not valid json")
        |> authed()
        |> req_json()

      {Plug.Adapters.Test.Conn, %{ref: ref}} = conn.adapter

      assert_raise Plug.Parsers.ParseError, fn -> call(conn) end

      assert_received {^ref, {400, _headers, resp_body}}
      body = Jason.decode!(resp_body)
      assert body["result"] == "error"
      assert body["message"] =~ "invalid JSON"
    end
  end

  describe "request body over the 64KB Plug.Parsers limit -> honest 413 envelope (audit E5/H3)" do
    # Same reraise-under-Plug.Test shape as the malformed-JSON case above.
    # Before this fix, `handle_errors/2`'s generic clause answered 413 with
    # the message "internal server error" — the right status, a false
    # message, since `Plug.Exception.status/1` resolves
    # `Plug.Parsers.RequestTooLargeError` to 413 on its own.
    test "POST with an oversized JSON body returns 413 with an honest message" do
      oversized = Jason.encode!(%{"data" => String.duplicate("a", 70_000)})

      conn =
        conn(:post, "/core/options", oversized)
        |> authed()
        |> req_json()

      {Plug.Adapters.Test.Conn, %{ref: ref}} = conn.adapter

      assert_raise Plug.Parsers.RequestTooLargeError, fn -> call(conn) end

      assert_received {^ref, {413, _headers, resp_body}}
      body = Jason.decode!(resp_body)
      assert body["result"] == "error"
      assert body["message"] == "request body too large"
      # The message never echoes the caller's byte count (phase 5: an error
      # message is a leak channel) even though the body itself is on hand.
      refute body["message"] =~ "70"
    end
  end

  describe "unmatched routes" do
    test "an unknown path returns a 404 error envelope, not a bare Plug 404" do
      conn = conn(:get, "/definitely/not/a/route") |> authed() |> call()

      assert conn.status == 404
      body = json_body(conn)
      assert body["result"] == "error"
      assert is_binary(body["message"])
    end
  end

  describe "auth" do
    test "no Authorization header -> 401 error envelope" do
      conn = conn(:get, "/info") |> call()

      assert conn.status == 401
      body = json_body(conn)
      assert body["result"] == "error"
      assert is_binary(body["message"])
    end

    test "wrong/garbage token -> 401 error envelope" do
      conn =
        conn(:get, "/info")
        |> put_req_header("authorization", "Bearer garbage-token-value")
        |> call()

      assert conn.status == 401
      assert json_body(conn)["result"] == "error"
    end

    test "malformed Authorization header (not Bearer) -> 401" do
      conn =
        conn(:get, "/info")
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> call()

      assert conn.status == 401
    end
  end

  defp req_json(conn), do: put_req_header(conn, "content-type", "application/json")
end
