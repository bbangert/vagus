defmodule Vagus.Runtime.Migration do
  @moduledoc """
  Moves a board from balena-engine to podman over its first podman boots.
  No process of its own: `Vagus.Runtime.Host` runs `prepare/1` in its
  preparation and `check/2` from its own timer while `pending?/1`.

  The order keeps an A/B rollback possible until the podman slot is
  validated: Core runs on its config inside balena's volume tree and
  balena's store stays where it is, so a revert to the balena slot finds
  both intact.

    1. Pending while `/root/balena-engine` exists and the marker
       `/root/vagus/engine-migrated` does not.
    2. On the first preparation of a boot whose slot is validated, Core's
       config directory is renamed out of balena's tree to
       `/root/vagus/core/config` (`prepare/1`). One `rename(2)` on one
       filesystem: it either happened or not. The Host runs it before it is
       ready, and Core is created only once it is.
    3. Images are pulled again by their usual callers, Core's first (the
       Host serves Core's pull ahead of queued ones). Before the first pull
       the Host asks `space/1` whether they fit beside balena's store, and
       refuses pulls while they do not.
    4. Once the slot is validated, the config renamed, every wanted image is
       in podman's store and Core answers healthy, the rest of
       `/root/balena-engine` is deleted and the marker written
       (`check/2`). A deletion cut short by a reboot is finished at the
       next check: the marker comes only after it.

  All paths and probes are options, defaulted for the device: `:legacy_root`,
  `:marker`, `:config_dir`, `:graphroot`, `:mountinfo`, `:validated?`
  (0-arity), `:wanted_images` (0-arity, `{:ok, refs} | {:error, reason}`),
  `:image_present?` (1-arity, a boolean or an error), `:core_healthy?`
  (0-arity), `:df` (as `Vagus.Backend.Host.DiskUsage` takes it) and `:host`
  (the Host the default probes run their podman calls under).
  """

  require Logger

  alias Vagus.App.File, as: AppFile
  alias Vagus.Backend.Host.DiskUsage

  @legacy_root "/root/balena-engine"
  @marker "/root/vagus/engine-migrated"
  @config_dir "/root/vagus/core/config"
  @volume "vagus-core-config"

  # For an image balena's store does not hold: a little above the largest
  # app image measured on a board, a little below Core's (about 1.9 GB).
  @unknown_image_bytes 1024 * 1_048_576

  @type condition :: :validated | :config_renamed | :images | :core_healthy
  @type space :: :ok | {:short, need :: non_neg_integer(), free :: non_neg_integer()}

  @spec pending?(keyword()) :: boolean()
  def pending?(opts \\ []) do
    dir?(legacy_root(opts)) and not exists?(marker(opts))
  end

  @doc """
  Core's config directory on the host: the new one once it exists, else the
  legacy one inside balena's volume tree while that exists, else the new
  one (a board that never ran balena).
  """
  @spec core_config_path(keyword()) :: String.t()
  def core_config_path(opts \\ []) do
    new = config_dir(opts)
    legacy = legacy_config_dir(opts)

    cond do
      dir?(new) -> new
      dir?(legacy) -> legacy
      true -> new
    end
  end

  @spec legacy_config_dir(keyword()) :: String.t()
  def legacy_config_dir(opts \\ []),
    do: Path.join([legacy_root(opts), "volumes", @volume, "_data"])

  @doc """
  The quick step, for the Host's preparation. Renames the legacy config
  directory once the slot is validated, and gives a board with no legacy
  config an empty new one, since podman refuses to bind a missing source.
  `rename?: false` skips the rename: a Host restarted within a boot must not
  move the directory from under a Core already created on it.
  """
  @spec prepare(keyword()) :: :renamed | :kept | :created | {:error, term()}
  def prepare(opts \\ []) do
    legacy = legacy_config_dir(opts)
    new = config_dir(opts)

    cond do
      dir?(new) -> :kept
      not dir?(legacy) -> create(new)
      not Keyword.get(opts, :rename?, true) -> :kept
      not validated?(opts) -> :kept
      true -> rename(legacy, new)
    end
  end

  # The paths are module defaults or a test's temp dir, never request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp create(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        :created

      {:error, reason} ->
        Logger.error("Vagus.Runtime.Migration: #{dir} not created: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp rename(legacy, new) do
    with :ok <- File.mkdir_p(Path.dirname(new)),
         :ok <- File.rename(legacy, new) do
      Logger.info("Vagus.Runtime.Migration: Core's config moved to #{new}")
      :renamed
    else
      {:error, reason} ->
        Logger.error(
          "Vagus.Runtime.Migration: Core's config not moved to #{new}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Whether the wanted images missing from podman's store fit on the
  graphroot's filesystem beside balena's store.

  The need is each missing image's unpacked size in balena's store (its
  layers' `size` files, each shared layer once): podman unpacks the same
  layers, and reading them costs no network. An image balena does not hold
  counts as #{div(@unknown_image_bytes, 1_048_576)} MiB. On top comes half
  the largest image, for the compressed copy a pull spools on the same
  filesystem. `{:error, reason}` when the answer is unknown.
  """
  @spec space(keyword()) :: space() | {:error, term()}
  def space(opts \\ []) do
    with {:ok, images} <- wanted_images(opts),
         {:ok, free} <- free_bytes(opts) do
      need = images |> Enum.reject(&present?(&1, opts)) |> need_bytes(opts)
      if need <= free, do: :ok, else: {:short, need, free}
    end
  end

  @doc false
  @spec need_bytes([String.t()], keyword()) :: non_neg_integer()
  def need_bytes([], _opts), do: 0

  def need_bytes(images, opts) do
    store = balena_store(opts)
    sized = Enum.map(images, &image_layers(store, &1))

    layers =
      for {:ok, layers} <- sized, layer <- layers, into: %{}, do: layer

    unknown = Enum.count(sized, &(&1 == :unknown))

    largest =
      sized
      |> Enum.map(fn
        {:ok, layers} -> layers |> Enum.map(&elem(&1, 1)) |> Enum.sum()
        :unknown -> @unknown_image_bytes
      end)
      |> Enum.max()

    Enum.sum(Map.values(layers)) + unknown * @unknown_image_bytes + div(largest, 2)
  end

  @doc """
  The slow step, from the Host's timer. With `space?: true` it also answers
  `space/1`. Then deletes `/root/balena-engine` and writes the marker when
  every condition holds; `{:waiting, condition}` names the first that does
  not.
  """
  @spec check(keyword(), keyword()) :: %{
          space: space() | {:error, term()} | nil,
          cleanup: :done | {:waiting, condition()} | {:error, term()}
        }
  def check(opts, check_opts \\ []) do
    space = if Keyword.get(check_opts, :space?, false), do: space(opts)
    %{space: space, cleanup: cleanup(opts)}
  end

  @spec cleanup(keyword()) :: :done | {:waiting, condition()} | {:error, term()}
  def cleanup(opts \\ []) do
    cond do
      not pending?(opts) -> :done
      not validated?(opts) -> {:waiting, :validated}
      not renamed?(opts) -> {:waiting, :config_renamed}
      not images_present?(opts) -> {:waiting, :images}
      not core_healthy?(opts) -> {:waiting, :core_healthy}
      true -> delete_legacy(opts)
    end
  end

  defp renamed?(opts), do: dir?(config_dir(opts)) and not exists?(legacy_config_dir(opts))

  defp images_present?(opts) do
    case wanted_images(opts) do
      {:ok, images} -> Enum.all?(images, &present?(&1, opts))
      {:error, _} -> false
    end
  end

  defp present?(image, opts) do
    probe = Keyword.get(opts, :image_present?, &default_present?(&1, opts))
    probe.(image) == true
  end

  defp default_present?(image, opts),
    do: Vagus.Runtime.Engine.image_present?(image, host: opts[:host])

  defp core_healthy?(opts) do
    Keyword.get(opts, :core_healthy?, fn -> Vagus.Core.Health.check() == :healthy end).()
  end

  defp validated?(opts), do: Keyword.get(opts, :validated?, &firmware_valid?/0).() == true

  # "Valid" in nerves_runtime's sense: the next boot runs this slot again,
  # also true on a board that does not use validation and so cannot revert.
  defp firmware_valid?, do: Nerves.Runtime.firmware_valid?()

  defp delete_legacy(opts) do
    root = legacy_root(opts)

    case mounts_under(root, opts) do
      [] ->
        with :ok <- remove_tree(root), :ok <- write_marker(opts) do
          Logger.info("Vagus.Runtime.Migration: #{root} deleted; migration complete")
          :done
        end

      mounts ->
        Logger.warning(
          "Vagus.Runtime.Migration: #{root} not deleted, something is mounted inside: " <>
            Enum.join(mounts, ", ")
        )

        {:error, {:mounted, mounts}}
    end
  end

  # rm -rf without -L: lstat decides, so a symlink is removed as itself and
  # never followed. Not File.rm_rf/1, which returns every path it removed: a
  # balena store holds hundreds of thousands. Goes on past a failure, as
  # rm -rf does, and returns the first.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_tree(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        children =
          case :file.list_dir_all(path) do
            {:ok, names} -> Enum.map(names, &remove_tree(Path.join(path, &1)))
            {:error, reason} -> [{:error, {reason, path}}]
          end

        first_error(children ++ [rmdir(path)])

      {:ok, _not_a_directory} ->
        unlink(path)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {reason, path}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp rmdir(path) do
    case File.rmdir(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {reason, path}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp unlink(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {reason, path}}
    end
  end

  defp first_error(results) do
    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        :ok

      {:error, _} = error ->
        Logger.error("Vagus.Runtime.Migration: deleting balena's store: #{inspect(error)}")
        error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_marker(opts) do
    path = marker(opts)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, "") do
      :ok
    else
      {:error, reason} ->
        Logger.error("Vagus.Runtime.Migration: #{path} not written: #{inspect(reason)}")
        {:error, {:marker, reason}}
    end
  end

  # A mount inside the tree would have its own files deleted through it.
  # sobelow_skip ["Traversal.FileModule"]
  defp mounts_under(root, opts) do
    case File.read(Keyword.get(opts, :mountinfo, "/proc/self/mountinfo")) do
      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true),
            [_id, _parent, _dev, _root, point | _] <- [String.split(line, " ")],
            point = unescape(point),
            point == root or String.starts_with?(point, root <> "/"),
            do: point

      # Unknown counts as mounted: the deletion waits for a readable answer.
      {:error, reason} ->
        ["(mountinfo unreadable: #{inspect(reason)})"]
    end
  end

  defp unescape(point) do
    Regex.replace(~r/\\([0-7]{3})/, point, fn _, octal -> <<String.to_integer(octal, 8)>> end)
  end

  defp free_bytes(opts) do
    df_opts = Keyword.take(opts, [:df])

    case DiskUsage.read_bytes(graphroot(opts), df_opts) do
      # DiskUsage reports a df it could not run or read as an empty disk.
      {:ok, {0, _}} -> {:error, :df_failed}
      {:ok, {_total, free}} -> {:ok, free}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wanted_images(opts) do
    Keyword.get(opts, :wanted_images, &default_wanted_images/0).()
  end

  @doc """
  Core's image at its installed version and the image of every container app
  that should run.
  """
  @spec default_wanted_images() :: {:ok, [String.t()]} | {:error, term()}
  def default_wanted_images do
    core =
      case Vagus.Core.Versions.installed() do
        nil -> []
        version -> [Vagus.Core.Container.image(version)]
      end

    {:ok, core ++ wanted_app_images()}
  catch
    :exit, reason -> {:error, {:versions, reason}}
  end

  defp wanted_app_images do
    for slug <- AppFile.saved(),
        {:ok, %{wanted: :started, config: config}} <- [AppFile.read(slug)],
        image = app_image(config),
        is_binary(image),
        uniq: true,
        do: image
  end

  # An app with no image of its own builds no spec: it has nothing to pull.
  defp app_image(config) do
    Vagus.App.Steps.build_spec(config, access_token: "").image
  rescue
    ArgumentError -> nil
  end

  ## balena's image store

  # repositories.json maps each tag to an image id; the image's config lists
  # its layers' diff ids, and a layer's directory in layerdb is named by its
  # chain id: the first diff id, then sha256("<parent chain> <diff id>").
  defp balena_store(opts) do
    case Path.wildcard(Path.join([legacy_root(opts), "image", "*", "repositories.json"])) do
      [repositories | _] -> {Path.dirname(repositories), read_json(repositories)}
      [] -> nil
    end
  end

  defp image_layers(nil, _image), do: :unknown

  defp image_layers({dir, repositories}, image) do
    with %{"Repositories" => repos} <- repositories,
         "sha256:" <> id <- find_id(repos, image),
         %{"rootfs" => %{"diff_ids" => [_ | _] = diff_ids}} <-
           read_json(Path.join([dir, "imagedb", "content", "sha256", id])),
         {:ok, layers} <- layer_sizes(dir, diff_ids) do
      {:ok, layers}
    else
      _ -> :unknown
    end
  end

  defp find_id(repos, image) do
    candidates = [image, docker_name(image)]

    Enum.find_value(repos, fn
      {_repo, tags} when is_map(tags) -> Enum.find_value(candidates, &Map.get(tags, &1))
      _ -> nil
    end)
  end

  # balena stores references fully qualified, as Docker does.
  defp docker_name(image) do
    case String.split(image, "/", parts: 2) do
      [single] ->
        "docker.io/library/" <> single

      [first, _rest] ->
        if String.contains?(first, [".", ":"]) or first == "localhost",
          do: image,
          else: "docker.io/" <> image
    end
  end

  defp layer_sizes(dir, diff_ids) do
    diff_ids
    |> Enum.reduce_while({nil, []}, fn diff_id, {parent, acc} ->
      chain = chain_id(parent, diff_id)
      "sha256:" <> hex = chain

      case read_int(Path.join([dir, "layerdb", "sha256", hex, "size"])) do
        {:ok, size} -> {:cont, {chain, [{chain, size} | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {_last, layers} -> {:ok, layers}
      :error -> :error
    end
  end

  defp chain_id(nil, diff_id), do: diff_id

  defp chain_id(parent, diff_id),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, parent <> " " <> diff_id), case: :lower)

  # sobelow_skip ["Traversal.FileModule"]
  defp read_json(path) do
    with {:ok, text} <- File.read(path), {:ok, json} <- Jason.decode(text), do: json
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_int(path) do
    with {:ok, text} <- File.read(path),
         {n, _} when n >= 0 <- Integer.parse(String.trim(text)) do
      {:ok, n}
    else
      _ -> :error
    end
  end

  # lstat: a symlink is never taken for the directory it points at.
  # sobelow_skip ["Traversal.FileModule"]
  defp dir?(path), do: match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))

  # sobelow_skip ["Traversal.FileModule"]
  defp exists?(path), do: match?({:ok, _}, File.lstat(path))

  defp legacy_root(opts), do: Keyword.get(opts, :legacy_root, @legacy_root)
  defp marker(opts), do: Keyword.get(opts, :marker, @marker)
  defp config_dir(opts), do: Keyword.get(opts, :config_dir, @config_dir)

  defp graphroot(opts),
    do: Keyword.get(opts, :graphroot, "/root/containers/storage")
end
