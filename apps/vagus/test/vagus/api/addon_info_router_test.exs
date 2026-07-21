defmodule Vagus.API.AddonInfoRouterTest do
  @moduledoc "GET /addons/{slug}/info — Core (supervisor) + add-on self reads."
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vagus.Addon.{Config, Registry, State}

  @opts Vagus.API.Router.init([])

  setup do
    {:ok, c} =
      Config.parse(%{
        "name" => "Mosquitto broker",
        "version" => "7.1.0",
        "slug" => "core_mosquitto",
        "description" => "An Open Source MQTT broker",
        "arch" => ["aarch64"],
        "auth_api" => true
      })

    :ok = State.put(c, :started)
    on_exit(fn -> State.delete("core_mosquitto") end)
    %{config: c}
  end

  defp addon_token(slug) do
    token = "tok-#{System.unique_integer([:positive])}"

    :ok =
      Registry.register(token, %{slug: slug, services_role: %{}, auth_api: true, discovery: []})

    on_exit(fn -> Registry.unregister_slug(slug) end)
    token
  end

  defp call(path, headers) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Vagus.API.Router.call(conn, @opts)
  end

  defp data(conn), do: Jason.decode!(conn.resp_body)["data"]

  test "supervisor (Core) reads any slug by name" do
    conn =
      call("/addons/core_mosquitto/info", [{"authorization", "Bearer #{Vagus.API.Token.get()}"}])

    assert conn.status == 200
    assert data(conn)["name"] == "Mosquitto broker"
    assert data(conn)["slug"] == "core_mosquitto"
  end

  test "an add-on reads its own info via self" do
    token = addon_token("core_mosquitto")
    conn = call("/addons/self/info", [{"x-supervisor-token", token}])
    assert conn.status == 200
    assert data(conn)["name"] == "Mosquitto broker"
  end

  test "an add-on may not read another add-on's info" do
    token = addon_token("some_other")
    assert call("/addons/core_mosquitto/info", [{"x-supervisor-token", token}]).status == 403
  end

  test "supervisor reading an unknown slug → 404" do
    conn = call("/addons/ghost/info", [{"authorization", "Bearer #{Vagus.API.Token.get()}"}])
    assert conn.status == 404
  end
end
