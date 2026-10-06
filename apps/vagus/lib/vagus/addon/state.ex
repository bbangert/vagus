defmodule Vagus.Addon.State do
  @moduledoc """
  Tracks installed/running add-ons by slug — the per-add-on state store the
  add-on-info endpoint (`GET /addons/{slug}/info`) and the lifecycle routes
  (`docs/contract-2026.7-m4-addendum.md` §A1.1) need to answer for a slug the
  caller names (e.g. Core resolving a discovery message's provider, or the
  `POST /addons/{slug}/start` handler restarting a previously-installed
  add-on with its saved options).

  Holds the parsed `Vagus.Addon.Config`, a lifecycle `state`
  (`:started`/`:stopped`), and the add-on's stored `user_options` (the raw
  user-supplied options map, independent of the config's own defaults —
  `Vagus.Addon.OptionsSchema.effective/3` merges the two at start time).
  `Vagus.Addon.Manager` records `:started`/`:stopped` here across
  install/start/stop/restart/uninstall; `POST /addons/{slug}/options`
  updates `user_options` directly via `put_options/2` without touching
  lifecycle state or restarting the add-on.

  ## Per-install persisted settings (IW-P0-T2)

  Five more fields ride alongside `user_options` — four for the ingress +
  watchdog features (`docs/contract-2026.7-m4b-ingress-watchdog.md` §B3.1,
  §B8), plus the network port overrides:

    * `ingress_token` — the real Supervisor generates this once at install
      time (`secrets.token_urlsafe()`) and never regenerates it — unlike
      `access_token`, which is reissued every start. Here it's generated
      with `Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)`
      the first time a slug's entry is created (charset `[-_A-Za-z0-9]`,
      matching the real ingress middleware's
      `/ingress/[-_A-Za-z0-9]+/.*` route regex) and then preserved verbatim
      by every later `put/3` call, restart, and persistence round-trip —
      the same "preserve unless this is a brand-new entry" rule `put/3`
      already applies to `user_options`.
    * `ingress_port` — `nil | pos_integer()`, default `nil`. The resolved
      dynamic port; left unset here and allocated later by the ingress
      subsystem (§B3.2).
    * `ingress_panel` — boolean, default `false`. The user-facing sidebar
      toggle (independent of the config-time `ingress` capability flag).
    * `watchdog` — boolean, default `false`. The persisted watchdog
      enable/disable (§B8) — there's no `config.yaml` default for this; it's
      purely a per-install setting.
    * `ports` — `%{"<port>/<proto>" => host_port | nil}`, default `%{}`. The
      user's host-port remaps from the frontend's Network card, kept apart
      from `config.ports` (which declares *which* ports exist) and overlaid on
      it by `Vagus.Addon.Ports.effective/2`. Persisted under the `"network"`
      key, the name the wire uses.

  Two more fields ride alongside those five (phase 6 chunk A, audit E1/E2)
  — same additive pattern `ports` itself used, no version bump:

    * `boot` — `nil | "auto" | "manual"`, default `nil`. The persisted
      `POST /addons/{slug}/options` override; `nil` means "never explicitly
      set", which `Vagus.Addon.Config.effective_boot/2` falls back from to
      the add-on's own `config.boot` (itself `"auto"` by default, or
      `"manual_only"` for an add-on whose config forbids autostart
      entirely — see that function).
    * `auto_update` — `nil | boolean()`, default `nil`, falling back to
      `false` at render time (`Vagus.Addon.Info.render/4`). Vagus has **no**
      periodic auto-updater — this is stored and reported honestly, purely
      so the frontend's toggle reflects what the user actually saved, and is
      never itself acted on.

  And one more alongside those, for the device-passthrough work
  (`docs/contract-2026.7-m4-addendum.md` §A1.5):

    * `protected` — boolean, default **`true`**. The add-on's protection
      mode, set by `POST /addons/{slug}/security`. Unlike every other
      setting here it defaults to `true` and decodes tolerantly *to* `true`:
      it is the gate on `full_access`/`host_pid`/`docker_api`, so a missing
      or corrupt field has to land on the restrictive side. Read at start
      time by `Vagus.Addon.Manager.build_spec/2`; it takes effect on the
      next container create, not immediately.

  Before this, `POST /addons/{slug}/options` accepted a `boot`/`auto_update`
  key, 200'd, and silently discarded both — the exact bug class `network`
  was previously fixed for (see that field's own note above): the toggle
  animated, the save succeeded, and the value reverted on the next page
  load because there was nowhere for it to persist to.

  `put_setting/4` writes one of `ingress_port`/`ingress_panel`/`watchdog`/
  `ports`/`boot`/`auto_update`/`protected` for an already-tracked slug
  (`:error` if untracked); `ingress_token` has no setter since nothing ever
  changes it once assigned.

  ## Persistence (M4-P8-T1)

  Real Supervisor persists installed add-ons + their options to
  `sys_apps.data` so a device reboot doesn't forget them; without that, this
  emulator would need every add-on reinstalled by hand after every reboot.
  `opts[:persist_path]` (falling back to `config :vagus, :addon_state_path`)
  names a JSON file this GenServer loads from at `init/1` and write-throughs
  to after every mutating call (`put/3`, `put_options/3`, `put_setting/4`,
  `delete/2`); `nil` (the default in `config/test.exs`, and implicitly on
  `:host` where it's never set) disables persistence entirely — pure
  in-memory, the original behavior.

  The file holds `{"version": 1, "addons": {"<slug>": {"config": <raw
  Config.to_persistable/1 map>, "state": "started"|"stopped",
  "user_options": {...}, "ingress_token": "...", "ingress_port":
  null|<port>, "ingress_panel": bool, "watchdog": bool, "network":
  {"<port>/<proto>": <host_port>|null}, "boot": null|"auto"|"manual",
  "auto_update": null|bool, "protected": bool}}}`.
  `Config.parse/1` — not this module — is the single validator on reload:
  each entry's `config` is re-parsed (and its key checked against the
  parsed slug) at `init/1`, and anything invalid/mismatched, or a file
  that's missing/unreadable/not-JSON, is logged and dropped rather than
  crashing boot — a corrupt state file must never brick the device. Every
  per-install field beyond `config`/`state`/`user_options` is decoded
  tolerantly rather than invalidating the whole entry: a missing/non-string
  `ingress_token` gets a freshly generated one (old files predate the
  field), a missing/invalid `ingress_port` falls back to `nil`, a
  missing/non-boolean `ingress_panel`/`watchdog` falls back to `false`, a
  missing/non-map `network` falls back to `%{}` with its entries re-checked
  individually (a hand-edited file reaches the container spec too), and a
  missing/invalid `boot`/`auto_update` falls back to `nil` (not `false` for
  `auto_update` — see that field's decoder), and a missing/non-boolean
  `protected` falls back to `true` (the *safe* side, unlike every other
  boolean here) — the format is purely
  additive, so the version number doesn't change. Writes are `mkdir_p` +
  write-to-`.tmp` + `File.rename`
  (atomic against a mid-write power loss) and best-effort: a write failure
  is logged and the lifecycle call still succeeds, since a flash write
  failure is not a reason to fail an add-on start/stop.
  """

  use GenServer

  require Logger

  alias Vagus.Addon.Config

  @type entry :: %{
          config: Config.t(),
          state: :started | :stopped,
          user_options: map(),
          ingress_token: String.t(),
          ingress_port: nil | pos_integer(),
          ingress_panel: boolean(),
          watchdog: boolean(),
          ports: Vagus.Addon.Ports.t(),
          boot: nil | String.t(),
          auto_update: nil | boolean(),
          protected: boolean()
        }

  @persist_version 1

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Records `config` with lifecycle `state` (default `:started`), keyed by
  slug. `opts[:user_options]` sets the stored user options; when omitted, any
  user options already stored for this slug are preserved (a start/stop
  transition must not wipe out previously-configured options) — a genuinely
  new install starts with no entry, so it correctly defaults to `%{}`.
  `opts[:server]` overrides the target GenServer (default `#{inspect(__MODULE__)}`).
  """
  @spec put(Config.t(), :started | :stopped, keyword()) :: :ok
  def put(%Config{} = config, state \\ :started, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    user_options = Keyword.get(opts, :user_options)
    GenServer.call(server, {:put, config, state, user_options})
  end

  @doc "Returns the `%{config, state, user_options}` entry for `slug`, or `:error` if unknown."
  @spec get(String.t(), GenServer.server()) :: {:ok, entry()} | :error
  def get(slug, server \\ __MODULE__) do
    GenServer.call(server, {:get, slug})
  end

  @doc """
  Replaces `slug`'s stored user options (`POST /addons/{slug}/options`).
  `:error` if `slug` isn't tracked (not installed).
  """
  @spec put_options(String.t(), map(), GenServer.server()) :: :ok | :error
  def put_options(slug, user_options, server \\ __MODULE__) when is_map(user_options) do
    GenServer.call(server, {:put_options, slug, user_options})
  end

  @doc """
  Writes one persisted per-install setting for `slug` — `:ingress_port`,
  `:ingress_panel`, `:watchdog`, `:ports`, `:boot`, `:auto_update` or
  `:protected` (`ingress_token` has no setter; it's
  generated once and never changes). `:error` if `slug` isn't tracked (not
  installed). The guard clause is load-bearing: it's the only thing
  stopping a typo'd/unknown key from being written straight to the entry
  map and silently persisted.
  """
  @spec put_setting(
          String.t(),
          :ingress_port
          | :ingress_panel
          | :watchdog
          | :ports
          | :boot
          | :auto_update
          | :protected,
          term(),
          GenServer.server()
        ) ::
          :ok | :error
  def put_setting(slug, key, value, server \\ __MODULE__)
      when key in [
             :ingress_port,
             :ingress_panel,
             :watchdog,
             :ports,
             :boot,
             :auto_update,
             :protected
           ] do
    GenServer.call(server, {:put_setting, slug, key, value})
  end

  @doc "Removes `slug` (e.g. on uninstall). Returns `:ok` even if absent."
  @spec delete(String.t(), GenServer.server()) :: :ok
  def delete(slug, server \\ __MODULE__) do
    GenServer.call(server, {:delete, slug})
  end

  @doc "Lists all tracked entries."
  @spec list(GenServer.server()) :: [entry()]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  ## GenServer

  @impl GenServer
  def init(opts) do
    path = persist_path(opts)
    entries = if path, do: load_entries(path), else: %{}
    {:ok, %{path: path, entries: entries}}
  end

  @impl GenServer
  def handle_call(
        {:put, %Config{slug: slug} = config, state, user_options},
        _from,
        %{
          entries: entries
        } = s
      ) do
    resolved_options = user_options || existing_user_options(entries, slug)

    entry =
      %{config: config, state: state, user_options: resolved_options}
      |> Map.merge(preserved_settings(entries, slug))

    entries = Map.put(entries, slug, entry)
    persist(s.path, entries)
    {:reply, :ok, %{s | entries: entries}}
  end

  def handle_call({:get, slug}, _from, %{entries: entries} = s) do
    {:reply, Map.fetch(entries, slug), s}
  end

  def handle_call({:put_options, slug, user_options}, _from, %{entries: entries} = s) do
    case Map.fetch(entries, slug) do
      {:ok, entry} ->
        entries = Map.put(entries, slug, %{entry | user_options: user_options})
        persist(s.path, entries)
        {:reply, :ok, %{s | entries: entries}}

      :error ->
        {:reply, :error, s}
    end
  end

  def handle_call({:put_setting, slug, key, value}, _from, %{entries: entries} = s) do
    case Map.fetch(entries, slug) do
      {:ok, entry} ->
        entries = Map.put(entries, slug, Map.put(entry, key, value))
        persist(s.path, entries)
        {:reply, :ok, %{s | entries: entries}}

      :error ->
        {:reply, :error, s}
    end
  end

  def handle_call({:delete, slug}, _from, %{entries: entries} = s) do
    entries = Map.delete(entries, slug)
    persist(s.path, entries)
    {:reply, :ok, %{s | entries: entries}}
  end

  def handle_call(:list, _from, %{entries: entries} = s) do
    {:reply, Map.values(entries), s}
  end

  defp existing_user_options(entries, slug) do
    case Map.get(entries, slug) do
      %{user_options: opts} -> opts
      nil -> %{}
    end
  end

  # Same "preserve unless this is a brand-new entry" rule as
  # `existing_user_options/2`, for the four settings introduced in
  # IW-P0-T2: an existing slug keeps whatever it already has (in
  # particular `ingress_token`, which must never regenerate), while a
  # genuinely new install gets defaults plus a freshly generated token.
  defp preserved_settings(entries, slug) do
    case Map.get(entries, slug) do
      %{
        ingress_token: token,
        ingress_port: port,
        ingress_panel: panel,
        watchdog: watchdog,
        ports: ports,
        boot: boot,
        auto_update: auto_update,
        protected: protected
      } ->
        %{
          ingress_token: token,
          ingress_port: port,
          ingress_panel: panel,
          watchdog: watchdog,
          ports: ports,
          boot: boot,
          auto_update: auto_update,
          protected: protected
        }

      nil ->
        %{
          ingress_token: generate_ingress_token(),
          ingress_port: nil,
          ingress_panel: false,
          watchdog: false,
          ports: %{},
          boot: nil,
          auto_update: nil,
          protected: true
        }
    end
  end

  # Charset `[-_A-Za-z0-9]` (URL-safe base64, no padding) — matches the real
  # ingress middleware's `/ingress/[-_A-Za-z0-9]+/.*` route regex
  # (`docs/contract-2026.7-m4b-ingress-watchdog.md` §B3.1). Generated once
  # per slug at entry creation and never regenerated, mirroring the real
  # Supervisor's `secrets.token_urlsafe()` at install time.
  defp generate_ingress_token do
    Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  ## Persistence internals

  # Only falls back to the app env when `opts` doesn't carry the key at
  # all — an explicit `persist_path: nil` (as tests use to prove the
  # disabled path never touches disk) must stay disabled, not resurrect the
  # configured default.
  defp persist_path(opts) do
    Keyword.get(opts, :persist_path, Application.get_env(:vagus, :addon_state_path))
  end

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp load_entries(path) do
    case File.read(path) do
      {:ok, content} ->
        decode_entries(path, content)

      # No file yet (nothing persisted across a reboot, or the very first
      # boot) is expected, not corruption — stay quiet. Any other read
      # failure (permission denied, path is a directory, ...) is a real
      # problem worth a log, but still starts empty rather than crashing.
      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning(
          "Vagus.Addon.State: could not read #{path} (#{inspect(reason)}), starting empty"
        )

        %{}
    end
  end

  defp decode_entries(path, content) do
    case Jason.decode(content) do
      {:ok, %{"addons" => addons}} when is_map(addons) ->
        Enum.reduce(addons, %{}, fn {slug, raw}, acc ->
          case decode_entry(slug, raw) do
            {:ok, entry} -> Map.put(acc, slug, entry)
            :error -> acc
          end
        end)

      {:ok, other} ->
        Logger.warning(
          "Vagus.Addon.State: #{path} has an unexpected shape (#{inspect(other)}), " <>
            "starting empty"
        )

        %{}

      {:error, reason} ->
        Logger.warning(
          "Vagus.Addon.State: #{path} is not valid JSON (#{inspect(reason)}), starting empty"
        )

        %{}
    end
  end

  defp decode_entry(slug, raw) when is_map(raw) do
    with %{"config" => cfg_raw, "state" => state_raw} <- raw,
         {:ok, config} <- Config.parse(cfg_raw),
         true <- config.slug == slug,
         {:ok, state} <- decode_state(state_raw) do
      user_options = Map.get(raw, "user_options", %{})

      {:ok,
       %{
         config: config,
         state: state,
         user_options: user_options,
         ingress_token: decode_ingress_token(raw),
         ingress_port: decode_ingress_port(raw),
         ingress_panel: decode_bool_setting(raw, "ingress_panel"),
         watchdog: decode_bool_setting(raw, "watchdog"),
         ports: decode_ports(raw),
         boot: decode_boot(raw),
         auto_update: decode_maybe_bool_setting(raw, "auto_update"),
         protected: decode_protected(raw)
       }}
    else
      _ ->
        Logger.warning(
          "Vagus.Addon.State: dropping invalid/mismatched entry for #{inspect(slug)}"
        )

        :error
    end
  end

  defp decode_entry(slug, _raw) do
    Logger.warning("Vagus.Addon.State: dropping non-map entry for #{inspect(slug)}")
    :error
  end

  defp decode_state("started"), do: {:ok, :started}
  defp decode_state("stopped"), do: {:ok, :stopped}
  defp decode_state(_other), do: :error

  # Missing/non-string -> freshly generated (old files predate the field,
  # and a garbage value here is worse than a working one — this token gates
  # ingress URL access).
  defp decode_ingress_token(raw) do
    case Map.get(raw, "ingress_token") do
      token when is_binary(token) -> token
      _ -> generate_ingress_token()
    end
  end

  # Missing/invalid (non-integer, zero, or negative) -> nil, same as a
  # never-allocated port; the ingress subsystem allocates a real one later.
  defp decode_ingress_port(raw) do
    case Map.get(raw, "ingress_port") do
      port when is_integer(port) and port > 0 -> port
      _ -> nil
    end
  end

  # Missing/non-boolean -> false, the documented default for both
  # `ingress_panel` and `watchdog`.
  defp decode_bool_setting(raw, key) do
    case Map.get(raw, key) do
      value when is_boolean(value) -> value
      _ -> false
    end
  end

  # Missing/invalid -> `"auto"`/`"manual"` are the only persistable values
  # (a config-level `"manual_only"` can never land here — the router refuses
  # to persist it, see `Vagus.API.Router.apply_addon_options/4`); anything
  # else, including a hand-edited file's stray `"manual_only"`, decodes to
  # `nil` ("never explicitly set") rather than being trusted verbatim.
  defp decode_boot(raw) do
    case Map.get(raw, "boot") do
      value when value in ["auto", "manual"] -> value
      _ -> nil
    end
  end

  # Like `decode_bool_setting/2` but preserves "never set" as `nil` rather
  # than defaulting to `false` — `auto_update`'s `nil` and `false` are both
  # real, distinct states (`nil` = fall back to the config default at render
  # time; `false` = the user explicitly turned it off).
  defp decode_maybe_bool_setting(raw, key) do
    case Map.get(raw, key) do
      value when is_boolean(value) -> value
      _ -> nil
    end
  end

  # Deliberately not `decode_bool_setting/2`: that one's documented default is
  # `false`, which is the *unsafe* side here. `protected` gates `full_access`,
  # `host_pid` and `docker_api`, so an old state file written before the field
  # existed — or a hand-edited/corrupt one — must come back protected.
  defp decode_protected(raw) do
    case Map.get(raw, "protected") do
      value when is_boolean(value) -> value
      _ -> true
    end
  end

  # The user's host-port overrides, persisted under `"network"` to match the
  # wire key the frontend posts. Absent on every file written before this
  # setting existed, hence the `%{}` default — the same tolerant-load rule the
  # other settings use, and why this needed no `@persist_version` bump.
  # Values are re-checked here rather than trusted: the write path validates
  # them, but a hand-edited `addons.json` reaches the container spec too.
  defp decode_ports(raw) do
    case Map.get(raw, "network") do
      ports when is_map(ports) ->
        Map.filter(ports, fn {port, host} ->
          is_binary(port) and
            (is_nil(host) or (is_integer(host) and host >= 0 and host <= 65_535))
        end)

      _ ->
        %{}
    end
  end

  defp persist(nil, _entries), do: :ok

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp persist(path, entries) do
    tmp = path <> ".tmp"

    result =
      with :ok <- File.mkdir_p(Path.dirname(path)),
           {:ok, json} <- Jason.encode(to_disk_map(entries)),
           :ok <- File.write(tmp, json) do
        File.rename(tmp, path)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Vagus.Addon.State: failed to persist #{path}: #{inspect(reason)}")
        :ok
    end
  end

  defp to_disk_map(entries) do
    %{
      "version" => @persist_version,
      "addons" =>
        Map.new(entries, fn {slug,
                             %{
                               config: config,
                               state: state,
                               user_options: user_options,
                               ingress_token: ingress_token,
                               ingress_port: ingress_port,
                               ingress_panel: ingress_panel,
                               watchdog: watchdog,
                               ports: ports,
                               boot: boot,
                               auto_update: auto_update,
                               protected: protected
                             }} ->
          {slug,
           %{
             "config" => Config.to_persistable(config),
             "state" => Atom.to_string(state),
             "user_options" => user_options,
             "ingress_token" => ingress_token,
             "ingress_port" => ingress_port,
             "ingress_panel" => ingress_panel,
             "watchdog" => watchdog,
             "network" => ports,
             "boot" => boot,
             "auto_update" => auto_update,
             "protected" => protected
           }}
        end)
    }
  end
end
