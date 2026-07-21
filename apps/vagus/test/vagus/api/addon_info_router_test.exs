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

  # /addons/{slug}/stats shares the info access rules (P5-T2). The 403 path
  # returns before any engine call, so this stays hermetic.
  test "an add-on may not read another add-on's stats" do
    token = addon_token("some_other")
    assert call("/addons/core_mosquitto/stats", [{"x-supervisor-token", token}]).status == 403
  end

  test "a slug with path/ref-unsafe characters is rejected (403), not interpolated" do
    conn = call("/addons/bad;slug/stats", [{"authorization", "Bearer #{Vagus.API.Token.get()}"}])
    assert conn.status == 403
    conn = call("/addons/bad;slug/info", [{"authorization", "Bearer #{Vagus.API.Token.get()}"}])
    assert conn.status == 403
  end

  test "/core/stats returns the zero CoreStats shape when no container configured" do
    conn = call("/core/stats", [{"authorization", "Bearer #{Vagus.API.Token.get()}"}])
    assert conn.status == 200
    data = Jason.decode!(conn.resp_body)["data"]
    assert data["cpu_percent"] == 0.0
    assert data["memory_usage"] == 0
    assert Map.has_key?(data, "memory_percent")
  end

  describe "ingress fields + watchdog (§B3.4, §B8)" do
    setup do
      {:ok, c} =
        Config.parse(%{
          "name" => "ESPHome",
          "version" => "1.0.0",
          "slug" => "core_esphome",
          "description" => "ESPHome dashboard",
          "arch" => ["aarch64"],
          "ingress" => true,
          "ingress_port" => 6052
        })

      :ok = State.put(c, :started)
      :ok = State.put_setting("core_esphome", :ingress_panel, true)
      :ok = State.put_setting("core_esphome", :watchdog, true)
      {:ok, entry} = State.get("core_esphome")
      on_exit(fn -> State.delete("core_esphome") end)
      %{config: c, entry: entry}
    end

    test "info carries the real per-install ingress token in entry/url, plus the persisted panel/watchdog bools",
         %{entry: entry} do
      conn =
        call("/addons/core_esphome/info", [
          {"authorization", "Bearer #{Vagus.API.Token.get()}"}
        ])

      assert conn.status == 200
      info = data(conn)

      token = entry.ingress_token
      assert info["ingress"] == true
      assert info["ingress_entry"] == "/api/hassio_ingress/#{token}"
      assert info["ingress_url"] == "/api/hassio_ingress/#{token}/"
      assert info["ingress_port"] == 6052
      assert info["ingress_panel"] == true
      assert info["watchdog"] == true
    end

    test "GET /addons/self/info serves the same resolved ingress fields (§B3.2 fact 5)" do
      token = addon_token("core_esphome")
      conn = call("/addons/self/info", [{"x-supervisor-token", token}])
      assert conn.status == 200
      info = data(conn)
      assert info["ingress"] == true
      assert info["ingress_port"] == 6052
    end
  end
end
