defmodule Vagus.Test.FakeEngine do
  @moduledoc """
  A minimal unix-socket HTTP/1.1 daemon standing in for the Docker/
  balena-engine control socket — the same fake-daemon-over-a-unix-socket
  pattern `test/vagus/runtime/events_test.exs` uses inline, pulled into a
  reusable module for `Vagus.Core.Lifecycle` tests, which drive many more
  request shapes (inspect/create/start/stop/restart/remove/pull) in a
  fixed, test-known sequence per op.

  `start/1` takes an ordered list of canned responses — `{status, body}` (or
  `{status, body, delay: ms}` to hold the connection open before replying,
  for lock-contention tests that need an op to stay "in flight"), `body` a
  map (JSON-encoded), a binary (sent raw — used for `/images/create`'s
  non-JSON streamed status lines), or `nil` (empty body) — consumed strictly
  in request-arrival order. Since every `Vagus.Core.Lifecycle` op issues a
  deterministic sequence of Engine-API calls (there's no unscripted
  branching the fake daemon needs to react to — each op's *own* logic
  already decided what to call next based on the *previous* canned
  response), scripting "the Nth request gets the Nth response" is simpler
  and more robust than pattern-matching request paths/refs (which vary —
  `Vagus.Runtime.Docker.create_container/2` returns a daemon-assigned id
  that later `start`/`stop`/`remove` calls target, not the fixed
  container name). Every request is still recorded (`requests/1`) so tests
  can assert exactly what was sent and in what order.

  A request past the end of the script gets a `500` (never crashes the fake
  server or hangs the client) — a scripting bug in the test shows up as a
  clear HTTP error in the client's return value rather than a stuck test.

  No `Agent`/`GenServer` here: the accept loop is a single `spawn_link`ed
  recursive process that owns its own state (scripted responses + request
  log) directly, polling its mailbox between accepts — a supervised OTP
  process would outlive the one test that owns it for no benefit, and
  `stop/1` (called from each test's `on_exit`) is what actually bounds its
  lifetime, exactly like `events_test.exs`'s fake listener.

  ## Usage

      engine =
        FakeEngine.start([
          {200, %{"Config" => %{"Image" => "..."}, "State" => %{"Running" => false}}},
          {204, nil}
        ])

      Lifecycle.start(docker: [socket: engine.socket])

      assert [%{method: :get, path: "/containers/homeassistant/json"}, %{method: :post}] =
               FakeEngine.requests(engine)

      FakeEngine.stop(engine)
  """

  @doc "Starts the fake daemon; returns a handle for `requests/1`/`stop/1`."
  @spec start([
          {pos_integer(), map() | binary() | nil}
          | {pos_integer(), map() | binary() | nil, keyword()}
        ]) ::
          map()
  def start(responses) when is_list(responses) do
    path = socket_path()
    # A leftover socket file from a previous run collides (:eaddrinuse) —
    # same precaution `events_test.exs` takes.
    _ = File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        {:ifaddr, {:local, path}},
        active: false,
        packet: :raw,
        backlog: 128
      ])

    pid = spawn_link(fn -> loop(listen, %{responses: responses, log: []}) end)

    %{socket: path, listen: listen, pid: pid}
  end

  @doc "Recorded requests, oldest first: `%{method:, path:, query:, body:}`."
  @spec requests(map()) :: [map()]
  def requests(%{pid: pid}) do
    send(pid, {:get_requests, self()})

    receive do
      {:requests, list} -> list
    after
      2_000 -> raise "Vagus.Test.FakeEngine: requests/1 timed out waiting for the daemon process"
    end
  end

  @doc "Stops the fake daemon and removes its socket file."
  @spec stop(map()) :: :ok
  def stop(%{listen: listen, socket: path, pid: pid}) do
    :gen_tcp.close(listen)
    Process.exit(pid, :kill)
    File.rm(path)
    :ok
  end

  ## Main loop — polls the mailbox (for `requests/1` queries) between
  ## accepts, one connection at a time, exactly as the real Engine-API
  ## client makes them (`Vagus.Runtime.Docker`'s moduledoc: one short-lived
  ## Mint connection per request).

  defp loop(listen, state) do
    receive do
      {:get_requests, from} ->
        send(from, {:requests, Enum.reverse(state.log)})
        loop(listen, state)
    after
      0 -> accept_once(listen, state)
    end
  end

  defp accept_once(listen, state) do
    case :gen_tcp.accept(listen, 100) do
      {:ok, sock} -> loop(listen, serve(sock, state))
      {:error, :timeout} -> loop(listen, state)
      {:error, _reason} -> :ok
    end
  end

  defp serve(sock, state) do
    state =
      case read_request(sock) do
        {:ok, method, path, query, body} ->
          {resp, responses} = pop_response(state.responses)
          send_scripted(sock, resp)
          entry = %{method: method, path: path, query: query, body: body}
          %{state | responses: responses, log: [entry | state.log]}

        {:error, _reason} ->
          state
      end

    :gen_tcp.close(sock)
    state
  end

  defp pop_response([next | rest]), do: {next, rest}

  defp pop_response([]),
    do: {{500, %{"message" => "Vagus.Test.FakeEngine: response script exhausted"}}, []}

  defp send_scripted(sock, {status, body}), do: send_response(sock, status, body)

  defp send_scripted(sock, {status, body, opts}) do
    case Keyword.get(opts, :delay) do
      nil -> :ok
      ms -> Process.sleep(ms)
    end

    send_response(sock, status, body)
  end

  ## Request parsing

  defp read_request(sock) do
    case read_head(sock, "") do
      {:ok, head, leftover} ->
        [request_line | header_lines] = String.split(head, "\r\n")
        [method_str, target, _http_version] = String.split(request_line, " ", parts: 3)
        headers = parse_headers(header_lines)
        content_length = headers |> Map.get("content-length", "0") |> String.to_integer()

        case read_body(sock, leftover, content_length) do
          {:ok, raw_body} ->
            {path, query} = split_target(target)
            {:ok, method_atom(method_str), path, query, decode_body(raw_body, headers)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_head(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      [head, rest] = String.split(acc, "\r\n\r\n", parts: 2)
      {:ok, head, rest}
    else
      case :gen_tcp.recv(sock, 0, 5_000) do
        {:ok, data} -> read_head(sock, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp read_body(_sock, already, content_length) when byte_size(already) >= content_length do
    <<body::binary-size(^content_length), _rest::binary>> = already
    {:ok, body}
  end

  defp read_body(sock, already, content_length) do
    need = content_length - byte_size(already)

    case :gen_tcp.recv(sock, need, 5_000) do
      {:ok, data} -> {:ok, already <> data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_headers(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [k, v] -> Map.put(acc, k |> String.trim() |> String.downcase(), String.trim(v))
        _other -> acc
      end
    end)
  end

  defp split_target(target) do
    case String.split(target, "?", parts: 2) do
      [path] -> {path, %{}}
      [path, qs] -> {path, URI.decode_query(qs)}
    end
  end

  # Fixed whitelist, not `String.to_atom/1` — the method comes off the
  # socket, and only these verbs are ever legitimately sent by
  # `Vagus.Runtime.Docker`.
  defp method_atom("GET"), do: :get
  defp method_atom("POST"), do: :post
  defp method_atom("PUT"), do: :put
  defp method_atom("DELETE"), do: :delete
  defp method_atom("PATCH"), do: :patch
  defp method_atom("HEAD"), do: :head
  defp method_atom(other), do: raise("Vagus.Test.FakeEngine: unsupported HTTP method #{other}")

  defp decode_body("", _headers), do: nil

  defp decode_body(body, headers) do
    if json?(headers) do
      case Jason.decode(body) do
        {:ok, decoded} -> decoded
        {:error, _reason} -> body
      end
    else
      body
    end
  end

  defp json?(headers) do
    case Map.get(headers, "content-type") do
      nil -> false
      ct -> String.contains?(ct, "application/json")
    end
  end

  ## Response writing

  defp send_response(sock, status, nil), do: send_raw(sock, status, "text/plain", "")

  defp send_response(sock, status, body) when is_binary(body),
    do: send_raw(sock, status, "text/plain", body)

  defp send_response(sock, status, body) when is_map(body),
    do: send_raw(sock, status, "application/json", Jason.encode!(body))

  defp send_raw(sock, status, content_type, body) do
    head =
      "HTTP/1.1 #{status} #{reason_phrase(status)}\r\n" <>
        "Content-Type: #{content_type}\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Connection: close\r\n\r\n"

    :gen_tcp.send(sock, head <> body)
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(201), do: "Created"
  defp reason_phrase(204), do: "No Content"
  defp reason_phrase(304), do: "Not Modified"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(500), do: "Internal Server Error"
  defp reason_phrase(_status), do: "Unknown"

  defp socket_path do
    Path.join(System.tmp_dir!(), "vagus-core-engine-#{System.unique_integer([:positive])}.sock")
  end
end
