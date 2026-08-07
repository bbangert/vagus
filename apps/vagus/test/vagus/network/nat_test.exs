defmodule Vagus.Network.NatTest do
  # async: false — the config-driven describes read/write the global app env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vagus.Network.Nat

  @bin "iptables-legacy"
  @rule [
    "-d",
    "172.30.32.2",
    "-p",
    "tcp",
    "--dport",
    "80",
    "-j",
    "DNAT",
    "--to-destination",
    "172.30.32.2:8888"
  ]

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

    :ok
  end

  # A fake `iptables-legacy` that records every invocation in order and
  # answers each one via `responder`. `-C`/`-S` are the probes: their exit
  # status is the answer ("is this rule/chain there?"), never an error.
  defp fake(responder) do
    {:ok, agent} =
      start_supervised({Agent, fn -> [] end}, id: {:calls, System.unique_integer([:positive])})

    cmd = fn bin, args ->
      Agent.update(agent, &[{bin, args} | &1])
      responder.(args)
    end

    {cmd, fn -> agent |> Agent.get(& &1) |> Enum.reverse() end}
  end

  defp probe?(args), do: "-C" in args or "-S" in args

  # Nothing is installed: every probe fails, every mutation succeeds.
  defp absent, do: fn args -> if probe?(args), do: {"", 1}, else: {"", 0} end

  # Everything is installed: every probe succeeds.
  defp present, do: fn _args -> {"", 0} end

  defp opts(cmd), do: [enabled: true, cmd: cmd, ip: "172.30.32.2", port: 8888]

  describe "ensure/1 — fresh assert" do
    test "creates the chain, adds the DNAT rule and jumps into BOTH hooks" do
      {cmd, calls} = fake(absent())

      assert Nat.ensure(opts(cmd)) == :ok

      assert calls.() == [
               {@bin, ["-t", "nat", "-S", "VAGUS_NAT"]},
               {@bin, ["-t", "nat", "-N", "VAGUS_NAT"]},
               {@bin, ["-t", "nat", "-C", "VAGUS_NAT"] ++ @rule},
               {@bin, ["-t", "nat", "-A", "VAGUS_NAT"] ++ @rule},
               {@bin, ["-t", "nat", "-C", "PREROUTING", "-j", "VAGUS_NAT"]},
               {@bin, ["-t", "nat", "-I", "PREROUTING", "1", "-j", "VAGUS_NAT"]},
               {@bin, ["-t", "nat", "-C", "OUTPUT", "-j", "VAGUS_NAT"]},
               {@bin, ["-t", "nat", "-I", "OUTPUT", "1", "-j", "VAGUS_NAT"]}
             ]
    end

    test "the OUTPUT jump is not optional — host-network clients skip PREROUTING" do
      # The spike's load-bearing finding (2026-08-07, .149): Core and every
      # `host_network: true` add-on generate their packets locally, so a
      # PREROUTING-only rule serves bridged add-ons and silently breaks Core.
      {cmd, calls} = fake(absent())
      Nat.ensure(opts(cmd))

      inserted = for {_bin, args} <- calls.(), "-I" in args, do: Enum.at(args, 3)
      assert inserted == ["PREROUTING", "OUTPUT"]
    end

    test "both jumps go in at position 1, ahead of balena's dst-type LOCAL jump" do
      {cmd, calls} = fake(absent())
      Nat.ensure(opts(cmd))

      for {_bin, args} <- calls.(), "-I" in args do
        assert Enum.at(args, 4) == "1"
      end
    end
  end

  describe "ensure/1 — idempotence" do
    test "everything already present runs only the probes, mutating nothing" do
      {cmd, calls} = fake(present())

      assert Nat.ensure(opts(cmd)) == :ok

      assert calls.() == [
               {@bin, ["-t", "nat", "-S", "VAGUS_NAT"]},
               {@bin, ["-t", "nat", "-C", "VAGUS_NAT"] ++ @rule},
               {@bin, ["-t", "nat", "-C", "PREROUTING", "-j", "VAGUS_NAT"]},
               {@bin, ["-t", "nat", "-C", "OUTPUT", "-j", "VAGUS_NAT"]}
             ]
    end

    test "a half-flushed table (OUTPUT jump gone) is healed without touching the rest" do
      # The engine-restart failure mode this module exists for: the chain and
      # rule survive, a jump does not.
      responder = fn args ->
        cond do
          not probe?(args) -> {"", 0}
          "OUTPUT" in args -> {"", 1}
          true -> {"", 0}
        end
      end

      {cmd, calls} = fake(responder)

      assert Nat.ensure(opts(cmd)) == :ok

      mutations = for {_bin, args} <- calls.(), not probe?(args), do: args
      assert mutations == [["-t", "nat", "-I", "OUTPUT", "1", "-j", "VAGUS_NAT"]]
    end

    test "an existing chain is not recreated" do
      responder = fn args ->
        cond do
          not probe?(args) -> {"", 0}
          "-S" in args -> {"", 0}
          true -> {"", 1}
        end
      end

      {cmd, calls} = fake(responder)
      Nat.ensure(opts(cmd))

      refute Enum.any?(calls.(), fn {_bin, args} -> "-N" in args end)
    end
  end

  describe "ensure/1 — failures" do
    test "a failing chain creation stops there and reports the invocation" do
      responder = fn args ->
        if "-N" in args, do: {"iptables: Permission denied\n", 3}, else: {"", 1}
      end

      {cmd, calls} = fake(responder)

      log =
        capture_log(fn ->
          assert {:error, {args, "iptables: Permission denied", 3}} = Nat.ensure(opts(cmd))
          assert args == ["-t", "nat", "-N", "VAGUS_NAT"]
        end)

      assert log =~ "Permission denied"
      # Nothing after the failure — no rule against a chain that isn't there.
      assert length(calls.()) == 2
    end

    test "a failing jump insert reports and stops before the second hook" do
      responder = fn args ->
        cond do
          probe?(args) -> {"", 1}
          "-I" in args and "PREROUTING" in args -> {"boom\n", 1}
          true -> {"", 0}
        end
      end

      {cmd, calls} = fake(responder)

      capture_log(fn ->
        assert {:error, {_args, "boom", 1}} = Nat.ensure(opts(cmd))
      end)

      refute Enum.any?(calls.(), fn {_bin, args} -> "OUTPUT" in args and "-I" in args end)
    end

    test "a missing iptables-legacy binary degrades to exit 127, never raises" do
      assert {output, 127} = Nat.default_cmd("vagus-definitely-not-a-binary", ["-t", "nat", "-S"])
      assert output =~ "enoent"
    end
  end

  describe "teardown/1" do
    test "removes both jumps, then flushes and deletes the chain" do
      {cmd, calls} = fake(present())

      assert Nat.teardown(enabled: true, cmd: cmd) == :ok

      assert calls.() == [
               {@bin, ["-t", "nat", "-C", "PREROUTING", "-j", "VAGUS_NAT"]},
               {@bin, ["-t", "nat", "-D", "PREROUTING", "-j", "VAGUS_NAT"]},
               {@bin, ["-t", "nat", "-C", "OUTPUT", "-j", "VAGUS_NAT"]},
               {@bin, ["-t", "nat", "-D", "OUTPUT", "-j", "VAGUS_NAT"]},
               {@bin, ["-t", "nat", "-S", "VAGUS_NAT"]},
               {@bin, ["-t", "nat", "-F", "VAGUS_NAT"]},
               {@bin, ["-t", "nat", "-X", "VAGUS_NAT"]}
             ]
    end

    test "nothing installed is a no-op that only probes" do
      {cmd, calls} = fake(absent())

      assert Nat.teardown(enabled: true, cmd: cmd) == :ok

      assert calls.() == [
               {@bin, ["-t", "nat", "-C", "PREROUTING", "-j", "VAGUS_NAT"]},
               {@bin, ["-t", "nat", "-C", "OUTPUT", "-j", "VAGUS_NAT"]},
               {@bin, ["-t", "nat", "-S", "VAGUS_NAT"]}
             ]
    end

    test "ensure ∘ teardown is symmetric — every chain/jump ensure creates is removed" do
      {ensure_cmd, ensure_calls} = fake(absent())
      Nat.ensure(opts(ensure_cmd))
      {teardown_cmd, teardown_calls} = fake(present())
      Nat.teardown(enabled: true, cmd: teardown_cmd)

      created = for {_bin, args} <- ensure_calls.(), not probe?(args), do: Enum.at(args, 3)
      removed = for {_bin, args} <- teardown_calls.(), not probe?(args), do: Enum.at(args, 3)

      assert Enum.sort(Enum.uniq(created)) == Enum.sort(Enum.uniq(removed))
    end
  end

  describe "the gate" do
    test "disabled (the :host/:test default) executes nothing at all" do
      {cmd, calls} = fake(absent())
      Application.delete_env(:vagus, :supervisor_nat)

      assert Nat.enabled?() == false
      assert Nat.ensure(cmd: cmd) == :ok
      assert Nat.teardown(cmd: cmd) == :ok
      assert calls.() == []
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

      assert Nat.dnat_rule() == {:ok, @rule}
    end

    test "the destination defaults to the supervisor anchor when :api_bind_ip is unset" do
      Application.delete_env(:vagus, :api_bind_ip)
      Application.put_env(:vagus, :api_port, 9999)

      assert {:ok, rule} = Nat.dnat_rule()
      assert "172.30.32.2:9999" in rule
    end

    test "an :api_bind_ip tuple is normalised to its string form" do
      assert {:ok, rule} = Nat.dnat_rule(ip: {172, 30, 32, 2}, port: 8888)
      assert rule == @rule
    end

    test "an :api_port still on 80 installs nothing — that is a listener, not a rewrite" do
      {cmd, calls} = fake(absent())

      log =
        capture_log(fn ->
          assert Nat.ensure(enabled: true, cmd: cmd, port: 80) == {:error, :no_rewrite_needed}
        end)

      assert log =~ ":api_port is 80"
      assert calls.() == []
    end

    test "an unreadable :api_bind_ip installs nothing and says so" do
      {cmd, calls} = fake(absent())

      log =
        capture_log(fn ->
          assert {:error, {:invalid_ip, "nope"}} = Nat.ensure(enabled: true, cmd: cmd, ip: "nope")
        end)

      assert log =~ "http://supervisor/"
      assert calls.() == []
    end

    test "a nonsense :api_port installs nothing" do
      {cmd, calls} = fake(absent())

      capture_log(fn ->
        assert {:error, {:invalid_port, "eighty"}} =
                 Nat.ensure(enabled: true, cmd: cmd, port: "eighty")
      end)

      assert calls.() == []
    end
  end
end
