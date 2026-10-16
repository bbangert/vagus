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
    do: [enabled: true, nft_dir: dir, cmd: cmd, ip: "172.30.32.2", port: 8888]

  describe "ensure/1" do
    test "the ruleset: both hooks at -110, prerouting and output" do
      # Core and every host-network app generate their packets locally, so a
      # prerouting-only rule serves bridged apps and silently breaks Core.
      assert Nat.ruleset(ip: "172.30.32.2", port: 8888) == {:ok, @ruleset}
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

    test "nft_cmd/2 reports a missing binary as an exit, never a raise" do
      assert {_msg, 127} = Nat.nft_cmd("vagus-no-such-nft", ["-f", "/dev/null"])
    end
  end

  describe "teardown/1" do
    test "declares the table before deleting it, so an absent table is fine", %{dir: dir} do
      assert Nat.teardown(opts(dir, nft_fake({"", 0}))) == :ok
      assert_received {:nft, "nft", ["-f", _], "table ip vagus\ndelete table ip vagus\n"}
    end
  end

  describe "the gate" do
    test "disabled (the :host/:test default) executes nothing at all", %{dir: dir} do
      Application.delete_env(:vagus, :supervisor_nat)
      cmd = nft_fake({"", 0})

      assert Nat.enabled?() == false
      assert Nat.ensure(cmd: cmd, nft_dir: dir) == :ok
      assert Nat.teardown(cmd: cmd, nft_dir: dir) == :ok
      refute_received {:nft, _, _, _}
      refute File.exists?(dir)
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
