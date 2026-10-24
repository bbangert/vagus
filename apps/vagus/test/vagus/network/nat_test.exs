defmodule Vagus.Network.NatTest do
  # async: false — the config-driven describes read/write the global app env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vagus.Network.Nat

  @ruleset """
  table ip vagus
  flush table ip vagus
  table ip vagus {
  \tchain prerouting {
  \t\ttype nat hook prerouting priority -110; policy accept;
  \t\tip daddr 172.30.32.2 tcp dport 80 dnat to 172.30.32.2:8888
  \t}
  \tchain output {
  \t\ttype nat hook output priority -110; policy accept;
  \t\tip daddr 172.30.32.2 tcp dport 80 dnat to 172.30.32.2:8888
  \t}
  \tchain forward {
  \t\ttype filter hook forward priority filter; policy accept;
  \t\tiifname != "hassio" oifname != "hassio" drop
  \t\toifname "hassio" iifname != "hassio" ct state new ct status & dnat == 0 drop
  \t}
  \tchain prerouting_filter {
  \t\ttype filter hook prerouting priority mangle; policy accept;
  \t\tiifname "hassio" ip daddr 127.0.0.0/8 ct status & dnat == 0 drop
  \t}
  }
  """

  setup do
    original = %{
      nat: Application.get_env(:vagus, :supervisor_nat),
      ip: Application.get_env(:vagus, :api_bind_ip),
      port: Application.get_env(:vagus, :api_port)
    }

    on_exit(fn ->
      for {key, config} <- [supervisor_nat: :nat, api_bind_ip: :ip, api_port: :port] do
        case Map.fetch!(original, config) do
          nil -> Application.delete_env(:vagus, key)
          value -> Application.put_env(:vagus, key, value)
        end
      end
    end)

    dir = Path.join(System.tmp_dir!(), "vagus-nft-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    on_exit(fn -> File.rm_rf(sysctl_root(dir)) end)
    # Each test's own load record: a shared one would let one test's load
    # answer for another's.
    on_exit(fn -> :persistent_term.erase({__MODULE__, dir}) end)
    %{dir: dir}
  end

  # Records each call with the text of the file nft is handed, read while
  # the file still exists.
  defp nft_fake(answer) do
    test = self()

    fn bin, args ->
      text = with ["-f", path] <- args, {:ok, text} <- File.read(path), do: text
      send(test, {:nft, bin, args, text})
      answer
    end
  end

  defp opts(dir, cmd),
    do: [
      enabled: true,
      nft_dir: dir,
      cmd: cmd,
      ip: "172.30.32.2",
      port: 8888,
      loaded_key: {__MODULE__, dir},
      sysctl_root: sysctl_root(dir)
    ]

  # A /proc/sys stand-in where the hassio bridge exists.
  defp sysctl_root(dir) do
    root = dir <> "-sys"
    File.mkdir_p!(Path.join(root, "net/ipv4/conf/hassio"))
    root
  end

  defp sysctl(dir, key), do: File.read(Path.join(sysctl_root(dir), key))

  describe "ensure/1" do
    test "the ruleset: both nat hooks at -110, and the forward filter" do
      # Core and every host-network app generate their packets locally, so a
      # prerouting-only rule serves bridged apps and silently breaks Core.
      assert Nat.ruleset(ip: "172.30.32.2", port: 8888) == {:ok, @ruleset}
    end

    test "the forward drop tests the dnat flag, never the whole status word" do
      # `ct status != dnat` matches nearly every connection: published ports
      # would be dropped with the rest.
      {:ok, ruleset} = Nat.ruleset(ip: "172.30.32.2", port: 8888)
      assert ruleset =~ ~s(oifname "hassio" iifname != "hassio" ct state new)
      assert ruleset =~ "ct status & dnat == 0 drop"
      refute ruleset =~ "ct status != dnat"
    end

    test "loads the ruleset with one nft -f, then removes the file", %{dir: dir} do
      assert Nat.ensure(opts(dir, nft_fake({"", 0}))) == :ok
      assert_received {:nft, "nft", ["-f", path], @ruleset}
      refute_received {:nft, _, _, _}
      refute File.exists?(path)
      assert Path.dirname(path) == dir
    end

    test "a refused load is the error, with nft's message, and leaves no file", %{dir: dir} do
      cmd = nft_fake({"Error: Could not process rule: No such file or directory\n", 1})

      capture_log(fn ->
        assert {:error, {["-f", path], "Error: Could not process rule" <> _, 1}} =
                 Nat.ensure(opts(dir, cmd))

        refute File.exists?(path)
      end)
    end

    test "makes its directory 0700, as it can run before the Host does", %{dir: dir} do
      assert Nat.ensure(opts(dir, nft_fake({"", 0}))) == :ok
      assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700
    end

    test "a ruleset file that cannot be written is the error, and nft never runs",
         %{dir: dir} do
      File.mkdir_p!(Path.dirname(dir))
      File.write!(dir, "a file where the directory should be")

      log =
        capture_log(fn ->
          assert {:error, {:nft_file, _reason}} = Nat.ensure(opts(dir, nft_fake({"", 0})))
        end)

      assert log =~ "not written"
      refute_received {:nft, _, _, _}
    end
  end

  describe "agentnet" do
    test "hassio may not open connections into agentnet, only on the agent flavor" do
      {:ok, text} = Nat.ruleset(ip: "172.30.32.2", port: 8888, agentnet: true)

      agentnet =
        ~s(\t\tiifname "agentnet" oifname "agentnet" accept\n) <>
          ~s(\t\toifname "agentnet" iifname != "agentnet" ct state new drop\n)

      baseline_drop = ~s(\t\tiifname != "hassio" oifname != "hassio" drop\n)
      assert text == String.replace(@ruleset, baseline_drop, agentnet <> baseline_drop)

      assert Nat.ruleset(ip: "172.30.32.2", port: 8888, agentnet: false) == {:ok, @ruleset}
    end

    # A reload with no opts (a bridged start, `set_lab/2`) must keep the rule.
    test "unset, it follows the flavor" do
      prev = Application.get_env(:vagus, :flavor)
      on_exit(fn -> Application.put_env(:vagus, :flavor, prev || :default) end)

      Application.put_env(:vagus, :flavor, :default)
      assert Nat.ruleset(ip: "172.30.32.2", port: 8888) == {:ok, @ruleset}

      Application.put_env(:vagus, :flavor, :agent_dev_board)
      assert Vagus.Network.Agentnet.enabled?()
      {:ok, text} = Nat.ruleset(ip: "172.30.32.2", port: 8888)
      assert text =~ ~s(oifname "agentnet" iifname != "agentnet" ct state new drop)
    end
  end

  describe "lab interfaces" do
    test "forward accepts and masquerade, ahead of the drops, only while listed" do
      {:ok, ruleset} =
        Nat.ruleset(ip: "172.30.32.2", port: 8888, lab: [{"eth1", "eth0"}])

      assert ruleset =~
               """
               \t\ttype filter hook forward priority filter; policy accept;
               \t\tiifname "eth1" oifname "eth0" accept
               \t\tiifname "eth0" oifname "eth1" ct state established,related accept
               \t\tiifname != "hassio" oifname != "hassio" drop
               """

      assert String.ends_with?(ruleset, """
             \tchain postrouting {
             \t\ttype nat hook postrouting priority srcnat; policy accept;
             \t\tiifname "eth1" oifname "eth0" masquerade
             \t}
             }
             """)

      assert Nat.ruleset(ip: "172.30.32.2", port: 8888, lab: []) == {:ok, @ruleset}
    end

    test "set_lab/2 stores the list for later renders once it is loaded", %{dir: dir} do
      opts = lab_opts(dir, nft_fake({"", 0}))

      assert Nat.set_lab([{"eth1", "eth0"}], opts) == :ok
      assert_received {:nft, "nft", _, text}
      assert text =~ "masquerade"
      assert {:ok, later} = Nat.ruleset(opts)
      assert later =~ "masquerade"
    end

    test "a refused load keeps the stored list and re-renders it", %{dir: dir} do
      opts = lab_opts(dir, nft_fake({"", 0}))
      :ok = Nat.set_lab([{"eth1", "eth0"}], opts)
      assert_received {:nft, _, _, _}

      capture_log(fn ->
        assert {:error, _} = Nat.set_lab([], Keyword.put(opts, :cmd, nft_fake({"boom", 1})))
      end)

      assert [{:nft, _, _, new}, {:nft, _, _, old}] = receive_all()
      refute new =~ "eth1"
      assert old =~ ~s(iifname "eth1" oifname "eth0" masquerade)
      assert Nat.lab(opts) == [{"eth1", "eth0"}]
    end

    test "nft loaded but the sysctl step failed: the old list goes back in", %{dir: dir} do
      opts = lab_opts(dir, nft_fake({"", 0}))
      no_sysctl = Keyword.put(opts, :sysctl_root, dir <> "-absent")

      capture_log(fn ->
        assert {:error, {:sysctl, _, _}} = Nat.set_lab([{"eth1", "eth0"}], no_sysctl)
      end)

      assert [{:nft, _, _, new}, {:nft, _, _, old}] = receive_all()
      assert new =~ "eth1"
      refute old =~ "eth1"
      assert Nat.lab(opts) == []
    end

    test "every interface name is checked before it reaches the ruleset" do
      for pair <- [{"..", "eth0"}, {".", "eth0"}, {"eth1", ~s(eth0" accept)}, {"eth1", ".."}],
          do:
            assert(
              Nat.ruleset(ip: "172.30.32.2", port: 8888, lab: [pair]) ==
                {:error, :invalid_ifname}
            )

      assert Nat.valid_ifname?("enx001122334455")
      assert Nat.valid_ifname?("eth1.100")
      refute Nat.valid_ifname?("a234567890123456")
      refute Nat.valid_ifname?("-eth1")
      refute Nat.valid_ifname?("")
      refute Nat.valid_ifname?(:eth1)
    end

    test "writers are serialized: a boot-gate load waits out a set_lab and renders its list",
         %{dir: dir} do
      {cmd, release} = blocking_nft()
      opts = lab_opts(dir, cmd)

      setter = Task.async(fn -> Nat.set_lab([{"eth1", "eth0"}], opts) end)
      assert_receive {:nft_blocked, first}
      gate = Task.async(fn -> Nat.ensure(opts) end)
      refute_receive {:nft_blocked, _}, 300

      release.(first)
      assert Task.await(setter) == :ok
      assert_receive {:nft_blocked, second}, 5_000
      release.(second)
      assert Task.await(gate, 10_000) == :ok

      second_text = nft_text(second)
      assert second_text =~ ~s(iifname "eth1" oifname "eth0" masquerade)
      assert Nat.ruleset(opts) == {:ok, second_text}
    end

    test "two concurrent set_lab calls leave the kernel holding the stored list",
         %{dir: dir} do
      {cmd, release} = blocking_nft()
      opts = lab_opts(dir, cmd)

      a = Task.async(fn -> Nat.set_lab([{"eth1", "eth0"}], opts) end)
      assert_receive {:nft_blocked, first}
      b = Task.async(fn -> Nat.set_lab([{"eth2", "eth0"}], opts) end)
      refute_receive {:nft_blocked, _}, 300

      release.(first)
      assert_receive {:nft_blocked, second}, 5_000
      release.(second)
      assert Task.await(a) == :ok
      assert Task.await(b, 10_000) == :ok

      assert Nat.ruleset(opts) == {:ok, nft_text(second)}
    end

    test "a load that cannot take the table in time is :busy", %{dir: dir} do
      {cmd, release} = blocking_nft()
      opts = lab_opts(dir, cmd)

      a = Task.async(fn -> Nat.set_lab([{"eth1", "eth0"}], opts) end)
      assert_receive {:nft_blocked, first}
      assert Nat.ensure(Keyword.put(opts, :lock_retries, 0)) == {:error, :busy}
      assert Nat.set_lab([], Keyword.put(opts, :lock_retries, 0)) == {:error, :busy}

      release.(first)
      assert Task.await(a) == :ok
      assert Nat.lab(opts) == [{"eth1", "eth0"}]
    end

    test "a timed-out load keeps the stored list, and rolls back only after it answered",
         %{dir: dir} do
      test = self()
      calls = :counters.new(1, [])

      cmd = fn _bin, ["-f", path] ->
        :counters.add(calls, 1, 1)
        text = File.read!(path)
        send(test, {:start, text})
        Process.sleep(50)
        send(test, {:done, text})
        if :counters.get(calls, 1) == 1, do: {"nft: no answer in 10000 ms", 124}, else: {"", 0}
      end

      opts = lab_opts(dir, cmd)

      capture_log(fn ->
        assert {:error, {_, _, 124}} = Nat.set_lab([{"eth1", "eth0"}], opts)
      end)

      assert [{:start, new}, {:done, new}, {:start, old}, {:done, old}] = receive_all()
      assert new =~ "eth1"
      refute old =~ "eth1"
      assert Nat.lab(opts) == []
    end

    test "an invalid name loads nothing", %{dir: dir} do
      opts = lab_opts(dir, nft_fake({"", 0}))
      assert Nat.set_lab([{"..", "eth0"}], opts) == {:error, :invalid_ifname}
      assert receive_all() == []
      assert Nat.lab(opts) == []
    end
  end

  # Each nft call parks with its ruleset text until the test releases it.
  defp blocking_nft do
    test = self()

    cmd = fn _bin, ["-f", path] ->
      ref = make_ref()
      send(test, {:nft_blocked, {self(), ref, File.read!(path)}})

      receive do
        {:release, ^ref} -> {"", 0}
      end
    end

    {cmd, fn {pid, ref, _text} -> send(pid, {:release, ref}) end}
  end

  defp nft_text({_pid, _ref, text}), do: text

  defp lab_opts(dir, cmd) do
    on_exit(fn -> :persistent_term.erase({__MODULE__, :lab, dir}) end)
    opts(dir, cmd) ++ [lab_key: {__MODULE__, :lab, dir}]
  end

  defp receive_all(acc \\ []) do
    receive do
      msg -> receive_all([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "forwarding sysctls" do
    test "ip_forward and the bridge's route_localnet are set once the table is loaded",
         %{dir: dir} do
      assert Nat.ensure(opts(dir, nft_fake({"", 0}))) == :ok
      assert sysctl(dir, "net/ipv4/ip_forward") == {:ok, "1"}
      assert sysctl(dir, "net/ipv4/conf/hassio/route_localnet") == {:ok, "1"}
    end

    test "never before the filter: a refused load leaves forwarding off", %{dir: dir} do
      capture_log(fn -> Nat.ensure(opts(dir, nft_fake({"boom", 1}))) end)
      assert {:error, :enoent} = sysctl(dir, "net/ipv4/ip_forward")
    end

    test "a bridge that does not exist yet fails the load and records nothing",
         %{dir: dir} do
      opts = opts(dir, nft_fake({"", 0}))
      File.rm_rf!(Path.join(opts[:sysctl_root], "net/ipv4/conf/hassio"))

      log =
        capture_log(fn ->
          assert {:error, {:sysctl, "net/ipv4/conf/hassio/route_localnet", :enoent}} =
                   Nat.ensure(opts)
        end)

      assert log =~ "route_localnet not set"
      refute :persistent_term.get(opts[:loaded_key], false)

      File.mkdir_p!(Path.join(opts[:sysctl_root], "net/ipv4/conf/hassio"))
      assert Nat.ensure_loaded(opts) == :ok
      assert sysctl(dir, "net/ipv4/conf/hassio/route_localnet") == {:ok, "1"}
    end
  end

  describe "nft_cmd/3" do
    test "passes the command's output and status through" do
      assert {"hi\n", 0} = Nat.nft_cmd("echo", ["hi"])
      assert {_out, 1} = Nat.nft_cmd("false", [])
    end

    test "a missing binary is an exit, never a raise" do
      assert {_msg, 127} = Nat.nft_cmd("vagus-no-such-nft", ["-f", "/dev/null"])
    end

    test "a command that does not answer in time is exit 124" do
      assert {msg, 124} = Nat.nft_cmd("sleep", ["2"], 50)
      assert msg =~ "no answer in 50 ms"
    end

    test "a timed-out command is killed before the answer, never left to finish", %{dir: dir} do
      File.mkdir_p!(dir)
      marker = Path.join(dir, "late")

      assert {_msg, 124} = Nat.nft_cmd("sh", ["-c", "sleep 0.5; touch #{marker}"], 50)
      Process.sleep(800)
      refute File.exists?(marker)
    end

    test "a runner that crashes is exit 1, never a raise" do
      assert {_msg, 1} = Nat.nft_cmd("echo", [:not_a_string])
    end
  end

  describe "the gate" do
    test "disabled (the :host/:test default) executes nothing at all", %{dir: dir} do
      Application.delete_env(:vagus, :supervisor_nat)
      cmd = nft_fake({"", 0})

      assert Nat.enabled?() == false
      assert Nat.ensure(cmd: cmd, nft_dir: dir) == :ok
      refute_received {:nft, _, _, _}
      refute File.exists?(dir)
    end

    test "ensure_loaded/1 is :ok with NAT off, and never loads", %{dir: dir} do
      Application.put_env(:vagus, :supervisor_nat, false)
      assert Nat.ensure_loaded(cmd: nft_fake({"boom", 1}), nft_dir: dir) == :ok
      refute_received {:nft, _, _, _}
    end

    test "enabled?/0 follows :supervisor_nat" do
      Application.put_env(:vagus, :supervisor_nat, true)
      assert Nat.enabled?()

      Application.put_env(:vagus, :supervisor_nat, false)
      refute Nat.enabled?()
    end
  end

  describe "the rule the config produces" do
    test "target.exs's values give the spike-proven rule" do
      Application.put_env(:vagus, :api_bind_ip, "172.30.32.2")
      Application.put_env(:vagus, :api_port, 8888)

      assert Nat.ruleset() == {:ok, @ruleset}
    end

    test "the destination defaults to the supervisor anchor when :api_bind_ip is unset" do
      Application.delete_env(:vagus, :api_bind_ip)
      Application.put_env(:vagus, :api_port, 9999)

      assert {:ok, ruleset} = Nat.ruleset()
      assert ruleset =~ "ip daddr 172.30.32.2 tcp dport 80 dnat to 172.30.32.2:9999"
    end

    test "an :api_bind_ip tuple is normalised to its string form" do
      assert Nat.ruleset(ip: {172, 30, 32, 2}, port: 8888) == {:ok, @ruleset}
    end

    test "an :api_port still on 80 installs nothing — that is a listener, not a rewrite",
         %{dir: dir} do
      log =
        capture_log(fn ->
          opts = Keyword.put(opts(dir, nft_fake({"", 0})), :port, 80)
          assert Nat.ensure(opts) == {:error, :no_rewrite_needed}
        end)

      assert log =~ ":api_port is 80"
      refute_received {:nft, _, _, _}
    end

    test "an unreadable :api_bind_ip installs nothing and says so", %{dir: dir} do
      log =
        capture_log(fn ->
          opts = Keyword.put(opts(dir, nft_fake({"", 0})), :ip, "nope")
          assert {:error, {:invalid_ip, "nope"}} = Nat.ensure(opts)
        end)

      assert log =~ "http://supervisor/"
      refute_received {:nft, _, _, _}
    end

    test "a nonsense :api_port installs nothing", %{dir: dir} do
      capture_log(fn ->
        opts = Keyword.put(opts(dir, nft_fake({"", 0})), :port, "eighty")
        assert {:error, {:invalid_port, "eighty"}} = Nat.ensure(opts)
      end)

      refute_received {:nft, _, _, _}
    end
  end
end
