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
             ip_range: "172.30.40.128-172.30.40.254",
             interface_name: "agentnet",
             internal: true
           }

    assert Agentnet.name() == "agentnet"
    assert Agentnet.gateway() == "172.30.40.1"
    assert Agentnet.memory_ip() == "172.30.40.2"
  end

  test "off the agent flavor it does nothing", %{fake: fake, ip: ip} do
    refute Agentnet.enabled?(agentnet: false)
    opts = [agentnet: false, engine: Fake, fake: fake, host_bridge: true, ip_cmd: ip.(&ok/1)]
    assert Agentnet.ensure(opts) == :ok

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

  describe "on podman" do
    alias Vagus.Test.FakePodman

    defp podman(rules) do
      fake = FakePodman.start(rules)
      host = FakePodman.start_host(fake.bin)

      {fake,
       [agentnet: true, engine: Vagus.Runtime.Engine.Podman, host: host, podman_bin: fake.bin]}
    end

    defp verbs(fake), do: Enum.map(FakePodman.verbs(fake), &Enum.take(&1, 2))

    # `podman network inspect`'s shape (test/fixtures/podman/network_inspect_hassio.json).
    defp inspect_out(overrides \\ %{}) do
      subnet =
        Map.merge(
          %{
            "subnet" => "172.30.40.0/24",
            "gateway" => "172.30.40.1",
            "lease_range" => %{"start_ip" => "172.30.40.128", "end_ip" => "172.30.40.254"}
          },
          Map.get(overrides, :subnet, %{})
        )

      network = %{
        "name" => "agentnet",
        "internal" => Map.get(overrides, :internal, true),
        "subnets" => [subnet]
      }

      Jason.encode!([network]) <> "\n"
    end

    test "an existing internal network is kept" do
      {fake, opts} =
        podman([
          {"network exists *", [{0, ""}]},
          {"network inspect *", [{0, inspect_out()}]}
        ])

      assert Agentnet.ensure(opts) == :ok
      assert ["network", "inspect", "--", "agentnet"] in FakePodman.verbs(fake)

      refute ["network", "create"] in verbs(fake)
    end

    test "a leftover not internal, or on another subnet or lease range, is remade" do
      for leftover <- [
            %{internal: false},
            %{subnet: %{"subnet" => "172.30.40.0/23"}},
            %{
              subnet: %{
                "lease_range" => %{"start_ip" => "172.30.40.1", "end_ip" => "172.30.40.254"}
              }
            },
            %{subnet: %{"lease_range" => nil}}
          ] do
        {fake, opts} =
          podman([
            {"network exists *", [{0, ""}]},
            {"network inspect *", [{0, inspect_out(leftover)}]},
            {"network rm *", [{0, "agentnet\n"}]},
            {"network create *", [{0, "agentnet\n"}]}
          ])

        assert Agentnet.ensure(opts) == :ok, inspect(leftover)
        assert ["network", "rm", "--", "agentnet"] in FakePodman.verbs(fake)
        create = Enum.find(FakePodman.verbs(fake), &match?(["network", "create" | _], &1))
        assert ["--internal", "--ip-range", "172.30.40.128-172.30.40.254"] -- create == []
      end
    end

    test "one that cannot be remade, a container still on it, is an error" do
      {fake, opts} =
        podman([
          {"network exists *", [{0, ""}]},
          {"network inspect *", [{0, inspect_out(%{internal: false})}]},
          {"network rm *", [{2, "Error: network agentnet is being used\n"}]}
        ])

      log =
        capture_log(fn ->
          assert Agentnet.ensure(opts) == {:error, {:failed, :ensure_network, :mismatch}}
        end)

      assert log =~ "not as specified"
      refute ["network", "create"] in verbs(fake)
    end

    test "two ensures at once make it once" do
      {fake, opts} =
        podman([
          {"network exists *", [{1, ""}, {0, ""}]},
          {"network create *", [{0, "agentnet\n", hold: true}]},
          {"network inspect *", [{0, inspect_out()}]}
        ])

      first = Task.async(fn -> Agentnet.ensure(opts) end)
      wait_until(fn -> ["network", "create"] in verbs(fake) end)
      second = Task.async(fn -> Agentnet.ensure(opts) end)

      # The second waits on the lock, never reaching podman while the
      # create is in flight.
      Process.sleep(200)
      assert length(FakePodman.verbs(fake) |> Enum.filter(&match?(["network" | _], &1))) == 2

      FakePodman.release(fake)
      assert Task.await(first) == :ok
      assert Task.await(second) == :ok
      assert Enum.count(verbs(fake), &(&1 == ["network", "create"])) == 1
    end

    defp wait_until(fun, tries \\ 100) do
      cond do
        fun.() -> :ok
        tries == 0 -> flunk("condition never held")
        true -> Process.sleep(20) && wait_until(fun, tries - 1)
      end
    end
  end

  defp ok(_args), do: {"", 0}
end
