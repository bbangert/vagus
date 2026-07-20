defmodule Vagus.Core.ClientTest do
  use ExUnit.Case, async: true

  alias Vagus.Core.{Client, TokenStore}

  # A tiny Plug standing in for Core's `/auth/token` (and one arbitrary
  # protected path, for the 401-retry-once test), run via Bandit on an
  # ephemeral port (`port: 0`) — no new deps, Bandit/Plug are already in
  # the dep tree. Script-driven per test via a fixed-name `Agent`
  # (`Vagus.Core.ClientTest.FakeCore.Script`): tests within this module
  # always run serially regardless of `async`, so a fixed name is safe.
  defmodule FakeCore do
    @moduledoc false
    use Plug.Router

    plug(Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"])
    plug(:match)
    plug(:dispatch)

    post "/auth/token" do
      if Map.has_key?(conn.body_params, "client_id") do
        send_json(conn, 400, %{"error" => "invalid_request"})
      else
        case next_scripted_response(__MODULE__.AuthScript) do
          :default ->
            send_json(conn, 200, %{
              "access_token" => "access-#{System.unique_integer([:positive])}",
              "expires_in" => 3600,
              "token_type" => "Bearer"
            })

          {status, body} ->
            send_json(conn, status, body)
        end
      end
    end

    get "/protected" do
      case next_scripted_response(__MODULE__.ProtectedScript) do
        :default -> send_json(conn, 200, %{"ok" => true})
        {status, body} -> send_json(conn, status, body)
      end
    end

    match _ do
      send_json(conn, 404, %{"error" => "not_found"})
    end

    # Two independent scripted-response queues (one per route) - a script
    # queued for /protected must never be consumed by an /auth/token call
    # that happens to occur first (e.g. the retry path's re-exchange).
    defp next_scripted_response(agent_name) do
      Agent.get_and_update(agent_name, fn
        [next | rest] -> {next, rest}
        [] -> {:default, []}
      end)
    end

    defp send_json(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  setup do
    start_supervised!(%{
      id: FakeCore.AuthScript,
      start: {Agent, :start_link, [fn -> [] end, [name: FakeCore.AuthScript]]}
    })

    start_supervised!(%{
      id: FakeCore.ProtectedScript,
      start: {Agent, :start_link, [fn -> [] end, [name: FakeCore.ProtectedScript]]}
    })

    bandit = start_supervised!({Bandit, plug: FakeCore, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    %{base_url: "http://127.0.0.1:#{port}"}
  end

  defp script(entries), do: Agent.update(FakeCore.ProtectedScript, fn _ -> entries end)

  defp start_client(opts) do
    name = :"client_#{System.unique_integer([:positive])}"
    start_supervised!({Client, Keyword.put(opts, :name, name)})
    name
  end

  defp start_token_store(refresh_token) do
    path =
      Path.join(
        System.tmp_dir!(),
        "vagus_client_test_ts_#{System.unique_integer([:positive])}.json"
      )

    name = :"token_store_#{System.unique_integer([:positive])}"
    start_supervised!({TokenStore, name: name, path: path})

    if refresh_token do
      :ok = TokenStore.put_options(%{"refresh_token" => refresh_token}, name)
    end

    on_exit(fn -> File.rm(path) end)
    name
  end

  defp finch_name, do: :"finch_#{System.unique_integer([:positive])}"

  describe "access_token/1 exchange request shape" do
    test "exchanges the refresh token with no client_id field, per contract §5", %{
      base_url: base_url
    } do
      finch = finch_name()
      start_supervised!({Finch, name: finch})
      token_store = start_token_store("my-refresh-token")

      client =
        start_client(core_base_url: base_url, finch_name: finch, token_store: token_store)

      assert {:ok, token} = Client.access_token(client)
      assert is_binary(token)
      assert String.starts_with?(token, "access-")
    end
  end

  describe "no-refresh-token error path" do
    test "returns {:error, :no_refresh_token} without attempting a network call" do
      finch = finch_name()
      start_supervised!({Finch, name: finch})
      # An unreachable base_url proves no network call was attempted - if
      # exchange/1 tried anyway, this would surface as a connection error
      # instead of :no_refresh_token.
      token_store = start_token_store(nil)

      client =
        start_client(
          core_base_url: "http://127.0.0.1:1",
          finch_name: finch,
          token_store: token_store
        )

      assert Client.access_token(client) == {:error, :no_refresh_token}
    end
  end

  describe "expiry logic (injected clock)" do
    test "re-exchanges once the cached token has expired", %{base_url: base_url} do
      finch = finch_name()
      start_supervised!({Finch, name: finch})
      token_store = start_token_store("refresh-for-expiry")

      clock_agent =
        start_supervised!(%{id: :clock_agent, start: {Agent, :start_link, [fn -> 0 end]}})

      clock = fn -> Agent.get(clock_agent, & &1) end

      client =
        start_client(
          core_base_url: base_url,
          finch_name: finch,
          token_store: token_store,
          clock: clock
        )

      assert {:ok, token1} = Client.access_token(client)

      # Still within expires_in (3600s) - cached token reused, no new
      # exchange (FakeCore returns a token with a fresh unique suffix each
      # exchange, so an unchanged token proves the cache was used).
      Agent.update(clock_agent, fn _ -> 100 end)
      assert {:ok, ^token1} = Client.access_token(client)

      # Past expiry - forces a fresh exchange, yielding a different token.
      Agent.update(clock_agent, fn _ -> 10_000 end)
      assert {:ok, token2} = Client.access_token(client)
      assert token2 != token1
    end
  end

  describe "request/3 401-retry-once" do
    test "clears cache, re-exchanges, and retries once on a 401", %{base_url: base_url} do
      finch = finch_name()
      start_supervised!({Finch, name: finch})
      token_store = start_token_store("refresh-for-retry")
      client = start_client(core_base_url: base_url, finch_name: finch, token_store: token_store)

      # Prime the cache with an initial exchange.
      assert {:ok, _token} = Client.access_token(client)

      # /protected: first call 401s (simulating a token Core has since
      # invalidated), then 200s after the client's forced re-exchange.
      script([{401, %{}}])

      assert {:ok, %Finch.Response{status: 200}} =
               Client.request(:get, "/protected", server: client)
    end

    test "surfaces {:error, :unauthorized} if the retry also 401s", %{base_url: base_url} do
      finch = finch_name()
      start_supervised!({Finch, name: finch})
      token_store = start_token_store("refresh-for-retry-fail")
      client = start_client(core_base_url: base_url, finch_name: finch, token_store: token_store)

      assert {:ok, _token} = Client.access_token(client)
      script([{401, %{}}, {401, %{}}])

      assert Client.request(:get, "/protected", server: client) == {:error, :unauthorized}
    end
  end

  describe "malformed token response" do
    test "expires_in of the wrong type -> {:error, :invalid_token_response}, GenServer survives",
         %{base_url: base_url} do
      finch = finch_name()
      start_supervised!({Finch, name: finch})
      token_store = start_token_store("refresh-for-malformed")
      client = start_client(core_base_url: base_url, finch_name: finch, token_store: token_store)

      Agent.update(FakeCore.AuthScript, fn _ ->
        [{200, %{"access_token" => "tok", "expires_in" => "3600"}}]
      end)

      pid = GenServer.whereis(client)
      assert Client.access_token(client) == {:error, :invalid_token_response}
      assert Process.alive?(pid)

      # The GenServer is still fully usable afterwards - a well-formed
      # response on the next call exchanges normally rather than being
      # left wedged by the earlier bad one.
      assert {:ok, token} = Client.access_token(client)
      assert is_binary(token)
    end
  end

  describe "invalidate/1" do
    test "forces the next access_token/1 call to re-exchange", %{base_url: base_url} do
      finch = finch_name()
      start_supervised!({Finch, name: finch})
      token_store = start_token_store("refresh-for-invalidate")
      client = start_client(core_base_url: base_url, finch_name: finch, token_store: token_store)

      assert {:ok, token1} = Client.access_token(client)
      :ok = Client.invalidate(client)
      assert {:ok, token2} = Client.access_token(client)
      assert token2 != token1
    end
  end
end
