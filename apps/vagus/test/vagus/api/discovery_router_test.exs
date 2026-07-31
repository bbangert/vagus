defmodule Vagus.API.DiscoveryRouterTest do
  @moduledoc """
  P4-T2: /discovery endpoints through Auth's caller resolution.

  The dedup tests (audit B3) intercept the Core push via `:discovery_push`
  (`Vagus.API.Router.push_discovery/2`'s seam) instead of standing up a real
  `Vagus.Core.Client`/Core: the router's push is fire-and-forget
  (`Vagus.Discovery.Push.push/2` always returns `:ok` and does its real work
  in a detached `Task`), so intercepting at that boundary is the only way to
  assert "a push was attempted" without also asserting anything about
  network delivery, which isn't this module's concern.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vagus.Addon.Registry

  @opts Vagus.API.Router.init([])

  setup do
    prev = Application.get_env(:vagus, :discovery_push)
    test_pid = self()

    Application.put_env(:vagus, :discovery_push, fn method, message ->
      send(test_pid, {:discovery_push, method, message})
      :ok
    end)

    on_exit(fn ->
      # `is_nil/1`, not a truthiness check: an explicitly-configured `nil`
      # (there isn't one today, but nothing rules it out later) is still a
      # real value to restore rather than delete.
      if is_nil(prev),
        do: Application.delete_env(:vagus, :discovery_push),
        else: Application.put_env(:vagus, :discovery_push, prev)
    end)

    :ok
  end

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

  test "two identical POSTs from the same add-on dedup to one uuid and exactly one Core push" do
    token = addon_token("core_mosquitto", ["mqtt"])

    body_params = %{
      "service" => "mqtt",
      "config" => %{"host" => "core-mosquitto", "port" => 1883}
    }

    conn1 = call(:post, "/discovery", token, body_params)
    assert conn1.status == 200
    uuid = body(conn1)["data"]["uuid"]
    assert_receive {:discovery_push, :post, %{uuid: ^uuid}}

    # The second, identical POST — the add-on-restart case (audit B3) — must
    # neither mint a new uuid nor push a duplicate to Core.
    conn2 = call(:post, "/discovery", token, body_params)
    assert conn2.status == 200
    assert body(conn2)["data"]["uuid"] == uuid
    refute_received {:discovery_push, _method, _message}

    sup = Vagus.API.Token.get()
    data = body(call(:get, "/discovery", sup, nil))["data"]
    assert length(Enum.filter(data["discovery"], &(&1["addon"] == "core_mosquitto"))) == 1
  end

  test "a changed config for the same add-on/service keeps the uuid and pushes again" do
    token = addon_token("core_mosquitto", ["mqtt"])

    conn1 = call(:post, "/discovery", token, %{"service" => "mqtt", "config" => %{"host" => "a"}})
    uuid = body(conn1)["data"]["uuid"]
    assert_receive {:discovery_push, :post, %{uuid: ^uuid}}

    conn2 = call(:post, "/discovery", token, %{"service" => "mqtt", "config" => %{"host" => "b"}})
    assert body(conn2)["data"]["uuid"] == uuid
    assert_receive {:discovery_push, :post, %{uuid: ^uuid}}

    sup = Vagus.API.Token.get()
    data = body(call(:get, "/discovery/#{uuid}", sup, nil))["data"]
    assert data["config"] == %{"host" => "b"}
  end

  test "a distinct add-on, or a distinct service from the same add-on, gets its own uuid + push" do
    token_a = addon_token("core_mosquitto", ["mqtt"])
    token_b = addon_token("other_addon", ["mqtt"])

    conn_a = call(:post, "/discovery", token_a, %{"service" => "mqtt", "config" => %{}})
    uuid_a = body(conn_a)["data"]["uuid"]
    assert_receive {:discovery_push, :post, %{uuid: ^uuid_a}}

    conn_b = call(:post, "/discovery", token_b, %{"service" => "mqtt", "config" => %{}})
    uuid_b = body(conn_b)["data"]["uuid"]
    assert_receive {:discovery_push, :post, %{uuid: ^uuid_b}}

    refute uuid_a == uuid_b
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
    # 401, not 403 (audit E3/H3): both discovery reads are `@require_home_
    # assistant` upstream, and that wrapper raises `HTTPUnauthorized` —
    # matching the `/ingress/session` precedent, not this router's usual
    # wrong-caller 403.
    token = addon_token("core_mosquitto", ["mqtt"])
    assert call(:get, "/discovery", token, nil).status == 401
  end

  test "an add-on may not read a single discovery message either (Core-only)" do
    owner = addon_token("core_mosquitto", ["mqtt"])
    conn = call(:post, "/discovery", owner, %{"service" => "mqtt", "config" => %{}})
    uuid = body(conn)["data"]["uuid"]

    assert call(:get, "/discovery/#{uuid}", owner, nil).status == 401
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
