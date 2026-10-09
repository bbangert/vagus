defmodule Vagus.API.ServicesRouterTest do
  @moduledoc "P4-T1: /services endpoints through Auth's caller resolution."
  use ExUnit.Case, async: false
  use Plug.Test

  import Vagus.AppFixtures

  @opts Vagus.API.Router.init([])

  # Register a running add-on with the given grants; return its token.
  defp addon_token(slug, services_role) do
    register_app_token(app_config(slug), identity: %{services_role: services_role})
  end

  defp call(method, path, token, body \\ nil) do
    conn = conn(method, path, body && Jason.encode!(body))
    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> Vagus.API.Router.call(@opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "provider can publish → read → delete mqtt" do
    token = addon_token("core_mosquitto", %{"mqtt" => "provide"})
    payload = %{"host" => "core-mosquitto", "port" => 1883}

    conn = call(:post, "/services/mqtt", token, payload)
    assert conn.status == 200
    assert body(conn)["result"] == "ok"

    conn = call(:get, "/services/mqtt", token, nil)
    assert conn.status == 200
    data = body(conn)["data"]
    assert data["host"] == "core-mosquitto"
    assert data["port"] == 1883
    assert data["ssl"] == false
    assert data["protocol"] == "3.1.1"
    assert data["addon"] == "core_mosquitto"

    conn = call(:delete, "/services/mqtt", token, nil)
    assert conn.status == 200

    # gone
    assert call(:get, "/services/mqtt", token, nil).status == 400
  end

  test "a non-provider add-on gets 403 on publish" do
    token = addon_token("some_addon", %{"mqtt" => "want"})
    conn = call(:post, "/services/mqtt", token, %{"host" => "h", "port" => 1})
    assert conn.status == 403
  end

  test "the supervisor token may not publish (not an add-on provider)" do
    token = Vagus.API.Token.get()
    conn = call(:post, "/services/mqtt", token, %{"host" => "h", "port" => 1})
    assert conn.status == 403
  end

  test "invalid mqtt body → 400, no state set" do
    token = addon_token("core_mosquitto", %{"mqtt" => "provide"})
    conn = call(:post, "/services/mqtt", token, %{"port" => 1883})
    assert conn.status == 400
    assert body(conn)["message"] =~ "host"
    assert :error = Vagus.App.service("mqtt")
  end

  test "bad port → 400" do
    token = addon_token("core_mosquitto", %{"mqtt" => "provide"})
    conn = call(:post, "/services/mqtt", token, %{"host" => "h", "port" => 70_000})
    assert conn.status == 400
  end

  # The token is held by the app's process, so with no process the publish
  # is not authenticated at all.
  test "a publish while the app's process cannot be started answers 401" do
    token = addon_token("core_mosquitto", %{"mqtt" => "provide"})
    :ok = Supervisor.terminate_child(Vagus.App.Supervisor, Vagus.App.Instances)

    on_exit(fn ->
      {:ok, _pid} = Supervisor.restart_child(Vagus.App.Supervisor, Vagus.App.Instances)
    end)

    conn = call(:post, "/services/mqtt", token, %{"host" => "h", "port" => 1})
    assert conn.status == 401
    assert :error = Vagus.App.service("mqtt")
  end

  test "a second provider is refused with 400" do
    first = addon_token("core_mosquitto", %{"mqtt" => "provide"})
    second = addon_token("other_broker", %{"mqtt" => "provide"})
    assert call(:post, "/services/mqtt", first, %{"host" => "a", "port" => 1}).status == 200

    conn = call(:post, "/services/mqtt", second, %{"host" => "b", "port" => 1})
    assert {conn.status, body(conn)["message"]} == {400, "Service already provided"}
    assert {:ok, "core_mosquitto", %{"host" => "a"}} = Vagus.App.service("mqtt")
  end

  test "withdrawing a service that is not provided answers 200" do
    token = addon_token("core_mosquitto", %{"mqtt" => "provide"})

    conn = call(:delete, "/services/mqtt", token, nil)
    assert {conn.status, body(conn)["result"]} == {200, "ok"}
  end

  test "GET /services lists mqtt availability" do
    token = addon_token("reader", %{"mqtt" => "want"})
    conn = call(:get, "/services", token, nil)
    assert conn.status == 200
    assert [%{"slug" => "mqtt"} | _] = body(conn)["data"]["services"]
  end

  test "unknown/garbage token is still 401 (Auth unchanged for non-callers)" do
    conn = call(:get, "/services", "definitely-not-a-token", nil)
    assert conn.status == 401
  end
end
