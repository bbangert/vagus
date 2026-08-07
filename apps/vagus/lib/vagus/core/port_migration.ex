defmodule Vagus.Core.PortMigration do
  @moduledoc """
  A one-shot rewrite of the port Core has *persisted* for itself, run before
  Core is started (`Vagus.Core.Lifecycle.start/1`).

  ## Why this exists

  Core 2026.8 keeps its HTTP configuration in a store of its own —
  `<config>/.storage/http`, written by
  `homeassistant/components/http/config.py`'s `HTTPConfigStore`:

      {"version": 2, "minor_version": 2, "key": "http",
       "data": {"stable": {"server_port": 8123, ...},
                "pending": null,
                "yaml_migration_done": true}}

  `stable` is the last configuration Core confirmed as working, `pending` an
  unconfirmed one staged for its next start. On startup Core applies
  `pending` (if it is set and hasn't already failed a trial) else `stable`,
  and **that stored value wins outright** — `default_server_port()` (80
  whenever `SUPERVISOR` is in the environment, `http/const.py`'s
  `SUPERVISOR_DEFAULT_PORT`) is only ever consulted to build a *default*
  config for a device that has no store yet.

  Vagus fleet boards do have one, and it says 8123. That is the fossil of
  this repo's own pre-`Vagus.API.Listener` behaviour: the Supervisor API
  wildcard-bound `0.0.0.0:80`, Core's first-install bind of port 80 failed,
  Core fell back to `_DEFAULT_CONFIG_LEGACY_PORT` (8123) — and then
  persisted that fallback as `stable`. Freeing port 80 (`Vagus.Network.Nat`
  plus the listener move) is therefore necessary but not sufficient: an
  already-installed Core reads 8123 out of its store and stays there
  forever. Upstream has no migration path for this and never needed one (a
  real HAOS Supervisor never held port 80), and the socket API
  (`Vagus.Core.HttpConfig`'s `GET /api/core/http_config`) is read-only —
  there is no supervisor-side call that moves Core's port. Editing the store
  is the only lever.

  ## What it does, and the conditions it does it under

  Every condition must hold, and each is a reason to stay out of the way:

    1. **The marker is absent.** One shot per device, forever — see below.
    2. **The store exists and parses.** No store means a Core that has never
       run here, which will pick 80 from `default_server_port()` on its own.
    3. **`data.pending` is `null`.** A staged trial config is a decision the
       user is in the middle of making, with a five-minute auto-revert timer
       attached to it; Core would apply it in preference to `stable` anyway.
    4. **`data.stable.server_port` is #{8123}.** That exact value is the
       fossil above. Any other port is a port somebody chose.

  The rewrite changes that one field to #{80} and nothing else: the store is
  decoded, the single value replaced, and re-encoded, so `created_at`, the
  SSL settings, trusted proxies, `yaml_migration_done` and the version
  envelope all survive. The write is a sibling tmp file plus `File.rename/2`
  (the `Vagus.Addon.State` idiom) so a power loss mid-write can never leave
  Core with a truncated store, and the original file's mode is carried onto
  the replacement — Core writes this store `private=True` (0600), and a
  migration must not widen that.

  JSON is emitted 2-space-pretty because that is what Core itself writes
  (`homeassistant/helpers/json.py` encodes `.storage` with orjson's
  `OPT_INDENT_2`). Byte-level fidelity is not a goal and not achievable —
  Core rewrites the whole file from its own in-memory state at the next
  `_async_persist()` — but valid JSON with every field preserved is
  mandatory: this file is the only thing standing between the device and a
  Core that will not start.

  ## The marker, and when it is *not* written

  The marker is a plain file on `/data` (`config :vagus,
  :core_port_migration_marker`, target-only — unset on host and in the test
  suite, which makes this whole module a no-op there, the same
  path-presence gate `Vagus.Core.Transport`'s socket uses). Its existence,
  not its contents, is the signal; it carries a one-line note purely so a
  device forensics session can see what happened and when.

  It is written when the migration runs **and** when the stored port is
  already #{80} — in the second case there is nothing left to migrate, so
  recording it costs one `File.write/2` per device and buys back the
  `File.read/2` of Core's store on every subsequent `start/1`.

  It is deliberately **not** written when the store is missing, unreadable,
  unparseable, has a pending config, or holds some third port. Those are all
  states that can change: a device whose Core has not been installed yet, or
  whose user later reverts to the legacy port through the UI and thereby
  re-persists a `stable` 8123, still gets its single migration when the
  conditions are actually met. The "some other port" case is the load-bearing
  one — writing the marker there would burn the one shot on a device whose
  user had deliberately chosen, say, 8080, and it would be burnt at the exact
  moment the migration could not have run anyway.

  ## Failure is always a no-op

  Nothing here can fail a Core start. Every error path logs (warning for
  anything unexpected, debug for the ordinary "nothing to do" cases) and
  returns; `Vagus.Core.Lifecycle` ignores the return value entirely. The
  fallback if this module does nothing at all is the status quo — Core keeps
  serving 8123 — and the fallback if the rewrite lands but port 80 turns out
  to be taken is Core's own bind-failure chain, which drops back to 8123 by
  itself. Neither outcome is a device that will not boot.

  ## Options

    * `:port_migration_marker` - the marker path. Defaults to
      `config :vagus, :core_port_migration_marker`; `nil` disables the
      module.
    * `:homeassistant_path` - the host-side directory of Core's `/config`
      volume, i.e. where `.storage/http` is looked for. Defaults to
      `Vagus.Core.Container.config_path/1` (the engine data root's
      `volumes/vagus-core-config/_data`), the same injection key
      `Vagus.Core.Lifecycle`'s safe-mode marker and
      `Vagus.Backend.Host.DiskBreakdown` use for that volume.
  """

  require Logger

  alias Vagus.Core.Container

  # Core's own storage key for the `http` integration — `Store(STORAGE_KEY)`
  # with `STORAGE_KEY = DOMAIN`, so the file is literally named after it.
  @store_relative_path ".storage/http"
  @tmp_suffix ".vagus-tmp"

  # The same two constants `Vagus.Addon.Ports.reserved_host_ports/0` reserves,
  # for the same reason and from the same source: 80 is Core's port under a
  # Supervisor (`SUPERVISOR_DEFAULT_PORT`), 8123 its bind-failure fallback
  # (`_DEFAULT_CONFIG_LEGACY_PORT`, and `Vagus.Core.HttpConfig.defaults/0`'s
  # port). They are duplicated rather than shared because both places want a
  # compile-time constant, and neither may read the other's cache.
  @target_port 80
  @legacy_port 8123

  @typedoc """
  `:migrated` when the store was rewritten; `{:skipped, reason}` when a
  condition said not to; `{:error, reason}` when the rewrite itself failed.
  """
  @type outcome :: :migrated | {:skipped, term()} | {:error, term()}

  @doc "The port Core is migrated *to* (`#{@target_port}`)."
  @spec target_port() :: pos_integer()
  def target_port, do: @target_port

  @doc "The persisted port that triggers a migration (`#{@legacy_port}`)."
  @spec legacy_port() :: pos_integer()
  def legacy_port, do: @legacy_port

  @doc """
  Runs the one-shot migration if — and only if — all four conditions in the
  moduledoc hold.

  Never raises, and every outcome is safe to ignore.
  """
  @spec run(keyword()) :: outcome()
  def run(opts \\ []) do
    case marker_path(opts) do
      nil ->
        Logger.debug(
          "Vagus.Core.PortMigration: no marker path configured (host/test) — not migrating"
        )

        {:skipped, :disabled}

      marker ->
        run_with_marker(marker, opts)
    end
  end

  ## Internals

  defp marker_path(opts) do
    Keyword.get_lazy(opts, :port_migration_marker, fn ->
      Application.get_env(:vagus, :core_port_migration_marker)
    end)
  end

  # The marker check comes first so a disabled/already-migrated device never
  # even resolves the engine data root, let alone reads Core's store.
  defp run_with_marker(marker, opts) do
    if File.exists?(marker) do
      {:skipped, :already_migrated}
    else
      migrate(marker, Path.join(Container.config_path(opts), @store_relative_path))
    end
  end

  defp migrate(marker, path) do
    with {:ok, body} <- read_store(path),
         {:ok, stored} <- decode_store(path, body),
         {:ok, port} <- stable_port(path, stored) do
      apply_port(port, marker, path, stored)
    end
  end

  # Both paths are config/module-derived — the engine data root joined with
  # constant volume/store names, or the `:core_port_migration_marker` config
  # key. No request input reaches either; the `opts` seams are test-only.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_store(path) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, body}

      {:error, :enoent} ->
        Logger.debug(
          "Vagus.Core.PortMigration: #{path} does not exist — Core has not stored an " <>
            "HTTP config on this device yet, nothing to migrate"
        )

        {:skipped, :no_store}

      {:error, reason} ->
        Logger.warning(
          "Vagus.Core.PortMigration: could not read #{path} (#{inspect(reason)}) — " <>
            "leaving Core's stored port alone"
        )

        {:skipped, {:unreadable, reason}}
    end
  end

  defp decode_store(path, body) do
    case Jason.decode(body) do
      {:ok, stored} when is_map(stored) ->
        {:ok, stored}

      {:ok, _other} ->
        Logger.warning(
          "Vagus.Core.PortMigration: #{path} is not a JSON object — leaving it alone"
        )

        {:skipped, :unexpected_shape}

      {:error, %Jason.DecodeError{position: position}} ->
        # The position, never the data: this file is Core-written and can
        # hold certificate paths, and `inspect/1` on the error would spill
        # its bytes into the device's fixed-size ring buffer (the same
        # discipline `Vagus.Core.HttpConfig` applies to response bodies).
        Logger.warning(
          "Vagus.Core.PortMigration: #{path} is not valid JSON " <>
            "(#{inspect({:position, position})}) — leaving it alone"
        )

        {:skipped, :unparseable}
    end
  end

  defp stable_port(path, %{"data" => %{"stable" => %{"server_port" => port}} = data})
       when is_integer(port) do
    if pending?(data) do
      Logger.info(
        "Vagus.Core.PortMigration: #{path} has a pending HTTP config staged — " <>
          "leaving Core's stored port alone (the user is mid-decision)"
      )

      {:skipped, :pending_config}
    else
      {:ok, port}
    end
  end

  defp stable_port(path, _stored) do
    Logger.warning(
      "Vagus.Core.PortMigration: #{path} has no readable data.stable.server_port — " <>
        "leaving it alone"
    )

    {:skipped, :unexpected_shape}
  end

  # An absent key is treated as "no pending config", matching Core: it writes
  # the key on every persist, so absence can only mean a store older than
  # this shape, which by definition has nothing staged.
  defp pending?(%{"pending" => nil}), do: false
  defp pending?(%{"pending" => _config}), do: true
  defp pending?(_data), do: false

  defp apply_port(@legacy_port, marker, path, stored) do
    case rewrite(path, stored) do
      :ok ->
        Logger.info(
          "Vagus.Core.PortMigration: rewrote Core's stored stable server_port " <>
            "#{@legacy_port} -> #{@target_port} in #{path} — Core binds the new port at " <>
            "its next start"
        )

        write_marker(marker, "migrated #{@legacy_port} -> #{@target_port}")
        :migrated

      {:error, reason} = error ->
        Logger.warning(
          "Vagus.Core.PortMigration: could not rewrite #{path} (#{inspect(reason)}) — " <>
            "Core keeps serving #{@legacy_port}; will retry at the next Core start"
        )

        error
    end
  end

  defp apply_port(@target_port, marker, _path, _stored) do
    Logger.debug(
      "Vagus.Core.PortMigration: Core's stored stable server_port is already " <>
        "#{@target_port} — recording the marker so this check stops running"
    )

    write_marker(marker, "already #{@target_port}")
    {:skipped, :already_target}
  end

  defp apply_port(port, _marker, _path, _stored) do
    Logger.info(
      "Vagus.Core.PortMigration: Core's stored stable server_port is #{port}, not " <>
        "#{@legacy_port} — leaving it alone and NOT recording the marker (see the moduledoc)"
    )

    {:skipped, {:other_port, port}}
  end

  # tmp-then-rename in the same directory (`Vagus.Addon.State`'s idiom):
  # `File.rename/2` within one filesystem is atomic, so Core can only ever
  # observe the old store or the new one.
  #
  # sobelow_skip ["Traversal.FileModule"]
  defp rewrite(path, stored) do
    tmp = path <> @tmp_suffix
    updated = put_in(stored, ["data", "stable", "server_port"], @target_port)

    result =
      with {:ok, json} <- Jason.encode(updated, pretty: true),
           :ok <- File.write(tmp, json),
           :ok <- copy_mode(path, tmp) do
        File.rename(tmp, path)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> cleanup(tmp, reason)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp cleanup(tmp, reason) do
    _ = File.rm(tmp)
    {:error, reason}
  end

  # Core writes this store `private=True` (0600). A replacement created under
  # this process's umask would be world-readable, so the original's mode is
  # carried over; a store we cannot stat is one we are about to fail on
  # anyway, so that case just leaves the default mode alone.
  #
  # sobelow_skip ["Traversal.FileModule"]
  defp copy_mode(path, tmp) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> File.chmod(tmp, Bitwise.band(mode, 0o7777))
      {:error, _reason} -> :ok
    end
  end

  # Always `:ok`: a marker that cannot be written means this runs again next
  # boot, which is harmless — the rewritten store then hits the
  # already-#{@target_port} branch.
  #
  # sobelow_skip ["Traversal.FileModule"]
  defp write_marker(marker, note) do
    with :ok <- File.mkdir_p(Path.dirname(marker)),
         :ok <- File.write(marker, "#{note} at #{DateTime.to_iso8601(DateTime.utc_now())}\n") do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "Vagus.Core.PortMigration: could not write the marker #{marker} " <>
            "(#{inspect(reason)}) — Core's stored port will be re-checked at the next start"
        )

        :ok
    end
  end
end
