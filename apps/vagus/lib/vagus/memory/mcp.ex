defmodule Vagus.Memory.MCP do
  @moduledoc """
  The memory tools as an MCP server over Streamable HTTP, at `/mcp`.
  Stateless request/response: each POST carries one JSON-RPC message, a
  request is answered with one JSON body, a notification or response with
  an empty 202. No session id and no SSE stream: nothing here ever
  initiates a message, so `GET` is 405 as the transport allows.

  `source_task` comes from the `X-Vagus-Task` header, else `?task=`, else
  the peer's address.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Vagus.Memory.MCP.Tools

  @body_cap 1_048_576
  @call_ms 15_000
  @latest "2025-11-25"
  @versions [@latest, "2025-06-18", "2025-03-26"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: ["mcp"]} = conn, opts) do
    cond do
      not local_peer?(conn.remote_ip) -> send_resp(conn, 403, "")
      not local_origin?(conn) -> send_resp(conn, 403, "")
      conn.method == "POST" -> post(conn, opts)
      true -> conn |> put_resp_header("allow", "POST") |> send_resp(405, "")
    end
  end

  def call(conn, _opts), do: send_resp(conn, 404, "")

  # The listener's addresses are reachable from more than agentnet: a
  # `hassio` app or a LAN host routing to the board can reach the gateway
  # address too, so the source is checked. A spoofed agentnet source gets
  # its handshake's reply on agentnet, never back to the spoofer.
  defp local_peer?({127, _, _, _}), do: true
  defp local_peer?({172, 30, 40, _}), do: true
  defp local_peer?(_ip), do: false

  # The transport requires it: a browser page that rebinds a name to a
  # local address carries its own origin.
  defp local_origin?(conn) do
    case get_req_header(conn, "origin") do
      [] -> true
      [origin | _] -> URI.parse(origin).host in ["localhost", "127.0.0.1", "172.30.40.1"]
    end
  end

  defp post(conn, opts) do
    case read_body(conn, length: @body_cap, read_timeout: @call_ms) do
      {:ok, body, conn} -> message(conn, JSON.decode(body), opts)
      {:more, _partial, conn} -> send_resp(conn, 413, "")
      {:error, _reason} -> send_resp(conn, 400, "")
    end
  end

  defp message(conn, {:ok, %{"jsonrpc" => "2.0", "method" => method} = msg}, opts)
       when is_binary(method) do
    case Map.fetch(msg, "id") do
      {:ok, id} when is_binary(id) or is_integer(id) ->
        reply(conn, id, request(method, Map.get(msg, "params", %{}), conn, opts))

      {:ok, _bad_id} ->
        reply(conn, nil, {:error, -32_600, "Invalid Request"})

      :error ->
        send_resp(conn, 202, "")
    end
  end

  # A response to a request this server never sends.
  defp message(conn, {:ok, %{"jsonrpc" => "2.0", "id" => _id} = msg}, _opts)
       when is_map_key(msg, "result") or is_map_key(msg, "error"),
       do: send_resp(conn, 202, "")

  defp message(conn, {:ok, _not_a_message}, _opts),
    do: reply(conn, nil, {:error, -32_600, "Invalid Request"})

  defp message(conn, {:error, _reason}, _opts),
    do: reply(conn, nil, {:error, -32_700, "Parse error"})

  defp request("initialize", params, _conn, _opts) do
    version =
      case params do
        %{"protocolVersion" => version} when version in @versions -> version
        _other -> @latest
      end

    {:ok,
     %{
       protocolVersion: version,
       capabilities: %{tools: %{}},
       serverInfo: %{name: "vagus-memory", version: server_version()}
     }}
  end

  defp request("ping", _params, _conn, _opts), do: {:ok, %{}}
  defp request("tools/list", _params, _conn, _opts), do: {:ok, %{tools: Tools.list()}}

  defp request("tools/call", %{"name" => name} = params, conn, opts) when is_binary(name) do
    arguments = Map.get(params, "arguments") || %{}

    if Tools.known?(name),
      do: {:ok, result(run(name, arguments, context(conn, opts), opts))},
      else: {:error, -32_602, "Unknown tool: #{name}"}
  end

  defp request("tools/call", _params, _conn, _opts), do: {:error, -32_602, "Invalid params"}
  defp request(_method, _params, _conn, _opts), do: {:error, -32_601, "Method not found"}

  # In a task so the budget covers a hung embedder as well as the database.
  defp run(name, arguments, context, opts) do
    task =
      Task.Supervisor.async_nolink(opts[:tasks], fn -> Tools.call(name, arguments, context) end)

    case Task.yield(task, @call_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} ->
        outcome

      {:exit, reason} ->
        Logger.error("Vagus.Memory.MCP: tool #{name} crashed: #{inspect(reason)}")
        {:error, :internal}

      nil ->
        {:error, :timeout}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp result({:ok, value}),
    do: %{content: [%{type: "text", text: JSON.encode!(value)}], isError: false}

  defp result({:error, reason}),
    do: %{content: [%{type: "text", text: JSON.encode!(%{error: reason(reason)})}], isError: true}

  defp reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason({:invalid_argument, name}), do: "invalid_argument: #{name}"
  defp reason({:db, code}), do: "db: #{code}"
  defp reason(reason), do: inspect(reason)

  defp context(conn, opts) do
    conn = fetch_query_params(conn)

    task =
      case get_req_header(conn, "x-vagus-task") do
        [task | _] when task != "" -> task
        _none -> non_empty(conn.query_params["task"])
      end

    %{
      store: opts[:store],
      task: task,
      source_task: task || "peer:" <> to_string(:inet.ntoa(conn.remote_ip))
    }
  end

  defp non_empty(value) when is_binary(value) and value != "", do: value
  defp non_empty(_value), do: nil

  defp reply(conn, id, outcome) do
    body =
      case outcome do
        {:ok, result} ->
          %{jsonrpc: "2.0", id: id, result: result}

        {:error, code, message} ->
          %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(body))
  end

  defp server_version, do: to_string(Application.spec(:vagus, :vsn) || "0.0.0")
end
