defmodule Vagus.Network.LabTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.Network.{Lab, Nat}

  @accept ~s(iifname "eth1" oifname "eth0" accept)
  @return ~s(iifname "eth0" oifname "eth1" ct state established,related accept)
  @masquerade ~s(iifname "eth1" oifname "eth0" masquerade)

  setup do
    id = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "vagus-lab-#{id}")
    sysctl_root = dir <> "-sys"
    File.mkdir_p!(Path.join(sysctl_root, "net/ipv4/conf/hassio"))

    nft = :atomics.new(1, [])
    test = self()

    cmd = fn _bin, ["-f", path] ->
      send(test, {:nft, File.read!(path)})
      if :atomics.get(nft, 1) == 0, do: {"", 0}, else: {"boom", 1}
    end

    nat_opts = [
      enabled: true,
      nft_dir: dir,
      cmd: cmd,
      ip: "172.30.32.2",
      port: 8888,
      sysctl_root: sysctl_root,
      loaded_key: {__MODULE__, :loaded, id},
      lab_key: {__MODULE__, :lab, id}
    ]

    on_exit(fn ->
      File.rm_rf(dir)
      File.rm_rf(sysctl_root)
      :persistent_term.erase(nat_opts[:loaded_key])
      :persistent_term.erase(nat_opts[:lab_key])
    end)

    %{nat_opts: nat_opts, nft: nft, name: :"lab_#{id}"}
  end

  defp start(ctx, extra \\ []) do
    test = self()

    opts =
      [
        name: ctx.name,
        nat_opts: ctx.nat_opts,
        primary: fn -> "eth0" end,
        configure: fn ifname, config ->
          send(test, {:configure, ifname, config})
          :ok
        end,
        deconfigure: fn ifname ->
          send(test, {:deconfigure, ifname})
          :ok
        end
      ]
      |> Keyword.merge(extra)

    start_supervised!({Lab, opts})
    [server: ctx.name]
  end

  test "up configures a non-persisted static address and forwards out the primary", ctx do
    s = start(ctx)
    assert Lab.up("eth1", "10.42.0.1/24", s) == :ok

    assert_received {:configure, "eth1",
                     %{
                       type: VintageNetEthernet,
                       ipv4: %{method: :static, address: "10.42.0.1", prefix_length: 24}
                     }}

    assert_received {:nft, text}
    assert text =~ @accept
    assert text =~ @return
    assert text =~ @masquerade
    assert Lab.status(s) == [%{ifname: "eth1", cidr: "10.42.0.1/24", primary: "eth0"}]

    # A bridged start's load keeps the rules.
    :persistent_term.erase(ctx.nat_opts[:loaded_key])
    assert Nat.ensure_loaded(Keyword.delete(ctx.nat_opts, :lab)) == :ok
    assert_received {:nft, again}
    assert again =~ @masquerade
  end

  test "down removes the rules and the address", ctx do
    s = start(ctx)
    :ok = Lab.up("eth1", "10.42.0.1/24", s)
    assert_received {:nft, _}

    assert Lab.down("eth1", s) == :ok
    assert_received {:nft, text}
    refute text =~ "eth1"
    refute text =~ "postrouting"
    assert_received {:deconfigure, "eth1"}
    assert Lab.status(s) == []
    assert Lab.down("eth1", s) == {:error, :not_up}
  end

  test "protected and malformed names are refused before anything runs", ctx do
    s = start(ctx)

    for name <- ["eth0", "wlan0", "lo", "hassio", "hassio0"] do
      assert Lab.up(name, "10.42.0.1/24", s) == {:error, :protected}
    end

    assert Lab.up(~s(eth1" accept), "10.42.0.1/24", s) == {:error, :invalid_ifname}
    refute_received {:configure, _, _}
    refute_received {:nft, _}
  end

  test "malformed cidrs are refused", ctx do
    s = start(ctx)

    for cidr <- ["10.42.0.1", "10.42.0.1/33", "10.42.0.1/0", "10.42.0/24", "x/24", "10.42.0.1/2x"] do
      assert Lab.up("eth1", cidr, s) == {:error, :invalid_cidr}
    end

    refute_received {:configure, _, _}
  end

  test "the primary interface itself is refused", ctx do
    s = start(ctx, primary: fn -> "eth1" end)
    assert Lab.up("eth1", "10.42.0.1/24", s) == {:error, :primary}
    refute_received {:configure, _, _}
  end

  test "a refused nft load rolls the address back", ctx do
    s = start(ctx)
    :atomics.put(ctx.nft, 1, 1)

    capture_log(fn ->
      assert {:error, {:nat, {["-f", _], "boom", 1}}} = Lab.up("eth1", "10.42.0.1/24", s)
    end)

    assert_received {:deconfigure, "eth1"}
    assert Lab.status(s) == []
    assert Nat.lab(lab_key: ctx.nat_opts[:lab_key]) == []
  end

  test "a VintageNet refusal never touches nft", ctx do
    s = start(ctx, configure: fn _, _ -> {:error, :bad} end)
    assert Lab.up("eth1", "10.42.0.1/24", s) == {:error, {:vintage_net, :bad}}
    refute_received {:nft, _}
  end

  test "init clears a lab list left by a previous instance", ctx do
    :persistent_term.put(ctx.nat_opts[:lab_key], [{"eth1", "eth0"}])
    s = start(ctx)

    assert Lab.status(s) == []
    assert_received {:nft, text}
    refute text =~ "eth1"
    assert Nat.lab(lab_key: ctx.nat_opts[:lab_key]) == []
  end

  test "init with no stored list runs nothing", ctx do
    s = start(ctx)
    assert Lab.status(s) == []
    refute_received {:nft, _}
  end
end
