defmodule Vagus.API.DiscoveryRouterTest do
  @moduledoc "P4-T2: /discovery endpoints through Auth's caller resolution."
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vagus.Addon.Registry

  @opts Vagus.API.Router.init([])

  # Register a running add-on that declares `discovery`; return its token.
  defp addon_token(slug, discovery) do
    token = "tok-#{System.unique_integer([:positive])}"

    :ok =
      Registry.register(token, %{
        slug: slug,
        services_role: %{},
        auth_api: false,
        discovery: discovery
      })

    on_exit(fn ->
      Registry.unregister_slug(slug)
      Vagus.Discovery.delete_by_slug(slug)
    end)

    token
  end

  defp call(method, path, token, body \\ nil) do
    conn = conn(method, path, body && Jason.encode!(body))
    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> Vagus.API.Router.call(@opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "provider posts discovery → gets a uuid → Core reads it back" do
    token = addon_token("core_mosquitto", ["mqtt"])
    config = %{"host" => "core-mosquitto", "port" => 1883}

    conn = call(:post, "/discovery", token, %{"service" => "mqtt", "config" => config})
    assert conn.status == 200
    uuid = body(conn)["data"]["uuid"]
    assert uuid =~ ~r/\A[0-9a-f]{32}\z/

    # Core (supervisor token) reads the single record — addon/service/config.
    sup = Vagus.API.Token.get()
    conn = call(:get, "/discovery/#{uuid}", sup, nil)
    assert conn.status == 200
    data = body(conn)["data"]
    assert data["addon"] == "core_mosquitto"
    assert data["service"] == "mqtt"
    assert data["config"] == config
    assert data["uuid"] == uuid

    # ...and the list, with the services index.
    conn = call(:get, "/discovery", sup, nil)
    assert conn.status == 200
    data = body(conn)["data"]
    assert Enum.any?(data["discovery"], &(&1["uuid"] == uuid))
    assert data["services"]["mqtt"] == ["core_mosquitto"]
  end

  test "an add-on that did not declare the service gets 403" do
    token = addon_token("some_addon", [])
    conn = call(:post, "/discovery", token, %{"service" => "mqtt", "config" => %{}})
    assert conn.status == 403
  end

  test "the supervisor token may not POST discovery (not an app)" do
    sup = Vagus.API.Token.get()
    conn = call(:post, "/discovery", sup, %{"service" => "mqtt", "config" => %{}})
    assert conn.status == 403
  end

  test "missing/invalid config → 400" do
    token = addon_token("core_mosquitto", ["mqtt"])
    conn = call(:post, "/discovery", token, %{"service" => "mqtt"})
    assert conn.status == 400

    conn = call(:post, "/discovery", token, %{"config" => %{}})
    assert conn.status == 400
  end

  test "an add-on may not read the discovery list (Core-only)" do
    token = addon_token("core_mosquitto", ["mqtt"])
    assert call(:get, "/discovery", token, nil).status == 403
  end

  test "delete is owner-only, then the record is gone" do
    owner = addon_token("core_mosquitto", ["mqtt"])
    other = addon_token("intruder", ["mqtt"])

    conn = call(:post, "/discovery", owner, %{"service" => "mqtt", "config" => %{}})
    uuid = body(conn)["data"]["uuid"]

    assert call(:delete, "/discovery/#{uuid}", other, nil).status == 403
    assert call(:delete, "/discovery/#{uuid}", owner, nil).status == 200

    sup = Vagus.API.Token.get()
    assert call(:get, "/discovery/#{uuid}", sup, nil).status == 404
  end

  test "GET single unknown uuid → 404 for Core" do
    sup = Vagus.API.Token.get()
    assert call(:get, "/discovery/deadbeefdeadbeefdeadbeefdeadbeef", sup, nil).status == 404
  end
end
