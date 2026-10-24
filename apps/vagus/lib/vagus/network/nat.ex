defmodule Vagus.Network.Nat do
  @moduledoc """
  Vagus's own nft table and the forwarding sysctls bridged apps need: the
  DNAT that keeps `http://supervisor/` working after the Supervisor-API
  listener moved off port 80, and the filters that let the board route for
  the `hassio` bridge and nothing else.

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

  ## Forwarding

  Nothing on the board turns IPv4 forwarding on (balena's daemon did), and
  without it published ports and container egress are dead. netavark's
  localhost port publishing (`127.0.0.1:<port>`) also needs
  `route_localnet` on `hassio`, as the DNAT'd packet keeps its loopback
  source. Both are written here (`:sysctl_root`), after the table is in
  place, so forwarding never runs unfiltered.

  The `forward` chain then stands in for balena's `FORWARD` policy drop,
  since netavark's own chain accepts:

    * forwarding between two interfaces neither of which is `hassio` (eth0
      to wlan0, ...) is dropped: the board is no router;
    * a new connection entering `hassio` from another interface is dropped
      unless conntrack shows it was DNAT'd, i.e. a published port, so a LAN
      host routing `172.30.32.0/23` via the board reaches no app directly.

  Traffic between containers, container egress and replies pass. The flag
  test is `ct status & dnat == 0`: `ct status != dnat` compares the whole
  status word, matches nearly every connection, and drops published ports
  too.

  With `route_localnet` on, a container could reach the host's loopback
  services by routing to `127.0.0.0/8` through its gateway. The
  `prerouting_filter` chain drops what arrives on `hassio` for a loopback
  address unless it belongs to a DNAT'd connection: the replies of a
  localhost published port do. It runs after conntrack (-200), which it
  reads, and before routing.

  ## Lab interfaces

  `Vagus.Network.Lab` routes a device wired to an extra NIC out through the
  primary interface: per `{lab, primary}` pair the forward chain accepts
  `lab -> primary` and its replies ahead of the drops, and a `postrouting`
  chain masquerades it. The list lives in `:persistent_term` (`set_lab/2`)
  so every later render, including the one `ensure_loaded/1` makes for a
  bridged start, keeps the rules; an empty list renders the baseline table.

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
  # After conntrack (-200) has attached the connection the rule reads.
  @prerouting_filter_priority "mangle"
  # nft -f is one netlink transaction and takes no lock, so it answers at once
  # or not at all.
  @nft_timeout_ms 10_000
  @sigkill_delay_ms 1_000
  @kill_budget_ms @sigkill_delay_ms + 1_000

  @loaded_key {__MODULE__, :loaded}
  @lab_key {__MODULE__, :lab}
  @lock_retries 8

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
    * `:sysctl_root` — where the sysctl files are written (default
      `/proc/sys`)
    * `:lab` — `{lab_ifname, primary_ifname}` pairs to forward and masquerade
      (default: the list `set_lab/2` stored); a name failing `valid_ifname?/1`
      is `{:error, :invalid_ifname}` and nothing is loaded

  `{:error, :busy}` when another load holds the table past `:lock_retries`.

  Test seams: `:loaded_key`, `:lab_key`.
  """
  @spec ensure(keyword()) :: :ok | {:error, term()}
  def ensure(opts \\ []) do
    if Keyword.get(opts, :enabled, enabled?()),
      do: serialized(opts, fn -> load(opts) end),
      else: :ok
  end

  @doc """
  Loads the table with `lab` and, once it is in, stores the list every later
  render uses. A failed load leaves the stored list as it was.
  """
  @spec set_lab([{String.t(), String.t()}], keyword()) :: :ok | {:error, term()}
  def set_lab(lab, opts \\ []) when is_list(lab) do
    key = Keyword.get(opts, :lab_key, @lab_key)

    with :ok <- check_lab(lab) do
      serialized(opts, fn ->
        previous = :persistent_term.get(key, [])

        case maybe_load(Keyword.put(opts, :lab, lab)) do
          :ok ->
            :persistent_term.put(key, lab)

          {:error, _} = error ->
            # A load that failed after nft (the sysctl step) leaves the new
            # rules in the kernel: put the old list back there too so it
            # matches the stored one. Best effort.
            _ = maybe_load(Keyword.put(opts, :lab, previous))
            error
        end
      end)
    end
  end

  defp maybe_load(opts),
    do: if(Keyword.get(opts, :enabled, enabled?()), do: load(opts), else: :ok)

  defp load(opts) do
    with {:ok, text} <- ruleset(opts),
         :ok <- load_nft(text, opts),
         :ok <- enable_forwarding(opts) do
      :persistent_term.put(Keyword.get(opts, :loaded_key, @loaded_key), true)
    end
  end

  # The table has three writers (the boot gate, a bridged start's
  # ensure_loaded, Lab), and each renders the stored list before its load
  # lands: unserialized, a render taken before another writer's commit loads
  # after it and the kernel no longer matches the list. The retries' backoff
  # (~16 s on average, 32 s at most for the default) outlasts one bounded
  # nft run with its kill (12 s).
  defp serialized(opts, fun) do
    lock = {{__MODULE__, Keyword.get(opts, :lab_key, @lab_key)}, self()}

    case :global.trans(lock, fun, [node()], Keyword.get(opts, :lock_retries, @lock_retries)) do
      :aborted -> {:error, :busy}
      result -> result
    end
  end

  @spec lab(keyword()) :: [{String.t(), String.t()}]
  def lab(opts \\ []),
    do:
      Keyword.get_lazy(opts, :lab, fn ->
        :persistent_term.get(Keyword.get(opts, :lab_key, @lab_key), [])
      end)

  # Names are interpolated into the nft ruleset. 15 is IFNAMSIZ minus the
  # NUL; the leading alphanumeric rules out "." and "..", which the kernel
  # refuses as names.
  @ifname ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,14}\z/

  @spec valid_ifname?(term()) :: boolean()
  def valid_ifname?(name) when is_binary(name), do: Regex.match?(@ifname, name)
  def valid_ifname?(_), do: false

  @doc """
  `:ok` once `ensure/1` has succeeded in this VM, else `ensure/1` now. The
  start of a bridged container calls it: without the filters the LAN
  reaches the container through netavark's accepting policy, and without
  the sysctls its ports and egress are dead, so the start fails instead and
  the next start retries. Nothing undoes either within a boot (netavark
  never touches another table, and Vagus's dummy port keeps the bridge), so
  a success holds until the next boot. Same options as `ensure/1`.
  """
  @spec ensure_loaded(keyword()) :: :ok | {:error, term()}
  def ensure_loaded(opts \\ []) do
    cond do
      not Keyword.get(opts, :enabled, enabled?()) -> :ok
      :persistent_term.get(Keyword.get(opts, :loaded_key, @loaded_key), false) -> :ok
      true -> ensure(opts)
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
    lab = lab(opts)

    with :ok <- check_lab(lab),
         {:ok, ip} <- target_ip(opts),
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
       #{lab_forward(lab)}#{agentnet_forward(opts)}\t\tiifname != "#{bridge}" oifname != "#{bridge}" drop
       \t\toifname "#{bridge}" iifname != "#{bridge}" ct state new ct status & dnat == 0 drop
       \t}
       \tchain prerouting_filter {
       \t\ttype filter hook prerouting priority #{@prerouting_filter_priority}; policy accept;
       \t\tiifname "#{bridge}" ip daddr 127.0.0.0/8 ct status & dnat == 0 drop
       \t}
       #{lab_postrouting(lab)}}
       """}
    end
  end

  defp check_lab(lab) do
    valid? = fn
      {lab_if, primary} -> valid_ifname?(lab_if) and valid_ifname?(primary)
      _ -> false
    end

    if Enum.all?(lab, valid?), do: :ok, else: {:error, :invalid_ifname}
  end

  defp lab_forward(lab) do
    Enum.map_join(lab, fn {lab_if, primary} ->
      ~s(\t\tiifname "#{lab_if}" oifname "#{primary}" accept\n) <>
        ~s(\t\tiifname "#{primary}" oifname "#{lab_if}" ct state established,related accept\n)
    end)
  end

  # The baseline already drops every other interface into `agentnet`, but
  # lets `hassio` route there: no `hassio` app may reach the memory DB. The
  # host itself goes out through OUTPUT and is untouched. Intra-bridge
  # traffic is accepted first in case `br_netfilter` hands it to this hook,
  # where the baseline would drop it.
  defp agentnet_forward(opts) do
    if Vagus.Network.Agentnet.enabled?(opts) do
      net = Vagus.Network.Agentnet.name()

      ~s(\t\tiifname "#{net}" oifname "#{net}" accept\n) <>
        ~s(\t\toifname "#{net}" iifname != "#{net}" ct state new drop\n)
    else
      ""
    end
  end

  defp lab_postrouting([]), do: ""

  defp lab_postrouting(lab) do
    rules =
      Enum.map_join(lab, fn {lab_if, primary} ->
        ~s(\t\tiifname "#{lab_if}" oifname "#{primary}" masquerade\n)
      end)

    "\tchain postrouting {\n\t\ttype nat hook postrouting priority srcnat; policy accept;\n" <>
      rules <> "\t}\n"
  end

  ## sysctls

  # The bridge's own entry exists only once the bridge does: a start before
  # that fails here and is retried with the next.
  # sobelow_skip ["Traversal.FileModule"]
  defp enable_forwarding(opts) do
    root = Keyword.get(opts, :sysctl_root, "/proc/sys")

    Enum.reduce_while(
      ["net/ipv4/ip_forward", "net/ipv4/conf/#{Network.name()}/route_localnet"],
      :ok,
      fn key, :ok ->
        path = Path.join(root, key)

        case File.write(path, "1") do
          :ok ->
            {:cont, :ok}

          {:error, reason} ->
            Logger.warning("Vagus.Network.Nat: #{path} not set to 1: #{inspect(reason)}")
            {:halt, {:error, {:sysctl, key, reason}}}
        end
      end
    )
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

  # Under muontrap, so a timed-out nft is killed rather than left to commit
  # its transaction after the caller has rolled back or released the table
  # lock: closing a plain port only closes its pipes. The port closes without
  # waiting for the child, so a timeout waits out the kill before answering.
  # BoundedCall stays as the outer bound (MuonTrap's own timeout has been
  # seen not to fire, see `Vagus.Dist`); killing its task closes the port,
  # which kills the child too.
  @doc false
  @spec nft_cmd(String.t(), [String.t()], timeout()) :: {String.t(), non_neg_integer()}
  def nft_cmd(bin, args, timeout_ms \\ @nft_timeout_ms) do
    fun = fn ->
      MuonTrap.cmd(bin, args,
        stderr_to_stdout: true,
        timeout: timeout_ms,
        delay_to_sigkill: @sigkill_delay_ms
      )
    end

    case Vagus.BoundedCall.run(fun, timeout_ms + @kill_budget_ms) do
      {out, status} when is_integer(status) ->
        {out, status}

      {_out, :timeout} ->
        Process.sleep(@kill_budget_ms)
        {"#{bin}: no answer in #{timeout_ms} ms", 124}

      {:error, :attempt_timeout} ->
        Process.sleep(@kill_budget_ms)
        {"#{bin}: no answer in #{timeout_ms} ms", 124}

      {:error, {:exit, {%ErlangError{original: reason}, _stack}}} ->
        {"#{bin}: #{inspect(reason)}", 127}

      {:error, {:exit, reason}} ->
        {"#{bin}: #{inspect(reason)}", 1}
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
