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
end
