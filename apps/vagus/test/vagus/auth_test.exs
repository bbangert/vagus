defmodule Vagus.AuthTest do
  @moduledoc """
  P4-T3: the /auth credential cache + Core forward.

  `async: false`: the socket tests move `:core_socket_path`, which is
  process-global application env every other `Vagus.Core.Transport` caller
  reads.
  """
  use ExUnit.Case, async: false

  alias Vagus.Auth

  defmodule FakeCoreSocket do
    @moduledoc "Core's `api/hassio_auth` as it answers on the Supervisor socket."
    use Plug.Router

    plug(:match)
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["*/*"])
    plug(:dispatch)

    post "/api/hassio_auth" do
      send(
        Application.fetch_env!(:vagus, :auth_socket_test_pid),
        {:hassio_auth, conn.body_params}
      )

      send_resp(conn, 200, "")
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end

  # A stub Core client. `check_login/4` runs synchronously in the calling
  # process, so the reply queue + recorded calls live in that process's
  # dictionary — no separate (unsupervised) process needed. `request/3`
  # matches `Vagus.Core.Client.request/3`.
  defmodule StubCore do
    def request(method, path, opts) do
      [reply | rest] = Process.get(:stub_replies)
      Process.put(:stub_replies, rest)

      call = %{method: method, path: path, body: Jason.decode!(Keyword.fetch!(opts, :body))}
      Process.put(:stub_calls, [call | Process.get(:stub_calls, [])])

      reply
    end
  end

  setup do
    cache = start_supervised!({Auth, name: nil})
    %{cache: cache}
  end

  defp with_core(replies, fun) do
    Process.put(:stub_replies, replies)
    Process.put(:stub_calls, [])
    fun.()
  end

  defp core_calls, do: Process.get(:stub_calls, []) |> Enum.reverse()

  test "valid creds forwarded to Core → true, and cached (no second Core call)", %{cache: cache} do
    with_core([{:ok, %{status: 200}}], fn ->
      opts = [server: cache, core_client: StubCore]
      assert Auth.check_login("alice", "s3cret", "core_mosquitto", opts)
      # Second call is served from cache — Core was only hit once.
      assert Auth.check_login("alice", "s3cret", "core_mosquitto", opts)

      assert [call] = core_calls()
      assert call.method == :post
      assert call.path == "/api/hassio_auth"

      assert call.body == %{
               "username" => "alice",
               "password" => "s3cret",
               "addon" => "core_mosquitto"
             }
    end)
  end

  test "Core 401 → false, not cached", %{cache: cache} do
    with_core([{:ok, %{status: 401}}, {:ok, %{status: 401}}], fn ->
      opts = [server: cache, core_client: StubCore]
      refute Auth.check_login("mallory", "bad", "core_mosquitto", opts)
      refute Auth.check_login("mallory", "bad", "core_mosquitto", opts)
      assert length(core_calls()) == 2
    end)
  end

  test "Core unreachable (no refresh token) → false", %{cache: cache} do
    with_core([{:error, :no_refresh_token}], fn ->
      refute Auth.check_login("alice", "s3cret", "x", server: cache, core_client: StubCore)
    end)
  end

  test "cache key does not collide across the user:pass boundary (B2)", %{cache: cache} do
    # Cache ("alice", "x:y"); a differently-split pair ("alice:x", "y") must NOT
    # be served from that cache entry — it must re-check Core.
    with_core([{:ok, %{status: 200}}, {:ok, %{status: 401}}], fn ->
      opts = [server: cache, core_client: StubCore]
      assert Auth.check_login("alice", "x:y", "m", opts)
      refute Auth.check_login("alice:x", "y", "m", opts)
      assert length(core_calls()) == 2
    end)
  end

  # Restores whatever `:core_socket_path` was (config/test.exs pins it to
  # `nil`) rather than hardcoding it back, the discipline transport_test.exs
  # follows.
  defp put_socket_path(path) do
    prev = Application.get_env(:vagus, :core_socket_path)
    Application.put_env(:vagus, :core_socket_path, path)
    on_exit(fn -> Application.put_env(:vagus, :core_socket_path, prev) end)
    :ok
  end

  defp socket_path do
    path =
      Path.join(System.tmp_dir!(), "vagus_auth_socket_#{System.unique_integer([:positive])}.sock")

    on_exit(fn -> File.rm(path) end)
    path
  end

  # A real AF_UNIX socket nothing is listening on — closing the listener does
  # not unlink it, exactly as a dead Core leaves its socket behind.
  defp bind_socket!(path) do
    {:ok, listen} = :gen_tcp.listen(0, ifaddr: {:local, path})
    :gen_tcp.close(listen)
    path
  end

  test "when the Core socket exists, forward posts to it, not to the TCP client", %{cache: cache} do
    path = socket_path()
    Application.put_env(:vagus, :auth_socket_test_pid, self())
    on_exit(fn -> Application.delete_env(:vagus, :auth_socket_test_pid) end)

    start_supervised!(
      {Bandit,
       plug: FakeCoreSocket,
       port: 0,
       thousand_island_options: [num_acceptors: 1, transport_options: [ip: {:local, path}]]}
    )

    put_socket_path(path)

    # An empty reply queue would crash StubCore if the TCP branch were taken.
    with_core([], fn ->
      assert Auth.check_login("alice", "secret", "m", server: cache, core_client: StubCore)
      assert core_calls() == []
    end)

    assert_receive {:hassio_auth,
                    %{"username" => "alice", "password" => "secret", "addon" => "m"}},
                   2_000
  end

  test "a dead Core's leftover socket is a rejection, not a crash", %{cache: cache} do
    # S1: `forward/4` resolves the socket once and threads it into
    # `ApiSocket.post/3`. Nothing is listening here, so the connect fails and
    # the login is refused — the TCP client is still not consulted.
    put_socket_path(bind_socket!(socket_path()))

    with_core([], fn ->
      refute Auth.check_login("alice", "secret", "m", server: cache, core_client: StubCore)
      assert core_calls() == []
    end)
  end

  test "a socket that vanished falls back to TCP rather than raising", %{cache: cache} do
    # The end the S1 race used to blow up at: a `nil` resolution reaching
    # `Mint.HTTP.connect(:http, {:local, nil}, 0, ...)` raises, turning an
    # auth request into a 500. `forward/4` now resolves once and threads the
    # result, so the only `nil` left is this one — the clean TCP branch.
    # `Vagus.Core.ApiSocketTest` covers the other end (`post/3` handed a
    # `nil` socket directly).
    path = bind_socket!(socket_path())
    put_socket_path(path)
    File.rm!(path)

    with_core([{:ok, %{status: 401}}], fn ->
      refute Auth.check_login("alice", "secret", "m", server: cache, core_client: StubCore)
    end)
  end

  test "with no Core socket, forward falls back to the TCP client", %{cache: cache} do
    with_core([{:ok, %{status: 200}}], fn ->
      assert Auth.check_login("alice", "secret", "m", server: cache, core_client: StubCore)
      assert length(core_calls()) == 1
    end)
  end

  test "reset_cache forces a re-check against Core", %{cache: cache} do
    with_core([{:ok, %{status: 200}}, {:ok, %{status: 200}}], fn ->
      opts = [server: cache, core_client: StubCore]
      assert Auth.check_login("alice", "s3cret", "x", opts)
      :ok = Auth.reset_cache(cache)
      assert Auth.check_login("alice", "s3cret", "x", opts)
      assert length(core_calls()) == 2
    end)
  end
end
