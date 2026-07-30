defmodule Vagus.API.RouterVersionsTest do
  @moduledoc """
  `GET /info`'s live `homeassistant` field (audit G5) and the three
  `Vagus.Core.Versions.invalidate/1` call sites (audit G4) —
  `Vagus.API.CoreLifecycleRouterTest` already covers `GET /core/info`
  itself; this file is deliberately separate so it doesn't collide with
  that file's own uncommitted in-flight changes.

  `async: false` — every test swaps the process-global
  `config :vagus, :core_versions_server`, restored in `on_exit`.
  """
  use ExUnit.Case, async: false

  import Mox
  import Plug.Test
  import Plug.Conn

  alias Vagus.API.{Router, Token}
  alias Vagus.Core.Versions

  # GET /info calls `Vagus.Backend.os().info()` (via `StaticData.root_info/0`)
  # — same order-independence fix `Vagus.API.StaticDataTest` documents: Mox's
  # global mode ties stub ownership to whichever process last called
  # `set_mox_global/1`, and `Vagus.API.RouterBackendTest` reclaims it for
  # itself. Re-claiming ownership and re-stubbing here makes this module
  # order-independent instead of depending on the ambient stub from
  # `test/test_helper.exs` still being alive.
  setup :set_mox_global

  setup do
    stub_with(Vagus.Backend.OSMock, Vagus.Backend.OS.HostStub)
    :ok
  end

  @opts Router.init([])

  defp call(conn), do: Router.call(conn, @opts)
  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> Token.get())
  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp start_versions(fetch) do
    path =
      Path.join(
        System.tmp_dir!(),
        "vagus-router-versions-rt-#{System.unique_integer([:positive])}.json"
      )

    name = :"router_versions_rt_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: name,
      start: {Versions, :start_link, [[name: name, path: path, fetch: fetch]]}
    })

    prev_server = Application.get_env(:vagus, :core_versions_server)
    Application.put_env(:vagus, :core_versions_server, name)

    on_exit(fn ->
      if prev_server,
        do: Application.put_env(:vagus, :core_versions_server, prev_server),
        else: Application.delete_env(:vagus, :core_versions_server)

      File.rm(path)
    end)

    name
  end

  # Points :core_versions_server at a name nothing is registered under, so
  # a call `:exit`s with `:noproc` — the cheapest reliable way to force the
  # G2/G5 fallback path without racing a real slow fetch.
  defp point_at_dead_versions_server do
    prev_server = Application.get_env(:vagus, :core_versions_server)
    Application.put_env(:vagus, :core_versions_server, :vagus_test_nonexistent_versions_server)

    on_exit(fn ->
      if prev_server,
        do: Application.put_env(:vagus, :core_versions_server, prev_server),
        else: Application.delete_env(:vagus, :core_versions_server)
    end)
  end

  describe "GET /info homeassistant field (G5)" do
    test "matches GET /core/info's version when Vagus.Core.Versions answers" do
      versions = start_versions(fn -> {:error, :offline} end)
      :ok = Versions.set_installed("2026.7.5", versions)

      info = conn(:get, "/info") |> authed() |> call()
      core_info = conn(:get, "/core/info") |> authed() |> call()

      assert json_body(info)["data"]["homeassistant"] == "2026.7.5"
      assert json_body(core_info)["data"]["version"] == "2026.7.5"
    end

    test "falls back to the static Core version when Vagus.Core.Versions exits" do
      point_at_dead_versions_server()

      conn = conn(:get, "/info") |> authed() |> call()

      assert conn.status == 200

      assert json_body(conn)["data"]["homeassistant"] ==
               Vagus.API.StaticData.root_info()[:homeassistant]
    end
  end

  describe "reload_updates/refresh_updates/supervisor/reload invalidate the Versions cache (G4)" do
    for path <- ["/reload_updates", "/refresh_updates", "/supervisor/reload"] do
      test "POST #{path} forces the next latest/1 read to re-fetch" do
        test_pid = self()

        fetch = fn ->
          send(test_pid, :fetch_invoked)
          {:ok, "2026.7.9"}
        end

        versions = start_versions(fetch)

        assert Versions.latest(versions) == "2026.7.9"
        assert_received :fetch_invoked

        conn = conn(:post, unquote(path), Jason.encode!(%{})) |> authed() |> call()
        assert conn.status == 200

        # Cache is still fresh (< 24h) — without the route wiring
        # Versions.invalidate/1 through, this second read would be served
        # straight from cache with no second fetch.
        assert Versions.latest(versions) == "2026.7.9"
        assert_received :fetch_invoked
      end
    end
  end
end
