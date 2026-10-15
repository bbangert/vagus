defmodule Vagus.API.WSAbnormalCloseTest.Raw do
  @moduledoc """
  A WebSocket client over a bare socket: `Mint.WebSocket` will not send an
  unmasked frame, a reserved opcode, or a length it has no payload for.
  """

  @recv_timeout 30_000

  @spec connect(pos_integer(), String.t(), [{String.t(), String.t()}]) ::
          {:gen_tcp.socket(), status_line :: String.t(), rest :: binary()}
  def connect(port, path, headers \\ []) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    request = [
      "GET #{path} HTTP/1.1\r\nhost: localhost\r\nconnection: Upgrade\r\nupgrade: websocket\r\n",
      "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\nsec-websocket-version: 13\r\n",
      Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end),
      "\r\n"
    ]

    :ok = :gen_tcp.send(socket, request)
    {head, rest} = read_head(socket, "")
    {socket, head |> String.split("\r\n") |> hd(), rest}
  end

  defp read_head(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {head, rest}

      [_incomplete] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, @recv_timeout)
        read_head(socket, acc <> data)
    end
  end

  @doc """
  One client frame. The mask key is zero, so the payload crosses the wire
  byte for byte. `announce:` states a length other than the payload's;
  `mask: false` omits the key.
  """
  @spec frame(0 | 1, 0..15, binary(), keyword()) :: iodata()
  def frame(fin, opcode, payload, opts \\ []) do
    length = Keyword.get(opts, :announce, byte_size(payload))
    rsv = Keyword.get(opts, :rsv, 0)

    {mask_bit, key} = if Keyword.get(opts, :mask, true), do: {1, <<0::32>>}, else: {0, <<>>}

    length_field =
      cond do
        length <= 125 -> <<mask_bit::1, length::7>>
        length <= 65_535 -> <<mask_bit::1, 126::7, length::16>>
        true -> <<mask_bit::1, 127::7, length::64>>
      end

    [<<fin::1, rsv::3, opcode::4>>, length_field, key, payload]
  end

  @spec next_frame(:gen_tcp.socket(), binary()) :: {{opcode :: 0..15, binary()}, rest :: binary()}
  def next_frame(socket, buffer) do
    case parse(buffer) do
      {:ok, frame, rest} ->
        {frame, rest}

      :more ->
        {:ok, data} = :gen_tcp.recv(socket, 0, @recv_timeout)
        next_frame(socket, buffer <> data)
    end
  end

  @doc "The code of the server's close frame, or `:no_close_frame` if the socket ended first."
  @spec close_code(:gen_tcp.socket(), binary()) :: non_neg_integer() | :no_close_frame
  def close_code(socket, buffer) do
    case parse(buffer) do
      {:ok, {8, <<code::16, _reason::binary>>}, _rest} ->
        code

      {:ok, _other_frame, rest} ->
        close_code(socket, rest)

      :more ->
        case :gen_tcp.recv(socket, 0, @recv_timeout) do
          {:ok, data} -> close_code(socket, buffer <> data)
          {:error, _closed} -> :no_close_frame
        end
    end
  end

  defp parse(<<_::4, op::4, 0::1, 127::7, n::64, payload::binary-size(n), rest::binary>>),
    do: {:ok, {op, payload}, rest}

  defp parse(<<_::4, op::4, 0::1, 126::7, n::16, payload::binary-size(n), rest::binary>>),
    do: {:ok, {op, payload}, rest}

  defp parse(<<_::4, op::4, 0::1, n::7, payload::binary-size(n), rest::binary>>) when n < 126,
    do: {:ok, {op, payload}, rest}

  defp parse(_incomplete), do: :more
end

defmodule Vagus.API.WSAbnormalCloseTest.Echo do
  @moduledoc false
  @behaviour WebSock

  @impl WebSock
  def init(state), do: {:ok, state}

  @impl WebSock
  def handle_in({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}

  @impl WebSock
  def handle_info(_message, state), do: {:ok, state}
end

defmodule Vagus.API.WSAbnormalCloseTest.EchoApp do
  @moduledoc "An app's own WebSocket endpoint, behind the ingress proxy."
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    send(Application.fetch_env!(:vagus, :ws_abnormal_close_test_pid), :app_upgraded)
    WebSockAdapter.upgrade(conn, Vagus.API.WSAbnormalCloseTest.Echo, %{}, timeout: 900_000)
  end
end

defmodule Vagus.API.WSAbnormalCloseTest.Buggy do
  @moduledoc false
  @behaviour WebSock

  @impl WebSock
  def init(state), do: {:ok, state}

  @impl WebSock
  def handle_in(_frame, _state), do: raise("handler bug")

  @impl WebSock
  def handle_info(_message, state), do: {:ok, state}
end

defmodule Vagus.API.WSAbnormalCloseTest.BuggyEndpoint do
  @moduledoc "Upgrades to a handler that raises on any frame."
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts),
    do: WebSockAdapter.upgrade(conn, Vagus.API.WSAbnormalCloseTest.Buggy, %{}, timeout: 900_000)
end

defmodule Vagus.API.WSAbnormalCloseTest do
  @moduledoc """
  What reaches the log when a WebSocket on the listener `Vagus.API.Listener`
  configures ends abnormally: a frame Bandit refuses, or a bridge losing its
  upstream leg.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  import ExUnit.CaptureLog
  import Vagus.AppFixtures

  alias Vagus.Addon.Config
  alias Vagus.API.CoreProxyWSTest.Stack
  alias Vagus.API.{Dispatcher, Listener, SourceGuard}
  alias Vagus.API.WSAbnormalCloseTest.{BuggyEndpoint, EchoApp, Raw}
  alias Vagus.ConnectionLog

  @recv_timeout 30_000

  # With an escape sequence, as a caller aiming at a serial console would send.
  @marker "zz-marker\e[31m"
  # How `inspect/1` prints a binary that is not valid UTF-8.
  @marker_bytes @marker |> :binary.bin_to_list() |> Enum.join(", ")

  @core_limit 4_194_304
  @ingress_frame_limit 16_777_216
  # Bandit's default: the ingress upgrade sets `max_frame_size` alone.
  @ingress_message_limit 8_000_000

  @surfaces [:core_before_auth, :core_after_auth, :ingress]

  @violations [
    oversize_frame: {1009, "ws/oversize"},
    oversize_message: {1009, "ws/oversize"},
    invalid_utf8: {1007, "ws/protocol"},
    reserved_opcode: {1002, "ws/protocol"},
    unmasked_frame: {1002, "ws/protocol"},
    reserved_bits: {1002, "ws/protocol"},
    compressed_frame: {1002, "ws/protocol"},
    stray_continuation: {1002, "ws/protocol"},
    oversize_ping: {1002, "ws/protocol"},
    fragmented_ping: {1002, "ws/protocol"}
  ]

  @bridges [:core, :ingress]
  @upstream_losses [:unreachable, :killed, :wedged]

  setup do
    Stack.start()
    start_supervised!({Vagus.Ingress, []})

    Stack.put_env(:ws_abnormal_close_test_pid, self())
    app = start_supervised!({Bandit, plug: EchoApp, port: 0}, id: :echo_app)
    Stack.put_env(:ingress_target_fun, fn _slug -> {:ok, {"127.0.0.1", port(app), false}} end)

    ConnectionLog.attach()

    %{proxy: listener(Dispatcher)}
  end

  for surface <- @surfaces, {violation, {code, label}} <- @violations do
    test "#{surface}: #{violation} closes with #{code} and logs only a static label",
         %{proxy: proxy} do
      {code, log, own} = violate(proxy, unquote(surface), unquote(violation))

      assert code == unquote(code)
      refute_leak(log)
      assert_label_only(own, unquote(label))
    end
  end

  # As on a device, where `Vagus.API.SourceGuard` runs and the ring is small.
  for surface <- @surfaces, violation <- [:oversize_frame, :oversize_message, :invalid_utf8] do
    test "#{surface}: on device, #{violation} is counted and logs nothing", %{proxy: proxy} do
      on_device()
      {_code, label} = Keyword.fetch!(@violations, unquote(violation))

      {_code, log, own} = violate(proxy, unquote(surface), unquote(violation))

      refute_leak(log)
      assert_counted_only(own, label, "#{unquote(surface)}: #{unquote(violation)}")
    end
  end

  for bridge <- @bridges, loss <- @upstream_losses do
    test "#{bridge}: an upstream leg #{loss} closes with 1011 and logs only a static label",
         %{proxy: proxy} do
      {code, log, own} = lose_upstream(proxy, unquote(bridge), unquote(loss))

      assert code == 1011
      refute_leak(log)
      assert_label_only(own, "ws/upstream")
    end

    test "#{bridge}: on device, an upstream leg #{loss} is counted and logs nothing",
         %{proxy: proxy} do
      on_device()

      {code, log, own} = lose_upstream(proxy, unquote(bridge), unquote(loss))

      assert code == 1011
      refute_leak(log)
      assert_counted_only(own, "ws/upstream", "#{unquote(bridge)}: upstream #{unquote(loss)}")
    end
  end

  test "a handler that raises is still reported" do
    buggy = listener(BuggyEndpoint)

    {code, _log, own} =
      exchange(buggy, &upgraded(&1, "/"), fn socket, _connection ->
        :gen_tcp.send(socket, Raw.frame(1, 1, "anything"))
      end)

    assert code == 1011
    assert [report] = own
    assert report =~ "terminating"
    assert report =~ "handler bug"
  end

  defp on_device do
    Stack.put_env(:api_source_guard, true)
    Process.register(self(), SourceGuard)
  end

  # Whoever logged it.
  defp refute_leak(log) do
    refute log =~ "zz-marker"
    refute log =~ @marker_bytes
    refute log =~ "Last message"
    refute log =~ "websock_state"
    refute log =~ "credential"
  end

  # The one line is also the proof that the capture sees this process.
  defp assert_label_only(own, label) do
    assert [line] = own
    assert line =~ "closed a connection (#{label})"
    assert byte_size(line) < 200
  end

  defp assert_counted_only(own, label, name) do
    assert own == [], "#{name}: the connection process logged #{inspect(own)}"

    assert_received {:"$gen_cast", {:filtered, :ws, ^label}},
                    "#{name}: nothing was counted under #{label}"
  end

  defp violate(proxy, surface, violation) do
    exchange(proxy, connector(surface), fn socket, _connection ->
      :ok = :gen_tcp.send(socket, frames(violation, surface))
    end)
  end

  defp lose_upstream(proxy, :ingress, :unreachable) do
    Stack.put_env(:ingress_target_fun, fn _slug -> {:ok, {"127.0.0.1", unused_port(), false}} end)
    exchange(proxy, ingress_upgrade(), fn _socket, _connection -> :ok end)
  end

  defp lose_upstream(proxy, :core, :unreachable) do
    Stack.put_env(:core_base_url, "http://127.0.0.1:#{unused_port()}")
    token = core_token()

    exchange(proxy, connector(:core_before_auth), fn socket, _connection ->
      :ok = :gen_tcp.send(socket, auth_frame(token))
    end)
  end

  defp lose_upstream(proxy, bridge, :killed) do
    exchange(proxy, relaying(bridge), fn _socket, connection ->
      Process.exit(upstream(connection), :kill)
    end)
  end

  # A suspended upstream never answers the handoff, so the timeout is certain.
  defp lose_upstream(proxy, bridge, :wedged) do
    Stack.put_env(:core_ws_handoff_timeout, 50)
    Stack.put_env(:ingress_ws_handoff_timeout, 50)

    exchange(proxy, relaying(bridge), fn socket, connection ->
      :ok = :sys.suspend(upstream(connection))
      :ok = :gen_tcp.send(socket, Raw.frame(1, 1, ~s({"id":1,"type":"get_states"})))
    end)
  end

  defp relaying(:core), do: connector(:core_after_auth)
  defp relaying(:ingress), do: connector(:ingress)

  defp upstream(connection) do
    {_socket, %{connection: %{websock_state: %{upstream: upstream}}}} = :sys.get_state(connection)
    upstream
  end

  defp unused_port do
    {:ok, listening} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listening)
    :ok = :gen_tcp.close(listening)
    port
  end

  # Returns the close code, everything logged meanwhile, and what the
  # connection process itself logged. That process is gone by then, so both
  # are complete.
  defp exchange(server, connect, act) do
    {{code, connection}, log} =
      with_log([metadata: [:pid]], fn ->
        {socket, buffer} = connect.(port(server))

        try do
          connection = ConnectionLog.pid(socket)
          monitor = Process.monitor(connection)
          act.(socket, connection)
          code = Raw.close_code(socket, buffer)
          # A normal stop waits for the client's side of the close.
          :gen_tcp.close(socket)
          assert_receive {:DOWN, ^monitor, :process, ^connection, _reason}, @recv_timeout
          {code, connection}
        after
          :gen_tcp.close(socket)
        end
      end)

    {code, log, ConnectionLog.entries(log, connection)}
  end

  defp connector(:core_before_auth) do
    fn port ->
      {socket, buffer} = upgraded(port, "/core/websocket")
      {{1, auth_required}, buffer} = Raw.next_frame(socket, buffer)
      assert Jason.decode!(auth_required)["type"] == "auth_required"
      {socket, buffer}
    end
  end

  defp connector(:core_after_auth) do
    token = core_token()
    before_auth = connector(:core_before_auth)

    fn port ->
      {socket, buffer} = before_auth.(port)
      :ok = :gen_tcp.send(socket, auth_frame(token))
      {{1, auth_ok}, buffer} = Raw.next_frame(socket, buffer)
      assert Jason.decode!(auth_ok)["type"] == "auth_ok"
      assert_receive {:core_init, _core}, @recv_timeout
      {socket, buffer}
    end
  end

  defp connector(:ingress) do
    upgrade = ingress_upgrade()

    fn port ->
      upgraded = upgrade.(port)
      assert_receive :app_upgraded, @recv_timeout
      upgraded
    end
  end

  defp ingress_upgrade do
    slug = "ws_abnormal_close_#{System.unique_integer([:positive])}"

    {:ok, config} =
      Config.parse(%{
        "name" => "WS abnormal close test app",
        "version" => "1.0.0",
        "slug" => slug,
        "description" => "an ingress app",
        "arch" => ["amd64"],
        "ingress" => true,
        "ingress_port" => 8099
      })

    install_app(config, state: :started)
    {:ok, entry} = app_info(slug)
    {:ok, session} = Vagus.Ingress.create_session()

    &upgraded(&1, "/ingress/#{entry.ingress_token}/ws", [{"cookie", "ingress_session=#{session}"}])
  end

  defp core_token do
    register_app_token(app_config("ws_abnormal_close_core"), identity: %{homeassistant_api: true})
  end

  defp auth_frame(token), do: Raw.frame(1, 1, Jason.encode!(%{"access_token" => token}))

  defp upgraded(port, path, headers \\ []) do
    {socket, status, buffer} = Raw.connect(port, path, headers)
    assert status =~ "101"
    {socket, buffer}
  end

  # Every sequence ends on the frame that is refused, so the server has read
  # all of it and its close frame is not lost to a reset.
  defp frames(:oversize_frame, surface),
    do: Raw.frame(1, 1, @marker, announce: frame_limit(surface))

  defp frames(:oversize_message, surface) do
    [
      Raw.frame(0, 1, filler(message_limit(surface) - 1_000)),
      Raw.frame(1, 0, filler(2_000))
    ]
  end

  defp frames(:invalid_utf8, _surface), do: Raw.frame(1, 1, <<@marker::binary, 0xFF>>)
  defp frames(:reserved_opcode, _surface), do: Raw.frame(1, 3, @marker)
  defp frames(:unmasked_frame, _surface), do: Raw.frame(1, 1, "", announce: 100, mask: false)
  defp frames(:reserved_bits, _surface), do: Raw.frame(1, 1, @marker, rsv: 2)
  # Compression is never negotiated on this listener.
  defp frames(:compressed_frame, _surface), do: Raw.frame(1, 1, @marker, rsv: 4)
  defp frames(:stray_continuation, _surface), do: Raw.frame(1, 0, @marker)

  defp frames(:oversize_ping, _surface), do: Raw.frame(1, 9, filler(126))
  defp frames(:fragmented_ping, _surface), do: Raw.frame(0, 9, @marker)

  defp filler(size), do: String.duplicate(@marker, div(size, byte_size(@marker)) + 1)

  defp frame_limit(:ingress), do: @ingress_frame_limit
  defp frame_limit(_core), do: @core_limit

  defp message_limit(:ingress), do: @ingress_message_limit
  defp message_limit(_core), do: @core_limit

  defp listener(plug) do
    name = :"ws_abnormal_close_listener_#{System.unique_integer([:positive])}"
    start_supervised!({Bandit, Listener.bandit_options(plug: plug, port: 0, listener_name: name)})
  end

  defp port(server) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    port
  end
end
