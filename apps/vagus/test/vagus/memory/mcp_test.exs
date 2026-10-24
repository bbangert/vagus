defmodule Vagus.Memory.MCPTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Vagus.Memory.MCP

  # Answers the store's readiness call the way a store whose DB is down does.
  defmodule DownStore do
    use GenServer
    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)
    @impl true
    def init(nil), do: {:ok, nil}
    @impl true
    def handle_call(:context, _from, state), do: {:reply, {:error, :db_unavailable}, state}
  end

  setup context do
    tasks = Module.concat(__MODULE__, "Tasks#{context.line}")
    store = Module.concat(__MODULE__, "Store#{context.line}")
    start_supervised!({Task.Supervisor, name: tasks})
    start_supervised!({DownStore, store})
    %{opts: MCP.init(store: store, tasks: tasks)}
  end

  defp post(body, opts, fun \\ & &1) do
    :post
    |> conn("/mcp", body)
    |> put_req_header("content-type", "application/json")
    |> fun.()
    |> MCP.call(opts)
  end

  defp rpc(method, params, opts, id \\ 1) do
    conn = post(JSON.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params}), opts)
    assert conn.status == 200
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    JSON.decode!(conn.resp_body)
  end

  test "initialize echoes a supported version and answers the latest otherwise", %{opts: opts} do
    for version <- ["2025-11-25", "2025-06-18", "2025-03-26"] do
      assert %{"id" => 1, "result" => %{"protocolVersion" => ^version} = result} =
               rpc("initialize", %{protocolVersion: version}, opts)

      assert result["capabilities"] == %{"tools" => %{}}
      assert result["serverInfo"]["name"] == "vagus-memory"
    end

    assert %{"result" => %{"protocolVersion" => "2025-11-25"}} =
             rpc("initialize", %{protocolVersion: "2024-11-05"}, opts)
  end

  test "ping answers an empty result, keeping a string id", %{opts: opts} do
    assert rpc("ping", %{}, opts, "abc") == %{"jsonrpc" => "2.0", "id" => "abc", "result" => %{}}
  end

  test "server/discover and unknown methods are method-not-found", %{opts: opts} do
    for method <- ["server/discover", "resources/list", "nope"] do
      assert %{"error" => %{"code" => -32_601}} = rpc(method, %{}, opts)
    end
  end

  test "notifications and responses are accepted with an empty 202", %{opts: opts} do
    for body <- [
          %{jsonrpc: "2.0", method: "notifications/initialized"},
          %{jsonrpc: "2.0", id: 9, result: %{}}
        ] do
      conn = post(JSON.encode!(body), opts)
      assert conn.status == 202
      assert conn.resp_body == ""
    end
  end

  test "tools/list names the six tools, each with an object schema", %{opts: opts} do
    assert %{"result" => %{"tools" => tools}} = rpc("tools/list", %{}, opts)

    assert Enum.map(tools, & &1["name"]) ==
             ~w(remember recall journal device_note capture_register forget)

    for tool <- tools,
        do: assert(%{"type" => "object", "required" => [_ | _]} = tool["inputSchema"])
  end

  test "a tool's failure is a tool result with isError", %{opts: opts} do
    assert %{"result" => %{"isError" => true, "content" => [%{"type" => "text", "text" => text}]}} =
             rpc("tools/call", %{name: "recall", arguments: %{query: "kettle"}}, opts)

    assert JSON.decode!(text) == %{"error" => "db_unavailable"}

    assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
             rpc("tools/call", %{name: "remember", arguments: %{kind: 1, text: "x"}}, opts)

    assert JSON.decode!(text) == %{"error" => "invalid_argument: kind"}
  end

  test "a call over the task limit is answered busy without starting a task" do
    tasks = Module.concat(__MODULE__, "FullTasks")
    start_supervised!({Task.Supervisor, name: tasks, max_children: 1}, id: tasks)
    {:ok, _blocker} = Task.Supervisor.start_child(tasks, fn -> receive do: (:never -> :ok) end)
    opts = MCP.init(store: Module.concat(__MODULE__, "NoStore"), tasks: tasks)

    body =
      JSON.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "recall", arguments: %{query: "kettle"}}
      })

    conn = post(body, opts)
    assert conn.status == 503

    assert %{"id" => 1, "error" => %{"code" => -32_000, "message" => "busy"}} =
             JSON.decode!(conn.resp_body)

    assert length(Task.Supervisor.children(tasks)) == 1
  end

  test "an unknown tool is invalid params", %{opts: opts} do
    assert %{"error" => %{"code" => -32_602}} =
             rpc("tools/call", %{name: "drop_tables", arguments: %{}}, opts)
  end

  test "malformed JSON and non-messages are protocol errors", %{opts: opts} do
    assert %{"error" => %{"code" => -32_700}, "id" => nil} =
             JSON.decode!(post("{not json", opts).resp_body)

    assert %{"error" => %{"code" => -32_600}} = JSON.decode!(post("[1, 2]", opts).resp_body)

    assert %{"error" => %{"code" => -32_600}} =
             JSON.decode!(post(~s({"jsonrpc":"2.0","id":[1],"method":"ping"}), opts).resp_body)
  end

  test "a body over 1 MiB is refused", %{opts: opts} do
    assert post(String.duplicate("a", 1_048_577), opts).status == 413
  end

  test "GET is 405 and other paths 404", %{opts: opts} do
    conn = MCP.call(conn(:get, "/mcp"), opts)
    assert conn.status == 405
    assert get_resp_header(conn, "allow") == ["POST"]
    assert MCP.call(conn(:post, "/other", "{}"), opts).status == 404
  end

  test "a peer off loopback and agentnet, or a foreign origin, is refused", %{opts: opts} do
    ping = JSON.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"})

    assert post(ping, opts, &%{&1 | remote_ip: {172, 30, 32, 5}}).status == 403
    assert post(ping, opts, &%{&1 | remote_ip: {172, 30, 40, 130}}).status == 200
    assert post(ping, opts, &put_req_header(&1, "origin", "http://evil.example")).status == 403
    assert post(ping, opts, &put_req_header(&1, "origin", "http://localhost:3000")).status == 200
  end
end
