defmodule Vagus.API.CoreProxyWSDispatchTest.SpyRouter do
  @moduledoc """
  `Vagus.API.Router`, reporting each request that reaches it to the test.
  The message is for asserting that a request arrived. That none did is read
  from a counter instead.
  """

  @spec call(Plug.Conn.t()) :: Plug.Conn.t()
  def call(conn) do
    test_pid = Application.fetch_env!(:vagus, :core_ws_test_pid)
    send(test_pid, {:routed, conn.method, conn.request_path, hd(Process.get(:"$callers"))})
    Vagus.API.Router.call(conn, Vagus.API.Router.init([]))
  end
end

defmodule Vagus.API.CoreProxyWSDispatchTest do
  @moduledoc """
  `supervisor/api` answered in-process as the calling app, through the real
  bridge: a fake Core that reports every frame it is sent, the real proxy
  stack, and a hand-rolled WebSocket client.

  Nothing here sleeps to let something happen. A dispatch is held and
  released by message, through the `:ws_dispatch_fun` seam, and what another
  process does afterwards is waited for by asking that process.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  import ExUnit.CaptureLog
  import Mox
  import Plug.Conn
  import Plug.Test
  import Vagus.AppFixtures

  alias Vagus.API.CoreProxy.{WSBridge, WSDispatch}
  alias Vagus.API.CoreProxyWSDispatchTest.SpyRouter
  alias Vagus.API.CoreProxyWSTest.{Client, Stack}
  alias Vagus.API.{Dispatcher, SourceGuard}
  alias Vagus.App.Policy
  alias Vagus.Backend.HostMock

  @recv_timeout 30_000
  @task_supervisor Vagus.API.CoreProxy.TaskSupervisor
  @ordinary ~s({"id":99999,"type":"get_states"})

  # A handler's backend is a mock whose stubs belong to whichever test
  # process last claimed Mox's global mode, so they are claimed and set
  # again here: the handlers run in a task, not in this process.
  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub_with(Vagus.Backend.NetworkMock, Vagus.Backend.Network.HostStub)
    stub_with(Vagus.Backend.HostMock, Vagus.Backend.Host.HostStub)
    stub_with(Vagus.Backend.OSMock, Vagus.Backend.OS.HostStub)
    :ok
  end

  setup do
    assert tasks() == []

    on_exit(fn ->
      for pid <- tasks() do
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, @recv_timeout
      end
    end)

    Stack.start()
  end

  ## Helpers

  defp tasks, do: Task.Supervisor.children(@task_supervisor)

  # What another process has yet to do is asked of that process until it
  # has, or the deadline passes.
  defp eventually(check, deadline \\ System.monotonic_time(:millisecond) + @recv_timeout) do
    cond do
      check.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("never became true")

      true ->
        receive do
        after
          5 -> eventually(check, deadline)
        end
    end
  end

  defp await_no_tasks, do: eventually(fn -> tasks() == [] end)

  defp await_dispatches(bridge, count),
    do: eventually(fn -> map_size(websock_state(bridge).dispatches) == count end)

  defp token(slug, grants \\ %{}) do
    register_app_token(app_config(slug),
      token: "ws-dispatch-tok-#{System.unique_integer([:positive])}",
      identity: Map.merge(%{homeassistant_api: true, hassio_api: true}, grants)
    )
  end

  defp client(%{proxy_host: host, proxy_port: port}, slug, grants \\ %{}) do
    token = token(slug, grants)
    {Stack.relaying_client(host, port, token), token}
  end

  defp frame(id, method, endpoint, extra \\ %{}) do
    Jason.encode!(
      Map.merge(
        %{"id" => id, "type" => "supervisor/api", "method" => method, "endpoint" => endpoint},
        extra
      )
    )
  end

  defp send_text(client, text), do: Client.send_frame(client, {:text, text})

  defp reply(client) do
    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    {Jason.decode!(raw), client}
  end

  defp call(client, id, method, endpoint, extra \\ %{}) do
    client |> send_text(frame(id, method, endpoint, extra)) |> reply()
  end

  # The fake Core reports every frame it is sent, in order. `@ordinary` goes
  # after the frames under test, so its being the first one reported proves
  # none of them was relayed.
  defp assert_none_relayed(client) do
    client = send_text(client, @ordinary)
    assert_receive {:core_frame, :text, first}, @recv_timeout
    assert first == @ordinary, "a supervisor/api frame reached Core"
    {echo, client} = Client.next_frame(client, @recv_timeout)
    assert echo == {:text, @ordinary}
    client
  end

  # A request reaching the router is counted before the router runs, and so
  # before its task can answer. Reading the count after the answer is then
  # sound, where looking in the mailbox for the spy's message is not: that
  # message and the answer come from different processes, in no set order.
  defp spy do
    routed = :counters.new(1, [])
    Process.put(:routed, routed)

    Stack.put_env(
      :ws_dispatch_fun,
      &WSDispatch.run(&1, &2, &3, fn conn ->
        :counters.add(routed, 1, 1)
        SpyRouter.call(conn)
      end)
    )
  end

  defp routed, do: :counters.get(Process.get(:routed), 1)

  # Every dispatch is counted, reports itself, and then waits to be told its
  # outcome. The count is for the same reason as the spy's.
  defp hold_dispatches do
    test_pid = self()
    dispatched = :counters.new(1, [])
    Process.put(:dispatched, dispatched)

    Stack.put_env(:ws_dispatch_fun, fn slug, _credential, request ->
      :counters.add(dispatched, 1, 1)
      send(test_pid, {:dispatching, self(), hd(Process.get(:"$callers")), slug, request})

      receive do
        {:release, outcome} -> outcome
      end
    end)
  end

  defp dispatched, do: :counters.get(Process.get(:dispatched), 1)

  defp ok_outcome(data),
    do: {:response, 200, Jason.encode!(%{"result" => "ok", "data" => data})}

  defp release(task, outcome) do
    ref = Process.monitor(task)
    send(task, {:release, outcome})
    assert_receive {:DOWN, ^ref, :process, ^task, _reason}, @recv_timeout
  end

  defp dispatching(count) do
    for _ <- 1..count//1 do
      assert_receive {:dispatching, task, bridge, _slug, _request}, @recv_timeout
      {task, bridge}
    end
  end

  defp rest(method, path, token, body \\ nil) do
    conn =
      if body,
        do: conn(method, path, body) |> put_req_header("content-type", "application/json"),
        else: conn(method, path)

    conn = put_req_header(conn, "x-supervisor-token", token)

    try do
      conn = Dispatcher.call(conn, Dispatcher.init([]))
      {conn.status, conn.resp_body}
    rescue
      _raised_after_answering ->
        {status, _headers, body} = sent_resp(conn)
        {status, body}
    end
  end

  # Bandit keeps the WebSock state inside its handler's own.
  defp websock_state(bridge) do
    {_socket, %{connection: %{websock_state: state}}} = :sys.get_state(bridge)
    state
  end

  defp bridge_state(bridge), do: bridge |> :sys.get_state() |> inspect(limit: :infinity)

  defp assert_error(reply, id, code) do
    assert %{"id" => ^id, "type" => "result", "success" => false, "error" => %{"code" => ^code}} =
             reply
  end

  # The answer to a caller the dispatch no longer admits. The gate's own
  # refusals are not worded this way.
  @not_admitted "Supervisor-only commands are not available through this proxy"

  defp data(body), do: Jason.decode!(body)["data"]

  ## Answered as the app

  # An app's own info has no clock or meter in it, so the two reads are equal.
  test "a call is answered with what the same request over HTTP returns", ctx do
    install_app(app_config("wsd_other"))
    {client, token} = client(ctx, "wsd_self")

    {own, client} = call(client, 1, "get", "/addons/self/info")
    {200, body} = rest(:get, "/addons/self/info", token)
    assert own == %{"id" => 1, "type" => "result", "success" => true, "result" => data(body)}
    assert own["result"]["slug"] == "wsd_self"

    {foreign, client} = call(client, 2, "get", "/addons/wsd_other/info")
    assert {403, body} = rest(:get, "/addons/wsd_other/info", token)
    assert_error(foreign, 2, "unauthorized")
    assert foreign["error"]["message"] == Jason.decode!(body)["message"]

    assert_none_relayed(client)
  end

  test "a read with a clock in it has the same fields as over HTTP", ctx do
    {client, token} = client(ctx, "wsd_info")

    {reply, client} = call(client, 1, "get", "/supervisor/info")
    {200, body} = rest(:get, "/supervisor/info", token)

    assert reply["success"]
    assert reply["result"] != %{}
    assert Enum.sort(Map.keys(reply["result"])) == Enum.sort(Map.keys(data(body)))

    assert_none_relayed(client)
  end

  test "the tier gate refuses the app, whatever its role", ctx do
    {client, token} = client(ctx, "wsd_tier", %{hassio_role: "admin"})

    for {method, endpoint} <- [
          {:post, "/ingress/session"},
          {:get, "/os/datadisk/list"},
          {:post, "/addons/wsd_tier/security"}
        ] do
      assert {status, _body} = rest(method, endpoint, token)
      assert status in [401, 403]
    end

    {reply, client} = call(client, 1, "post", "/ingress/session")
    assert_error(reply, 1, "unauthorized")
    {reply, client} = call(client, 2, "get", "/os/datadisk/list")
    assert_error(reply, 2, "unauthorized")
    {reply, client} = call(client, 3, "post", "/addons/wsd_tier/security")
    assert_error(reply, 3, "unauthorized")

    assert_none_relayed(client)
  end

  test "an unknown path is closed: refused by tier, or not found to an admin", ctx do
    {default, _token} = client(ctx, "wsd_nope_default", %{hassio_role: "default"})
    {reply, _client} = call(default, 1, "get", "/nope")
    assert_error(reply, 1, "unauthorized")

    {admin, _token} = client(ctx, "wsd_nope_admin", %{hassio_role: "admin"})
    {reply, _client} = call(admin, 1, "get", "/nope")
    assert_error(reply, 1, "unknown_error")
    assert reply["error"]["message"] == "not found"
  end

  ## Refused before anything is dispatched

  test "what the dispatcher would not have sent to the router is never dispatched", ctx do
    spy()
    {client, _token} = client(ctx, "wsd_predispatch", %{hassio_role: "admin"})

    reserved = [
      "/core/api/hassio/info",
      "/core/api/hassio_auth",
      "/homeassistant/api/hassio_auth/password_reset",
      "/core/api/hassio_ingress/x/y"
    ]

    unsupported = [
      # The Core proxy and the WebSocket this call arrived on.
      "/core/api/states",
      "/core/api/",
      "/homeassistant/api/config",
      "/core/websocket",
      "/homeassistant/websocket",
      "/core/api/websocket",
      # The ingress proxy.
      "/ingress/Zm9vYmFyYmF6cXV4",
      "/ingress/Zm9vYmFyYmF6cXV4/index.html",
      # Streams and files.
      "/addons/self/logs/follow",
      "/addons/self/logs/boots/0/follow",
      "/host/logs/follow",
      "/core/logs/boots/-1/follow",
      "/backups/new/upload",
      "/backups/abcd1234/download",
      "/addons/self/icon",
      "/store/addons/core_ssh/logo",
      "/addons/self/changelog",
      "/store/addons/core_ssh/documentation",
      # Not one spelling of one path.
      "/core/api/%68assio/info",
      # A reserved view under more than one layer of encoding.
      "/core/api/%2568assio_auth",
      "/core/api/%252568assio/info",
      "/homeassistant/api/%252e/%2568assio_auth",
      "/core/api/%252Fhassio_auth/password_reset",
      "/core/api/./hassio_auth",
      "/core/api/../api/hassio_auth",
      "/supervisor/%69nfo",
      "/supervisor/%2569nfo",
      "/supervisor/./info",
      "/supervisor/../supervisor/info",
      "/supervisor//info",
      "/supervisor/info/",
      "//supervisor/info",
      "//evil.example/supervisor/info",
      "http://evil.example/supervisor/info",
      "supervisor/info",
      "",
      "/supervisor/info?x=1",
      "/supervisor/info#frag",
      "/supervisor\\info",
      "/supervisor/in fo",
      "/supervisor/infö",
      "/supervisor/info\u0000",
      # The exploit filter.
      "/addons/<script>alert(1)</script>",
      "/proc/self/environ"
    ]

    client =
      Enum.reduce(Enum.with_index(reserved, 1), client, fn {endpoint, id}, client ->
        {reply, client} = call(client, id, "get", endpoint)
        assert_error(reply, id, "unauthorized")
        client
      end)

    client =
      Enum.reduce(Enum.with_index(unsupported, 100), client, fn {endpoint, id}, client ->
        {reply, client} = call(client, id, "get", endpoint)
        assert_error(reply, id, "unknown_error")
        assert reply["error"]["message"] == "", endpoint
        client
      end)

    # A harmful query, and a target longer than a request line.
    {reply, client} =
      call(client, 900, "get", "/supervisor/info", %{"params" => %{"q" => "1 union select x("}})

    assert_error(reply, 900, "unknown_error")

    {reply, client} = call(client, 901, "get", "/" <> String.duplicate("a", 8_000))
    assert_error(reply, 901, "unknown_error")

    {reply, client} =
      call(client, 902, "get", "/supervisor/info", %{
        "params" => %{"q" => String.duplicate("a", 8_000)}
      })

    assert_error(reply, 902, "unknown_error")

    # The spy proves the call path works at all, then that nothing above used it.
    {reply, client} = call(client, 950, "get", "/supervisor/info")
    assert reply["success"]
    assert_receive {:routed, "GET", "/supervisor/info", _bridge}, @recv_timeout
    assert routed() == 1

    assert_none_relayed(client)
  end

  test "a query goes through params, and reaches the router encoded", ctx do
    test_pid = self()

    Stack.put_env(
      :ws_dispatch_fun,
      &WSDispatch.run(&1, &2, &3, fn conn ->
        send(test_pid, {:query, conn.query_string})
        SpyRouter.call(conn)
      end)
    )

    {client, _token} = client(ctx, "wsd_params", %{hassio_role: "admin"})

    {reply, _client} =
      call(client, 1, "get", "/supervisor/info", %{"params" => %{"a" => "b c", "n" => 2}})

    assert reply["success"]
    assert_receive {:query, "a=b+c&n=2"}, @recv_timeout
  end

  ## The frame

  test "only a frame Core's schema accepts is a call; the rest is refused, not dispatched",
       ctx do
    spy()
    {client, _token} = client(ctx, "wsd_schema")

    call = ~s("type":"supervisor/api","endpoint":"/supervisor/info","method":"get")

    malformed = [
      # No id, or one Core would not take.
      {~s({#{call}}), nil},
      {~s({"id":0,#{call}}), 0},
      {~s({"id":-1,#{call}}), -1},
      {~s({"id":1.0,#{call}}), 1.0},
      {~s({"id":"1",#{call}}), "1"},
      {~s({"id":true,#{call}}), true},
      {~s({"id":null,#{call}}), nil},
      # A repeated key: Core would read the last, the decoder here the first.
      {~s({"id":1,#{call},"id":2}), 2},
      {~s({"id":1,#{call},"endpoint":"/addons"}), 1},
      {~s({"id":1,#{call},"method":"post"}), 1},
      {~s({"id":1,#{call},"data":{},"data":{}}), 1},
      {~s({"id":1,#{call},"params":{},"params":{}}), 1},
      {~s({"id":1,#{call},"timeout":1,"timeout":2}), 1},
      # A key the schema does not have.
      {~s({"id":1,#{call},"extra":1}), 1},
      # Wrong types.
      {~s({"id":1,"type":"supervisor/api","endpoint":5,"method":"get"}), 1},
      {~s({"id":1,"type":"supervisor/api","endpoint":"/supervisor/info","method":5}), 1},
      {~s({"id":1,"type":"supervisor/api","endpoint":"/supervisor/info"}), 1},
      {~s({"id":1,"type":"supervisor/api","method":"get"}), 1},
      {~s({"id":1,#{call},"data":[]}), 1},
      {~s({"id":1,#{call},"data":null}), 1},
      {~s({"id":1,#{call},"data":"x"}), 1},
      {~s({"id":1,#{call},"params":[]}), 1},
      {~s({"id":1,#{call},"params":{"a":{}}}), 1},
      {~s({"id":1,#{call},"params":{"a":true}}), 1},
      {~s({"id":1,#{call},"timeout":"1"}), 1},
      {~s({"id":1,#{call},"timeout":true}), 1}
    ]

    client =
      Enum.reduce(malformed, client, fn {text, id}, client ->
        {reply, client} = client |> send_text(text) |> reply()
        assert_error(reply, id, "unauthorized")
        client
      end)

    assert routed() == 0
    assert_none_relayed(client)
  end

  test "an array containing a call is refused whole, and nothing is dispatched", ctx do
    spy()
    {client, _token} = client(ctx, "wsd_array")
    call = frame(1, "get", "/supervisor/info")

    client =
      Enum.reduce(["[#{call}]", "[#{@ordinary},#{call}]", "[#{call},#{call}]"], client, fn text,
                                                                                           client ->
        {reply, client} = client |> send_text(text) |> reply()
        assert_error(reply, nil, "unauthorized")
        client
      end)

    assert routed() == 0
    assert_none_relayed(client)
  end

  test "the method is one the router serves, in either case, and nothing else", ctx do
    spy()
    {client, token} = client(ctx, "wsd_method")

    {upper, client} = call(client, 1, "GET", "/supervisor/info")
    {mixed, client} = call(client, 2, "Get", "/supervisor/info")
    assert upper["success"] and mixed["success"]
    assert_receive {:routed, "GET", "/supervisor/info", _bridge}, @recv_timeout
    assert_receive {:routed, "GET", "/supervisor/info", _bridge}, @recv_timeout

    # Served by no route: what HTTP answers.
    {reply, client} = call(client, 3, "delete", "/supervisor/info")
    assert {404, _body} = rest(:delete, "/supervisor/info", token)
    assert_error(reply, 3, "unknown_error")
    assert reply["error"]["message"] == "not found"
    assert_receive {:routed, "DELETE", "/supervisor/info", _bridge}, @recv_timeout

    client =
      (~w(put patch head options trace connect PUT gët poſt) ++
         ["", " get", "get ", "get\n", "GET /addons HTTP/1.1"])
      |> Enum.with_index(10)
      |> Enum.reduce(client, fn {method, id}, client ->
        {reply, client} = call(client, id, method, "/supervisor/info")
        assert_error(reply, id, "unknown_error")
        client
      end)

    assert routed() == 3
    assert_none_relayed(client)
  end

  ## The size limits

  defp options_of(bytes) do
    empty = byte_size(Jason.encode!(%{"options" => %{"k" => ""}}))
    %{"options" => %{"k" => String.duplicate("a", bytes - empty)}}
  end

  test "the router's body limit applies to data, to the byte, before anything is started",
       ctx do
    spy()
    {client, token} = client(ctx, "wsd_body")

    at_limit = options_of(65_536)
    assert byte_size(Jason.encode!(at_limit)) == 65_536

    {reply, client} = call(client, 1, "post", "/addons/self/options", %{"data" => at_limit})
    {status, _body} = rest(:post, "/addons/self/options", token, Jason.encode!(at_limit))
    assert status != 413
    assert reply["success"] == (status == 200)
    refute reply["error"]["message"] == "request body too large"
    assert_receive {:routed, "POST", "/addons/self/options", bridge}, @recv_timeout
    await_dispatches(bridge, 0)

    client =
      Enum.reduce([{2, options_of(65_537)}, {3, options_of(200_000)}], client, fn {id, data},
                                                                                  client ->
        {reply, client} = call(client, id, "post", "/addons/self/options", %{"data" => data})

        # The answer is the one HTTP gives the same body.
        assert {413, body} = rest(:post, "/addons/self/options", token, Jason.encode!(data))
        assert_error(reply, id, "unknown_error")
        assert reply["error"]["message"] == Jason.decode!(body)["message"]
        client
      end)

    # Refused in the bridge: no task, no slot, nothing routed.
    assert routed() == 1
    assert websock_state(bridge).dispatches == %{}
    assert tasks() == []
    assert_none_relayed(client)
  end

  defp read(frame) do
    %Jason.OrderedObject{} = object = Jason.decode!(frame, objects: :ordered_objects)
    WSDispatch.read(object)
  end

  test "the size checks never refuse what the router would read" do
    call = ~s("id":1,"type":"supervisor/api","endpoint":"/x","method":"post")

    # Megabytes of frame around a small body.
    padded = "{" <> call <> String.duplicate(" ", 2_000_000) <> ~s(,"data":{"a":1}})
    assert {:ok, 1, %{body: ~s({"a":1})}} = read(padded)

    # Written long, encoded short: escapes and whitespace.
    escaped = String.duplicate("\\u0041", 60_000)
    assert {:ok, 1, %{body: body}} = read(~s({#{call},"data":{"a":"#{escaped}"}}))
    assert byte_size(body) == 60_008

    spaced = "[" <> String.duplicate("1 , ", 30_000) <> "1]"
    assert {:ok, 1, %{body: body}} = read(~s({#{call},"data":{"a":#{spaced}}}))
    assert byte_size(body) < 65_536

    # Sixty integers of a thousand digits, the most the decoder takes in one.
    digits = "[" <> String.duplicate(String.duplicate("9", 1_000) <> ",", 59) <> "9]"
    assert {:ok, 1, %{body: body}} = read(~s({#{call},"data":{"a":#{digits}}}))
    assert byte_size(body) == 59_068
  end

  test "data over the limit is refused, however it was written" do
    call = ~s("id":1,"type":"supervisor/api","endpoint":"/x","method":"post")

    # Written short, encoded long: the exact size decides, not the estimate.
    floats = "[" <> String.duplicate("1e5,", 15_000) <> "1e5]"
    assert byte_size(floats) < 65_536
    assert {:error, 1, :too_large} = read(~s({#{call},"data":{"a":#{floats}}}))

    # Long integers: just over, and megabytes over.
    integers = fn count ->
      "[" <> String.duplicate(String.duplicate("9", 1_000) <> ",", count) <> "9]"
    end

    assert {:error, 1, :too_large} = read(~s({#{call},"data":{"a":#{integers.(66)}}}))
    assert {:error, 1, :too_large} = read(~s({#{call},"data":{"a":#{integers.(3_000)}}}))

    # Many small elements, each of them counted.
    assert {:error, 1, :too_large} =
             read(~s({#{call},"data":{"a":[#{String.duplicate("[],", 40_000)}[]]}}))

    assert {:error, 1, :too_large} =
             read(~s({#{call},"data":{"a":"#{String.duplicate("a", 3_000_000)}"}}))
  end

  test "a query is bounded as written, at the request line's limit" do
    call = ~s("id":1,"type":"supervisor/api","endpoint":"/x","method":"get")
    query = fn bytes -> ~s({#{call},"params":{"q":"#{String.duplicate("a", bytes)}"}}) end

    # `/x` and `q=` are four bytes of the 8,000.
    assert {:ok, 1, %{query: "q=" <> _}} = read(query.(7_996))
    assert {:error, 1, :unsupported} = read(query.(7_997))
    assert {:error, 1, :unsupported} = read(query.(3_000_000))

    # Short as written, long once encoded.
    assert {:error, 1, :unsupported} =
             read(~s({#{call},"params":{"q":"#{String.duplicate(" /", 2_000)}"}}))
  end

  test "a request always carries the JSON content type, with or without a body" do
    for body <- ["", ~s({"a":1})] do
      conn =
        WSDispatch.conn(
          %{method: "POST", path: "/x", segments: ["x"], query: "", body: body, timeout_ms: 1},
          "t"
        )

      assert get_req_header(conn, "content-type") == ["application/json"]
    end
  end

  ## The caller is the one the socket was opened as

  test "an app uninstalled with its socket open is refused, and nothing is dispatched", ctx do
    spy()
    {client, _token} = client(ctx, "wsd_gone")

    {reply, client} = call(client, 1, "get", "/supervisor/info")
    assert reply["success"]
    assert_receive {:routed, "GET", "/supervisor/info", _bridge}, @recv_timeout

    forget_app("wsd_gone")

    {reply, client} = call(client, 2, "get", "/supervisor/info")
    assert_error(reply, 2, "unauthorized")
    assert routed() == 1

    assert_none_relayed(client)
  end

  test "a socket does not outlive the token it was opened with", ctx do
    spy()
    {client, _token} = client(ctx, "wsd_rotated")

    {reply, client} = call(client, 1, "get", "/supervisor/info")
    assert reply["success"]
    assert_receive {:routed, "GET", "/supervisor/info", _bridge}, @recv_timeout

    # Its process restarted: no container, so no token at all.
    install_app(app_config("wsd_rotated", %{"homeassistant_api" => true, "hassio_api" => true}))
    {reply, client} = call(client, 2, "get", "/supervisor/info")
    assert_error(reply, 2, "unauthorized")

    # Started again with the same grants: a new token, which this socket
    # never presented.
    token("wsd_rotated")
    {reply, client} = call(client, 3, "get", "/supervisor/info")
    assert_error(reply, 3, "unauthorized")
    assert reply["error"]["message"] == @not_admitted

    # Reinstalled without the grant.
    token("wsd_rotated", %{homeassistant_api: false})
    {reply, client} = call(client, 4, "get", "/supervisor/info")
    assert_error(reply, 4, "unauthorized")

    assert routed() == 1
    client = assert_none_relayed(client)

    # The token the app holds now opens a socket of its own.
    Client.send_frame(client, {:close, 1000, ""})
    assert_receive {:core_terminate, _reason}, @recv_timeout

    fresh = token("wsd_rotated", %{homeassistant_api: true})
    again = Stack.relaying_client(ctx.proxy_host, ctx.proxy_port, fresh)
    {reply, _client} = call(again, 1, "get", "/supervisor/info")
    assert reply["success"]
  end

  test "an app reinstalled with a higher role is refused, not graded as the new one", ctx do
    spy()
    {client, _token} = client(ctx, "wsd_raised", %{hassio_role: "default"})

    # `/addons` asks for manager: the gate refuses, in its own words.
    {reply, client} = call(client, 1, "get", "/addons")
    assert_error(reply, 1, "unauthorized")
    assert reply["error"]["message"] == "unauthorized"
    assert_receive {:routed, "GET", "/addons", _bridge}, @recv_timeout

    token("wsd_raised", %{hassio_role: "manager"})

    {reply, client} = call(client, 2, "get", "/addons")
    assert_error(reply, 2, "unauthorized")
    assert reply["error"]["message"] == @not_admitted
    assert routed() == 1

    assert_none_relayed(client)
  end

  # An update commits the new config before its start step mints a new
  # token, so for that long the old token names an app with new grants.
  test "grants changed under the same token are the ones that count", ctx do
    spy()
    {client, _token} = client(ctx, "wsd_inplace", %{hassio_role: "default"})
    [{app, _slug}] = Registry.lookup(Vagus.App.Directory, {:slug, "wsd_inplace"})

    set = fn key, value ->
      :sys.replace_state(app, fn {state, data} ->
        {state, %{data | config: Map.replace!(data.config, key, value)}}
      end)
    end

    {reply, client} = call(client, 1, "get", "/addons")
    assert_error(reply, 1, "unauthorized")

    set.(:hassio_role, "manager")
    {reply, client} = call(client, 2, "get", "/addons")
    assert reply["success"]

    set.(:hassio_role, "default")
    {reply, client} = call(client, 3, "get", "/addons")
    assert_error(reply, 3, "unauthorized")
    assert reply["error"]["message"] == "unauthorized"

    for _call <- 1..3, do: assert_receive({:routed, "GET", "/addons", _bridge}, @recv_timeout)

    # Without the grant the socket itself needs, the command is refused and
    # the request never put to the router.
    set.(:homeassistant_api, false)
    {reply, client} = call(client, 4, "get", "/supervisor/info")
    assert_error(reply, 4, "unauthorized")
    assert reply["error"]["message"] == @not_admitted
    assert routed() == 3

    assert_none_relayed(client)
  end

  ## No secret outside the request

  test "the token is in no bridge state, message or log, even when the handler dies", ctx do
    spy()
    {client, token} = client(ctx, "wsd_secret")

    {reply, client} = call(client, 1, "get", "/supervisor/info")
    assert reply["success"]
    assert_receive {:routed, "GET", "/supervisor/info", bridge}, @recv_timeout

    :erlang.trace(bridge, true, [:receive])

    expect(HostMock, :info, fn -> raise "boom #{token}" end)
    expect(HostMock, :info, fn -> exit({:boom, token}) end)
    expect(HostMock, :info, fn -> throw({:boom, token}) end)

    {client, log} =
      with_log(fn ->
        Enum.reduce(2..4, client, fn id, client ->
          {reply, client} = call(client, id, "get", "/host/info")
          assert_error(reply, id, "unknown_error")
          assert reply["error"]["message"] == "internal server error"
          client
        end)
      end)

    {reply, client} = call(client, 5, "get", "/supervisor/info")
    assert reply["success"]

    # What the state does hold of the credential is its hash.
    assert websock_state(bridge).credential == Policy.hash(token)
    refute bridge_state(bridge) =~ token
    :erlang.trace(bridge, false, [:receive])

    # Every trace message for the bridge is in the mailbox once this arrives.
    delivered = :erlang.trace_delivered(bridge)
    assert_receive {:trace_delivered, ^bridge, ^delivered}, @recv_timeout
    received = collect_trace(bridge, [])
    assert Enum.any?(received, &match?({:supervisor_api, _ref, _result}, &1))
    refute inspect(received, limit: :infinity, printable_limit: :infinity) =~ token

    refute log =~ token
    refute log =~ "boom"
    assert log =~ "a supervisor/api call raised RuntimeError in "
    assert log =~ "a supervisor/api call exited in "
    assert log =~ "a supervisor/api call threw in "

    if path = System.get_env("WS_CRASH_LOG"), do: File.write!(path, log)
    assert_none_relayed(client)
  end

  defp collect_trace(bridge, acc) do
    receive do
      {:trace, ^bridge, :receive, message} -> collect_trace(bridge, [message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @request %{method: "GET", path: "/x", segments: ["x"], query: "", body: "", timeout_ms: 1}

  # `run/4` is called here directly, so a raise it let through would fail
  # the test, and one it turned into a crash report would be in the log.
  test "a raise anywhere the token is in scope is caught, and logged without it" do
    token = token("wsd_guard")
    credential = Policy.hash(token)

    log =
      capture_log(fn ->
        # Comparing the hashes.
        assert WSDispatch.run("wsd_guard", :not_a_hash, @request) == :no_response
        # Building the request.
        assert WSDispatch.run("wsd_guard", credential, %{}) == :no_response
        # The router.
        assert WSDispatch.run("wsd_guard", credential, @request, fn conn ->
                 raise "boom " <> hd(get_req_header(conn, "x-supervisor-token"))
               end) == :no_response
      end)

    assert log =~
             "a supervisor/api call raised ArgumentError in Plug.Crypto.secure_compare/2"

    assert log =~ "a supervisor/api call raised KeyError in "
    assert log =~ "a supervisor/api call raised RuntimeError in "
    refute log =~ token
    refute log =~ "boom"

    if path = System.get_env("WS_GUARD_LOG"), do: File.write!(path, log)
  end

  test "a dispatch task that itself dies answers the call and logs nothing of the request",
       ctx do
    {client, token} = client(ctx, "wsd_task_crash")

    Stack.put_env(:ws_dispatch_fun, fn _slug, _credential, _request -> raise "task died" end)

    {client, log} =
      with_log(fn ->
        {reply, client} = call(client, 1, "get", "/supervisor/info", %{"data" => %{"zz" => 1}})
        assert_error(reply, 1, "unknown_error")
        assert reply["error"]["message"] == ""
        client
      end)

    # The crash report is there, so what is refuted below is refuted of it.
    assert log =~ "terminating"
    assert log =~ "(RuntimeError) task died"
    refute log =~ token
    refute log =~ "zz"
    if path = System.get_env("WS_TASK_CRASH_LOG"), do: File.write!(path, log)

    Stack.put_env(:ws_dispatch_fun, &WSDispatch.run/3)
    {reply, _client} = call(client, 2, "get", "/supervisor/info")
    assert reply["success"]
  end

  # From the compiled modules' import tables, so an aliased or imported call
  # counts and a mention in a comment does not.
  test "the dispatch is the one caller of App.token/1" do
    {:ok, modules} = :application.get_key(:vagus, :modules)

    callers =
      for module <- modules,
          {:ok, {^module, [imports: imports]}} <- [
            :beam_lib.chunks(:code.which(module), [:imports])
          ],
          {Vagus.App, :token, 1} in imports,
          do: module

    assert callers == [WSDispatch]
  end

  # The seam swaps out the whole dispatch, the caller's re-check included.
  test "the dispatch seam is compiled into the test build only" do
    lib = Path.expand("../../../lib", __DIR__)

    mentions =
      for file <- Path.wildcard(Path.join(lib, "**/*.ex")),
          File.read!(file) =~ "ws_dispatch_fun",
          do: Path.relative_to(file, lib)

    assert mentions == ["vagus/api/core_proxy/ws_bridge.ex"]

    # With every `if Mix.env() == :test` body removed, nothing names it.
    {outside, guarded} =
      lib
      |> Path.join("vagus/api/core_proxy/ws_bridge.ex")
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk(0, fn
        {:if, _meta,
         [
           {:==, _eq, [{{:., _dot, [{:__aliases__, _alias, [:Mix]}, :env]}, _call, []}, :test]},
           branches
         ]},
        guarded ->
          {{:if, [], [true, Keyword.delete(branches, :do)]}, guarded + 1}

        node, guarded ->
          {node, guarded}
      end)

    assert guarded == 1
    refute Macro.to_string(outside) =~ "ws_dispatch_fun"
  end

  ## Refusals are counted under static labels

  test "on device every refusal is cast to the guard under a constant label", ctx do
    hold_dispatches()
    {client, _token} = client(ctx, "wsd_counted")
    client = send_text(client, frame(1, "get", "/supervisor/info"))
    assert_receive {:dispatching, task, bridge, "wsd_counted", _request}, @recv_timeout
    state = websock_state(bridge)

    Stack.put_env(:api_source_guard, true)
    Process.register(self(), SourceGuard)

    full = %{
      state
      | dispatches:
          Map.new(1..8, &{make_ref(), %{id: &1, monitor: make_ref(), timer: make_ref()}})
    }

    log =
      capture_log(fn ->
        for {text, state} <- [
              {~s({"id":1,"type":"supervisor/api","endpoint":"/zz-marker"}), state},
              {frame(2, "get", "/core/api/zz-marker"), state},
              {frame(3, "post", "/zz-marker", %{"data" => options_of(70_000)}), state},
              {frame(4, "get", "/zz-marker"), full}
            ] do
          assert {:push, {:text, _result}, ^state} =
                   WSBridge.handle_in({text, [opcode: :text]}, state)
        end

        assert WSDispatch.run("wsd_no_such_app", <<0::256>>, @request) == :unauthorized
      end)

    refute log =~ "authz"
    refute log =~ "zz-marker"

    for label <-
          ~w(authz/core_ws authz/core_ws+endpoint authz/core_ws+body authz/core_ws+busy authz/core_ws+caller) do
      assert_received {:"$gen_cast", {:filtered, :authz, ^label}}
    end

    refute_received {:"$gen_cast", _other}

    Process.unregister(SourceGuard)
    release(task, :no_response)
    {_reply, _client} = reply(client)
  end

  ## Liveness and bounds

  test "pending calls never hold the relay, and each is answered under its own id", ctx do
    hold_dispatches()
    {client, _token} = client(ctx, "wsd_pending")

    client =
      Enum.reduce(1..8, client, fn id, client ->
        send_text(client, frame(id, "get", "/supervisor/info", %{"params" => %{"n" => id}}))
      end)

    # Each task is told apart by what its own request carries: the order
    # eight processes report in is not the order they were started in.
    tasks =
      for id <- 1..8 do
        query = "n=#{id}"

        assert_receive {:dispatching, task, _bridge, "wsd_pending", %{query: ^query}},
                       @recv_timeout

        {id, task}
      end

    # Ordinary frames relay, in order, with every call still pending.
    client =
      Enum.reduce(1..20, client, fn n, client ->
        text = ~s({"id":#{1000 + n},"type":"get_states"})
        client = send_text(client, text)
        assert_receive {:core_frame, :text, ^text}, @recv_timeout
        {echo, client} = Client.next_frame(client, @recv_timeout)
        assert echo == {:text, text}
        client
      end)

    # Answered in the reverse of the order they were asked in.
    Enum.reduce(Enum.reverse(tasks), client, fn {id, task}, client ->
      send(task, {:release, ok_outcome(%{"n" => id})})
      {reply, client} = reply(client)

      assert reply ==
               %{"id" => id, "type" => "result", "success" => true, "result" => %{"n" => id}}

      client
    end)
  end

  test "a call that times out is answered once; its task finishes and its answer is dropped",
       ctx do
    hold_dispatches()
    {client, _token} = client(ctx, "wsd_timeout")

    client = send_text(client, frame(1, "get", "/supervisor/info", %{"timeout" => 0}))
    assert_receive {:dispatching, task, bridge, _slug, %{timeout_ms: 0}}, @recv_timeout

    {reply, client} = reply(client)
    assert_error(reply, 1, "unknown_error")
    assert reply["error"]["message"] == ""

    # Left running, and still holding its slot.
    assert Process.alive?(task)
    assert tasks() == [task]
    assert map_size(websock_state(bridge).dispatches) == 1

    release(task, ok_outcome(%{"late" => true}))
    await_dispatches(bridge, 0)
    await_no_tasks()

    # Whatever the task sent has been handled, and none of it was an answer:
    # the next frame out is the next call's.
    {reply, _client} = call_released(client, 2)
    assert reply == %{"id" => 2, "type" => "result", "success" => true, "result" => %{"n" => 2}}
  end

  defp call_released(client, id) do
    client = send_text(client, frame(id, "get", "/supervisor/info"))
    assert_receive {:dispatching, task, _bridge, _slug, _request}, @recv_timeout
    send(task, {:release, ok_outcome(%{"n" => id})})
    reply(client)
  end

  test "one socket may leave eight calls unfinished, timed out or not; a ninth is told so",
       ctx do
    hold_dispatches()
    {client, _token} = client(ctx, "wsd_bound")

    client =
      Enum.reduce(1..8, client, fn id, client ->
        send_text(client, frame(id, "get", "/supervisor/info", %{"timeout" => 0}))
      end)

    started = dispatching(8)
    [{_task, bridge} | _rest] = started
    tasks = Enum.map(started, &elem(&1, 0))

    client =
      Enum.reduce(1..8, client, fn _n, client ->
        {reply, client} = reply(client)

        assert %{"success" => false, "error" => %{"code" => "unknown_error", "message" => ""}} =
                 reply

        client
      end)

    {reply, client} = call(client, 9, "get", "/supervisor/info")
    assert_error(reply, 9, "unknown_error")
    assert reply["error"]["message"] == "Too many requests in flight"
    assert dispatched() == 8
    assert length(tasks()) == 8

    # The slot is free once the bridge has seen the task end.
    release(hd(tasks), :no_response)
    await_dispatches(bridge, 7)
    {reply, _client} = call_released(client, 10)
    assert reply["success"]

    Enum.each(tl(tasks), &release(&1, :no_response))
    await_no_tasks()
  end

  # A socket's frames arrive as messages to the process that opened it, so
  # each socket here has a process of its own. It sends `calls`, reports how
  # many were answered busy, and closes the socket when told to.
  defp socket(ctx, token, calls) do
    test_pid = self()

    spawn_link(fn ->
      client = handshake(ctx, token)

      client =
        Enum.reduce(calls, client, fn id, client ->
          send_text(client, frame(id, "get", "/supervisor/info"))
        end)

      send(test_pid, {:busy, self(), busy_replies(client)})

      receive do
        :close -> Client.send_frame(client, {:close, 1000, ""})
      end
    end)
  end

  defp busy(socket) do
    assert_receive {:busy, ^socket, count}, @recv_timeout
    count
  end

  # `Stack.relaying_client/3` without the wait for the fake Core's report,
  # which goes to the test process.
  defp handshake(%{proxy_host: host, proxy_port: port}, token) do
    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)
    client = send_text(client, Jason.encode!(%{"access_token" => token}))
    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    %{"type" => "auth_ok"} = Jason.decode!(raw)
    client
  end

  # A socket's calls are started in order, so its busy answers are the only
  # frames it has until a task is released.
  defp busy_replies(client) do
    client = send_text(client, @ordinary)
    count_until_echo(client, 0)
  end

  defp count_until_echo(client, busy) do
    case Client.next_frame(client, @recv_timeout) do
      {{:text, @ordinary}, _client} ->
        busy

      {{:text, raw}, client} ->
        %{"error" => %{"message" => "Too many requests in flight"}} = Jason.decode!(raw)
        count_until_echo(client, busy + 1)
    end
  end

  test "all sockets together are bounded by the task supervisor", ctx do
    hold_dispatches()
    token = token("wsd_global")

    sockets = for _socket <- 1..5, do: socket(ctx, token, 1..8)

    # Forty calls, thirty-two tasks: the rest are answered at once.
    assert sockets |> Enum.map(&busy/1) |> Enum.sum() == 8

    tasks = 32 |> dispatching() |> Enum.map(&elem(&1, 0))
    assert dispatched() == 32
    assert Enum.sort(tasks()) == Enum.sort(tasks)

    Enum.each(tasks, &release(&1, :no_response))
    await_no_tasks()
    Enum.each(sockets, &send(&1, :close))
  end

  test "the bound on all sockets holds after the sockets that filled it have gone", ctx do
    hold_dispatches()
    token = token("wsd_orphans")

    sockets = for _socket <- 1..4, do: socket(ctx, token, 1..8)
    assert sockets |> Enum.map(&busy/1) |> Enum.sum() == 0

    started = dispatching(32)
    tasks = Enum.map(started, &elem(&1, 0))
    bridges = started |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    assert length(bridges) == 4

    # Every bridge goes, and every task is still there.
    monitors = Enum.map(bridges, &{&1, Process.monitor(&1)})
    Enum.each(sockets, &send(&1, :close))

    for {bridge, ref} <- monitors do
      assert_receive {:DOWN, ^ref, :process, ^bridge, _reason}, @recv_timeout
    end

    assert Enum.sort(tasks()) == Enum.sort(tasks)

    # A socket that has started nothing is told the bridge is busy.
    late = socket(ctx, token, [1])
    assert busy(late) == 1
    assert dispatched() == 32

    # Until a task ends.
    release(hd(tasks), :no_response)
    eventually(fn -> length(tasks()) == 31 end)
    next = socket(ctx, token, [1])
    assert busy(next) == 0
    [{task, _bridge}] = dispatching(1)

    Enum.each([task | tl(tasks)], &release(&1, :no_response))
    await_no_tasks()
    Enum.each([late, next], &send(&1, :close))
  end

  test "a socket closed with calls pending leaves their tasks to finish, and nothing behind",
       ctx do
    hold_dispatches()
    {client, _token} = client(ctx, "wsd_closed")

    client =
      Enum.reduce(1..3, client, fn id, client ->
        send_text(client, frame(id, "post", "/backups/new/full"))
      end)

    started = dispatching(3)
    [{_task, bridge} | _rest] = started
    tasks = Enum.map(started, &elem(&1, 0))
    bridge_ref = Process.monitor(bridge)

    log =
      capture_log(fn ->
        Client.send_frame(client, {:close, 1000, ""})
        assert_receive {:DOWN, ^bridge_ref, :process, ^bridge, reason}, @recv_timeout
        assert reason in [:normal, :shutdown] or match?({:shutdown, _why}, reason)

        assert Enum.all?(tasks, &Process.alive?/1)
        assert Enum.sort(tasks()) == Enum.sort(tasks)

        Enum.each(tasks, &release(&1, ok_outcome(%{})))
        await_no_tasks()
      end)

    refute log =~ "[error]"
  end

  test "Upstream dying with calls pending closes the socket and leaves the tasks to finish",
       ctx do
    hold_dispatches()
    {client, token} = client(ctx, "wsd_upstream")

    client = send_text(client, frame(1, "get", "/supervisor/info"))
    assert_receive {:dispatching, task, bridge, _slug, _request}, @recv_timeout
    bridge_ref = Process.monitor(bridge)

    # The stop is a shutdown, so no report prints the bridge's state, where
    # the credential's hash is. The label shows the capture saw the bridge.
    log =
      capture_log(fn ->
        Process.exit(websock_state(bridge).upstream, :kill)

        assert {{:close, 1011, _reason}, _client} = Client.next_frame(client, @recv_timeout)
        assert_receive {:DOWN, ^bridge_ref, :process, ^bridge, _reason}, @recv_timeout
      end)

    assert log =~ "closed a connection (ws/upstream)"
    refute log =~ "credential"
    refute log =~ token

    assert Process.alive?(task)
    release(task, ok_outcome(%{}))
    await_no_tasks()
  end

  test "a result for a call this socket never made is dropped", ctx do
    hold_dispatches()
    {client, _token} = client(ctx, "wsd_forged")

    client = send_text(client, frame(1, "get", "/supervisor/info"))
    assert_receive {:dispatching, task, bridge, _slug, _request}, @recv_timeout

    send(bridge, {:supervisor_api, make_ref(), ~s({"forged":true})})
    send(bridge, {:supervisor_api_timeout, make_ref()})
    send(bridge, {:DOWN, make_ref(), :process, self(), :normal})
    send(bridge, {:relay, :text, "from-upstream"})

    {frame, client} = Client.next_frame(client, @recv_timeout)
    assert frame == {:text, "from-upstream"}

    send(task, {:release, ok_outcome(%{"real" => true})})
    {reply, _client} = reply(client)
    assert reply["result"] == %{"real" => true}
  end
end
