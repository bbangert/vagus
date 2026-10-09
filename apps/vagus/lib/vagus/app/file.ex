defmodule Vagus.App.File do
  @moduledoc """
  One JSON file per installed app (`<:app_files_dir>/<slug>.json`), written
  by the app's own process: its config, whether it should run (`wanted`), the
  user's options and the seven per-install settings, the ingress token and
  the dynamic ingress port. The per-start token, container id and IP are
  never written: an app process that restarts recreates its container.

  Loading never bricks a boot. `Config.parse/1` re-validates the config, so a
  file it rejects, or one that is not JSON, is logged and skipped; every
  other field decodes tolerantly to its default, except `protected`, which
  falls back to `true` because it gates `full_access`, `host_pid` and
  `docker_api`.

  `import_once/2` seeds the directory from the single `addons.json` earlier
  releases kept. That file is only ever read, so a reverted firmware boots
  from it exactly as it was at the upgrade.
  """

  require Logger

  alias Vagus.Addon.Config

  @version 1

  @spec dir() :: String.t()
  def dir, do: Application.fetch_env!(:vagus, :app_files_dir)

  @doc "`:error` when there is no file, or none that decodes."
  @spec read(String.t(), String.t()) :: {:ok, map()} | :error
  def read(slug, dir \\ dir()) do
    with true <- Config.valid_slug?(slug) || :error,
         {:ok, content} <- read_file(path(dir, slug)),
         {:ok, raw} <- decode_json(slug, content) do
      decode(slug, raw)
    else
      _ -> :error
    end
  end

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp read_file(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        :error

      {:error, reason} ->
        Logger.warning("Vagus.App.File: could not read #{path}: #{inspect(reason)}")
        :error
    end
  end

  defp decode_json(slug, content) do
    case Jason.decode(content) do
      {:ok, raw} ->
        {:ok, raw}

      {:error, reason} ->
        Logger.warning("Vagus.App.File: #{slug}'s file is not valid JSON (#{inspect(reason)})")
        :error
    end
  end

  @doc "Writes atomically against a power cut: a tmp file, then a rename."
  @spec write(map(), String.t()) :: :ok | {:error, term()}
  def write(%{config: %Config{slug: slug}} = data, dir \\ dir()) do
    result =
      with :ok <- File.mkdir_p(dir),
           {:ok, json} <- Jason.encode(to_disk(data)) do
        replace(path(dir, slug), json)
      end

    with {:error, reason} <- result,
         do: Logger.warning("Vagus.App.File: could not write #{slug}: #{inspect(reason)}")

    result
  end

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp replace(path, content) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, content) do
      File.rename(tmp, path)
    end
  end

  @doc "Slugs that have a file, whether or not it decodes."
  @spec saved(String.t()) :: [String.t()]
  def saved(dir \\ dir()) do
    case File.ls(dir) do
      {:ok, names} ->
        for name <- names,
            Path.extname(name) == ".json",
            slug = Path.rootname(name),
            Config.valid_slug?(slug),
            do: slug

      {:error, _reason} ->
        []
    end
  end

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(slug, dir \\ dir()) do
    case File.rm(path(dir, slug)) do
      {:error, :enoent} -> :ok
      other -> other
    end
  end

  @doc """
  When the apps directory does not exist yet, writes one file per valid entry
  of `legacy` (`addons.json`). The files are built in a sibling directory and
  renamed into place, so an import cut short is redone on the next boot
  rather than leaving a partial set that would count as done.
  """
  @spec import_once(String.t(), String.t() | nil) :: {:ok, :skipped | non_neg_integer()}
  def import_once(dir \\ dir(), legacy \\ Application.get_env(:vagus, :addon_state_path)) do
    if File.dir?(dir), do: {:ok, :skipped}, else: import_legacy(dir, legacy)
  end

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp import_legacy(dir, legacy) do
    staging = dir <> ".import"
    File.rm_rf!(staging)
    entries = legacy_entries(legacy)

    for {slug, raw} <- entries,
        {:ok, data} <- [decode(slug, Map.put(raw, "wanted", raw["state"]))],
        do: :ok = write(data, staging)

    File.mkdir_p!(staging)
    File.mkdir_p!(Path.dirname(dir))
    :ok = File.rename(staging, dir)
    count = length(saved(dir))
    Logger.info("Vagus.App.File: imported #{count} of #{map_size(entries)} apps from #{legacy}")
    {:ok, count}
  end

  defp legacy_entries(nil), do: %{}

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp legacy_entries(path) do
    with {:ok, content} <- read_file(path),
         {:ok, %{"addons" => addons}} when is_map(addons) <- Jason.decode(content) do
      Map.filter(addons, fn {_slug, raw} -> is_map(raw) end)
    else
      _ -> %{}
    end
  end

  defp path(dir, slug), do: Path.join(dir, slug <> ".json")

  defp decode(slug, raw) when is_map(raw) do
    with %{"config" => config_raw, "wanted" => wanted_raw} <- raw,
         {:ok, config} <- Config.parse(config_raw),
         true <- config.slug == slug,
         {:ok, wanted} <- decode_wanted(wanted_raw) do
      {:ok,
       %{
         config: config,
         wanted: wanted,
         user_options: decode_options(raw),
         ingress_token: decode_ingress_token(raw),
         ingress_port: decode_ingress_port(raw),
         ingress_panel: decode_bool(raw, "ingress_panel"),
         watchdog: decode_bool(raw, "watchdog"),
         ports: decode_ports(raw),
         boot: decode_boot(raw),
         auto_update: decode_maybe_bool(raw, "auto_update"),
         protected: decode_protected(raw)
       }}
    else
      _ -> skip(slug)
    end
  end

  defp decode(slug, _raw), do: skip(slug)

  defp skip(slug) do
    Logger.warning("Vagus.App.File: skipping invalid or mismatched app #{inspect(slug)}")
    :error
  end

  defp decode_wanted("started"), do: {:ok, :started}
  defp decode_wanted("stopped"), do: {:ok, :stopped}
  defp decode_wanted(_other), do: :error

  defp decode_options(raw) do
    case Map.get(raw, "user_options") do
      options when is_map(options) -> options
      _ -> %{}
    end
  end

  # A garbage token is worse than a fresh one: it gates ingress URL access.
  defp decode_ingress_token(raw) do
    case Map.get(raw, "ingress_token") do
      token when is_binary(token) -> token
      _ -> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    end
  end

  # An invalid port reads as never assigned; the next start assigns one.
  defp decode_ingress_port(raw) do
    case Map.get(raw, "ingress_port") do
      port when is_integer(port) and port > 0 -> port
      _ -> nil
    end
  end

  defp decode_bool(raw, key) do
    case Map.get(raw, key) do
      value when is_boolean(value) -> value
      _ -> false
    end
  end

  # `nil` ("never set": the config's default applies) and `false` (the user
  # turned it off) are different answers.
  defp decode_maybe_bool(raw, key) do
    case Map.get(raw, key) do
      value when is_boolean(value) -> value
      _ -> nil
    end
  end

  # `manual_only` is a config value the router never persists; a stray one in
  # a hand-edited file is not trusted.
  defp decode_boot(raw) do
    case Map.get(raw, "boot") do
      value when value in ["auto", "manual"] -> value
      _ -> nil
    end
  end

  defp decode_protected(raw) do
    case Map.get(raw, "protected") do
      value when is_boolean(value) -> value
      _ -> true
    end
  end

  # Re-checked rather than trusted: a hand-edited file reaches the container
  # spec too.
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

  defp to_disk(data) do
    %{
      "version" => @version,
      "config" => Config.to_persistable(data.config),
      "wanted" => Atom.to_string(data.wanted),
      "user_options" => data.user_options,
      "ingress_token" => data.ingress_token,
      "ingress_port" => data.ingress_port,
      "ingress_panel" => data.ingress_panel,
      "watchdog" => data.watchdog,
      "network" => data.ports,
      "boot" => data.boot,
      "auto_update" => data.auto_update,
      "protected" => data.protected
    }
  end
end
