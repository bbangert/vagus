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
    test "success:true is forwarded to the manager with its payload" do
      state = %{manager: self(), client: :irrelevant}

      msg =
        Jason.encode!(%{
          "type" => "result",
          "id" => 1,
          "success" => true,
          "result" => [%{"id" => "abc", "is_owner" => true}]
        })

      assert {:ok, ^state} = Connection.handle_in({:text, msg}, state)
      assert_receive {:event_pusher_result, 1, {:ok, [%{"id" => "abc", "is_owner" => true}]}}
    end

    test "success:true with no result key forwards a nil payload (a push ack)" do
      state = %{manager: self(), client: :irrelevant}
      msg = Jason.encode!(%{"type" => "result", "id" => 1, "success" => true})

      assert {:ok, ^state} = Connection.handle_in({:text, msg}, state)
      assert_receive {:event_pusher_result, 1, {:ok, nil}}
    end

    test "success:false is forwarded as a :core_error, not crashed on" do
      state = %{manager: self(), client: :irrelevant}
      error = %{"code" => "unauthorized", "message" => "Unauthorized"}

      msg =
        Jason.encode!(%{"type" => "result", "id" => 2, "success" => false, "error" => error})

      assert {:ok, ^state} = Connection.handle_in({:text, msg}, state)
      assert_receive {:event_pusher_result, 2, {:error, {:core_error, ^error}}}
    end

    test "a result frame without an id is ignored rather than forwarded" do
      state = %{manager: self(), client: :irrelevant}
      msg = Jason.encode!(%{"type" => "result", "success" => true})

      assert {:ok, ^state} = Connection.handle_in({:text, msg}, state)
      refute_receive {:event_pusher_result, _, _}, 20
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
    # The whole point of the port-80 wedge fix: `:close` is the only
    # return that makes `Fresh.Connection` stop the process
    # (`reconnect: false` -> `{:stop, :normal}`), and only a dead
    # connection lets the manager re-resolve the transport. Anything
    # `:reconnect`-shaped keeps re-dialling the original URI forever.
    test "handle_disconnect/3 closes rather than reconnecting internally" do
      assert Connection.handle_disconnect(1006, "abnormal closure", %{}) == :close
    end

    test "handle_disconnect/3 closes on a clean server-initiated close too" do
      assert Connection.handle_disconnect(1000, "normal closure", %{}) == :close
      assert Connection.handle_disconnect(nil, nil, %{manager: self()}) == :close
    end

    test "handle_error/2 closes on a connect failure" do
      assert Connection.handle_error({:connecting_failed, :econnrefused}, %{}) == :close
    end

    test "handle_error/2 closes on every other transport error shape" do
      for error <- [
            {:upgrading_failed, :nxdomain},
            {:streaming_failed, :closed},
            {:establishing_failed, :not_upgraded},
            {:processing_failed, :whatever},
            {:decoding_failed, :bad_frame},
            {:encoding_failed, :bad_frame},
            {:casting_failed, :closed}
          ] do
        assert Connection.handle_error(error, %{}) == :close
      end
    end
  end

  describe "process lifecycle under Fresh" do
    # The callback assertions above only pin the return value; this pins
    # what `Fresh` does with it. Port 1 refuses instantly, so this is the
    # `{:connecting_failed, :econnrefused}` path — which used to hand
    # `Fresh` a `:reconnect` and leave the process retrying that same
    # URI forever, starving the manager of the `:DOWN` it re-picks the
    # transport on.
    test "a connection whose endpoint refuses dies instead of retrying internally" do
      state = %{manager: self(), client: :irrelevant}

      {:ok, pid} =
        Fresh.start("ws://127.0.0.1:1/api/websocket", Connection, state, error_logging: false)

      ref = Process.monitor(pid)

      # Fresh's own default backoff is 250ms, so an internally
      # reconnecting process is comfortably still alive at 2s.
      # `:noproc` rather than `:normal` when the refusal beat the monitor
      # — the connect attempt runs after `:gen_statem.start/3` has
      # already returned. Either way the process is gone, which is the
      # whole assertion; the manager's `:DOWN` handler treats both the
      # same.
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 2_000
      assert reason in [:normal, :noproc]
    end
  end
end
