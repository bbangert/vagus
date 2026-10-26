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

    # Index 1: nft fails when set; 2: deconfigure fails when set.
    fail = :atomics.new(2, [])
    test = self()

    cmd = fn _bin, ["-f", path] ->
      send(test, {:nft, File.read!(path)})
      if :atomics.get(fail, 1) == 0, do: {"", 0}, else: {"boom", 1}
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

    state_key = {__MODULE__, :ifaces, id}

    on_exit(fn ->
      File.rm_rf(dir)
      File.rm_rf(sysctl_root)
      :persistent_term.erase(nat_opts[:loaded_key])
      :persistent_term.erase(nat_opts[:lab_key])
      :persistent_term.erase(state_key)
    end)

    %{nat_opts: nat_opts, fail: fail, name: :"lab_#{id}", state_key: state_key}
  end

  defp start(ctx, extra \\ []) do
    test = self()
    fail = ctx.fail

    opts =
      [
        enabled: true,
        name: ctx.name,
        state_key: ctx.state_key,
        nat_opts: ctx.nat_opts,
        primary: fn -> "eth0" end,
        configured: fn -> [] end,
        addresses: fn _ -> [] end,
        configure: fn ifname, config ->
          send(test, {:configure, ifname, config})
          :ok
        end,
        deconfigure: fn ifname ->
          send(test, {:deconfigure, ifname})
          if :atomics.get(fail, 2) == 0, do: :ok, else: {:error, :busy}
        end
      ]
      |> Keyword.merge(extra)

    start_supervised!({Lab, opts})
    # The adopt continue runs before any call is served.
    _ = Lab.status(server: ctx.name)
    [server: ctx.name]
  end

  defp receive_all(acc \\ []) do
    receive do
      msg -> receive_all([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "up configures a non-persisted static address, then forwards out the primary", ctx do
    s = start(ctx)
    assert Lab.up("eth1", "10.42.0.1/24", s) == :ok

    assert [
             {:configure, "eth1",
              %{
                type: VintageNetEthernet,
                ipv4: %{method: :static, address: "10.42.0.1", prefix_length: 24}
              }},
             {:nft, text}
           ] = receive_all()

    assert text =~ @accept
    assert text =~ @return
    assert text =~ @masquerade
    assert Lab.status(s) == [%{ifname: "eth1", cidr: "10.42.0.1/24", primary: "eth0", state: :up}]

    assert :persistent_term.get(ctx.state_key) == %{
             "eth1" => %{cidr: "10.42.0.1/24", primary: "eth0", state: :up}
           }

    # A bridged start's load keeps the rules.
    :persistent_term.erase(ctx.nat_opts[:loaded_key])
    assert Nat.ensure_loaded(Keyword.delete(ctx.nat_opts, :lab)) == :ok
    assert [{:nft, again}] = receive_all()
    assert again =~ @masquerade
  end

  test "down removes the rules, then the address", ctx do
    s = start(ctx)
    :ok = Lab.up("eth1", "10.42.0.1/24", s)
    _ = receive_all()

    assert Lab.down("eth1", s) == :ok
    assert [{:nft, text}, {:deconfigure, "eth1"}] = receive_all()
    refute text =~ "eth1"
    refute text =~ "postrouting"
    assert Lab.status(s) == []
    assert :persistent_term.get(ctx.state_key) == %{}
    assert Lab.down("eth1", s) == {:error, :not_up}
  end

  test "down checkpoints the entry as broken while VintageNet removes the address", ctx do
    test = self()

    s =
      start(ctx,
        deconfigure: fn ifname ->
          send(test, {:deconfiguring, self()})
          receive do: (:go -> send(test, {:deconfigure, ifname}))
          :ok
        end
      )

    :ok = Lab.up("eth1", "10.42.0.1/24", s)
    _ = receive_all()

    task = Task.async(fn -> Lab.down("eth1", s) end)
    # Lab.down rewrites the nft ruleset before it deconfigures, so on a loaded
    # runner this can take well past assert_receive's default 100ms.
    assert_receive {:deconfiguring, pid}, 5_000
    assert %{"eth1" => %{state: :broken}} = :persistent_term.get(ctx.state_key)

    send(pid, :go)
    assert Task.await(task) == :ok
    assert :persistent_term.get(ctx.state_key) == %{}
  end

  test "a failed deconfigure after the rules are gone marks the entry broken", ctx do
    s = start(ctx)
    :ok = Lab.up("eth1", "10.42.0.1/24", s)
    _ = receive_all()
    :atomics.put(ctx.fail, 2, 1)

    assert Lab.down("eth1", s) == {:error, {:vintage_net, :busy}}
    assert [{:nft, text}, {:deconfigure, "eth1"}] = receive_all()
    refute text =~ "eth1"
    assert [%{ifname: "eth1", state: :broken}] = Lab.status(s)
    assert %{"eth1" => %{state: :broken}} = :persistent_term.get(ctx.state_key)

    # down again only has the address left to remove.
    assert Lab.down("eth1", s) == {:error, {:vintage_net, :busy}}
    assert receive_all() == [{:deconfigure, "eth1"}]

    # up with the same cidr restores the rules instead of answering :ok.
    :atomics.put(ctx.fail, 2, 0)
    assert Lab.up("eth1", "10.42.0.1/24", s) == :ok
    assert [{:configure, "eth1", _}, {:nft, text}] = receive_all()
    assert text =~ @masquerade
    assert [%{ifname: "eth1", state: :up}] = Lab.status(s)

    assert Lab.down("eth1", s) == :ok
    assert [{:nft, _}, {:deconfigure, "eth1"}] = receive_all()
    assert Lab.status(s) == []
  end

  test "a refused nft load on down keeps the entry and the address", ctx do
    s = start(ctx)
    :ok = Lab.up("eth1", "10.42.0.1/24", s)
    _ = receive_all()
    :atomics.put(ctx.fail, 1, 1)

    capture_log(fn ->
      assert {:error, {:nat, {["-f", _], "boom", 1}}} = Lab.down("eth1", s)
    end)

    # The refused load, then Nat's re-render of the old list; no deconfigure.
    assert [{:nft, _}, {:nft, _}] = receive_all()
    assert [%{ifname: "eth1"}] = Lab.status(s)
    assert Nat.lab(lab_key: ctx.nat_opts[:lab_key]) == [{"eth1", "eth0"}]

    :atomics.put(ctx.fail, 1, 0)
    assert Lab.down("eth1", s) == :ok
  end

  test "protected and malformed names are refused before anything runs", ctx do
    s = start(ctx)

    for name <- [
          "eth0",
          "wlan0",
          "lo",
          "usb0",
          "hassio",
          "hassio-anchor",
          "agentnet",
          "agentnet-anchor"
        ] do
      assert Lab.up(name, "10.42.0.1/24", s) == {:error, :protected}
    end

    for name <- [~s(eth1" accept), "..", ".", "a234567890123456", :eth1] do
      assert Lab.up(name, "10.42.0.1/24", s) == {:error, :invalid_ifname}
    end

    assert receive_all() == []
  end

  test "malformed cidrs are refused", ctx do
    s = start(ctx)

    for cidr <- ["10.42.0.1", "10.42.0.1/33", "10.42.0.1/0", "10.42.0/24", "x/24", "10.42.0.1/2x"] do
      assert Lab.up("eth1", cidr, s) == {:error, :invalid_cidr}
    end

    assert receive_all() == []
  end

  test "the primary interface itself is refused", ctx do
    s = start(ctx, primary: fn -> "eth1" end)
    assert Lab.up("eth1", "10.42.0.1/24", s) == {:error, :primary}
    assert receive_all() == []
  end

  test "without the nat module up refuses rather than forward nothing", ctx do
    s = start(ctx, nat_opts: Keyword.put(ctx.nat_opts, :enabled, false))
    assert Lab.up("eth1", "10.42.0.1/24", s) == {:error, :nat_disabled}
    assert receive_all() == []
  end

  test "an interface VintageNet already configures is refused", ctx do
    s = start(ctx, configured: fn -> ["usb1", "eth1"] end)
    assert Lab.up("eth1", "10.42.0.1/24", s) == {:error, :configured}
    assert receive_all() == []
  end

  test "a cidr overlapping a container bridge or the primary's subnet is refused", ctx do
    addresses = fn
      "eth0" ->
        [
          %{family: :inet6, address: {65_152, 0, 0, 0, 0, 0, 0, 1}, prefix_length: 64},
          %{
            family: :inet,
            address: {192, 168, 2, 10},
            netmask: {255, 255, 255, 0},
            prefix_length: 24
          },
          %{family: :inet, address: {10, 9, 0, 1}, netmask: {255, 255, 0, 0}}
        ]
    end

    s = start(ctx, addresses: addresses)

    for cidr <- [
          "172.30.33.1/24",
          "172.30.32.1/30",
          "172.30.40.9/28",
          "172.30.40.1/23",
          "172.16.0.1/12",
          "192.168.2.200/28",
          "10.9.200.1/24",
          "10.0.0.1/8"
        ] do
      assert Lab.up("eth1", cidr, s) == {:error, :overlap}, cidr
    end

    assert receive_all() == []
    assert Lab.up("eth1", "172.30.34.1/24", s) == :ok
    assert Lab.up("eth2", "172.30.41.1/24", s) == :ok
  end

  test "a refused nft load rolls the address back", ctx do
    s = start(ctx)
    :atomics.put(ctx.fail, 1, 1)

    capture_log(fn ->
      assert {:error, {:nat, {["-f", _], "boom", 1}}} = Lab.up("eth1", "10.42.0.1/24", s)
    end)

    assert [{:configure, "eth1", _}, {:nft, new}, {:nft, old}, {:deconfigure, "eth1"}] =
             receive_all()

    assert new =~ @masquerade
    refute old =~ "eth1"
    assert Lab.status(s) == []
    assert Nat.lab(lab_key: ctx.nat_opts[:lab_key]) == []
    assert :persistent_term.get(ctx.state_key) == %{}
  end

  test "nft and the rollback's deconfigure both refused: the entry is kept as broken", ctx do
    s = start(ctx)
    :atomics.put(ctx.fail, 1, 1)
    :atomics.put(ctx.fail, 2, 1)

    capture_log(fn ->
      assert {:error, {:nat, {["-f", _], "boom", 1}, {:rollback, :busy}}} =
               Lab.up("eth1", "10.42.0.1/24", s)
    end)

    _ = receive_all()
    broken = %{ifname: "eth1", cidr: "10.42.0.1/24", primary: "eth0", state: :broken}
    assert Lab.status(s) == [broken]
    assert %{"eth1" => %{state: :broken}} = :persistent_term.get(ctx.state_key)
    assert Nat.lab(lab_key: ctx.nat_opts[:lab_key]) == []
  end

  test "down on a broken entry only deconfigures, and keeps it while that fails", ctx do
    s = start(ctx)
    :atomics.put(ctx.fail, 1, 1)
    :atomics.put(ctx.fail, 2, 1)
    capture_log(fn -> {:error, {:nat, _, _}} = Lab.up("eth1", "10.42.0.1/24", s) end)
    _ = receive_all()
    :atomics.put(ctx.fail, 1, 0)

    assert Lab.down("eth1", s) == {:error, {:vintage_net, :busy}}
    assert receive_all() == [{:deconfigure, "eth1"}]
    assert [%{state: :broken}] = Lab.status(s)

    :atomics.put(ctx.fail, 2, 0)
    assert Lab.down("eth1", s) == :ok
    assert receive_all() == [{:deconfigure, "eth1"}]
    assert Lab.status(s) == []
    assert :persistent_term.get(ctx.state_key) == %{}
  end

  test "up on a broken entry retries the bring-up instead of refusing it", ctx do
    # VintageNet reports the address the failed rollback left behind.
    held = :atomics.new(1, [])
    s = start(ctx, configured: fn -> if :atomics.get(held, 1) == 1, do: ["eth1"], else: [] end)
    :atomics.put(ctx.fail, 1, 1)
    :atomics.put(ctx.fail, 2, 1)
    capture_log(fn -> {:error, {:nat, _, _}} = Lab.up("eth1", "10.42.0.1/24", s) end)
    _ = receive_all()
    :atomics.put(held, 1, 1)
    :atomics.put(ctx.fail, 1, 0)
    :atomics.put(ctx.fail, 2, 0)

    assert Lab.up("eth1", "10.42.0.1/24", s) == :ok
    assert [{:configure, "eth1", _}, {:nft, text}] = receive_all()
    assert text =~ @masquerade
    assert [%{ifname: "eth1", state: :up}] = Lab.status(s)
    assert Nat.lab(lab_key: ctx.nat_opts[:lab_key]) == [{"eth1", "eth0"}]
  end

  test "a cidr overlapping another lab interface's is refused, broken or not", ctx do
    s = start(ctx)
    :ok = Lab.up("eth1", "10.42.0.1/24", s)
    _ = receive_all()

    assert Lab.up("eth2", "10.42.0.2/24", s) == {:error, :overlap}
    assert Lab.up("eth2", "10.0.0.1/8", s) == {:error, :overlap}
    assert receive_all() == []
    assert Lab.up("eth2", "10.43.0.1/24", s) == :ok

    :sys.replace_state(ctx.name, fn st -> put_in(st.up["eth2"].state, :broken) end)
    assert Lab.up("eth3", "10.43.0.9/24", s) == {:error, :overlap}
  end

  test "a VintageNet refusal never touches nft", ctx do
    s = start(ctx, configure: fn _, _ -> {:error, :bad} end)
    assert Lab.up("eth1", "10.42.0.1/24", s) == {:error, {:vintage_net, :bad}}
    assert receive_all() == []
  end

  test "init adopts a previous instance's interfaces and renders their rules", ctx do
    :persistent_term.put(ctx.state_key, %{
      "eth1" => %{cidr: "10.42.0.1/24", primary: "eth0", state: :up}
    })

    s = start(ctx)

    assert Lab.status(s) == [%{ifname: "eth1", cidr: "10.42.0.1/24", primary: "eth0", state: :up}]
    assert [{:nft, text}] = receive_all()
    assert text =~ @masquerade
    assert Nat.lab(lab_key: ctx.nat_opts[:lab_key]) == [{"eth1", "eth0"}]
    assert Lab.up("eth1", "10.42.0.1/24", s) == :ok
  end

  test "the entry is checkpointed as pending while VintageNet configures it", ctx do
    test = self()

    s =
      start(ctx,
        configure: fn ifname, _config ->
          send(test, {:configuring, self()})
          receive do: (:go -> send(test, {:configure, ifname, :done}))
          :ok
        end
      )

    task = Task.async(fn -> Lab.up("eth1", "10.42.0.1/24", s) end)
    assert_receive {:configuring, pid}
    assert %{"eth1" => %{state: :pending}} = :persistent_term.get(ctx.state_key)

    send(pid, :go)
    assert Task.await(task) == :ok
    assert %{"eth1" => %{state: :up}} = :persistent_term.get(ctx.state_key)
  end

  test "init undoes an interrupted bring-up, or keeps it as broken if that fails", ctx do
    pending = %{cidr: "10.42.0.1/24", primary: "eth0", state: :pending}
    :persistent_term.put(ctx.state_key, %{"eth1" => pending})

    log = capture_log(fn -> start(ctx) end)
    assert log =~ "interrupted bring-up of eth1 undone"
    assert [{:deconfigure, "eth1"}] = receive_all()
    assert Lab.status(server: ctx.name) == []
    assert :persistent_term.get(ctx.state_key) == %{}
    assert Lab.up("eth1", "10.42.0.1/24", server: ctx.name) == :ok

    stop_supervised!(Lab)
    _ = receive_all()
    :persistent_term.put(ctx.state_key, %{"eth2" => pending})
    :atomics.put(ctx.fail, 2, 1)
    capture_log(fn -> start(ctx) end)

    assert [%{ifname: "eth2", state: :broken}] = Lab.status(server: ctx.name)
  end

  test "init drops rules no adopted interface accounts for", ctx do
    :persistent_term.put(ctx.nat_opts[:lab_key], [{"eth1", "eth0"}])
    s = start(ctx)

    assert Lab.status(s) == []
    assert [{:nft, text}] = receive_all()
    refute text =~ "eth1"
    assert Nat.lab(lab_key: ctx.nat_opts[:lab_key]) == []
  end

  test "init with nothing stored runs nothing", ctx do
    s = start(ctx)
    assert Lab.status(s) == []
    assert receive_all() == []
  end

  test "calls with no server return an error instead of exiting" do
    s = [server: :"lab_absent_#{System.unique_integer([:positive])}"]
    assert Lab.up("eth1", "10.42.0.1/24", s) == {:error, :not_running}
    assert Lab.down("eth1", s) == {:error, :not_running}
    assert Lab.status(s) == {:error, :not_running}
  end

  test "start_link is :ignore unless enabled" do
    assert Lab.start_link(enabled: false) == :ignore
  end
end
