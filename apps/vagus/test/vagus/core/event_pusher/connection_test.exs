defmodule Vagus.Core.EventPusher.ConnectionTest do
  use ExUnit.Case, async: true

  alias Vagus.Core.{Client, EventPusher.Connection, TokenStore}

  # No live WS handshake against a fake Core server here — websock_adapter
  # (needed for Bandit to accept a WebSocket upgrade) isn't in the dep
  # tree, and the task explicitly allows exercising Fresh's callback
  # functions directly with synthetic frames/state instead. A real
  # `Vagus.Core.Client` + `Vagus.Core.TokenStore` pair (private, named,
  # isolated from the app's global singletons) stands in for the
  # dependency Connection actually calls at each step; a tiny Bandit-based
  # fake `/auth/token` backs the "token available" case (same technique as
  # Vagus.Core.ClientTest).
  defmodule FakeCore do
    @moduledoc false
    use Plug.Router

    plug(Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"])
    plug(:match)
    plug(:dispatch)

    post "/auth/token" do
      body = Jason.encode!(%{"access_token" => "conn-test-access-token", "expires_in" => 3600})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defp start_client_with_refresh_token(refresh_token, opts \\ []) do
    token_store_name = :"conn_test_ts_#{System.unique_integer([:positive])}"

    path =
      Path.join(
        System.tmp_dir!(),
        "vagus_conn_test_ts_#{System.unique_integer([:positive])}.json"
      )

    start_supervised!(%{
      id: token_store_name,
      start: {TokenStore, :start_link, [[name: token_store_name, path: path]]}
    })

    if refresh_token do
      :ok = TokenStore.put_options(%{"refresh_token" => refresh_token}, token_store_name)
    end

    on_exit(fn -> File.rm(path) end)

    core_base_url = Keyword.get(opts, :core_base_url, "http://127.0.0.1:1")
    client_name = :"conn_test_client_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: client_name,
      start:
        {Client, :start_link,
         [[name: client_name, token_store: token_store_name, core_base_url: core_base_url]]}
    })

    client_name
  end

  defp start_fake_core do
    bandit = start_supervised!({Bandit, plug: FakeCore, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    "http://127.0.0.1:#{port}"
  end

  describe "handle_connect/3" do
    test "notifies the manager and passes state through unchanged" do
      state = %{manager: self(), client: :irrelevant}
      assert {:ok, ^state} = Connection.handle_connect(101, [], state)
      assert_receive {:event_pusher_connection, :connected, pid}
      assert pid == self()
    end
  end

  describe "handle_in/2 - auth_required" do
    test "replies with an auth frame carrying the access token when one is available" do
      base_url = start_fake_core()
      client = start_client_with_refresh_token("conn-test-refresh-token", core_base_url: base_url)
      state = %{manager: self(), client: client}

      assert {:reply, [{:text, frame}], ^state} =
               Connection.handle_in({:text, Jason.encode!(%{"type" => "auth_required"})}, state)

      assert %{"type" => "auth", "access_token" => token} = Jason.decode!(frame)
      assert is_binary(token)
    end

    test "closes to retry when no access token is available (no refresh token yet)" do
      client = start_client_with_refresh_token(nil)
      state = %{manager: self(), client: client}

      assert {:close, 1011, _reason, ^state} =
               Connection.handle_in({:text, Jason.encode!(%{"type" => "auth_required"})}, state)
    end
  end

  describe "handle_in/2 - auth_ok" do
    test "notifies the manager it's ready" do
      state = %{manager: self(), client: :irrelevant}

      assert {:ok, ^state} =
               Connection.handle_in({:text, Jason.encode!(%{"type" => "auth_ok"})}, state)

      assert_receive {:event_pusher_connection, :ready, pid}
      assert pid == self()
    end
  end

  describe "handle_in/2 - auth_invalid" do
    test "invalidates the cached access token and does not crash" do
      client = start_client_with_refresh_token("conn-test-refresh-token-2")
      state = %{manager: self(), client: client}

      # Prime the cache (client's exchange target is unreachable, so this
      # legitimately fails - what matters is that invalidate/1 afterwards
      # doesn't raise regardless of prior cache state).
      _ = Client.access_token(client)

      assert {:ok, ^state} =
               Connection.handle_in({:text, Jason.encode!(%{"type" => "auth_invalid"})}, state)
    end
  end

  describe "handle_in/2 - result acks" do
    test "success:true is ignored" do
      state = %{manager: self(), client: :irrelevant}
      msg = Jason.encode!(%{"type" => "result", "id" => 1, "success" => true})
      assert {:ok, ^state} = Connection.handle_in({:text, msg}, state)
    end

    test "success:false is logged and ignored, not crashed on" do
      state = %{manager: self(), client: :irrelevant}
      msg = Jason.encode!(%{"type" => "result", "id" => 1, "success" => false})
      assert {:ok, ^state} = Connection.handle_in({:text, msg}, state)
    end
  end

  describe "handle_in/2 - unknown/undecodable frames" do
    test "an unrecognized but valid JSON frame is ignored, not crashed on" do
      state = %{manager: self(), client: :irrelevant}
      msg = Jason.encode!(%{"type" => "something_new", "whatever" => 1})
      assert {:ok, ^state} = Connection.handle_in({:text, msg}, state)
    end

    test "undecodable (non-JSON) text is ignored, not crashed on" do
      state = %{manager: self(), client: :irrelevant}
      assert {:ok, ^state} = Connection.handle_in({:text, "not json {{{"}, state)
    end

    test "a binary frame is ignored, not crashed on" do
      state = %{manager: self(), client: :irrelevant}
      assert {:ok, ^state} = Connection.handle_in({:binary, <<1, 2, 3>>}, state)
    end
  end

  describe "handle_disconnect/3 and handle_error/2" do
    test "handle_disconnect/3 always reconnects (Fresh's own backoff takes over)" do
      assert Connection.handle_disconnect(1006, "abnormal closure", %{}) == :reconnect
    end

    test "handle_error/2 always reconnects" do
      assert Connection.handle_error({:streaming_failed, :closed}, %{}) == :reconnect
    end
  end
end
