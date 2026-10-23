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

    test "set_lab/2 stores the list for later renders, and restores it on a refused load",
         %{dir: dir} do
      opts = opts(dir, nft_fake({"", 0})) ++ [lab_key: {__MODULE__, :lab, dir}]
      on_exit(fn -> :persistent_term.erase({__MODULE__, :lab, dir}) end)

      assert Nat.set_lab([{"eth1", "eth0"}], opts) == :ok
      assert_received {:nft, "nft", _, text}
      assert text =~ "masquerade"
      assert {:ok, later} = Nat.ruleset(opts)
      assert later =~ "masquerade"

      capture_log(fn ->
        failing = Keyword.put(opts, :cmd, nft_fake({"boom", 1}))
        assert {:error, _} = Nat.set_lab([], failing)
      end)

      assert Nat.lab(opts) == [{"eth1", "eth0"}]
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
