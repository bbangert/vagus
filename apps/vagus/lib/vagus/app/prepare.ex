defmodule Vagus.App.Prepare do
  @moduledoc """
  What has to be on the host before an app's instance is made, and what is
  taken away after the app is uninstalled.

  `run/3` is one step of the action that creates the instance, not an
  action of its own. Nothing it leaves is something a pass could observe
  without an engine call and several file reads, and a mark in status
  could not stand in for looking: status is committed before the action
  runs, so a pass cut between the two would find the mark and no
  directories. Run again with the create it belongs to, it costs a few
  system calls and gives the same result.

  In order, as the start this replaces has it:

    1. the directories the container binds that are the app's own
       (`Vagus.App.Container.Config.bind_sources/2`);
    2. for a manifest with `dsp: true`, that a skeleton library has been
       supplied and the DSP's device nodes are there;
    3. `options.json` in the app's data directory: the user's options over
       the manifest's, as the manifest's schema admits them;
    4. the app network, unless the app is on the host's or has no container;
    5. the device rules for the container
       (`Vagus.Addon.Devices.cgroup_rules/3`), which read the nodes.

  What refuses before anything was asked of the engine, the DSP checks and
  options the schema does not admit, is `{:error, {:invalid, reason}}`:
  trying again changes nothing. A directory or file that could not be
  written is `{:error, {:mkdir | :write_options, …}}`.

  ## Options

    * `:network`, `(-> :ok | {:error, term})`, which makes sure the app
      network exists (default `Vagus.Network.ensure/0` and its anchors)
    * `:dsp_state`, `(-> :configured | :not_configured | :unsupported)`
      (default `Vagus.DSP.state/0`)
    * `:devices`, options for `Vagus.Addon.Devices`
  """

  alias Vagus.Addon.{Config, Devices, OptionsSchema}
  alias Vagus.App.Container
  alias Vagus.App.Facts
  alias Vagus.Network
  alias Vagus.Runtime.Docker

  @type prepared :: %{device_cgroup_rules: [String.t()]}

  @spec run(map(), Facts.t(), keyword()) :: {:ok, prepared()} | {:error, term()}
  def run(%{config: %Config{} = config} = spec, %Facts{} = facts, opts \\ []) do
    devices = Keyword.get(opts, :devices, [])

    with :ok <- directories(Container.Config.bind_sources(spec, facts)),
         :ok <- dsp_store(config, Keyword.get(opts, :dsp_state, &Vagus.DSP.state/0)),
         :ok <- dsp_devices(config, devices),
         :ok <- write_options(spec, facts),
         :ok <- network(spec, Keyword.get(opts, :network, &ensure_network/0)) do
      protected? = Map.get(spec.settings, :protected, true)
      {:ok, %{device_cgroup_rules: Devices.cgroup_rules(config, protected?, devices)}}
    end
  end

  @doc "The app's data directory, the source of its `/data`."
  @spec data_dir(String.t(), Facts.t()) :: Path.t()
  def data_dir(slug, %Facts{data_root: root}), do: Path.join([root, "addons", "data", slug])

  @spec options_path(String.t(), Facts.t()) :: Path.t()
  def options_path(slug, facts), do: Path.join(data_dir(slug, facts), "options.json")

  # The path is built from the data root and an admitted slug.
  # sobelow_skip ["Traversal.FileModule"]
  @spec data?(String.t(), Facts.t()) :: boolean()
  def data?(slug, facts), do: File.exists?(data_dir(slug, facts))

  @doc """
  Removes the app's data directory. A slug that could name anything but a
  directory of its own is refused, though admission lets none through: the
  slug goes straight into the path that is removed.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec remove_data(String.t(), Facts.t()) :: :ok | {:error, term()}
  def remove_data(slug, facts) do
    if Config.valid_slug?(slug) do
      case File.rm_rf(data_dir(slug, facts)) do
        {:ok, _removed} -> :ok
        {:error, reason, path} -> {:error, {:remove_data, path, reason}}
      end
    else
      {:error, {:invalid, {:slug, slug}}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp directories(sources) do
    Enum.reduce_while(sources, :ok, fn source, :ok ->
      case File.mkdir_p(source) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:mkdir, source, reason}}}
      end
    end)
  end

  defp dsp_store(%Config{dsp: true}, state) do
    case state.() do
      :configured ->
        :ok

      :not_configured ->
        {:error,
         {:invalid,
          {:dsp_not_configured,
           "no DSP skeleton library has been supplied — upload one from the QAIRT SDK " <>
             "on the Vagus admin panel"}}}

      :unsupported ->
        {:error, {:invalid, {:dsp_unsupported, "this device has no Hexagon DSP"}}}
    end
  end

  defp dsp_store(_config, _state), do: :ok

  # After the store: a board without a DSP has no nodes either, and "a node
  # is missing" would be the less useful of the two answers.
  defp dsp_devices(%Config{dsp: true}, devices) do
    case Devices.unresolved_dsp_nodes(devices) do
      [] ->
        :ok

      missing ->
        {:error,
         {:invalid,
          {:dsp_devices_unavailable,
           "this device's DSP nodes are not available (#{Enum.join(missing, ", ")}) — " <>
             "the app could not use the DSP even if it started"}}}
    end
  end

  defp dsp_devices(_config, _devices), do: :ok

  # sobelow_skip ["Traversal.FileModule"]
  defp write_options(%{config: %Config{} = config} = spec, facts) do
    case OptionsSchema.effective(config.schema, config.options, Map.get(spec, :options, %{})) do
      {:ok, options} ->
        path = options_path(config.slug, facts)

        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, Jason.encode!(options)) do
          :ok
        else
          {:error, reason} -> {:error, {:write_options, reason}}
        end

      {:error, reason} ->
        {:error, {:invalid, {:invalid_options, reason}}}
    end
  end

  defp network(%{lifecycle: :native}, _ensure), do: :ok
  defp network(%{config: %Config{host_network: true}}, _ensure), do: :ok

  defp network(_spec, ensure) do
    with {:error, reason} <- ensure.(), do: {:error, Docker.failure(reason)}
  end

  defp ensure_network do
    with {:ok, _id} <- Network.ensure() do
      # The Supervisor's address on the bridge, where a bridged app reaches
      # the API, is lost at every reboot.
      Network.ensure_supervisor_ip()
      :ok
    end
  end
end
