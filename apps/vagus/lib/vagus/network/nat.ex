defmodule Vagus.Network.Nat do
  @moduledoc """
  The DNAT rules that keep `http://supervisor/` working after the
  Supervisor-API listener moved off port 80.

  ## Why this exists

  Home Assistant Core 2026.8 binds `0.0.0.0:80` on a supervised install, and
  a wildcard bind cannot coexist with anything else holding port 80 — so
  Vagus's own listener vacates it (`Vagus.API.Listener` binds
  `172.30.32.2:<:api_port>`). The add-on contract, however, hardwires port
  80: add-ons reach the Supervisor at `http://supervisor/` and Core's
  `SUPERVISOR`/`HASSIO` env carries a bare IP with port 80 implied
  (`Vagus.Core.Container`). Neither is configurable, so the port has to be
  served — by a destination rewrite rather than a listener.

  ## Under balena-engine: an own chain

  Everything lives in an own chain (`VAGUS_NAT`) so it can be asserted,
  inspected and torn down without touching balena-engine's chains, which
  share the `nat` table:

      iptables-legacy -t nat -N VAGUS_NAT
      iptables-legacy -t nat -A VAGUS_NAT -d 172.30.32.2 -p tcp --dport 80 \\
        -j DNAT --to-destination 172.30.32.2:8888
      iptables-legacy -t nat -I PREROUTING 1 -j VAGUS_NAT
      iptables-legacy -t nat -I OUTPUT 1 -j VAGUS_NAT

  **Both jumps are required.** `PREROUTING` only sees packets that arrive on
  an interface — i.e. bridged add-ons. The host itself and every
  `host_network: true` container (Core, ESPHome, ...) generate their packets
  locally and traverse `OUTPUT` instead, never `PREROUTING`. Device-proven
  on the rpi3 2026-08-07 against all three client shapes (bridged add-on,
  host-network add-on, host process); a `PREROUTING`-only rule silently
  serves the bridged case and breaks Core.

  `iptables-legacy` is the binary under balena-engine, which runs
  `--iptables=true` against the same legacy tables.

  ## Under podman: one nft table

  The podman system image ships no iptables. netavark keeps its own rules in
  `table inet netavark` and never touches another table, so the same match
  lives in Vagus's own `table ip vagus`, with a nat chain on each of the two
  hooks above (`ruleset/1`). Both chains sit at priority -110, ahead of
  netavark's DNAT (`dstnat`, -100): an app publishing host port 80 would
  otherwise take `172.30.32.2:80` too, since netavark's port DNAT matches
  every local address. At -100 the winner depends on which table loaded
  first.

  The table is loaded with one `nft -f`, which the kernel applies as a single
  transaction, and the file starts by declaring and flushing the table, so a
  reload replaces the rules instead of adding to them.

  ## Idempotence

  `ensure/1` is safe to call repeatedly and re-asserts unconditionally
  rather than diffing: the DNAT rule is `-C`-probed and only added when the
  probe fails, and the chain is created only when `-S` says it is missing.
  The two jumps get a stricter check than `-C` can give — `-S <hook>` is
  parsed and a jump that is present but no longer *first* is deleted and
  re-inserted, since a jump sitting behind balena's is a jump that does
  nothing. That matters because the failure mode this guards against — a
  balena-engine restart re-writing the `nat` table — is not observable from
  here, so the callers (`Vagus.App.Gates.network/0` at boot,
  `Vagus.Engine.Manager` after a daemon start) simply call it again and let
  the probes decide.

  Gated by `config :vagus, :supervisor_nat` (only `config/target.exs` sets
  it), the same target-only convention as `:ingress_source_ip` — `:host` and
  `mix test` have neither a `172.30.32.2` nor the tools, and `ensure/1` is a
  no-op that shells out to nothing there.
  """

  require Logger

  alias Vagus.Network

  @binary "iptables-legacy"
  @table "nat"
  @chain "VAGUS_NAT"

  # The port the add-on contract hardwires (`http://supervisor/`) and Core's
  # `SUPERVISOR` env implies. Not configurable upstream, hence not here.
  @contract_port 80

  # PREROUTING for bridged add-ons, OUTPUT for host-network clients (Core).
  # Position 1 in both: balena's own `dst-type LOCAL -> DOCKER` jump matches
  # `172.30.32.2` once the anchor is bound, so ours has to be reached first.
  @jump_chains ["PREROUTING", "OUTPUT"]

  @default_port 8888

  @nft_table "vagus"
  # Ahead of netavark's DNAT at -100; see the moduledoc.
  @nft_priority -110
  # nft -f is one netlink transaction and takes no lock, so it answers at once
  # or not at all.
  @nft_timeout_ms 10_000

  @doc "Whether DNAT management is switched on (`config :vagus, :supervisor_nat`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:vagus, :supervisor_nat, false) == true

  @doc """
  Asserts the chain, the DNAT rule and both jumps (idempotent).

  Returns `:ok` when everything is in place — including when the module is
  disabled, in which case nothing is executed at all. `{:error, reason}`
  carries the first failing invocation as `{argv, output, exit_status}`;
  callers log it and carry on, since a device without DNAT still runs, it
  just loses `http://supervisor/`.

  ## Options

    * `:enabled` — override the `enabled?/0` gate (tests, and callers that
      have already decided)
    * `:ip` — the destination address to rewrite (default
      `config :vagus, :api_bind_ip`, else `Vagus.Network.supervisor_ip/0`)
    * `:port` — the port to rewrite to (default `config :vagus, :api_port`)
    * `:cmd` — 2-arity command runner `(binary, args) -> {output, status}`
    * `:engine` — the engine adapter (default `config :vagus, :engine`);
      `Vagus.Runtime.Engine.Podman` selects nft
    * `:nft_dir` — where the ruleset file is written for `nft -f`
      (default `/run/vagus`)
  """
  @spec ensure(keyword()) :: :ok | {:error, term()}
  def ensure(opts \\ []) do
    cond do
      not Keyword.get(opts, :enabled, enabled?()) -> :ok
      nft?(opts) -> with {:ok, text} <- ruleset(opts), do: load_nft(text, opts)
      true -> with {:ok, rule} <- dnat_rule(opts), do: apply_rules(rule, runner(opts))
    end
  end

  @doc """
  Removes both jumps, then flushes and deletes the chain (idempotent).

  The mirror image of `ensure/1` — the jumps go first so no packet can be
  sent to a chain that is being emptied. Same options and same return shape.
  """
  @spec teardown(keyword()) :: :ok | {:error, term()}
  def teardown(opts \\ []) do
    cond do
      not Keyword.get(opts, :enabled, enabled?()) -> :ok
      # Declaring the table first makes the delete succeed when it is absent.
      nft?(opts) -> load_nft("table ip #{@nft_table}\ndelete table ip #{@nft_table}\n", opts)
      true -> remove_rules(runner(opts))
    end
  end

  @doc """
  The nft ruleset `ensure/1` loads under podman: it creates the table when
  absent and flushes it before declaring the chains, so loading it again
  leaves exactly one copy of each rule. Same match as `dnat_rule/1`.
  """
  @spec ruleset(keyword()) :: {:ok, String.t()} | {:error, term()}
  def ruleset(opts \\ []) do
    with {:ok, ip} <- target_ip(opts),
         {:ok, port} <- target_port(opts) do
      rule = "ip daddr #{ip} tcp dport #{@contract_port} dnat to #{ip}:#{port}"

      {:ok,
       """
       table ip #{@nft_table}
       flush table ip #{@nft_table}
       table ip #{@nft_table} {
       \tchain prerouting {
       \t\ttype nat hook prerouting priority #{@nft_priority}; policy accept;
       \t\t#{rule}
       \t}
       \tchain output {
       \t\ttype nat hook output priority #{@nft_priority}; policy accept;
       \t\t#{rule}
       \t}
       }
       """}
    end
  end

  @doc """
  The `-d ... -j DNAT ...` rule body, without the `-A`/`-C` verb.

  Exposed so the exact argv can be asserted without running anything.
  `{:error, :no_rewrite_needed}` when the API port *is* the contract port —
  a `80 -> 80` DNAT is a no-op the kernel would still evaluate per packet,
  and reaching that state means `:api_port` and this module disagree about
  who owns 80.
  """
  @spec dnat_rule(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def dnat_rule(opts \\ []) do
    with {:ok, ip} <- target_ip(opts),
         {:ok, port} <- target_port(opts) do
      {:ok,
       [
         "-d",
         ip,
         "-p",
         "tcp",
         "--dport",
         to_string(@contract_port),
         "-j",
         "DNAT",
         "--to-destination",
         "#{ip}:#{port}"
       ]}
    end
  end

  @doc "The own chain's name (`VAGUS_NAT`)."
  @spec chain() :: String.t()
  def chain, do: @chain

  ## Rule assertion

  defp apply_rules(rule, cmd) do
    with :ok <- ensure_chain(cmd),
         :ok <- ensure_rule(cmd, rule) do
      Enum.reduce_while(@jump_chains, :ok, fn hook, :ok ->
        case ensure_jump(cmd, hook) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp ensure_chain(cmd) do
    if run?(cmd, ["-t", @table, "-S", @chain]) do
      :ok
    else
      run(cmd, ["-t", @table, "-N", @chain])
    end
  end

  defp ensure_rule(cmd, rule) do
    if run?(cmd, ["-t", @table, "-C", @chain] ++ rule) do
      :ok
    else
      run(cmd, ["-t", @table, "-A", @chain] ++ rule)
    end
  end

  # `-C` is not enough here: it matches the jump at *any* position, and this
  # module's contract is position 1 (see @jump_chains). A jump that something
  # else has since overtaken is therefore deleted and re-inserted rather than
  # accepted.
  defp ensure_jump(cmd, hook) do
    case jump_position(cmd, hook) do
      :first ->
        :ok

      :absent ->
        insert_jump(cmd, hook)

      :later ->
        with :ok <- run(cmd, ["-t", @table, "-D", hook, "-j", @chain]),
             do: insert_jump(cmd, hook)
    end
  end

  defp insert_jump(cmd, hook), do: run(cmd, ["-t", @table, "-I", hook, "1", "-j", @chain])

  # `-S <hook>` is iptables-save syntax: the chain policy, then one `-A` line
  # per rule in evaluation order. A hook we cannot list is reported `:absent`
  # so the insert runs and reports the real failure.
  defp jump_position(cmd, hook) do
    with {out, 0} <- cmd.(@binary, ["-t", @table, "-S", hook]),
         [_ | _] = rules <- rule_lines(out) do
      cond do
        jump?(hd(rules), hook) -> :first
        Enum.any?(rules, &jump?(&1, hook)) -> :later
        true -> :absent
      end
    else
      _no_rules_or_failure -> :absent
    end
  end

  defp rule_lines(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, ["-A ", "-I "]))
  end

  # Exactly our jump and nothing else: a line carrying match criteria on the
  # way to @chain is somebody else's rule.
  defp jump?(line, hook) do
    case String.split(line, " ", trim: true) do
      [verb, ^hook, "-j", @chain] when verb in ["-A", "-I"] -> true
      _other -> false
    end
  end

  ## Teardown

  defp remove_rules(cmd) do
    with :ok <- remove_jumps(cmd) do
      if run?(cmd, ["-t", @table, "-S", @chain]) do
        with :ok <- run(cmd, ["-t", @table, "-F", @chain]),
             do: run(cmd, ["-t", @table, "-X", @chain])
      else
        :ok
      end
    end
  end

  defp remove_jumps(cmd) do
    Enum.reduce_while(@jump_chains, :ok, fn hook, :ok ->
      if run?(cmd, ["-t", @table, "-C", hook, "-j", @chain]) do
        case run(cmd, ["-t", @table, "-D", hook, "-j", @chain]) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  ## nft

  defp nft?(opts),
    do:
      Keyword.get_lazy(opts, :engine, fn -> Application.get_env(:vagus, :engine) end) ==
        Vagus.Runtime.Engine.Podman

  # A file rather than `-f -`: neither System.cmd nor MuonTrap can close a
  # child's stdin, which nft needs to see the end of the ruleset. One file per
  # call, so two concurrent loads never read each other's half-written text.
  # The directory is tmpfs owned by root, never request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp load_nft(text, opts) do
    dir = Keyword.get(opts, :nft_dir, "/run/vagus")
    path = Path.join(dir, "vagus-nat-#{System.unique_integer([:positive])}.nft")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, text) do
      try do
        run(Keyword.get(opts, :cmd, &nft_cmd/2), "nft", ["-f", path])
      after
        File.rm(path)
      end
    else
      {:error, reason} ->
        Logger.warning("Vagus.Network.Nat: #{path} not written: #{inspect(reason)}")
        {:error, {:nft_file, reason}}
    end
  end

  # Bounded unlike the iptables path: a stuck call would hold the boot gate,
  # and an abandoned nft still finishes or fails its one transaction alone.
  # Not MuonTrap.cmd/3, whose output acks can race the child's exit and kill
  # the caller with `:epipe` (see `Vagus.Runtime.Podman.Cmd`).
  @doc false
  @spec nft_cmd(String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  def nft_cmd(bin, args) do
    case Vagus.BoundedCall.run(fn -> Vagus.Host.Cmd.run(bin, args) end, @nft_timeout_ms) do
      {out, status} when is_binary(out) -> {out, status}
      {:error, :attempt_timeout} -> {"#{bin}: no answer in #{@nft_timeout_ms} ms", 124}
      {:error, {:exit, reason}} -> {"#{bin}: #{inspect(reason)}", 1}
    end
  end

  ## Invocation

  # A probe: `-C`/`-S` answer "is it there" with the exit status, and a
  # nonzero one is the expected answer, never an error to report.
  defp run?(cmd, args) do
    match?({_out, 0}, cmd.(@binary, args))
  end

  defp run(cmd, args), do: run(cmd, @binary, args)

  defp run(cmd, bin, args) do
    case cmd.(bin, args) do
      {_out, 0} ->
        :ok

      {out, status} ->
        Logger.warning(
          "Vagus.Network.Nat: #{bin} #{Enum.join(args, " ")} failed (#{status}): " <>
            String.trim(out)
        )

        {:error, {args, String.trim(out), status}}
    end
  end

  defp runner(opts), do: Keyword.get(opts, :cmd, &default_cmd/2)

  # `Vagus.Host.Cmd.run/2` carries the missing-binary rescue (a real
  # possibility on a system built without the legacy userland). Public (not
  # private) so a test can drive that path through this seam, the same
  # "@doc false, but def" arrangement `Vagus.Provisioner.default_cmd/2` uses.
  @doc false
  @spec default_cmd(String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  def default_cmd(bin, args), do: Vagus.Host.Cmd.run(bin, args)

  ## Config

  defp target_ip(opts) do
    value =
      Keyword.get_lazy(opts, :ip, fn ->
        Application.get_env(:vagus, :api_bind_ip) || Network.supervisor_ip()
      end)

    case Network.parse_ip(value) do
      {:ok, ip} ->
        {:ok, Network.format_ip(ip)}

      :error ->
        Logger.warning(
          "Vagus.Network.Nat: #{inspect(value)} is not an IP address — " <>
            "no DNAT rule installed, add-ons cannot reach http://supervisor/"
        )

        {:error, {:invalid_ip, value}}
    end
  end

  defp target_port(opts) do
    case Keyword.get_lazy(opts, :port, fn ->
           Application.get_env(:vagus, :api_port, @default_port)
         end) do
      @contract_port ->
        Logger.warning(
          "Vagus.Network.Nat: :api_port is #{@contract_port}, the port the DNAT rule " <>
            "redirects FROM — the listener still holds it, so no rule is installed"
        )

        {:error, :no_rewrite_needed}

      port when is_integer(port) and port > 0 and port < 65_536 ->
        {:ok, port}

      other ->
        Logger.warning("Vagus.Network.Nat: :api_port #{inspect(other)} is not a valid port")
        {:error, {:invalid_port, other}}
    end
  end
end
