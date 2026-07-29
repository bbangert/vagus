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

  defp addon_token(slug, grants \\ %{}) do
    token = "tok-#{System.unique_integer([:positive])}"

    identity =
      Map.merge(
        %{
          slug: slug,
          services_role: %{},
          auth_api: true,
          discovery: [],
          hassio_api: true,
          hassio_role: "default"
        },
        grants
      )

    :ok = Registry.register(token, identity)
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

  # Audit A8. Upstream's `info_data` gates ONLY `ATTR_OPTIONS`, on
  # `expose_options` — "User options may contain secrets" — and redacts to an
  # empty map rather than dropping the key, because the frontend's config form
  # reads it unconditionally.
  describe "options redaction (A8)" do
    setup do
      :ok = State.put_options("core_mosquitto", %{"password" => "hunter2"})
      :ok
    end

    test "Core sees the real options" do
      conn =
        call("/addons/core_mosquitto/info", [
          {"authorization", "Bearer #{Vagus.API.Token.get()}"}
        ])

      assert conn.status == 200
      assert data(conn)["options"]["password"] == "hunter2"
    end

    test "the add-on itself sees its own options, by slug and via self" do
      for path <- ["/addons/core_mosquitto/info", "/addons/self/info"] do
        token = addon_token("core_mosquitto")
        conn = call(path, [{"x-supervisor-token", token}])

        assert conn.status == 200

        assert data(conn)["options"]["password"] == "hunter2",
               "#{path} redacted the add-on's own options"
      end
    end

    # Vagus is stricter than upstream here and this is the proof: upstream
    # would let a default-role add-on READ another add-on's info (with options
    # redacted); `resolve_info_slug/2` refuses outright, so the redaction
    # never even comes into play. If that guard is ever widened, the tests
    # above and this one together say what must remain true.
    test "another add-on cannot reach the info at all, redacted or otherwise" do
      token = addon_token("core_nosy")
      conn = call("/addons/core_mosquitto/info", [{"x-supervisor-token", token}])

      assert conn.status == 403
      refute conn.resp_body =~ "hunter2"
    end

    test "a manager-role add-on is refused too, for the same reason" do
      token = addon_token("core_manager_nosy", %{hassio_role: "manager"})
      conn = call("/addons/core_mosquitto/info", [{"x-supervisor-token", token}])

      assert conn.status == 403
      refute conn.resp_body =~ "hunter2"
    end
  end
end
