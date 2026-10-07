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
  lifetime, exactly like `events_test.exs`'s fake listener. A request is
  logged (and its response popped off the script) as soon as it's fully
  read — sending the response itself (honoring any scripted `delay:`)
  happens in a separate, unlinked, fire-and-forget process per connection,
  so a stalling response can't also delay `requests/1` from reflecting a
  request that has already arrived, nor block the loop from accepting the
  next connection.

  ## Streams

  A response may also be `{:stream, status, steps}`: chunked, written as the
  steps say and then ended. A step is `{:line, map}` (one JSON line),
  `{:chunk, binary}`, `{:wait, ms}`, `{:run, fun}` (called in the process
  that writes the response), `:abort` (close without ending the body) or
  `:stall`: send nothing more and wait for the client to close,
  then tell the `:notify` process given to `start/2`
  `{:fake_engine, :client_closed, path}`.

  ## A model instead of a script

  `start_model/1` starts an engine that keeps containers, images and an
  event ring and answers from them, for code whose calls no script can
  list in advance. See `Vagus.Test.FakeEngine.Model`.

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
  @spec start(
          [
            {pos_integer(), map() | binary() | nil}
            | {pos_integer(), map() | binary() | nil, keyword()}
            | {:stream, pos_integer(), [term()]}
          ],
          keyword()
        ) ::
          map()
  def start(responses, opts \\ []) when is_list(responses) do
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

    pid =
      spawn_link(fn ->
        loop(listen, %{responses: responses, log: [], notify: opts[:notify]})
      end)

    %{socket: path, listen: listen, pid: pid}
  end

  @doc "Starts `Vagus.Test.FakeEngine.Model`; the handle works with `requests/1` and `stop/1` too."
  @spec start_model(keyword()) :: map()
  def start_model(opts \\ []) do
    path = socket_path()
    _ = File.rm(path)
    {:ok, model} = __MODULE__.Model.start_link(Keyword.put(opts, :socket, path))
    %{socket: path, model: model}
  end

  @doc "Recorded requests, oldest first: `%{method:, path:, query:, body:}`."
  @spec requests(map()) :: [map()]
  def requests(%{model: model}), do: GenServer.call(model, :requests)

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
  def stop(%{model: model, socket: path}) do
    # Unlinked first: the caller may be the test this is linked to.
    Process.unlink(model)
    ref = Process.monitor(model)
    Process.exit(model, :kill)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    end

    File.rm(path)
    :ok
  end

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
    case read_request(sock) do
      {:ok, method, path, query, body} ->
        {resp, responses} = pop_response(state.responses)
        entry = %{method: method, path: path, query: query, body: body}

        # The response — including any scripted `delay:` — is sent from a
        # short-lived spawned process, not this accept loop, so a stalling
        # response can't also stall the request being recorded (`requests/1`
        # reflects it immediately) or the loop's ability to keep polling its
        # mailbox/accepting while that response is held open.
        notify = state.notify

        spawn(fn ->
          send_scripted(sock, resp, path, notify)
          :gen_tcp.close(sock)
        end)

        %{state | responses: responses, log: [entry | state.log]}

      {:error, _reason} ->
        :gen_tcp.close(sock)
        state
    end
  end

  defp pop_response([next | rest]), do: {next, rest}

  defp pop_response([]),
    do: {{500, %{"message" => "Vagus.Test.FakeEngine: response script exhausted"}}, []}

  defp send_scripted(sock, {:stream, status, steps}, path, notify),
    do: stream(sock, status, steps, path, notify)

  defp send_scripted(sock, {status, body}, _path, _notify), do: send_response(sock, status, body)

  defp send_scripted(sock, {status, body, opts}, _path, _notify) do
    case Keyword.get(opts, :delay) do
      nil -> :ok
      ms -> Process.sleep(ms)
    end

    send_response(sock, status, body)
  end

  ## Streams

  @doc false
  def stream(sock, status, steps, path, notify) do
    :gen_tcp.send(
      sock,
      "HTTP/1.1 #{status} #{reason_phrase(status)}\r\n" <>
        "Content-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
    )

    steps(sock, steps, path, notify)
  end

  defp steps(sock, [], _path, _notify), do: :gen_tcp.send(sock, "0\r\n\r\n")
  defp steps(_sock, [:abort | _rest], _path, _notify), do: :ok

  defp steps(sock, [:stall | _rest], path, notify) do
    # Nothing is expected from the client, so the read returns when it closes.
    _ = :gen_tcp.recv(sock, 0)
    if notify, do: send(notify, {:fake_engine, :client_closed, path})
    :ok
  end

  defp steps(sock, [step | rest], path, notify) do
    case step do
      {:line, map} -> chunk(sock, Jason.encode!(map) <> "\n")
      {:chunk, binary} -> chunk(sock, binary)
      {:wait, ms} -> Process.sleep(ms)
      {:run, fun} -> fun.()
    end

    steps(sock, rest, path, notify)
  end

  @doc false
  def chunk(sock, binary) do
    :gen_tcp.send(sock, Integer.to_string(byte_size(binary), 16) <> "\r\n" <> binary <> "\r\n")
  end

  ## Request parsing

  @doc false
  def read_request(sock) do
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

  @doc false
  def send_response(sock, status, body)

  def send_response(sock, status, nil), do: send_raw(sock, status, "text/plain", "")

  def send_response(sock, status, body) when is_binary(body),
    do: send_raw(sock, status, "text/plain", body)

  def send_response(sock, status, body) when is_map(body) or is_list(body),
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
  defp reason_phrase(409), do: "Conflict"
  defp reason_phrase(500), do: "Internal Server Error"
  defp reason_phrase(_status), do: "Unknown"

  defp socket_path do
    Path.join(System.tmp_dir!(), "vagus-core-engine-#{System.unique_integer([:positive])}.sock")
  end
end
