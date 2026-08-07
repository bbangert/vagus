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

  ## The rules

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

  `iptables-legacy` — not `iptables`/`nft` — is the binary: the target
  systems are built without nftables (`shared/linux-containers.config`) and
  ship the legacy userland via `vagus-balena-engine`. balena-engine itself
  runs `--iptables=true` against the same legacy tables.

  ## Idempotence

  `ensure/1` is safe to call repeatedly and re-asserts unconditionally
  rather than diffing: every rule is `-C`-probed and only added when the
  probe fails, and the chain is created only when `-S` says it is missing.
  That matters because the failure mode this guards against — a
  balena-engine restart re-writing the `nat` table — is not observable from
  here, so the callers (`Vagus.Addon.BootStarter` at boot,
  `Vagus.Engine.Manager` after a daemon start) simply call it again and let
  the probes decide.

  Gated by `config :vagus, :supervisor_nat` (only `config/target.exs` sets
  it), the same target-only convention as `:ingress_source_ip` — `:host` and
  `mix test` have neither a `172.30.32.2` nor an `iptables-legacy`, and
  `ensure/1` is a no-op that shells out to nothing there.
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
  """
  @spec ensure(keyword()) :: :ok | {:error, term()}
  def ensure(opts \\ []) do
    if Keyword.get(opts, :enabled, enabled?()) do
      with {:ok, rule} <- dnat_rule(opts), do: apply_rules(rule, runner(opts))
    else
      :ok
    end
  end

  @doc """
  Removes both jumps, then flushes and deletes the chain (idempotent).

  The mirror image of `ensure/1` — the jumps go first so no packet can be
  sent to a chain that is being emptied. Same options and same return shape.
  """
  @spec teardown(keyword()) :: :ok | {:error, term()}
  def teardown(opts \\ []) do
    if Keyword.get(opts, :enabled, enabled?()) do
      remove_rules(runner(opts))
    else
      :ok
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

  defp ensure_jump(cmd, hook) do
    if run?(cmd, ["-t", @table, "-C", hook, "-j", @chain]) do
      :ok
    else
      # Position 1, not `-A`: see @jump_chains.
      run(cmd, ["-t", @table, "-I", hook, "1", "-j", @chain])
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

  ## Invocation

  # A probe: `-C`/`-S` answer "is it there" with the exit status, and a
  # nonzero one is the expected answer, never an error to report.
  defp run?(cmd, args) do
    match?({_out, 0}, cmd.(@binary, args))
  end

  defp run(cmd, args) do
    case cmd.(@binary, args) do
      {_out, 0} ->
        :ok

      {out, status} ->
        Logger.warning(
          "Vagus.Network.Nat: #{@binary} #{Enum.join(args, " ")} failed (#{status}): " <>
            String.trim(out)
        )

        {:error, {args, String.trim(out), status}}
    end
  end

  defp runner(opts), do: Keyword.get(opts, :cmd, &default_cmd/2)

  # The binary and every argument are module constants or config-derived
  # addresses/ports — no request input reaches this. Public (not private) so
  # a test can exercise the missing-binary path directly, the same
  # "@doc false, but def" seam `Vagus.Provisioner.default_cmd/2` uses.
  # sobelow_skip ["CI.System"]
  @doc false
  @spec default_cmd(String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  def default_cmd(bin, args) do
    System.cmd(bin, args, stderr_to_stdout: true)
  rescue
    # `System.cmd/3` raises (rather than returning a status) when the binary
    # is missing or unusable — a real possibility on a system built without
    # the legacy userland. Exit 127 ("command not found") routes it into the
    # same nonzero-status handling as a rule that failed to apply.
    exception in [ErlangError] ->
      {"#{bin}: #{inspect(exception.original)}", 127}
  end

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
