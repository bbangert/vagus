defmodule Vagus.API.LogsRouterTest do
  @moduledoc "P5-T1: log routes — headers, text/plain, access, JSON side-endpoints (hermetic)."
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vagus.Addon.Registry

  @opts Vagus.API.Router.init([])

  defp sup(conn), do: put_req_header(conn, "authorization", "Bearer #{Vagus.API.Token.get()}")

  defp addon_token(slug) do
    token = "tok-#{System.unique_integer([:positive])}"

    :ok =
      Registry.register(token, %{slug: slug, services_role: %{}, auth_api: false, discovery: []})

    on_exit(fn -> Registry.unregister_slug(slug) end)
    token
  end

  test "host/logs is empty text/plain with the required headers (no journal)" do
    conn = conn(:get, "/host/logs") |> sup() |> Vagus.API.Router.call(@opts)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
    assert get_resp_header(conn, "x-first-cursor") == ["0"]
    assert get_resp_header(conn, "x-accel-buffering") == ["no"]
    assert conn.resp_body == ""
  end

  test "core/logs is empty text/plain when no core container is configured" do
    conn = conn(:get, "/core/logs") |> sup() |> Vagus.API.Router.call(@opts)
    assert conn.status == 200
    assert conn.resp_body == ""
  end

  test "an add-on may not read another add-on's logs" do
    token = addon_token("intruder")

    conn =
      conn(:get, "/addons/core_mosquitto/logs")
      |> put_req_header("x-supervisor-token", token)
      |> Vagus.API.Router.call(@opts)

    assert conn.status == 403
  end

  test "GET /host/logs/boots returns a single-boot map" do
    conn = conn(:get, "/host/logs/boots") |> sup() |> Vagus.API.Router.call(@opts)
    assert conn.status == 200
    assert %{"boots" => %{"0" => _}} = Jason.decode!(conn.resp_body)["data"]
  end

  test "GET /host/logs/identifiers returns an empty list" do
    conn = conn(:get, "/host/logs/identifiers") |> sup() |> Vagus.API.Router.call(@opts)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["data"] == %{"identifiers" => []}
  end

  describe "§A5 contract surface (P3)" do
    test "an unsupported Accept header is a 400" do
      conn =
        conn(:get, "/host/logs")
        |> sup()
        |> put_req_header("accept", "application/json")
        |> Vagus.API.Router.call(@opts)

      assert conn.status == 400
    end

    test "text/plain, text/x-log, */* and absent Accept are all accepted" do
      for accept <- ["text/plain", "text/x-log", "*/*", "text/plain; charset=utf-8"] do
        conn =
          conn(:get, "/host/logs")
          |> sup()
          |> put_req_header("accept", accept)
          |> Vagus.API.Router.call(@opts)

        assert conn.status == 200, "accept #{accept} should be 200"
      end
    end

    test "sourceless families serve empty text/plain with headers" do
      for path <- [
            "/audio/logs",
            "/audio/logs/latest",
            "/dns/logs",
            "/multicast/logs",
            "/homeassistant/logs"
          ] do
        conn = conn(:get, path) |> sup() |> Vagus.API.Router.call(@opts)
        assert conn.status == 200, path
        assert conn.resp_body == "", path
        assert get_resp_header(conn, "x-first-cursor") == ["0"], path
      end
    end

    test "boots endpoints degrade honestly (single boot, no journal)" do
      for path <- [
            "/host/logs/boots/0",
            "/host/logs/boots/-1",
            "/core/logs/boots/0",
            "/supervisor/logs/boots/17",
            "/audio/logs/boots/0"
          ] do
        conn = conn(:get, path) |> sup() |> Vagus.API.Router.call(@opts)
        assert conn.status == 200, path
        assert conn.resp_body == "", path
      end
    end

    test "an add-on may not read another add-on's boots logs" do
      token = addon_token("boots-intruder")

      conn =
        conn(:get, "/addons/core_mosquitto/logs/boots/0")
        |> put_req_header("x-supervisor-token", token)
        |> Vagus.API.Router.call(@opts)

      assert conn.status == 403
    end
  end
end
