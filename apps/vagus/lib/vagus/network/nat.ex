defmodule Vagus.Network.Nat do
  @moduledoc """
  Vagus's own nft table: the DNAT that keeps `http://supervisor/` working
  after the Supervisor-API listener moved off port 80, and the forward filter
  that keeps the LAN off the `hassio` bridge.

  ## Why this exists

  Home Assistant Core 2026.8 binds `0.0.0.0:80` on a supervised install, and
  a wildcard bind cannot coexist with anything else holding port 80 — so
  Vagus's own listener vacates it (`Vagus.API.Listener` binds
  `172.30.32.2:<:api_port>`). The add-on contract, however, hardwires port
  80: add-ons reach the Supervisor at `http://supervisor/` and Core's
  `SUPERVISOR`/`HASSIO` env carries a bare IP with port 80 implied
  (`Vagus.Core.Container`). Neither is configurable, so the port has to be
  served — by a destination rewrite rather than a listener.

  ## One nft table

  netavark keeps its own rules in `table inet netavark` and never touches
  another table, so the match lives in Vagus's own `table ip vagus`, with a
  nat chain on each of two hooks (`ruleset/1`):

    * `prerouting` sees packets that arrive on an interface, i.e. bridged
      apps;
    * `output` sees what the host itself and every `host_network: true`
      container (Core, ESPHome, ...) generate locally, which never traverse
      prerouting. A prerouting-only rule silently serves the bridged case
      and breaks Core (device-proven on the rpi3 2026-08-07 against all three
      client shapes).

  Both chains sit at priority -110, ahead of netavark's DNAT (`dstnat`,
  -100): an app publishing host port 80 would otherwise take
  `172.30.32.2:80` too, since netavark's port DNAT matches every local
  address. At -100 the winner depends on which table loaded first.

  ## Forward filter

  netavark's `FORWARD` chain has policy accept and lets anything reach a
  container's address, so a LAN host routing `172.30.32.0/23` via the board
  could open connections to every bridged app (balena's `FORWARD` policy was
  drop). The `forward` chain drops a new connection entering `hassio` from
  another interface unless conntrack shows it was DNAT'd, i.e. a published
  port. Traffic between containers, container egress and replies are not
  new-from-outside and pass. The flag test is `ct status & dnat == 0`:
  `ct status != dnat` compares the whole status word, matches nearly every
  connection, and drops published ports too.

  The table is loaded with one `nft -f`, which the kernel applies as a single
  transaction, and the file starts by declaring and flushing the table, so a
  reload replaces the rules instead of adding to them: `ensure/1` is safe to
  call repeatedly (`Vagus.App.Gates.network/0` does at every boot).

  Gated by `config :vagus, :supervisor_nat` (only `config/target.exs` sets
  it), the same target-only convention as `:ingress_source_ip` — `:host` and
  `mix test` have neither a `172.30.32.2` nor `nft`, and `ensure/1` is a
  no-op that shells out to nothing there.
  """

  require Logger

  alias Vagus.Network

  # The port the add-on contract hardwires (`http://supervisor/`) and Core's
  # `SUPERVISOR` env implies. Not configurable upstream, hence not here.
  @contract_port 80

  @default_port 8888

  @nft_table "vagus"
  # Ahead of netavark's DNAT at -100; see the moduledoc.
  @nft_priority -110
  # A drop in any base chain is final whatever netavark's accepts say, so the
  # order against netavark's own filter chain does not matter.
  @forward_priority "filter"
  # nft -f is one netlink transaction and takes no lock, so it answers at once
  # or not at all.
  @nft_timeout_ms 10_000

  @doc "Whether DNAT management is switched on (`config :vagus, :supervisor_nat`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:vagus, :supervisor_nat, false) == true

  @doc """
  Loads the ruleset (idempotent).

  Returns `:ok` when it is in place — including when the module is
  disabled, in which case nothing is executed at all. `{:error, reason}`
  carries a failed load as `{argv, output, exit_status}`; callers log it and
  carry on, since a device without DNAT still runs, it just loses
  `http://supervisor/`.

  ## Options

    * `:enabled` — override the `enabled?/0` gate (tests, and callers that
      have already decided)
    * `:ip` — the destination address to rewrite (default
      `config :vagus, :api_bind_ip`, else `Vagus.Network.supervisor_ip/0`)
    * `:port` — the port to rewrite to (default `config :vagus, :api_port`)
    * `:cmd` — 2-arity command runner `(binary, args) -> {output, status}`
    * `:nft_dir` — where the ruleset file is written for `nft -f`
      (default `/run/vagus`)
  """
  @spec ensure(keyword()) :: :ok | {:error, term()}
  def ensure(opts \\ []) do
    if Keyword.get(opts, :enabled, enabled?()) do
      with {:ok, text} <- ruleset(opts), do: load_nft(text, opts)
    else
      :ok
    end
  end

  @doc """
  The nft ruleset `ensure/1` loads: it creates the table when absent and
  flushes it before declaring the chains, so loading it again leaves exactly
  one copy of each rule.

  `{:error, :no_rewrite_needed}` when the API port *is* the contract port —
  a `80 -> 80` DNAT is a no-op the kernel would still evaluate per packet,
  and reaching that state means `:api_port` and this module disagree about
  who owns 80.
  """
  @spec ruleset(keyword()) :: {:ok, String.t()} | {:error, term()}
  def ruleset(opts \\ []) do
    with {:ok, ip} <- target_ip(opts),
         {:ok, port} <- target_port(opts) do
      rule = "ip daddr #{ip} tcp dport #{@contract_port} dnat to #{ip}:#{port}"
      bridge = Network.name()

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
       \tchain forward {
       \t\ttype filter hook forward priority #{@forward_priority}; policy accept;
       \t\toifname "#{bridge}" iifname != "#{bridge}" ct state new ct status & dnat == 0 drop
       \t}
       }
       """}
    end
  end

  ## nft

  # A file rather than `-f -`: neither System.cmd nor MuonTrap can close a
  # child's stdin, which nft needs to see the end of the ruleset. One file per
  # call, so two concurrent loads never read each other's half-written text,
  # created exclusively so nothing placed there beforehand is written through.
  # The directory is tmpfs, never request input; it is made 0700 here as well
  # because this can run before the Host's preparation does.
  # sobelow_skip ["Traversal.FileModule"]
  defp load_nft(text, opts) do
    dir = Keyword.get(opts, :nft_dir, "/run/vagus")
    path = Path.join(dir, "vagus-nat-#{System.unique_integer([:positive])}.nft")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(path, text, [:exclusive]) do
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

  # Bounded: a stuck call would hold the boot gate, and an abandoned nft
  # still finishes or fails its one transaction alone. Not MuonTrap.cmd/3,
  # whose output acks can race the child's exit and kill the caller with
  # `:epipe` (see `Vagus.Runtime.Podman.Cmd`).
  @doc false
  @spec nft_cmd(String.t(), [String.t()], timeout()) :: {String.t(), non_neg_integer()}
  def nft_cmd(bin, args, timeout_ms \\ @nft_timeout_ms) do
    case Vagus.BoundedCall.run(fn -> Vagus.Host.Cmd.run(bin, args) end, timeout_ms) do
      {out, status} when is_binary(out) -> {out, status}
      {:error, :attempt_timeout} -> {"#{bin}: no answer in #{timeout_ms} ms", 124}
      {:error, {:exit, reason}} -> {"#{bin}: #{inspect(reason)}", 1}
    end
  end

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
