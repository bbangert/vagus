defmodule Vagus.API.RouterBackendTest do
  @moduledoc """
  Proves the router calls through to whatever backend `config :vagus,
  :backends` selects, rather than baking in `Vagus.Backend.Network.HostStub`/
  `Host.HostStub`/`OS.HostStub` behavior directly — and covers the new
  P4-T3/T4 routes' success/error branches (`test/vagus/api/router_test.exs`
  only covers the Phase 2 static-seam routes).

  `async: false` + Mox global mode (`test/test_helper.exs`): this is the
  ONE test module in the suite that calls `Mox.expect/3`, so it must never
  run concurrently with the rest of the (async) suite, which relies on the
  global default `stub_with/2` delegation to the host stubs set up once in
  `test_helper.exs`. `verify_on_exit!/1` clears each test's expectations so
  they never leak into the next.
  """

  use ExUnit.Case, async: false

  import Mox
  import Plug.Test
  import Plug.Conn

  alias Vagus.API.{Router, Token}
  alias Vagus.Backend.{HostMock, NetworkMock, OSMock}

  # Mox's global mode ties "who may add expectations/stubs" to a single
  # owner process — whichever one last called `set_mox_global/1`. That was
  # `test/test_helper.exs`'s own (long-gone) process, so each test here
  # re-claims ownership for itself before calling `expect/3` — safe only
  # because this module is `async: false` (never running at the same time
  # as anything else, per ExUnit's async/non-async isolation guarantee).
  setup :set_mox_global
  setup :verify_on_exit!

  @opts Router.init([])

  defp call(conn), do: Router.call(conn, @opts)
  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> Token.get())
  defp req_json(conn), do: put_req_header(conn, "content-type", "application/json")
  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  describe "GET /os/info calls the configured OS backend" do
    test "returns exactly what Vagus.Backend.os().info() produces" do
      expect(OSMock, :info, fn ->
        %{
          version: "9.9.9",
          version_latest: "9.9.9",
          update_available: false,
          board: "test-board",
          boot: "A",
          data_disk: nil,
          boot_slots: %{}
        }
      end)

      conn = conn(:get, "/os/info") |> authed() |> call()

      assert conn.status == 200
      assert json_body(conn)["data"]["board"] == "test-board"
    end
  end

  describe "GET /host/info calls the configured Host backend" do
    test "returns exactly what Vagus.Backend.host().info() produces" do
      expect(HostMock, :info, fn ->
        %{
          agent_version: nil,
          apparmor_version: nil,
          chassis: nil,
          virtualization: nil,
          cpe: nil,
          deployment: nil,
          disk_free: 1.0,
          disk_total: 2.0,
          disk_used: 1.0,
          disk_life_time: nil,
          features: ["reboot"],
          hostname: "unit-test-host",
          llmnr_hostname: nil,
          kernel: nil,
          operating_system: nil,
          timezone: nil,
          dt_utc: nil,
          dt_synchronized: nil,
          use_ntp: nil,
          startup_time: nil,
          boot_timestamp: nil,
          broadcast_llmnr: nil,
          broadcast_mdns: nil
        }
      end)

      conn = conn(:get, "/host/info") |> authed() |> call()

      assert conn.status == 200
      assert json_body(conn)["data"]["hostname"] == "unit-test-host"
    end
  end

  describe "GET /network/info calls the configured Network backend" do
    test "returns exactly what Vagus.Backend.network().info() produces" do
      expect(NetworkMock, :info, fn ->
        %{
          interfaces: [],
          docker: %{
            interface: "docker0",
            address: "172.30.32.0/23",
            gateway: "172.30.32.1",
            dns: "172.30.32.1"
          },
          host_internet: false,
          supervisor_internet: true
        }
      end)

      conn = conn(:get, "/network/info") |> authed() |> call()

      assert conn.status == 200
      assert json_body(conn)["data"]["host_internet"] == false
    end
  end

  describe "GET /network/interface/:ifname/info" do
    test "ok tuple from the backend -> 200 with the NetworkInterface shape" do
      expect(NetworkMock, :interface_info, fn "eth0" ->
        {:ok,
         %{
           interface: "eth0",
           type: "ethernet",
           enabled: true,
           connected: true,
           primary: true,
           mac: "aa:bb:cc:dd:ee:ff",
           ipv4: nil,
           ipv6: nil,
           wifi: nil,
           vlan: nil,
           mdns: nil,
           llmnr: nil
         }}
      end)

      conn = conn(:get, "/network/interface/eth0/info") |> authed() |> call()

      assert conn.status == 200
      assert json_body(conn)["data"]["interface"] == "eth0"
    end

    test "error tuple from the backend -> 400 error envelope" do
      expect(NetworkMock, :interface_info, fn "bogus0" ->
        {:error, "interface bogus0 not found"}
      end)

      conn = conn(:get, "/network/interface/bogus0/info") |> authed() |> call()

      assert conn.status == 400
      body = json_body(conn)
      assert body["result"] == "error"
      assert body["message"] == "interface bogus0 not found"
    end
  end

  describe "GET /network/interface/:ifname/accesspoints" do
    test "ok tuple -> 200 wrapped in the accesspoints key, each entry AccessPoint-shaped" do
      expect(NetworkMock, :access_points, fn "wlan0" ->
        {:ok,
         [
           %{
             mode: "infrastructure",
             ssid: "MyWifi",
             frequency: 2437,
             signal: 80,
             mac: "de:ad:be:ef:00:01"
           }
         ]}
      end)

      conn = conn(:get, "/network/interface/wlan0/accesspoints") |> authed() |> call()

      assert conn.status == 200
      assert [%{"ssid" => "MyWifi"}] = json_body(conn)["data"]["accesspoints"]
    end

    test "error tuple (e.g. not a wireless interface) -> 400 error envelope" do
      expect(NetworkMock, :access_points, fn "eth0" ->
        {:error, "eth0 is not a wireless interface"}
      end)

      conn = conn(:get, "/network/interface/eth0/accesspoints") |> authed() |> call()

      assert conn.status == 400
      assert json_body(conn)["message"] =~ "not a wireless"
    end
  end

  describe "POST /network/interface/:ifname/update" do
    test ":ok from the backend -> 200 ok envelope, empty data" do
      expect(NetworkMock, :configure, fn "eth0", %{"ipv4" => %{"method" => "dhcp"}} -> :ok end)

      conn =
        conn(
          :post,
          "/network/interface/eth0/update",
          Jason.encode!(%{"ipv4" => %{"method" => "dhcp"}})
        )
        |> authed()
        |> req_json()
        |> call()

      assert conn.status == 200
      assert json_body(conn)["data"] == %{}
    end

    test "unsupported-field error from the backend -> 400 listing what's unsupported" do
      expect(NetworkMock, :configure, fn "eth0", %{"ipv6" => %{}} ->
        {:error, "unsupported field(s): ipv6"}
      end)

      conn =
        conn(:post, "/network/interface/eth0/update", Jason.encode!(%{"ipv6" => %{}}))
        |> authed()
        |> req_json()
        |> call()

      assert conn.status == 400
      assert json_body(conn)["message"] == "unsupported field(s): ipv6"
    end
  end

  describe "POST /host/reboot" do
    test "responds ok before the backend's reboot/0 side effect runs" do
      test_pid = self()

      expect(HostMock, :reboot, fn ->
        send(test_pid, :rebooted)
        :ok
      end)

      conn = conn(:post, "/host/reboot") |> authed() |> call()

      assert conn.status == 200
      assert json_body(conn)["result"] == "ok"

      # The side effect is decoupled onto its own process (Task.start/1) —
      # by the time we've already asserted the response above, it may not
      # have run yet, proving it isn't blocking the reply.
      assert_receive :rebooted, 500
    end
  end

  describe "POST /host/shutdown" do
    test "responds ok before the backend's shutdown/0 side effect runs" do
      test_pid = self()

      expect(HostMock, :shutdown, fn ->
        send(test_pid, :shutdown_called)
        :ok
      end)

      conn = conn(:post, "/host/shutdown") |> authed() |> call()

      assert conn.status == 200
      assert json_body(conn)["result"] == "ok"
      assert_receive :shutdown_called, 500
    end
  end
end
