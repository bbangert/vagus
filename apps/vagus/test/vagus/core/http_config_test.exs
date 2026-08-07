defmodule Vagus.Core.HttpConfigTest do
  @moduledoc """
  A4 — Core's HTTP-config pull (`GET /api/core/http_config`, socket-only).

  `async: false`: the transport-resolution tests move `:core_socket_path`
  and `:core_base_url`, which are process-global application env
  (`config/test.exs` pins the former to `nil` for the whole suite), and the
  scripted fake Core answers through a fixed-name Agent.
  """
  use ExUnit.Case, async: false

  alias Vagus.Core.HttpConfig

  @script __MODULE__.Script

  defmodule FakeCore do
    @moduledoc """
    A stand-in for Core's socket listener. The response is read per request
    from a fixed-name Agent, so one listener can serve a success and then a
    failure inside the same test (proving the cache keeps the old value).
    """
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/api/core/http_config" do
      {status, body} = Agent.get(Vagus.Core.HttpConfigTest.Script, & &1)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, body)
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end

  setup do
    prev_socket = Application.get_env(:vagus, :core_socket_path)
    prev_base = Application.get_env(:vagus, :core_base_url)

    on_exit(fn ->
      Application.put_env(:vagus, :core_socket_path, prev_socket)

      if is_nil(prev_base),
        do: Application.delete_env(:vagus, :core_base_url),
        else: Application.put_env(:vagus, :core_base_url, prev_base)
    end)

    :ok
  end

  ## Helpers

  defp start_cache(opts \\ []) do
    name = :"http_config_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: name,
      start: {HttpConfig, :start_link, [Keyword.put(opts, :name, name)]}
    })

    name
  end

  defp start_script(response) do
    start_supervised!(%{
      id: @script,
      start: {Agent, :start_link, [fn -> response end, [name: @script]]}
    })

    :ok
  end

  defp script(response), do: Agent.update(@script, fn _prev -> response end)

  defp ok_body(fields) do
    {200,
     Jason.encode!(
       Map.merge(
         %{"port" => 8123, "ssl" => false, "ssl_peer_certificate" => false, "server_host" => nil},
         fields
       )
     )}
  end

  # A fake Core listening on a unix socket, exactly where Core's own
  # `SUPERVISOR_CORE_API_SOCKET` listener would be.
  defp start_socket_core(response) do
    :ok = start_script(response)

    path =
      Path.join(System.tmp_dir!(), "vagus_http_config_#{System.unique_integer([:positive])}.sock")

    on_exit(fn -> File.rm(path) end)

    start_supervised!(
      {Bandit,
       plug: FakeCore,
       port: 0,
       thousand_island_options: [num_acceptors: 1, transport_options: [ip: {:local, path}]]},
      id: :fake_core_socket
    )

    path
  end

  # Rescripts the running fake Core with one `server_host` shape, pulls, and
  # hands back what the cache made of it.
  defp pull_server_host(cache, server_host) do
    script(ok_body(%{"port" => 8123, "server_host" => server_host}))
    assert HttpConfig.refresh(server: cache) == :ok
    HttpConfig.get(cache).server_host
  end

  ## Tests

  describe "defaults" do
    test "a never-pulled cache reports Core's legacy port, no ssl, no server_host" do
      cache = start_cache()

      assert HttpConfig.get(cache) == %{port: 8123, ssl: false, server_host: nil}
      assert HttpConfig.get(cache) == HttpConfig.defaults()
    end

    test "get/1 on a dead cache falls back to the defaults instead of exiting" do
      cache = start_cache()
      :ok = stop_supervised!(cache)

      assert HttpConfig.get(cache) == HttpConfig.defaults()
    end
  end

  describe "refresh/1 over the socket" do
    test "caches what Core reports" do
      path =
        start_socket_core(
          ok_body(%{"port" => 80, "ssl" => true, "server_host" => ["0.0.0.0", "::"]})
        )

      cache = start_cache()

      # Resolved through the real transport, not an injected one: the socket
      # existing is what makes this endpoint reachable at all.
      Application.put_env(:vagus, :core_socket_path, path)
      Application.put_env(:vagus, :core_base_url, "http://127.0.0.1:1")

      assert HttpConfig.refresh(server: cache) == :ok
      assert HttpConfig.get(cache) == %{port: 80, ssl: true, server_host: ["0.0.0.0", "::"]}
    end

    test "a later Core restart on a different port re-caches" do
      path = start_socket_core(ok_body(%{"port" => 80}))
      cache = start_cache()
      Application.put_env(:vagus, :core_socket_path, path)

      assert HttpConfig.refresh(server: cache) == :ok
      assert HttpConfig.get(cache).port == 80

      script(ok_body(%{"port" => 8123}))

      assert HttpConfig.refresh(server: cache) == :ok
      assert HttpConfig.get(cache).port == 8123
    end

    test "absent ssl/server_host fall back to the defaults, port still wins" do
      path = start_socket_core({200, Jason.encode!(%{"port" => 8080})})
      cache = start_cache()

      assert HttpConfig.refresh(server: cache, transport: {:socket, path}) == :ok
      assert HttpConfig.get(cache) == %{port: 8080, ssl: false, server_host: nil}
    end
  end

  describe "server_host shapes" do
    setup do
      # One listener, rescripted per assertion: every shape below is decoded
      # by the same code path a device hits.
      path = start_socket_core(ok_body(%{}))
      Application.put_env(:vagus, :core_socket_path, path)

      %{cache: start_cache()}
    end

    test "the wildcard list a live 2026.8 Core actually answers with", %{cache: cache} do
      assert pull_server_host(cache, ["0.0.0.0", "::"]) == ["0.0.0.0", "::"]
    end

    test "a single configured host is still a list", %{cache: cache} do
      assert pull_server_host(cache, ["192.168.1.10"]) == ["192.168.1.10"]
    end

    test "the scalar form is normalized to a one-element list", %{cache: cache} do
      assert pull_server_host(cache, "0.0.0.0") == ["0.0.0.0"]
    end

    test "an empty list is Core reporting no bound address, not 'unknown'", %{cache: cache} do
      assert pull_server_host(cache, []) == []
    end

    test "a shape we can't read falls back to the default, port still cached", %{cache: cache} do
      assert pull_server_host(cache, ["0.0.0.0", 42]) == nil
      assert pull_server_host(cache, 42) == nil
      assert pull_server_host(cache, %{"host" => "0.0.0.0"}) == nil
      assert HttpConfig.get(cache).port == 8123
    end

    test "the accepted list is capped — it is cached indefinitely (W3)", %{cache: cache} do
      at_cap = List.duplicate("0.0.0.0", 32)
      assert pull_server_host(cache, at_cap) == at_cap

      assert pull_server_host(cache, List.duplicate("0.0.0.0", 33)) == nil
      assert HttpConfig.get(cache).port == 8123
    end
  end

  describe "the port-migration confirmation" do
    setup do
      path = start_socket_core(ok_body(%{"port" => 8123}))
      Application.put_env(:vagus, :core_socket_path, path)
      parent = self()

      %{
        cache: start_cache(),
        confirm: fn -> send(parent, :confirmed) end
      }
    end

    test "fires when Core reports the migration's target port", ctx do
      script(ok_body(%{"port" => Vagus.Core.PortMigration.target_port()}))

      assert HttpConfig.refresh(server: ctx.cache, confirm: ctx.confirm) == :ok
      assert_received :confirmed
    end

    test "does not fire while Core is still on the legacy port", ctx do
      assert HttpConfig.refresh(server: ctx.cache, confirm: ctx.confirm) == :ok
      refute_received :confirmed
    end

    test "does not fire on a failed pull — an unstored config proves nothing", ctx do
      script({500, "boom"})

      assert {:error, {:http_error, 500}} =
               HttpConfig.refresh(server: ctx.cache, confirm: ctx.confirm)

      refute_received :confirmed
    end

    test "a confirmation that fails never fails the refresh", ctx do
      script(ok_body(%{"port" => Vagus.Core.PortMigration.target_port()}))
      confirm = fn -> {:error, :enotdir} end

      assert HttpConfig.refresh(server: ctx.cache, confirm: confirm) == :ok
      assert HttpConfig.get(ctx.cache).port == Vagus.Core.PortMigration.target_port()
    end

    test "the real default is a no-op in the suite (no marker configured)", ctx do
      # `config/test.exs` pins `:core_port_migration_marker` to nil, so the
      # un-injected path can't reach a filesystem from here.
      script(ok_body(%{"port" => Vagus.Core.PortMigration.target_port()}))

      assert HttpConfig.refresh(server: ctx.cache) == :ok
    end
  end

  describe "refresh/1 with no socket (TCP fallback / host dev)" do
    test "skips the pull entirely and keeps the defaults" do
      # A TCP listener that WOULD answer the endpoint: if the pull were
      # attempted over TCP at all, the cache would end up at 80.
      :ok = start_script(ok_body(%{"port" => 80}))
      bandit = start_supervised!({Bandit, plug: FakeCore, port: 0})
      {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

      Application.put_env(:vagus, :core_socket_path, nil)
      Application.put_env(:vagus, :core_base_url, "http://127.0.0.1:#{port}")

      cache = start_cache()

      assert HttpConfig.refresh(server: cache) == {:skipped, :no_socket}
      assert HttpConfig.get(cache) == HttpConfig.defaults()
    end

    test "a configured-but-absent socket is also a skip" do
      cache = start_cache()

      Application.put_env(
        :vagus,
        :core_socket_path,
        Path.join(System.tmp_dir!(), "vagus_http_config_absent.sock")
      )

      assert HttpConfig.refresh(server: cache) == {:skipped, :no_socket}
    end
  end

  describe "refresh/1 failures keep the previous cache" do
    setup do
      path = start_socket_core(ok_body(%{"port" => 80, "ssl" => true}))
      cache = start_cache()
      Application.put_env(:vagus, :core_socket_path, path)

      assert HttpConfig.refresh(server: cache) == :ok
      %{cache: cache, cached: %{port: 80, ssl: true, server_host: nil}}
    end

    test "a non-200 response", %{cache: cache, cached: cached} do
      script({500, "boom"})

      assert HttpConfig.refresh(server: cache) == {:error, {:http_error, 500}}
      assert HttpConfig.get(cache) == cached
    end

    test "a body that isn't JSON is reported as a shape, never as the body (S3c)",
         %{cache: cache, cached: cached} do
      script({200, "<html>a-secret-looking-blob</html>"})

      # `inspect(reason)` goes straight into RingLogger — a
      # `%Jason.DecodeError{}` would carry up to 4KB of Core's body with it.
      assert {:error, {:invalid_json, {:position, position}} = reason} =
               HttpConfig.refresh(server: cache)

      assert is_integer(position)
      refute inspect(reason) =~ "a-secret-looking-blob"
      assert HttpConfig.get(cache) == cached
    end

    test "a body bigger than the cap is abandoned mid-stream (W3)",
         %{cache: cache, cached: cached} do
      # Otherwise-valid JSON, so the only thing rejecting it is the size cap:
      # Core answering this endpoint with a multi-GB body must not be able to
      # OOM a 512MB device.
      script({200, Jason.encode!(%{"port" => 8080, "pad" => String.duplicate("x", 70_000)})})

      assert HttpConfig.refresh(server: cache) == {:error, :response_too_large}
      assert HttpConfig.get(cache) == cached
    end

    test "JSON without a usable port", %{cache: cache, cached: cached} do
      script({200, Jason.encode!(%{"ssl" => true})})

      assert HttpConfig.refresh(server: cache) == {:error, :invalid_response}
      assert HttpConfig.get(cache) == cached

      script({200, Jason.encode!(%{"port" => 0})})
      assert HttpConfig.refresh(server: cache) == {:error, :invalid_response}
      assert HttpConfig.get(cache) == cached
    end

    test "nothing listening on an existing socket file", %{cache: cache, cached: cached} do
      stale = Path.join(System.tmp_dir!(), "vagus_http_config_stale.sock")
      File.write!(stale, "")
      on_exit(fn -> File.rm(stale) end)

      assert {:error, _reason} = HttpConfig.refresh(server: cache, transport: {:socket, stale})
      assert HttpConfig.get(cache) == cached
    end

    test "a cache process that is gone", %{cache: cache} do
      :ok = stop_supervised!(cache)

      assert {:error, {:cache_unavailable, _reason}} = HttpConfig.refresh(server: cache)
    end
  end
end
