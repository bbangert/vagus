defmodule Vagus.API.ListenerLogTest.Raising do
  @moduledoc "A handler with a bug."
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(_conn, _opts), do: raise("handler bug")
end

defmodule Vagus.API.ListenerLogTest do
  @moduledoc """
  What a request Bandit rejects before any plug runs leaves in the log, on
  the listener `Vagus.API.Listener` configures.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vagus.API.{Dispatcher, Listener, Token}
  alias Vagus.API.ListenerLogTest.Raising
  alias Vagus.ConnectionLog

  @recv_timeout 30_000

  @marker "zz-marker\e[31m"
  @long String.duplicate(@marker, 2_000)

  @rejected [
    garbage_request_line: {"#{@marker} #{@marker}\r\n\r\n", "HTTP/1.0 400"},
    header_without_colon: {"GET /info HTTP/1.1\r\nhost: x\r\n#{@marker}\r\n\r\n", "HTTP/1.0 400"},
    oversize_request_line: {"GET /#{@long} HTTP/1.1\r\nhost: x\r\n\r\n", "HTTP/1.0 414"},
    oversize_header: {"GET /info HTTP/1.1\r\nhost: x\r\nx-big: #{@long}\r\n\r\n", "HTTP/1.0 431"},
    # Bandit rejects control bytes in a field value (400) before it counts
    # headers, so the repeated header carries a marker without the escape.
    too_many_headers:
      {"GET /info HTTP/1.1\r\nhost: x\r\n#{String.duplicate("x-h: zz-marker\r\n", 200)}\r\n",
       "HTTP/1.0 431"},
    unknown_http_version: {"GET /#{@marker} HTTP/9.9\r\nhost: x\r\n\r\n", "HTTP/1.0 400"},
    no_host_header: {"GET /#{@marker} HTTP/1.1\r\n\r\n", "HTTP/1.0 400"},
    bad_content_length:
      {"POST /info HTTP/1.1\r\nhost: x\r\ncontent-length: #{@marker}\r\n\r\n", "HTTP/1.0 400"},
    bad_chunk_size:
      {"POST /supervisor/options HTTP/1.1\r\nhost: x\r\ncontent-type: application/json\r\n" <>
         "transfer-encoding: chunked\r\n\r\nZZ#{@marker}\r\n", "HTTP/1.1 400"}
  ]

  @http2_preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  setup do
    ConnectionLog.attach()
  end

  for {name, {request, status}} <- @rejected do
    test "#{name} is answered #{status} and logs nothing" do
      {response, log, own} = request(listener(Dispatcher), unquote(request))

      assert String.starts_with?(response, unquote(status))
      refute log =~ "zz-marker"
      assert own == []
    end
  end

  # Nothing that calls this API speaks cleartext HTTP/2, and Bandit logs
  # every frame of a type it does not know, payload included.
  test "the HTTP/2 preface is refused, and frames sent after it are not logged" do
    unknown_frame = <<byte_size(@marker)::24, 0xEE, 0, 0::32, @marker::binary>>
    settings = <<0::24, 4, 0, 0::32>>

    {response, log, own} =
      request(listener(Dispatcher), [@http2_preface, settings, unknown_frame, unknown_frame])

    assert response == ""
    refute log =~ "zz-marker"
    assert own == []
  end

  test "an ordinary request is still answered" do
    request =
      "GET /supervisor/ping HTTP/1.1\r\nhost: x\r\nauthorization: Bearer #{Token.get()}\r\n" <>
        "connection: close\r\n\r\n"

    {response, _log, own} = request(listener(Dispatcher), request)

    assert String.starts_with?(response, "HTTP/1.1 200")
    assert own == []
  end

  # Also the proof that the capture sees a connection process's lines.
  test "a plug that raises is still reported, with its stacktrace" do
    request = "GET / HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n"

    {response, _log, own} = request(listener(Raising), request)

    assert String.starts_with?(response, "HTTP/1.1 500")
    assert [report] = own
    assert report =~ "(RuntimeError) handler bug"
    assert report =~ "Raising.call/2"
  end

  # Returns once the connection process is gone, so `own`, what it logged,
  # is complete.
  defp request(server, request) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    {{response, connection}, log} =
      with_log([metadata: [:pid]], fn ->
        {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

        try do
          connection = ConnectionLog.pid(socket)
          monitor = Process.monitor(connection)
          send_all(socket, List.wrap(request))
          # An HTTP/2 connection would otherwise stay open.
          _ = :gen_tcp.shutdown(socket, :write)
          response = read_to_close(socket, "")
          assert_receive {:DOWN, ^monitor, :process, ^connection, _reason}, @recv_timeout
          {response, connection}
        after
          :gen_tcp.close(socket)
        end
      end)

    {response, log, ConnectionLog.entries(log, connection)}
  end

  # The first packet must go out; the server may close the connection as
  # soon as it has judged it, so the rest may meet a closed socket.
  defp send_all(socket, [first | rest]) do
    :ok = :gen_tcp.send(socket, first)

    Enum.reduce_while(rest, :ok, fn packet, :ok ->
      case :gen_tcp.send(socket, packet) do
        :ok -> {:cont, :ok}
        {:error, reason} when reason in [:enotconn, :closed, :epipe, :econnreset] -> {:halt, :ok}
      end
    end)
  end

  defp read_to_close(socket, acc) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, data} -> read_to_close(socket, acc <> data)
      {:error, _closed} -> acc
    end
  end

  defp listener(plug) do
    name = :"listener_log_#{System.unique_integer([:positive])}"
    start_supervised!({Bandit, Listener.bandit_options(plug: plug, port: 0, listener_name: name)})
  end
end
