defmodule Vagus.Core.TransportTest do
  @moduledoc """
  A2 — the shared Supervisor↔Core transport. `async: false`: every test here
  moves `:core_socket_path`/`:core_base_url`, which are process-global
  application env.
  """
  use ExUnit.Case, async: false

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

    on_exit(fn -> File.rm(path) end)
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
      path = socket_path()
      File.write!(path, "")
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
      File.write!(path, "")
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
      path = socket_path()
      File.write!(path, "")
      Application.put_env(:vagus, :core_socket_path, nil)

      assert Transport.current(socket: path) == {:socket, path}
      assert Transport.current(base_url: "http://elsewhere:1") == {:tcp, "http://elsewhere:1"}
    end
  end

  describe "build/5" do
    test "TCP prefixes the base URL" do
      request = Transport.build({:tcp, "http://core.invalid:8123"}, :get, "/api/states?x=1")

      assert request.host == "core.invalid"
      assert request.port == 8123
      assert request.path == "/api/states"
      assert request.query == "x=1"
      assert request.unix_socket == nil
    end

    test "socket keeps the path verbatim and dials the socket" do
      request = Transport.build({:socket, "/run/x.sock"}, :post, "/api/states?x=1", [], "body")

      assert request.unix_socket == "/run/x.sock"
      assert request.scheme == :http
      assert request.path == "/api/states"
      assert request.query == "x=1"
      assert request.body == "body"
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
        |> Transport.build(:get, "/api/states?filter=a%2Fb")
        |> Finch.request(__MODULE__.Finch)

      assert {:ok, %Finch.Response{status: 200, body: body}} = response
      decoded = Jason.decode!(body)
      assert decoded["path"] == "/api/states"
      assert decoded["query"] == "filter=a%2Fb"
      assert decoded["authorization"] == []
    end
  end
end
