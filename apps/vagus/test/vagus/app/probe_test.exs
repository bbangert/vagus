defmodule Vagus.App.ProbeTest do
  # Real sockets on loopback: a Bandit server, a bare TLS listener, and ports
  # that refuse.
  use ExUnit.Case, async: true

  import Vagus.AppFixtures, only: [app_config: 2]

  alias Vagus.App.Probe

  defmodule Answers do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get("/", do: send_resp(conn, 200, "ok"))
    get("/redirect", do: conn |> put_resp_header("location", "/") |> send_resp(302, ""))
    get("/broken", do: send_resp(conn, 500, ""))

    get "/hang" do
      receive do
        :never -> send_resp(conn, 200, "")
      end
    end
  end

  setup do
    bandit = start_supervised!({Bandit, plug: Answers, port: 0, ip: :loopback})
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    %{port: port}
  end

  defp input(overrides \\ %{}, extra \\ %{}) do
    slug = "core_probe_#{System.unique_integer([:positive])}"
    Map.merge(%{config: app_config(slug, overrides), user_options: %{}, ip: "127.0.0.1"}, extra)
  end

  # A port nothing listens on: bound, then closed right before use.
  defp refused_port do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)
    port
  end

  describe "http" do
    test "a 200 is healthy", %{port: port} do
      assert :healthy = Probe.check("http://[HOST]:[PORT:#{port}]/", input())
    end

    test "a redirect is unhealthy", %{port: port} do
      assert :unhealthy = Probe.check("http://[HOST]:[PORT:#{port}]/redirect", input())
    end

    test "a server error is unhealthy", %{port: port} do
      assert :unhealthy = Probe.check("http://[HOST]:[PORT:#{port}]/broken", input())
    end

    test "a refused connection is unhealthy" do
      assert :unhealthy = Probe.check("http://[HOST]:[PORT:#{refused_port()}]/", input())
    end

    test "an answer that never comes is unhealthy at the bound, not a hang", %{port: port} do
      template = "http://[HOST]:[PORT:#{port}]/hang"
      task = Task.async(fn -> Probe.check(template, input(%{}, %{timeout_ms: 200})) end)
      assert {:ok, :unhealthy} = Task.yield(task, 2_000)
    end
  end

  test "https is probed without verifying the certificate" do
    rsa = [key: {:rsa, 2048, 65_537}]

    %{server_config: tls} =
      Map.new(
        :public_key.pkix_test_data(%{
          server_chain: %{root: rsa, peer: rsa},
          client_chain: %{root: rsa, peer: rsa}
        })
      )

    {:ok, listen} = :ssl.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}] ++ tls)
    {:ok, {_address, port}} = :ssl.sockname(listen)

    spawn_link(fn ->
      {:ok, socket} = :ssl.transport_accept(listen)
      {:ok, socket} = :ssl.handshake(socket)
      {:ok, _request} = :ssl.recv(socket, 0)
      :ok = :ssl.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")

      receive do
        :never -> :ok
      end
    end)

    assert :healthy = Probe.check("https://[HOST]:[PORT:#{port}]/", input())
  end

  describe "tcp" do
    test "a listening port is healthy", %{port: port} do
      assert :healthy = Probe.check("tcp://[HOST]:#{port}", input())
    end

    test "a refused port is unhealthy" do
      assert :unhealthy = Probe.check("tcp://[HOST]:#{refused_port()}", input())
    end
  end

  describe "what cannot be probed is :skip" do
    test "a template that does not parse" do
      assert :skip = Probe.check("not a template", input())
    end

    test "a bridged app with no address", %{port: port} do
      assert :skip = Probe.check("tcp://[HOST]:#{port}", input(%{}, %{ip: nil}))
    end
  end

  describe "a host-network app" do
    test "is dialled on loopback when its port listens there", %{port: port} do
      host_network = input(%{"host_network" => true}, %{ip: nil})
      assert :healthy = Probe.check("tcp://[HOST]:#{port}", host_network)
    end

    # The gateway is not on a test host: dialled there, the probe misses
    # rather than being skipped for want of an address.
    test "is dialled on the gateway when loopback refuses" do
      host_network = input(%{"host_network" => true}, %{ip: nil, timeout_ms: 200})
      task = Task.async(fn -> Probe.check("tcp://[HOST]:#{refused_port()}", host_network) end)
      assert {:ok, :unhealthy} = Task.yield(task, 2_000)
    end
  end
end
