defmodule Vagus.Addon.Config do
  @moduledoc """
  Parses + normalizes an add-on's `config.yaml`/`config.json` (already decoded
  to a string-keyed map) into a validated `%Vagus.Addon.Config{}` — the Elixir
  counterpart of the Supervisor's `_SCHEMA_APP_CONFIG`
  (`docs/contract-2026.7-m4-addendum.md` §A2.4).

  Decoding the file (YAML/JSON) is a separate concern owned by the store
  (P2-T3); this module is pure `map -> struct` so it's fully host-testable and
  dependency-free. The add-on options `schema`/`options` are captured verbatim
  here and validated later at start via `Vagus.Addon.OptionsSchema`.

  Config is untrusted (add-on-supplied), so `parse/1` returns
  `{:error, reason}` for anything malformed — never raises.

  `parse/1` also rejects the slugs Vagus reserves for itself
  (`reserved_slug?/1` — currently just `vagus`, the synthetic admin panel).
  That covers a persisted entry too: `Vagus.Addon.State.decode_entry/2`
  wraps `parse/1`, so a state file carrying a `vagus` add-on from before the
  reservation is dropped with a warning and the rest of the file still
  loads, per that module's "a corrupt state file must never brick the
  device" invariant.

  `ingress_entry`/`ingress_stream`/`panel_icon`/`panel_title`/`panel_admin`
  (`docs/contract-2026.7-m4b-ingress-watchdog.md` §B3.1) round out the
  ingress/panel config knobs alongside the pre-existing `ingress`/
  `ingress_port`; `ingress_port` additionally enforces the §B3.2
  dynamic-port/`ports:` collision guard at parse time.

  `homeassistant`/`machine` (phase 6 chunk A, audit G1) feed
  `Vagus.Addon.Availability`: `homeassistant` is a nilable version-floor
  string (`opt_str`, same shape as `watchdog`/`webui`/`image` — an opaque
  tag, not something this module orders); `machine` is a plain list of
  strings (`str_list`, same shape as `discovery`/`privileged`/`devices` —
  no charset enforcement here either, matching this module's existing
  looseness on every other bare string-list field). Neither field is
  otherwise interpreted by `parse/1` itself; `Availability` owns what they
  mean.

  ## `dsp:` — a Vagus-only key with no upstream counterpart

  `dsp: true` binds two directories read-only into the container so a QNN
  workload can reach the CDSP — the system image's fastrpc shells
  (`/usr/lib/dsp`) and the operator-supplied Hexagon skel (`Vagus.DSP`) — and
  grants the fastrpc/DMA-heap device rules both are inert without
  (`Vagus.Addon.Devices`). All three parts are required; see
  `Vagus.Addon.Manager`'s `dsp_mount/1` for what each supplies.
  `_SCHEMA_APP_CONFIG` has no such key, and
  upstream has **no precedent at all** for host-mounting vendor accelerator
  libraries — this rests on analogy to `kernel_modules`, which exists for the
  same reason: the payload has to match the kernel/firmware the running system
  image ships, so baking it into the add-on image would couple the add-on to a
  system version it cannot see.

  Deliberately absent from `GET /addons/{slug}/info` (plan D-D): that payload
  is contract-shaped for `aiohasupervisor`, and a Vagus-only key inside an
  upstream-shaped response is new divergence with no caller asking for it.
  """

  @slug_re ~r/^[-_.A-Za-z0-9]+$/
  # Slugs the Supervisor itself owns and no add-on may claim. A literal, not
  # `Vagus.API.AdminPanel.slug()`: referencing that module here would close a
  # compile-time cycle (Config <- Addon.State <- Ingress <- AdminPanel). The
  # two are pinned together by a test instead.
  @reserved_slugs ["vagus"]
  # Docker tag charset (W1) — `version:` becomes the tag half of the image
  # ref `Vagus.Addon.Manager.image_ref/2` builds (`"#{image}:#{version}"`)
  # and, unlike `slug`, previously had no charset validation at all even
  # though it's just as add-on-supplied/untrusted; an unvalidated value
  # could smuggle extra path/query structure into the Engine-API image
  # pull/delete calls that build on it.
  @version_re ~r/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/
  @service_re ~r/^(?<service>mqtt|mysql):(?<rights>provide|want|need)$/
  @arch_all ~w(aarch64 amd64 armhf armv7 i386)
  @backends ~w(container native)
  @startups ~w(initialize system services application once)
  @boots ~w(auto manual manual_only)
  @roles ~w(default homeassistant backup manager admin)
  @backup_modes ~w(hot cold)
  @stages ~w(stable experimental deprecated)

  @type mapping :: %{type: String.t(), read_only: boolean(), path: String.t() | nil}

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          slug: String.t(),
          description: String.t(),
          arch: [String.t()],
          backend: :container | :native,
          startup: String.t(),
          boot: String.t(),
          init: boolean(),
          image: String.t() | nil,
          ports: %{optional(String.t()) => non_neg_integer() | nil},
          map: [mapping()],
          hassio_api: boolean(),
          hassio_role: String.t(),
          homeassistant_api: boolean(),
          auth_api: boolean(),
          docker_api: boolean(),
          services: [String.t()],
          discovery: [String.t()],
          host_network: boolean(),
          host_dbus: boolean(),
          host_pid: boolean(),
          host_ipc: boolean(),
          host_uts: boolean(),
          privileged: [String.t()],
          full_access: boolean(),
          devices: [String.t()],
          dsp: boolean(),
          apparmor: boolean(),
          ingress: boolean(),
          ingress_port: non_neg_integer(),
          ingress_entry: String.t() | nil,
          ingress_stream: boolean(),
          panel_icon: String.t(),
          panel_title: String.t() | nil,
          panel_admin: boolean(),
          watchdog: String.t() | nil,
          webui: String.t() | nil,
          options: map(),
          schema: map() | false,
          backup: String.t(),
          backup_pre: String.t() | nil,
          backup_post: String.t() | nil,
          backup_exclude: [String.t()],
          timeout: non_neg_integer(),
          homeassistant: String.t() | nil,
          machine: [String.t()]
        }

  @enforce_keys [:name, :version, :slug, :description, :arch]
  defstruct name: nil,
            version: nil,
            slug: nil,
            description: nil,
            arch: [],
            backend: :container,
            startup: "application",
            boot: "auto",
            init: true,
            image: nil,
            ports: %{},
            map: [],
            hassio_api: false,
            hassio_role: "default",
            homeassistant_api: false,
            auth_api: false,
            docker_api: false,
            services: [],
            discovery: [],
            host_network: false,
            host_dbus: false,
            host_pid: false,
            host_ipc: false,
            host_uts: false,
            privileged: [],
            full_access: false,
            devices: [],
            dsp: false,
            apparmor: true,
            ingress: false,
            ingress_port: 8099,
            ingress_entry: nil,
            ingress_stream: false,
            panel_icon: "mdi:puzzle",
            panel_title: nil,
            panel_admin: true,
            watchdog: nil,
            webui: nil,
            options: %{},
            schema: %{},
            backup: "hot",
            backup_pre: nil,
            backup_post: nil,
            backup_exclude: [],
            timeout: 10,
            # Display-only, but load-bearing in the frontend: `stage` drives the
            # experimental/deprecated badge on a store card, `advanced` hides an
            # add-on behind the user's "advanced mode" profile toggle, and `url`
            # is the add-on's website link. Dropping them at parse time is why
            # ESPHome's beta and dev entries rendered as ordinary stable
            # add-ons in Vagus while HAOS badges them.
            stage: "stable",
            advanced: false,
            url: nil,
            # Availability (G1): a nilable Core-version floor and a machine
            # whitelist, both parsed but otherwise uninterpreted here — see
            # `Vagus.Addon.Availability`.
            homeassistant: nil,
            machine: []

  @doc """
  Parses a decoded config map into a `%Vagus.Addon.Config{}`, applying defaults
  and validating required fields + field formats. Returns `{:error, reason}` on
  any malformed input.
  """
  @spec parse(map()) :: {:ok, t()} | {:error, String.t()}
  def parse(raw) when is_map(raw) do
    {:ok, build(raw)}
  catch
    {:invalid, message} -> {:error, message}
  end

  def parse(_raw), do: {:error, "config must be a map"}

  @doc """
  The shared "is this slug safe to interpolate into a filesystem path" check
  (W3) — used by both `Vagus.Addon.Manager`'s data-dir `rm_rf` guard and
  `Vagus.Backups`' restore/create slug validation, replacing their previous
  divergent (and lowercase-only) regexes with the charset `parse/1` itself
  actually enforces (`@slug_re`, which permits uppercase and dots).

  That charset alone isn't enough for an `rm_rf`/`File` path segment though
  — `.` and `..` are themselves valid tokens under it — so this additionally
  rejects a bare `"."`/`".."` and anything containing `/` (redundant given
  `@slug_re` already excludes `/`, kept as explicit, charset-independent
  insurance) before returning `true`.
  """
  @spec valid_slug?(term()) :: boolean()
  def valid_slug?(slug) when is_binary(slug) do
    Regex.match?(@slug_re, slug) and slug not in [".", ".."] and not String.contains?(slug, "/")
  end

  def valid_slug?(_slug), do: false

  @doc """
  Whether `slug` is reserved by Vagus itself (the synthetic `vagus` admin
  panel, `Vagus.API.AdminPanel`) and so may not name an add-on.

  Deliberately separate from `valid_slug?/1`, which is a *filesystem*-safety
  guard (`Vagus.Addon.Manager.uninstall/2`'s `rm_rf`, `Vagus.Backups`):
  a reserved slug that somehow got installed must still be cleanable, so
  that check must keep accepting it.

  `Vagus.Addon.Manager.install/2` uses this to reject an install whose slug
  comes from the URL rather than from a parsed config.
  """
  @spec reserved_slug?(term()) :: boolean()
  def reserved_slug?(slug) when is_binary(slug), do: slug in @reserved_slugs
  def reserved_slug?(_slug), do: false

  @doc """
  The boot mode an add-on actually starts with (phase 6 chunk A, audit E1):
  `config.boot` (`"auto"`/`"manual"`/`"manual_only"`, the config.yaml
  default) overridden by `persisted` — the per-install `POST
  /addons/{slug}/options` value (`Vagus.Addon.State`'s `:boot` field,
  `nil | "auto" | "manual"`) — when the config allows an override at all.

  A `"manual_only"` config always wins, regardless of `persisted`: real
  Supervisor's `AppBootConfigCannotChangeError` refuses to ever persist an
  override against it (`Vagus.API.Router.apply_addon_options/4` enforces
  that same refusal at save time), so this reports `"manual"` for one even
  if a hand-edited state file somehow disagrees. `nil` (never explicitly
  set) falls back to `config.boot` itself.

  Used both to render the wire `boot` field (`Vagus.Addon.Info.render/4`)
  and to decide which persisted-`:started` add-ons actually restart at boot
  (`Vagus.Addon.BootStarter`) — one function so the two can't drift apart on
  what "boot: auto" means for a given add-on.
  """
  @spec effective_boot(t(), String.t() | nil) :: String.t()
  def effective_boot(%__MODULE__{boot: "manual_only"}, _persisted), do: "manual"
  def effective_boot(_config, persisted) when persisted in ["auto", "manual"], do: persisted
  def effective_boot(%__MODULE__{boot: boot}, _persisted), do: boot

  @doc """
  The inverse of `parse/1`: renders `config` back to the raw, string-keyed
  wire shape `parse/1` itself accepts — needed so `Vagus.Addon.State` can
  persist an installed add-on's config to disk (§ M4-P8-T1, real-Supervisor
  parity for its persisted `sys_apps.data`) and restore it across a device
  reboot without a second, divergent decoder: `parse/1` stays the single
  validator, both on the store's initial `config.yaml`/`config.json` decode
  and on this on-disk reload.

  Only has to be `parse/1`'s inverse, not a general serializer — every field
  is emitted verbatim (including `nil`s, e.g. `image`/`watchdog`/`webui`),
  and `map:` entries are rendered in the dict form (`%{"type", "read_only",
  "path"}`) since `parse/1` already normalizes both the legacy string form
  and the dict form to that same struct shape. If a round-trip
  (`parse(to_persistable(c)) == {:ok, c}`) ever breaks for some field, fix
  it here — never loosen `parse/1`, which stays the load-time validator for
  untrusted add-on-supplied config too.
  """
  @spec to_persistable(t()) :: map()
  def to_persistable(%__MODULE__{} = c) do
    %{
      "name" => c.name,
      "version" => c.version,
      "slug" => c.slug,
      "description" => c.description,
      "arch" => c.arch,
      "backend" => Atom.to_string(c.backend),
      "startup" => c.startup,
      "boot" => c.boot,
      "init" => c.init,
      "image" => c.image,
      "ports" => c.ports,
      "map" => Enum.map(c.map, &mapping_to_persistable/1),
      "hassio_api" => c.hassio_api,
      "hassio_role" => c.hassio_role,
      "homeassistant_api" => c.homeassistant_api,
      "auth_api" => c.auth_api,
      "docker_api" => c.docker_api,
      "services" => c.services,
      "discovery" => c.discovery,
      "host_network" => c.host_network,
      "host_dbus" => c.host_dbus,
      "host_pid" => c.host_pid,
      "host_ipc" => c.host_ipc,
      "host_uts" => c.host_uts,
      "privileged" => c.privileged,
      "full_access" => c.full_access,
      "devices" => c.devices,
      "dsp" => c.dsp,
      "apparmor" => c.apparmor,
      "ingress" => c.ingress,
      "ingress_port" => c.ingress_port,
      "ingress_entry" => c.ingress_entry,
      "ingress_stream" => c.ingress_stream,
      "panel_icon" => c.panel_icon,
      "panel_title" => c.panel_title,
      "panel_admin" => c.panel_admin,
      "watchdog" => c.watchdog,
      "webui" => c.webui,
      "options" => c.options,
      "schema" => c.schema,
      "backup" => c.backup,
      "backup_pre" => c.backup_pre,
      "backup_post" => c.backup_post,
      "backup_exclude" => c.backup_exclude,
      "timeout" => c.timeout,
      "stage" => c.stage,
      "advanced" => c.advanced,
      "url" => c.url,
      "homeassistant" => c.homeassistant,
      "machine" => c.machine
    }
  end

  defp mapping_to_persistable(%{type: type, read_only: read_only, path: path}) do
    %{"type" => type, "read_only" => read_only, "path" => path}
  end

  ## Internals

  defp build(raw) do
    %__MODULE__{
      name: req_str(raw, "name"),
      version: version(raw),
      slug: slug(raw),
      description: req_str(raw, "description"),
      arch: arch(raw)
    }
    |> put(:backend, backend(raw))
    |> put(:startup, enum(raw, "startup", @startups, "application"))
    |> put(:boot, enum(raw, "boot", @boots, "auto"))
    |> put(:init, boolean(raw, "init", true))
    |> put(:image, opt_str(raw, "image"))
    |> put(:ports, ports(raw))
    |> put(:map, mappings(raw))
    |> put(:hassio_api, boolean(raw, "hassio_api", false))
    |> put(:hassio_role, enum(raw, "hassio_role", @roles, "default"))
    |> put(:homeassistant_api, boolean(raw, "homeassistant_api", false))
    |> put(:auth_api, boolean(raw, "auth_api", false))
    |> put(:docker_api, boolean(raw, "docker_api", false))
    |> put(:services, services(raw))
    |> put(:discovery, str_list(raw, "discovery"))
    |> put(:host_network, boolean(raw, "host_network", false))
    |> put(:host_dbus, boolean(raw, "host_dbus", false))
    |> put(:host_pid, boolean(raw, "host_pid", false))
    |> put(:host_ipc, boolean(raw, "host_ipc", false))
    |> put(:host_uts, boolean(raw, "host_uts", false))
    |> put(:privileged, str_list(raw, "privileged"))
    |> put(:full_access, boolean(raw, "full_access", false))
    |> put(:devices, str_list(raw, "devices"))
    |> put(:dsp, boolean(raw, "dsp", false))
    |> put(:apparmor, boolean(raw, "apparmor", true))
    |> put(:ingress, boolean(raw, "ingress", false))
    |> put_ingress_port(raw)
    |> put(:ingress_entry, opt_str(raw, "ingress_entry"))
    |> put(:ingress_stream, boolean(raw, "ingress_stream", false))
    |> put(:panel_icon, panel_icon(raw))
    |> put(:panel_title, opt_str(raw, "panel_title"))
    |> put(:panel_admin, boolean(raw, "panel_admin", true))
    |> put(:watchdog, opt_str(raw, "watchdog"))
    |> put(:webui, opt_str(raw, "webui"))
    |> put(:options, map_field(raw, "options", %{}))
    |> put(:schema, schema(raw))
    |> put(:backup, enum(raw, "backup", @backup_modes, "hot"))
    |> put(:backup_pre, opt_str(raw, "backup_pre"))
    |> put(:backup_post, opt_str(raw, "backup_post"))
    |> put(:backup_exclude, str_list(raw, "backup_exclude"))
    |> put(:timeout, int(raw, "timeout", 10))
    |> put(:stage, enum(raw, "stage", @stages, "stable"))
    |> put(:advanced, boolean(raw, "advanced", false))
    |> put(:url, opt_str(raw, "url"))
    |> put(:homeassistant, opt_str(raw, "homeassistant"))
    |> put(:machine, str_list(raw, "machine"))
  end

  defp put(config, key, value), do: Map.put(config, key, value)

  # Which runtime backend drives this add-on (§A1.6). `native` = a supervised
  # BEAM subtree ("virtual add-on", e.g. the mqttx broker); anything else =
  # the default containerized backend. An explicit atom map (not
  # `String.to_atom`) keeps untrusted config from minting arbitrary atoms.
  defp backend(raw) do
    case enum(raw, "backend", @backends, "container") do
      "native" -> :native
      _ -> :container
    end
  end

  # -- required / typed field helpers ---------------------------------------

  defp req_str(raw, key) do
    case Map.get(raw, key) do
      v when is_binary(v) and v != "" -> v
      nil -> invalid("missing required field '#{key}'")
      _ -> invalid("field '#{key}' must be a string")
    end
  end

  defp opt_str(raw, key) do
    case Map.get(raw, key) do
      nil -> nil
      v when is_binary(v) -> v
      other -> invalid("field '#{key}' must be a string, got #{inspect(other)}")
    end
  end

  defp slug(raw) do
    slug = req_str(raw, "slug")

    cond do
      not Regex.match?(@slug_re, slug) -> invalid("slug '#{slug}' has invalid characters")
      slug in @reserved_slugs -> invalid("slug '#{slug}' is reserved")
      true -> slug
    end
  end

  defp version(raw) do
    version = req_str(raw, "version")

    if Regex.match?(@version_re, version),
      do: version,
      else: invalid("version '#{version}' has invalid characters")
  end

  defp arch(raw) do
    case Map.get(raw, "arch") do
      nil ->
        invalid("missing required field 'arch'")

      list when is_list(list) ->
        Enum.each(list, fn a ->
          unless a in @arch_all, do: invalid("unknown arch '#{a}'")
        end)

        list

      _ ->
        invalid("field 'arch' must be a list")
    end
  end

  defp enum(raw, key, allowed, default) do
    v = Map.get(raw, key, default)

    if v in allowed,
      do: v,
      else:
        invalid("field '#{key}' must be one of #{Enum.join(allowed, ", ")}, got #{inspect(v)}")
  end

  defp boolean(raw, key, default) do
    case Map.get(raw, key, default) do
      v when is_boolean(v) -> v
      other -> invalid("field '#{key}' must be a boolean, got #{inspect(other)}")
    end
  end

  defp int(raw, key, default) do
    case Map.get(raw, key, default) do
      v when is_integer(v) -> v
      other -> invalid("field '#{key}' must be an integer, got #{inspect(other)}")
    end
  end

  # `ingress_port` (§B3.1): a literal 1-65535 or exactly 0 (dynamic
  # assignment). Sets `:ingress_port` on the config being built (rather than
  # just returning the value like the other field helpers) so it can also run
  # the §B3.2 port-collision guard below against the config's already-parsed
  # `:ports` (set earlier in the `build/1` pipeline).
  defp put_ingress_port(config, raw) do
    port = ingress_port_value(raw)
    :ok = validate_ingress_dynamic_guard(config.ports, port)
    %{config | ingress_port: port}
  end

  defp ingress_port_value(raw) do
    case Map.get(raw, "ingress_port", 8099) do
      v when is_integer(v) and v >= 0 and v <= 65_535 ->
        v

      v when is_integer(v) ->
        invalid("field 'ingress_port' must be between 0 and 65535, got #{v}")

      other ->
        invalid("field 'ingress_port' must be an integer, got #{inspect(other)}")
    end
  end

  # §B3.2 last paragraph: an add-on declaring `ingress_port: 0` (dynamic
  # assignment) that also maps a host `ports:` value inside the dynamic
  # ingress range (62000-65500) is rejected — that collision would let a
  # client hit the add-on's ingress endpoint directly on the host, bypassing
  # the ingress-session-cookie check entirely.
  defp validate_ingress_dynamic_guard(_ports, port) when port != 0, do: :ok

  defp validate_ingress_dynamic_guard(ports, 0) do
    if Enum.any?(Map.values(ports), &(is_integer(&1) and &1 in 62_000..65_500)) do
      invalid(
        "ingress_port: 0 conflicts with a 'ports:' host value in the dynamic ingress " <>
          "range 62000-65500 (§B3.2)"
      )
    else
      :ok
    end
  end

  defp panel_icon(raw) do
    case Map.get(raw, "panel_icon", "mdi:puzzle") do
      v when is_binary(v) -> v
      other -> invalid("field 'panel_icon' must be a string, got #{inspect(other)}")
    end
  end

  defp map_field(raw, key, default) do
    case Map.get(raw, key, default) do
      v when is_map(v) -> v
      other -> invalid("field '#{key}' must be a map, got #{inspect(other)}")
    end
  end

  defp str_list(raw, key) do
    case Map.get(raw, key, []) do
      list when is_list(list) ->
        Enum.each(list, fn s ->
          unless is_binary(s), do: invalid("field '#{key}' must be a list of strings")
        end)

        list

      other ->
        invalid("field '#{key}' must be a list, got #{inspect(other)}")
    end
  end

  # -- structured fields ----------------------------------------------------

  # Docker port keys are "<port>/<proto>"; value is the host port (or null =
  # expose only / dynamic).
  defp ports(raw) do
    case Map.get(raw, "ports", %{}) do
      m when is_map(m) ->
        Map.new(m, fn
          {k, nil} -> {to_string(k), nil}
          {k, v} when is_integer(v) -> {to_string(k), v}
          {k, _} -> invalid("port '#{k}' host value must be an integer or null")
        end)

      other ->
        invalid("field 'ports' must be a map, got #{inspect(other)}")
    end
  end

  defp services(raw) do
    list = str_list(raw, "services")

    Enum.each(list, fn s ->
      unless Regex.match?(@service_re, s),
        do: invalid("service '#{s}' must be '<mqtt|mysql>:<provide|want|need>'")
    end)

    list
  end

  # `map:` is a list of either the dict form (%{"type","read_only?","path?"})
  # or the legacy string form "<type>[:<rw|ro>]". Normalize both to
  # %{type, read_only, path}. read_only defaults to true (contract §A1.4;
  # §A7#3 flags this default as worth re-confirming on real add-ons).
  defp mappings(raw) do
    case Map.get(raw, "map", []) do
      list when is_list(list) -> Enum.map(list, &mapping/1)
      other -> invalid("field 'map' must be a list, got #{inspect(other)}")
    end
  end

  defp mapping(entry) when is_binary(entry) do
    case String.split(entry, ":", parts: 2) do
      [type] -> %{type: type, read_only: true, path: nil}
      [type, "rw"] -> %{type: type, read_only: false, path: nil}
      [type, "ro"] -> %{type: type, read_only: true, path: nil}
      [type, other] -> invalid("map entry '#{type}:#{other}' access must be 'rw' or 'ro'")
    end
  end

  defp mapping(entry) when is_map(entry) do
    case Map.get(entry, "type") do
      t when is_binary(t) ->
        %{
          type: t,
          read_only: Map.get(entry, "read_only", true),
          path: Map.get(entry, "path")
        }

      _ ->
        invalid("map entry #{inspect(entry)} needs a string 'type'")
    end
  end

  defp mapping(other), do: invalid("map entry must be a string or map, got #{inspect(other)}")

  # `schema:` is either a map of option-name => element, or the boolean
  # `false` (meaning "no options validation").
  defp schema(raw) do
    case Map.get(raw, "schema", %{}) do
      false -> false
      m when is_map(m) -> m
      other -> invalid("field 'schema' must be a map or false, got #{inspect(other)}")
    end
  end

  defp invalid(message), do: throw({:invalid, message})
end
