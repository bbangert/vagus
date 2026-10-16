defmodule Vagus.App.GatesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.App.Gates
  alias Vagus.Runtime.Engine.Fake

  setup do
    dir = Path.join(System.tmp_dir!(), "vagus-gates-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    test = self()

    record = fn bin, args ->
      send(test, {:ran, bin, args})
      {"", 0}
    end

    fake = Fake.start()
    key = {__MODULE__, :nat_loaded, make_ref()}
    on_exit(fn -> :persistent_term.erase(key) end)

    opts = [
      engine: Fake,
      fake: fake,
      host_bridge: true,
      ip_cmd: record,
      cmd: record,
      enabled: true,
      nft_dir: dir,
      loaded_key: key,
      ip: "172.30.32.2",
      port: 8888
    ]

    %{fake: fake, opts: opts}
  end

  defp ran do
    receive do
      {:ran, bin, args} -> [{bin, args} | ran()]
    after
      0 -> []
    end
  end

  defp steps(ran) do
    Enum.map(ran, fn
      {"ip", ["addr", "add", "172.30.32.2/23" | _]} -> :anchor_supervisor
      {"ip", ["addr", "add", "172.30.32.3/23" | _]} -> :anchor_dns
      {"ip", _bridge} -> :bridge
      {"nft", ["-f", _]} -> :nat
    end)
    |> Enum.dedup()
  end

  test "the bridge, then the anchors, then the nft table", %{opts: opts} do
    assert Gates.network(opts) == :ok
    assert steps(ran()) == [:bridge, :anchor_supervisor, :anchor_dns, :nat]
  end

  test "the anchors and the NAT go on when the network create fails",
       %{fake: fake, opts: opts} do
    Fake.fail_next(fake, :ensure_network, :unavailable)
    capture_log(fn -> assert Gates.network(opts) == :ok end)
    assert steps(ran()) == [:bridge, :anchor_supervisor, :anchor_dns, :nat]
  end

  test "a load at boot is recorded, so bridged starts do not load again", %{opts: opts} do
    assert Gates.network(opts) == :ok
    ran()
    assert Vagus.Network.Nat.ensure_loaded(opts) == :ok
    assert ran() == []
  end

  test "a refused load is logged, boot goes on, and the next bridged start retries",
       %{opts: opts} do
    test = self()

    refuse = fn bin, args ->
      send(test, {:ran, bin, args})
      {"Error: Could not process rule\n", 1}
    end

    log =
      capture_log(fn -> assert Gates.network(Keyword.put(opts, :cmd, refuse)) == :ok end)

    assert log =~ "supervisor DNAT"
    assert steps(ran()) == [:bridge, :anchor_supervisor, :anchor_dns, :nat]

    capture_log(fn ->
      assert {:error, _} = Vagus.Network.Nat.ensure_loaded(Keyword.put(opts, :cmd, refuse))
    end)

    assert steps(ran()) == [:nat]
  end
end
