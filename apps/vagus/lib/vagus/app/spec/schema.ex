defmodule Vagus.App.Spec.Schema do
  @moduledoc """
  The spec of an App resource: its shape, what is admitted, and how it gets
  through JSON.

  ## Fields

    * `lifecycle`: the profile, `:container`, `:core` or `:native`
      (`Vagus.App.Profile`). Stored, because it is a decision made at
      install: a manifest that asks for `native` gets it only if the app is
      one of `facts.native_apps`.
    * `config`: the app's own copy of its manifest, a `Vagus.Addon.Config`.
    * `version`: the version to run, and the image tag. An Update writes it.
    * `options`: what the user set, to be merged over the manifest's.
    * `settings`: per install, the keys the profile lists.
    * `ingress_port`: the port assigned to an app whose manifest asks for a
      dynamic one, otherwise `nil` (`ingress_port/1` gives the port either
      way).
    * `run`, `restart_counter`, `start_counter`: what commands write.
    * `holds`: reasons not to run, each written and owned by another
      resource. The app should run when `run` and no hold (`wanted?/1`).

  Nothing derived is stored. The wave, the boot mode and every other answer
  of the profile is a function of these fields, so a new manifest cannot
  leave a stale copy of one behind.

  A Core spec has `lifecycle`, `version`, `run`, the counters and `holds`
  only, until its container config is built from a spec.

  ## Who writes what

  A path written with a `:writer` belongs to that writer until released
  (`Vagus.Resource.Store`).

    * `[:version]` (`version_path/0`): an Update, for as long as it runs.
    * `[:holds, name]` (`hold_path/1`): the resource that placed the hold.
      `[:holds]` is the kind's `writer_entries/0`, so a hold goes with its
      writer when that is released, value and all.
    * Everything else: commands, which write without a writer and own
      nothing.

  ## Admission

  `validate/2` is the kind's validator. The store runs it on every write of
  a spec, so it is pure, reads nothing, and answers any term at all with a
  refusal rather than raising. It also fills in what a spec left out, and
  what it returns is what is stored.

  It is given the whole spec and no other resource, so it cannot refuse a
  dynamic ingress port another app holds. See `ingress_port_contested?/2`.

  Every rule holds on every write, availability included: an app whose
  manifest asks for a newer Core than `facts.core_version` can be deleted
  but takes no other write, a stop among them. `core_version: nil` leaves
  that one rule out, and `availability/2` asks it alone.
  """

  alias Vagus.Addon.{Availability, Config, OptionsSchema}
  alias Vagus.App.{Facts, Profile}
  alias Vagus.Resource

  @typedoc """
  Why a spec is refused. A field or a setting of the wrong shape is
  `{:malformed, field}` or `{:malformed, {:settings, key}}`; a spec that is
  no map at all is `{:malformed, :spec}`.
  """
  @type refusal ::
          {:malformed, atom() | {:settings, atom()}}
          | {:unknown_lifecycle, term()}
          | {:missing, atom()}
          | {:field_not_in_profile, term(), Profile.tag()}
          | {:setting_not_in_profile, term(), Profile.tag()}
          | {:lifecycle_mismatch, Profile.tag()}
          | {:reserved_slug, String.t()}
          | :config_not_persistable
          | :no_image
          | {:not_supported, :architecture | :machine_type | :home_assistant_version, String.t()}
          | {:invalid_options, String.t()}
          | :watchdog_run_once
          | :ingress_port_missing
          | :ingress_port_not_assignable

  @kind :app
  @max_port 65_535
  # The Docker tag charset: `version` becomes the tag of the image pulled.
  @version ~r/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/
  @ingress_ports 62_000..65_500

  @fields %{
    "lifecycle" => :lifecycle,
    "config" => :config,
    "version" => :version,
    "options" => :options,
    "settings" => :settings,
    "ingress_port" => :ingress_port,
    "run" => :run,
    "restart_counter" => :restart_counter,
    "start_counter" => :start_counter,
    "holds" => :holds
  }
  @settings %{
    "ports" => :ports,
    "protected" => :protected,
    "watchdog" => :watchdog,
    "boot" => :boot,
    "ingress_panel" => :ingress_panel,
    "auto_update" => :auto_update
  }
  @lifecycles Map.new(Profile.tags(), &{Atom.to_string(&1), &1})

  @spec kind() :: Resource.kind()
  def kind, do: @kind

  @doc "The spec of a newly installed store app, before admission."
  @spec from_manifest(Config.t(), Facts.t(), map()) :: map()
  def from_manifest(%Config{} = config, %Facts{} = facts, fields \\ %{}) do
    Map.merge(%{lifecycle: lifecycle_for(config, facts), config: config}, fields)
  end

  @doc """
  A manifest that asks to run inside the VM runs there only when the app is
  one of ours. Such code runs with nothing between it and the system, so
  any other app asking gets a container.
  """
  @spec lifecycle_for(Config.t(), Facts.t()) :: :container | :native
  def lifecycle_for(%Config{backend: :native, slug: slug}, %Facts{native_apps: ours}),
    do: if(slug in ours, do: :native, else: :container)

  def lifecycle_for(%Config{}, %Facts{}), do: :container

  @spec writer_entries() :: [Resource.path()]
  def writer_entries, do: [[:holds]]

  @spec version_path() :: Resource.path()
  def version_path, do: [:version]

  @spec hold_path(String.t()) :: Resource.path()
  def hold_path(name) when is_binary(name), do: [:holds, name]

  @spec wanted?(map()) :: boolean()
  def wanted?(%{run: run, holds: holds}), do: run and holds == %{}

  @doc "Admission. See the moduledoc."
  @spec validate(term(), Facts.t()) :: {:ok, map()} | {:error, refusal()}
  def validate(spec, %Facts{} = facts) when is_map(spec) and not is_struct(spec) do
    with {:ok, tag, profile} <- profile(spec),
         :ok <- own_fields(spec, tag, profile),
         {:ok, spec} <- with_defaults(spec, profile),
         :ok <- shapes(spec, profile.fields()),
         :ok <- manifest(spec, tag, facts) do
      {:ok, spec}
    end
  end

  def validate(_spec, %Facts{}), do: {:error, {:malformed, :spec}}

  defp profile(%{lifecycle: tag}) do
    case Profile.fetch(tag) do
      {:ok, profile} -> {:ok, tag, profile}
      :error -> {:error, {:unknown_lifecycle, tag}}
    end
  end

  defp profile(_spec), do: {:error, {:missing, :lifecycle}}

  defp own_fields(spec, tag, profile) do
    with :ok <- foreign(Map.keys(spec), profile.fields(), :field_not_in_profile, tag) do
      case Map.get(spec, :settings) do
        %{} = settings when not is_struct(settings) ->
          known = Map.keys(profile.settings())
          foreign(Map.keys(settings), known, :setting_not_in_profile, tag)

        _absent_or_malformed ->
          :ok
      end
    end
  end

  # Sorted, so that which of several foreign keys is named does not depend
  # on the order a map happens to list them in.
  defp foreign(keys, known, reason, tag) do
    case Enum.sort(keys -- known) do
      [] -> :ok
      [key | _] -> {:error, {reason, key, tag}}
    end
  end

  defp with_defaults(spec, profile) do
    fields = profile.fields()
    config = Map.get(spec, :config)

    defaults =
      %{
        options: %{},
        ingress_port: nil,
        run: false,
        restart_counter: 0,
        start_counter: 0,
        holds: %{}
      }
      |> Map.take(fields)

    spec = Map.merge(defaults, spec)

    # The version an install runs is its manifest's until something says
    # otherwise.
    spec =
      case config do
        %Config{version: version} -> Map.put_new(spec, :version, version)
        _none -> spec
      end

    spec =
      if :settings in fields,
        do: Map.update(spec, :settings, profile.settings(), &merge_settings(profile, &1)),
        else: spec

    # A manifest that is none leaves the version out as well, and it is the
    # manifest that is wrong.
    case Enum.find(fields, &(not is_map_key(spec, &1))) do
      nil ->
        {:ok, spec}

      :version when config != nil and not is_struct(config, Config) ->
        {:error, {:malformed, :config}}

      field ->
        {:error, {:missing, field}}
    end
  end

  defp merge_settings(profile, %{} = settings) when not is_struct(settings),
    do: Map.merge(profile.settings(), settings)

  defp merge_settings(_profile, other), do: other

  defp shapes(spec, fields) do
    Enum.find_value(fields, :ok, fn field ->
      if shape?(field, Map.fetch!(spec, field)), do: nil, else: {:error, malformed(field, spec)}
    end)
  end

  defp malformed(:settings, %{settings: %{} = settings}) when not is_struct(settings) do
    key = settings |> Map.keys() |> Enum.sort() |> Enum.find(&(not setting?(&1, settings[&1])))
    {:malformed, {:settings, key}}
  end

  defp malformed(field, _spec), do: {:malformed, field}

  defp shape?(:lifecycle, _tag), do: true
  defp shape?(:config, config), do: is_struct(config, Config)
  defp shape?(:version, version), do: is_binary(version) and Regex.match?(@version, version)
  defp shape?(:options, options), do: plain_map?(options)
  defp shape?(:ingress_port, port), do: port == nil or port?(port, 1)
  defp shape?(:run, run), do: is_boolean(run)
  defp shape?(counter, n) when counter in [:restart_counter, :start_counter], do: count?(n)
  defp shape?(:holds, holds), do: plain_map?(holds)

  defp shape?(:settings, %{} = settings) when not is_struct(settings),
    do: Enum.all?(settings, fn {key, value} -> setting?(key, value) end)

  defp shape?(:settings, _other), do: false

  defp setting?(:ports, %{} = ports) when not is_struct(ports) do
    Enum.all?(ports, fn {port, host} ->
      is_binary(port) and String.valid?(port) and (host == nil or port?(host, 0))
    end)
  end

  defp setting?(flag, value) when flag in [:protected, :watchdog, :ingress_panel],
    do: is_boolean(value)

  defp setting?(:boot, boot), do: boot in [nil, "auto", "manual"]
  defp setting?(:auto_update, auto), do: auto == nil or is_boolean(auto)
  defp setting?(_key, _value), do: false

  defp port?(port, min), do: is_integer(port) and port >= min and port <= @max_port
  defp count?(n), do: is_integer(n) and n >= 0

  defp plain_map?(%{} = map) when not is_struct(map),
    do: Enum.all?(map, fn {key, value} -> plain_string?(key) and plain?(value) end)

  defp plain_map?(_other), do: false

  # What JSON gives back unchanged: anything else would be stored as
  # something the next start does not read as the same spec.
  defp plain?(value) when is_binary(value), do: String.valid?(value)
  defp plain?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  defp plain?([]), do: true
  defp plain?([head | tail]), do: plain?(head) and plain?(tail)
  defp plain?(%{} = map), do: plain_map?(map)
  defp plain?(_other), do: false

  defp plain_string?(key), do: is_binary(key) and String.valid?(key)

  defp manifest(_spec, :core, _facts), do: :ok

  defp manifest(%{config: config} = spec, tag, facts) do
    with :ok <- unreserved(config),
         :ok <- persistable(config),
         :ok <- lifecycle(config, tag, facts),
         :ok <- availability(config, facts),
         :ok <- options(config, spec.options),
         :ok <- watchdog(config, spec.settings) do
      ingress(config, Map.get(spec, :ingress_port))
    end
  end

  # The store reads back what it wrote and refuses a difference, by which
  # time the reason is no longer known. A struct built by hand, not by
  # `Config.parse/1`, is what fails here.
  defp persistable(config) do
    if Config.parse(Config.to_persistable(config)) == {:ok, config},
      do: :ok,
      else: {:error, :config_not_persistable}
  rescue
    _error -> {:error, :config_not_persistable}
  end

  # `Config.parse/1` refuses such a slug too. Asked first, so that a manifest
  # given another's slug after parsing is refused by name.
  defp unreserved(%Config{slug: slug}) do
    if Config.reserved_slug?(slug), do: {:error, {:reserved_slug, slug}}, else: :ok
  end

  defp lifecycle(%Config{} = config, tag, facts) do
    cond do
      lifecycle_for(config, facts) != tag -> {:error, {:lifecycle_mismatch, tag}}
      tag == :container and config.image == nil -> {:error, :no_image}
      true -> :ok
    end
  end

  @doc """
  Whether the manifest can run on this machine, by `Vagus.Addon.Availability`.
  The second element names which of upstream's three refusals it is, and
  the third is its message.
  """
  @spec availability(Config.t(), Facts.t()) ::
          :ok
          | {:error,
             {:not_supported, :architecture | :machine_type | :home_assistant_version, String.t()}}
  def availability(%Config{} = config, %Facts{} = facts) do
    # `Availability` checks the three in this order and says only which
    # message applies. Each is asked alone, so the first to refuse is known.
    checks = [
      architecture: %{config | machine: [], homeassistant: nil},
      machine_type: %{config | homeassistant: nil},
      home_assistant_version: config
    ]

    Enum.find_value(checks, :ok, fn {which, narrowed} ->
      case Availability.check(narrowed, facts.arch, facts.machine, facts.core_version) do
        {true, nil} -> nil
        {false, message} -> {:error, {:not_supported, which, message}}
      end
    end)
  end

  defp options(%Config{schema: schema, options: defaults}, user) do
    case OptionsSchema.effective(schema, defaults, user) do
      {:ok, _options} -> :ok
      {:error, message} -> {:error, {:invalid_options, message}}
    end
  end

  defp watchdog(%Config{startup: "once"}, %{watchdog: true}), do: {:error, :watchdog_run_once}
  defp watchdog(_config, _settings), do: :ok

  defp ingress(config, port) do
    cond do
      dynamic_ingress?(config) and port == nil -> {:error, :ingress_port_missing}
      not dynamic_ingress?(config) and port != nil -> {:error, :ingress_port_not_assignable}
      true -> :ok
    end
  end

  @doc "Whether the manifest leaves its ingress port to be assigned."
  @spec dynamic_ingress?(Config.t()) :: boolean()
  def dynamic_ingress?(%Config{ingress: ingress, ingress_port: port}), do: ingress and port == 0

  @doc "The port the app's ingress is reached at, or `nil` for an app without ingress."
  @spec ingress_port(map()) :: pos_integer() | nil
  def ingress_port(%{config: %Config{ingress: true} = config} = spec) do
    if dynamic_ingress?(config), do: Map.get(spec, :ingress_port), else: config.ingress_port
  end

  def ingress_port(_spec), do: nil

  @doc """
  The value of `ingress_port` for a new spec of `config`: `nil` unless the
  manifest asks for a dynamic port, and then the lowest port of the range
  that is in neither `held` (`held_ingress_ports/2`) nor `opts[:in_use]`,
  ports the caller found something listening on. `opts[:range]` replaces
  the range.

  Two callers that pick at once from the same reading pick the same port,
  and nothing here or in the store prevents it.
  `ingress_port_contested?/2` is how the later of the two finds out.
  """
  @spec assign_ingress_port(Config.t(), Enumerable.t(), keyword()) ::
          {:ok, pos_integer() | nil} | {:error, :no_ingress_port_free}
  def assign_ingress_port(%Config{} = config, held, opts \\ []) do
    if dynamic_ingress?(config) do
      taken = MapSet.union(MapSet.new(held), MapSet.new(Keyword.get(opts, :in_use, [])))

      case Enum.find(Keyword.get(opts, :range, @ingress_ports), &(&1 not in taken)) do
        nil -> {:error, :no_ingress_port_free}
        port -> {:ok, port}
      end
    else
      {:ok, nil}
    end
  end

  @doc "The dynamic ingress ports `apps` hold, leaving out the app named `except`."
  @spec held_ingress_ports([Resource.t()], Resource.name() | nil) :: MapSet.t(pos_integer())
  def held_ingress_ports(apps, except \\ nil) do
    for %Resource{name: name, spec: %{ingress_port: port}} <- apps,
        name != except,
        is_integer(port),
        into: MapSet.new(),
        do: port
  end

  @doc """
  Whether `app` must give up its dynamic ingress port: another of `apps`
  holds the same one and was created first.

  The store gives uids in the order it creates, so of two apps that picked
  the same port from the same reading exactly one, the later, sees this
  true, whichever of them looks and however often. It reads the apps after
  its create has returned, picks again without the ports then held, writes,
  and looks once more. An app is not started while this holds for it.
  """
  @spec ingress_port_contested?(Resource.t(), [Resource.t()]) :: boolean()
  def ingress_port_contested?(%Resource{spec: %{ingress_port: port}} = app, apps)
      when is_integer(port) do
    Enum.any?(apps, fn
      %Resource{spec: %{ingress_port: ^port}, uid: uid, name: name} ->
        name != app.name and uid < app.uid

      _other ->
        false
    end)
  end

  def ingress_port_contested?(%Resource{}, _apps), do: false

  @doc "The spec as JSON holds it. Inverted by `decode_spec/1` exactly, for any admitted spec."
  @spec encode_spec(map()) :: %{optional(String.t()) => term()}
  def encode_spec(spec) do
    Map.new(spec, fn
      {:lifecycle, tag} -> {"lifecycle", Atom.to_string(tag)}
      {:config, %Config{} = config} -> {"config", Config.to_persistable(config)}
      {:settings, settings} -> {"settings", Map.new(settings, &string_key/1)}
      field -> string_key(field)
    end)
  end

  defp string_key({key, value}) when is_atom(key), do: {Atom.to_string(key), value}

  @doc "Raises on a field, a setting or a lifecycle this build does not know."
  @spec decode_spec(%{optional(String.t()) => term()}) :: map()
  def decode_spec(raw) do
    Map.new(raw, fn
      {"lifecycle", tag} -> {:lifecycle, known!(@lifecycles, tag)}
      {"config", config} -> {:config, parsed!(config)}
      {"settings", settings} -> {:settings, Map.new(settings, &known_key(&1, @settings))}
      field -> known_key(field, @fields)
    end)
  end

  defp known_key({key, value}, known), do: {known!(known, key), value}

  defp known!(known, name) do
    case known do
      %{^name => atom} ->
        atom

      _unknown ->
        raise ArgumentError, "#{inspect(name)} is not one of #{inspect(Map.keys(known))}"
    end
  end

  defp parsed!(raw) do
    case Config.parse(raw) do
      {:ok, config} -> config
      {:error, message} -> raise ArgumentError, "stored manifest does not parse: #{message}"
    end
  end
end
