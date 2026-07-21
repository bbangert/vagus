defmodule Vagus.AuthTest do
  @moduledoc "P4-T3: the /auth credential cache + Core forward."
  use ExUnit.Case, async: true

  alias Vagus.Auth

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
