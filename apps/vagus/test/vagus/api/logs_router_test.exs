defmodule Vagus.API.LogsRouterTest do
  @moduledoc "P5-T1: log routes — headers, text/plain, access, JSON side-endpoints (hermetic)."
  use ExUnit.Case, async: false
  use Plug.Test

  import Vagus.AppFixtures

  alias Vagus.Addon.Config

  @opts Vagus.API.Router.init([])

  defp sup(conn), do: put_req_header(conn, "authorization", "Bearer #{Vagus.API.Token.get()}")

  defp addon_token(slug) do
    {:ok, config} =
      Config.parse(%{
        "name" => "Test App",
        "version" => "1",
        "slug" => slug,
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "x/y"
      })

    register_app_token(config)
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

  describe "container logs through the engine" do
    alias Vagus.Runtime.Engine.Fake

    setup do
      fake = Fake.start_global()
      previous = Application.get_env(:vagus, :core_container)
      Application.put_env(:vagus, :core_container, "homeassistant")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:vagus, :core_container, previous),
          else: Application.delete_env(:vagus, :core_container)
      end)

      Fake.put_container(fake, "homeassistant", logs: "\e[31mred\e[0m\nplain\n")
      %{fake: fake}
    end

    defp core_logs(query),
      do: conn(:get, "/core/logs" <> query) |> sup() |> Vagus.API.Router.call(@opts)

    test "the engine's text is served as-is, and no_colors strips ANSI" do
      assert core_logs("").resp_body == "\e[31mred\e[0m\nplain\n"
      assert core_logs("?no_colors").resp_body == "red\nplain\n"
    end

    test "verbose asks for the engine's stamps and renders them in the §A5 shape", %{fake: fake} do
      lines = String.split(core_logs("?verbose&no_colors").resp_body, "\n", trim: true)

      assert [red, plain] = lines
      assert red =~ ~r/^2026-10-14 21:00:00\.000 \S+ homeassistant: red$/
      assert plain =~ ~r/^2026-10-14 21:00:00\.000 \S+ homeassistant: plain$/
      assert {:logs, ["homeassistant"]} in Fake.calls(fake)
    end

    test "an engine error serves an empty body", %{fake: fake} do
      Fake.fail_next(fake, :logs, :unavailable)
      conn = core_logs("")
      assert conn.status == 200
      assert conn.resp_body == ""
    end
  end
end
