defmodule Vagus.Network.AgentnetTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.Network.Agentnet
  alias Vagus.Runtime.Engine.Fake
  alias Vagus.Runtime.Engine.NetworkSpec

  setup do
    test = self()

    ip = fn answer ->
      fn bin, args ->
        send(test, {:ip, bin, args})
        answer.(args)
      end
    end

    %{fake: Fake.start(), ip: ip}
  end

  defp ip_calls do
    receive do
      {:ip, "ip", args} -> [args | ip_calls()]
    after
      0 -> []
    end
  end

  test "an internal /24 with the host on .1 and the DB on .2" do
    assert Agentnet.spec() == %NetworkSpec{
             name: "agentnet",
             driver: :bridge,
             subnet: "172.30.40.0/24",
             gateway: "172.30.40.1",
             ip_range: nil,
             interface_name: "agentnet",
             internal: true
           }

    assert Agentnet.name() == "agentnet"
    assert Agentnet.gateway() == "172.30.40.1"
    assert Agentnet.memory_ip() == "172.30.40.2"
  end

  test "off the agent flavor it does nothing", %{fake: fake, ip: ip} do
    refute Agentnet.enabled?()

    assert Agentnet.ensure(engine: Fake, fake: fake, host_bridge: true, ip_cmd: ip.(&ok/1)) ==
             :ok

    assert Fake.calls(fake) == []
    assert ip_calls() == []
  end

  test "makes the network, then keeps the bridge with the gateway on it",
       %{fake: fake, ip: ip} do
    opts = [agentnet: true, engine: Fake, fake: fake, host_bridge: true, ip_cmd: ip.(&ok/1)]

    assert Agentnet.ensure(opts) == :ok
    assert Fake.calls(fake) == [{:ensure_network, [Agentnet.spec()]}]

    assert ip_calls() == [
             ["link", "add", "agentnet", "type", "bridge"],
             ["link", "add", "agentnet-anchor", "type", "dummy"],
             ["link", "set", "agentnet-anchor", "master", "agentnet", "up"],
             ["addr", "add", "172.30.40.1/24", "dev", "agentnet"],
             ["link", "set", "agentnet", "up"]
           ]
  end

  test "no bridge command off a board", %{fake: fake, ip: ip} do
    opts = [agentnet: true, engine: Fake, fake: fake, host_bridge: false, ip_cmd: ip.(&ok/1)]
    assert Agentnet.ensure(opts) == :ok
    assert ip_calls() == []
  end

  test "what exists counts as done; a bridge it cannot keep is logged, not returned",
       %{fake: fake, ip: ip} do
    exists = fn _args -> {"ip: RTNETLINK answers: File exists\n", 2} end
    opts = [agentnet: true, engine: Fake, fake: fake, host_bridge: true]

    assert Agentnet.ensure([{:ip_cmd, ip.(exists)} | opts]) == :ok
    assert length(ip_calls()) == 5

    fails = fn _args -> {"ip: RTNETLINK answers: Operation not supported\n", 2} end

    log =
      capture_log(fn -> assert Agentnet.ensure([{:ip_cmd, ip.(fails)} | opts]) == :ok end)

    assert log =~ "the agentnet bridge is not kept"
    assert length(ip_calls()) == 1
  end

  test "an engine failure is returned, and the bridge is still kept", %{fake: fake, ip: ip} do
    Fake.fail_next(fake, :ensure_network, :unavailable)
    opts = [agentnet: true, engine: Fake, fake: fake, host_bridge: true, ip_cmd: ip.(&ok/1)]

    assert Agentnet.ensure(opts) == {:error, :unavailable}
    assert length(ip_calls()) == 5
  end

  defp ok(_args), do: {"", 0}
end
