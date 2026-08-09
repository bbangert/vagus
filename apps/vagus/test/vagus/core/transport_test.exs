defmodule Vagus.Core.TransportTest do
  @moduledoc """
  A2 — the shared Supervisor↔Core transport. `async: false`: every test here
  moves `:core_socket_path`/`:core_base_url`, which are process-global
  application env.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vagus.Core.{Container, Transport}

  defmodule EchoPlug do
    @moduledoc "Reports back what actually arrived, so a test can prove which transport carried it."
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    match _ do
      body = %{
        "path" => conn.request_path,
        "query" => conn.query_string,
        "authorization" => Plug.Conn.get_req_header(conn, "authorization"),
        "method" => conn.method
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end
  end

  setup do
    prev_socket = Application.get_env(:vagus, :core_socket_path)
    prev_base = Application.get_env(:vagus, :core_base_url)

    on_exit(fn ->
      Application.put_env(:vagus, :core_socket_path, prev_socket)

      if is_nil(prev_base),
        do: Application.delete_env(:vagus, :core_base_url),
        else: Application.put_env(:vagus, :core_base_url, prev_base)
    end)

    :ok
  end

  defp socket_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "vagus_transport_#{System.unique_integer([:positive])}.sock"
      )

    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  # A real AF_UNIX socket with nothing listening on it: closing the listener
  # does NOT unlink the file, which is exactly the on-device situation (Core
  # never removes the socket it created). `File.lstat/1` reports `:other`.
  defp bind_socket!(path) do
    {:ok, listen} = :gen_tcp.listen(0, ifaddr: {:local, path})
    :gen_tcp.close(listen)
    path
  end

  describe "current/1" do
    test "no socket configured -> TCP" do
      Application.put_env(:vagus, :core_socket_path, nil)
      Application.put_env(:vagus, :core_base_url, "http://core.invalid:8123")

      assert Transport.current() == {:tcp, "http://core.invalid:8123"}
      assert Transport.socket() == nil
      refute Transport.implicit_auth?(Transport.current())
    end

    test "configured but absent socket -> TCP" do
      Application.put_env(:vagus, :core_socket_path, socket_path())
      Application.put_env(:vagus, :core_base_url, "http://core.invalid:8123")

      assert Transport.current() == {:tcp, "http://core.invalid:8123"}
    end

    test "an existing socket file wins over the TCP base URL" do
      path = bind_socket!(socket_path())
      Application.put_env(:vagus, :core_socket_path, path)
      Application.put_env(:vagus, :core_base_url, "http://core.invalid:8123")

      assert Transport.current() == {:socket, path}
      assert Transport.socket() == path
      assert Transport.implicit_auth?(Transport.current())
    end

    test "a socket that appears later is picked up without anything being invalidated" do
      path = socket_path()
      Application.put_env(:vagus, :core_socket_path, path)

      assert {:tcp, _base_url} = Transport.current()

      # Core starting is exactly this: the socket shows up under an already
      # running Vagus.
      bind_socket!(path)
      assert Transport.current() == {:socket, path}

      # ...and a Core container recreate takes it away again.
      File.rm!(path)
      assert {:tcp, _base_url} = Transport.current()
    end

    test "unset :core_socket_path means the on-device path" do
      Application.delete_env(:vagus, :core_socket_path)
      assert Transport.socket_path() == Container.socket_path()
    end

    test ":base_url and :socket options override the configured values" do
      path = bind_socket!(socket_path())
      Application.put_env(:vagus, :core_socket_path, nil)

      assert Transport.current(socket: path) == {:socket, path}
      assert Transport.current(base_url: "http://elsewhere:1") == {:tcp, "http://elsewhere:1"}
    end
  end

  describe "current/1 accepts only an actual unix socket (W1)" do
    setup do
      Application.put_env(:vagus, :core_base_url, "http://core.invalid:8123")
      :ok
    end

    test "a regular file planted at the socket path does not pin the transport" do
      path = socket_path()
      File.write!(path, "")
      Application.put_env(:vagus, :core_socket_path, path)

      # This is also the stale-Core case: `create_unix_server` raises on a
      # regular file, so a file here would otherwise wedge Vagus at a dead
      # endpoint with no fallback.
      assert Transport.current() == {:tcp, "http://core.invalid:8123"}
      assert Transport.socket() == nil
    end

    test "a symlink to a real socket elsewhere is refused — lstat never follows it" do
      target = bind_socket!(socket_path())
      link = socket_path()
      File.ln_s!(target, link)
      Application.put_env(:vagus, :core_socket_path, link)

      # Redirecting Supervisor→Core traffic (`Vagus.Auth` POSTs cleartext
      # credentials down it) is what following a symlink would buy an
      # attacker with write access to the socket directory.
      assert Transport.current() == {:tcp, "http://core.invalid:8123"}
    end

    test "a directory at the socket path is not a socket" do
      path = socket_path()
      File.mkdir_p!(path)
      Application.put_env(:vagus, :core_socket_path, path)

      assert Transport.current() == {:tcp, "http://core.invalid:8123"}
    end

    test "a real unix socket is accepted" do
      path = bind_socket!(socket_path())
      Application.put_env(:vagus, :core_socket_path, path)

      assert Transport.current() == {:socket, path}
    end
  end

  describe "the socket→TCP downgrade is logged (W5)" do
    setup do
      prev_interval = Application.get_env(:vagus, :core_transport_downgrade_log_ms)

      on_exit(fn ->
        if is_nil(prev_interval),
          do: Application.delete_env(:vagus, :core_transport_downgrade_log_ms),
          else: Application.put_env(:vagus, :core_transport_downgrade_log_ms, prev_interval)
      end)

      :ok
    end

    # One test, not four: the rate limiter is shared node-wide state, so the
    # window assertions only mean anything in a fixed order.
    test "warns on the socket→TCP edge, stays quiet on the upgrade and inside the window" do
      path = bind_socket!(socket_path())
      Application.put_env(:vagus, :core_socket_path, path)
      Application.put_env(:vagus, :core_base_url, "http://core.invalid:8123")
      Application.put_env(:vagus, :core_transport_downgrade_log_ms, 0)

      # Establish the socket as the current transport. Arriving AT the socket
      # is not a downgrade.
      assert capture_log(fn -> assert {:socket, ^path} = Transport.current() end) == ""

      File.rm!(path)
      log = capture_log(fn -> assert {:tcp, _base_url} = Transport.current() end)
      assert log =~ "no Supervisor↔Core socket"
      assert log =~ "bearer token in cleartext"

      # Steady state on TCP is silent — only the edge warns.
      assert capture_log(fn -> assert {:tcp, _base_url} = Transport.current() end) == ""

      # A flapping socket can't flood the ring buffer: the second downgrade
      # falls inside the (now 60s) window opened by the first.
      Application.put_env(:vagus, :core_transport_downgrade_log_ms, 60_000)
      bind_socket!(path)
      assert {:socket, ^path} = Transport.current()
      File.rm!(path)

      assert capture_log(fn -> assert {:tcp, _base_url} = Transport.current() end) == ""
    end
  end

  describe "build/6" do
    test "TCP prefixes the base URL" do
      request =
        Transport.build({:tcp, "http://core.invalid:8123"}, :internal, :get, "/api/states?x=1")

      assert request.host == "core.invalid"
      assert request.port == 8123
      assert request.path == "/api/states"
      assert request.query == "x=1"
      assert request.unix_socket == nil
    end

    test "socket keeps the path verbatim and dials the socket" do
      request =
        Transport.build({:socket, "/run/x.sock"}, :internal, :post, "/api/states?x=1", [], "body")

      assert request.unix_socket == "/run/x.sock"
      assert request.scheme == :http
      assert request.path == "/api/states"
      assert request.query == "x=1"
      assert request.body == "body"
    end

    test "an ordinary path builds the same request either way" do
      internal = Transport.build({:socket, "/run/x.sock"}, :internal, :get, "/api/states")
      proxied = Transport.build({:socket, "/run/x.sock"}, :proxied, :get, "/api/states")

      assert internal == proxied
    end
  end

  # `Vagus.API.Dispatcher` answers these with a 403 long before a request is
  # built, so reaching here at all means routing regressed — see
  # `Vagus.Core.Reserved`. The raise is the backstop, not the policy.
  describe "build/6 refuses Core's reserved namespace to a proxied caller" do
    test "the account-takeover path raises" do
      assert_raise Vagus.Core.Reserved.Error, ~r{/api/hassio_auth/password_reset}, fn ->
        Transport.build(
          {:socket, "/run/x.sock"},
          :proxied,
          :post,
          "/api/hassio_auth/password_reset"
        )
      end
    end

    test "an encoded spelling raises too — decoded once, like Core decodes it" do
      for path <- ["/api/%68assio_auth", "/api/hassio%2fapp", "/api/hassio_auth?x=1"] do
        assert_raise Vagus.Core.Reserved.Error, fn ->
          Transport.build({:socket, "/run/x.sock"}, :proxied, :get, path)
        end
      end
    end

    test "double-encoding does not sneak past — `%2568` stays `%68` on both sides" do
      request = Transport.build({:socket, "/run/x.sock"}, :proxied, :get, "/api/%2568assio_auth")

      assert request.path == "/api/%2568assio_auth"
    end

    test "the same paths are still ours to call internally" do
      request =
        Transport.build({:socket, "/run/x.sock"}, :internal, :post, "/api/hassio_auth")

      assert request.path == "/api/hassio_auth"
    end
  end

  describe "connect_args/1 + connect_opts/1 + ws_scheme/1" do
    test "socket is a Mint {:local, path} address on port 0, with a supplied hostname" do
      assert Transport.connect_args({:socket, "/run/x.sock"}) ==
               {:http, {:local, "/run/x.sock"}, 0}

      assert Transport.connect_opts({:socket, "/run/x.sock"}) == [hostname: "localhost"]
      assert Transport.ws_scheme({:socket, "/run/x.sock"}) == :ws
    end

    test "TCP splits the base URL" do
      assert Transport.connect_args({:tcp, "http://1.2.3.4:8123"}) == {:http, "1.2.3.4", 8123}
      assert Transport.connect_opts({:tcp, "http://1.2.3.4:8123"}) == []
      assert Transport.ws_scheme({:tcp, "http://1.2.3.4:8123"}) == :ws
    end

    test "https maps to wss" do
      assert {:https, "core", 443} = Transport.connect_args({:tcp, "https://core"})
      assert Transport.ws_scheme({:tcp, "https://core"}) == :wss
    end
  end

  describe "a real request over a real unix socket" do
    setup do
      path = socket_path()

      start_supervised!(
        {Bandit,
         plug: EchoPlug,
         port: 0,
         thousand_island_options: [num_acceptors: 1, transport_options: [ip: {:local, path}]]}
      )

      start_supervised!({Finch, name: __MODULE__.Finch})
      %{path: path}
    end

    test "reaches the listener and preserves path + query", %{path: path} do
      assert {:socket, ^path} = Transport.current(socket: path)

      response =
        {:socket, path}
        |> Transport.build(:internal, :get, "/api/states?filter=a%2Fb")
        |> Finch.request(__MODULE__.Finch)

      assert {:ok, %Finch.Response{status: 200, body: body}} = response
      decoded = Jason.decode!(body)
      assert decoded["path"] == "/api/states"
      assert decoded["query"] == "filter=a%2Fb"
      assert decoded["authorization"] == []
    end
  end
end
