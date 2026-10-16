defmodule Vagus.Runtime.Migration do
  @moduledoc """
  Moves a board from balena-engine to podman over its first podman boots.
  No process of its own: `Vagus.Runtime.Host` runs `prepare/1` in its
  preparation and `check/2` from its own timer while `pending?/1`, and each
  podman pull asks `pull_space/2` first.

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
       Host serves Core's pull ahead of queued ones). Each pull goes ahead
       only when its own image fits beside balena's store (`pull_space/2`),
       so Core's pull needs room for Core alone, and any other leaves room
       for Core until Core's image is back; a refused one is retried by its
       caller.
    4. While the wanted images do not all fit, Home Assistant shows a
       notification saying how much room the migration needs; it is
       dismissed once they fit or the migration is done.
    5. Once the slot is validated and the config renamed, the rest of
       `/root/balena-engine` is deleted and the marker written (`check/2`):
       at once while the images do not fit, which gives up the manual
       rollback to free the room; otherwise once every wanted image is in
       podman's store and Core answers healthy. A deletion cut short by a
       reboot is finished at the next check: the marker comes only after it.

  All paths and probes are options, defaulted for the device: `:legacy_root`,
  `:marker`, `:config_dir`, `:graphroot`, `:mountinfo`, `:validated?`
  (0-arity), `:wanted_images` (0-arity, `{:ok, refs} | {:error, reason}`),
  `:image_present?` (1-arity, a boolean or an error), `:core_image` (0-arity,
  the installed Core's image or `nil`), `:core_healthy?`
  (0-arity), `:df` (as `Vagus.Backend.Host.DiskUsage` takes it), `:notify`
  (1-arity, `{:raise, need, free} | :dismiss`, `:ok` once Home Assistant has
  it), `:lstat` and `:walk_hook` (the deletion's stat, and a call between a
  directory's stat and its listing; tests) and `:host` (the Host the
  default probes run their podman calls under).
  """

  require Logger

  alias Vagus.App.File, as: AppFile
  alias Vagus.Backend.Host.DiskUsage
  alias Vagus.Runtime.Mountinfo

  @legacy_root "/root/balena-engine"
  @marker "/root/vagus/engine-migrated"
  @config_dir "/root/vagus/core/config"
  @volume "vagus-core-config"

  # For an image balena's store does not hold: a little above the largest
  # app image measured on a board, a little below Core's (about 1.9 GB).
  @unknown_image_bytes 1024 * 1_048_576

  @notification_id "vagus_engine_migration_space"

  # The deletion gives the scheduler and the disk a breath this often.
  @walk_pause_every 256
  @walk_pause_ms 1

  @type condition :: :validated | :config_renamed | :images | :core_healthy
  @type space :: :ok | {:short, need :: non_neg_integer(), free :: non_neg_integer()}
  # :unknown: one may be up from before a restart, so a dismissal is due.
  @type notice :: nil | :unknown | %{need: non_neg_integer(), free: non_neg_integer()}

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
    with {:ok, images} <- wanted_images(opts) do
      images |> Enum.reject(&present?(&1, opts)) |> fits(opts)
    end
  end

  @doc """
  Whether one image fits, by the same estimate as `space/1`: the room one
  pull needs while a migration is pending. `:ok` once none is.

  Until Core's image is back, any other image must leave room for it too:
  an app pulled first could otherwise take the room Core needs, and before
  the slot is validated nothing would free it.
  """
  @spec pull_space(String.t(), keyword()) :: space() | {:error, term()}
  def pull_space(image, opts) do
    if pending?(opts), do: fits([image | reserved_for_core(image, opts)], opts), else: :ok
  end

  defp reserved_for_core(image, opts) do
    case core_image(opts) do
      nil -> []
      ^image -> []
      core -> if present?(core, opts), do: [], else: [core]
    end
  end

  # nil while Core has no installed version: there is nothing to keep room for.
  defp core_image(opts), do: Keyword.get(opts, :core_image, &default_core_image/0).()

  defp default_core_image do
    case Vagus.Core.Versions.installed() do
      nil -> nil
      version -> Vagus.Core.Container.image(version)
    end
  catch
    :exit, _not_running -> nil
  end

  defp fits(images, opts) do
    with {:ok, free} <- free_bytes(opts) do
      need = need_bytes(images, opts)
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
  The slow step, from the Host's timer: `cleanup/2`, and the notification in
  Home Assistant while the images do not fit. `notice:` is what the
  previous check left there; the result carries what is there now, for the
  next.
  """
  @spec check(keyword(), keyword()) :: %{
          cleanup: :done | {:waiting, condition()} | {:error, term()},
          notice: notice()
        }
  def check(opts, check_opts \\ []) do
    previous = Keyword.get(check_opts, :notice)
    space = if pending?(opts), do: space(opts), else: :ok
    cleanup = cleanup(opts, space)
    shown = if cleanup == :done, do: :ok, else: space
    %{cleanup: cleanup, notice: tell(shown, previous, opts)}
  end

  # One not delivered (Core down, no token yet) is tried again at the next
  # check, and the uncertainty it leaves is kept. Raising again under the
  # fixed id only replaces what Home Assistant shows.
  defp tell({:short, need, free}, previous, opts) when previous in [nil, :unknown] do
    case notify(opts).({:raise, need, free}) do
      :ok -> %{need: need, free: free}
      _not_delivered -> previous
    end
  end

  defp tell(:ok, previous, opts) when previous != nil do
    case notify(opts).(:dismiss) do
      :ok -> nil
      _not_delivered -> previous
    end
  end

  defp tell(_unchanged_or_unknown, previous, _opts), do: previous

  defp notify(opts), do: Keyword.get(opts, :notify, &notify_core/1)

  @doc "The persistent notification Home Assistant shows while the images do not fit."
  @spec notification(non_neg_integer(), non_neg_integer()) :: map()
  def notification(need, free) do
    %{
      "notification_id" => @notification_id,
      "title" => "Not enough room to finish moving to podman",
      "message" =>
        "This board is moving its containers from balena-engine to podman and must " <>
          "download their images again. They need about #{mib(need)} MiB; " <>
          "#{mib(free)} MiB is free beside the old balena-engine store. Images that " <>
          "do not fit are retried until they do. Once this firmware has been " <>
          "confirmed, the old store is deleted to make room, which ends the option " <>
          "to roll back to the previous firmware by hand."
    }
  end

  defp notify_core({:raise, need, free}),
    do: post("/api/services/persistent_notification/create", notification(need, free))

  defp notify_core(:dismiss),
    do:
      post("/api/services/persistent_notification/dismiss", %{
        "notification_id" => @notification_id
      })

  defp post(path, body) do
    case Vagus.Core.Client.request(:post, path,
           headers: [{"content-type", "application/json"}],
           body: Jason.encode!(body)
         ) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 -> :ok
      other -> {:error, other}
    end
  catch
    # An unstarted Core.Client exits :noproc.
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp mib(bytes), do: div(bytes, 1_048_576)

  @doc """
  Deletes `/root/balena-engine` and writes the marker when every condition
  holds; `{:waiting, condition}` names the first that does not. Given a
  `{:short, _, _}` `space`, a validated board with its config moved deletes
  without waiting for the images or Core.
  """
  @spec cleanup(keyword(), space() | {:error, term()} | nil) ::
          :done | {:waiting, condition()} | {:error, term()}
  def cleanup(opts \\ [], space \\ nil) do
    cond do
      not pending?(opts) -> :done
      not validated?(opts) -> {:waiting, :validated}
      not renamed?(opts) -> {:waiting, :config_renamed}
      match?({:short, _, _}, space) -> make_room(space, opts)
      not images_present?(opts) -> {:waiting, :images}
      not core_healthy?(opts) -> {:waiting, :core_healthy}
      true -> delete_legacy(opts)
    end
  end

  defp make_room({:short, need, free}, opts) do
    Logger.warning(
      "Vagus.Runtime.Migration: images need #{mib(need)} MiB, #{mib(free)} MiB free; " <>
        "deleting balena-engine's store before they are back. A manual rollback to " <>
        "the previous firmware is no longer possible"
    )

    delete_legacy(opts)
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

  # Core's data lives in the config directory, so nothing of the tree goes
  # before that is out of it, whichever way the deletion was reached.
  defp delete_legacy(opts) do
    root = legacy_root(opts)

    if renamed?(opts) do
      delete_unmounted(root, opts)
    else
      Logger.error("Vagus.Runtime.Migration: #{root} not deleted, Core's config is still inside")
      {:error, :config_not_moved}
    end
  end

  defp delete_unmounted(root, opts) do
    case mounts_under(root, opts) do
      [] ->
        with :ok <- remove_tree(root, opts), :ok <- write_marker(opts) do
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

  # rm -rf without -L, on one filesystem: lstat decides, so a symlink is
  # removed as itself and never followed, and an entry on another device (a
  # mount) is left alone. A directory is stat'ed again after its listing and
  # descended only while it is still the directory first seen, so one
  # swapped for a symlink in between is not followed. Not File.rm_rf/1,
  # which returns every path it removed (a balena store holds hundreds of
  # thousands). Goes on past a failure, as rm -rf does, and returns the
  # first; what vanished meanwhile (a second walk of the same tree) counts
  # as done.
  defp remove_tree(root, opts) do
    lstat = Keyword.get(opts, :lstat, &File.lstat/1)

    case lstat.(root) do
      {:ok, %File.Stat{major_device: dev}} ->
        walk = %{lstat: lstat, hook: Keyword.get(opts, :walk_hook, fn _ -> :ok end), dev: dev}
        Process.put(:vagus_walked, 0)
        remove(root, walk)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {reason, root}}
    end
  end

  defp remove(path, walk) do
    pace()

    case walk.lstat.(path) do
      {:ok, %File.Stat{major_device: dev}} when dev != walk.dev ->
        Logger.warning("Vagus.Runtime.Migration: #{path} is on another filesystem; left alone")
        {:error, {:other_filesystem, path}}

      {:ok, %File.Stat{type: :directory} = seen} ->
        walk.hook.(path)
        remove_dir(path, seen, walk)

      {:ok, _not_a_directory} ->
        unlink(path)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {reason, path}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_dir(path, seen, walk) do
    with {:ok, names} <- :file.list_dir_all(path),
         {:ok, now} <- walk.lstat.(path),
         true <- same_dir?(seen, now) do
      first_error(Enum.map(names, &remove(Path.join(path, &1), walk)) ++ [rmdir(path)])
    else
      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {reason, path}}

      false ->
        Logger.warning("Vagus.Runtime.Migration: #{path} changed while being deleted; skipped")
        {:error, {:changed, path}}
    end
  end

  defp same_dir?(seen, now),
    do:
      now.type == :directory and now.inode == seen.inode and now.major_device == seen.major_device

  defp pace do
    n = Process.get(:vagus_walked, 0) + 1
    Process.put(:vagus_walked, n)
    if rem(n, @walk_pause_every) == 0, do: Process.sleep(@walk_pause_ms)
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

  defp first_error(results), do: Enum.find(results, :ok, &match?({:error, _}, &1))

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
  defp mounts_under(root, opts) do
    case Mountinfo.read(Keyword.get(opts, :mountinfo, "/proc/self/mountinfo")) do
      {:ok, mounts} ->
        for {point, _fstype} <- mounts,
            point == root or String.starts_with?(point, root <> "/"),
            do: point

      # Unknown counts as mounted: the deletion waits for a readable answer.
      {:error, reason} ->
        ["(mountinfo unreadable: #{inspect(reason)})"]
    end
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
  # Each id must be a sha256 digest before it names a path, and metadata of
  # any other shape makes the image's size unknown.
  defp balena_store(opts) do
    case Path.wildcard(Path.join([legacy_root(opts), "image", "*", "repositories.json"])) do
      [repositories | _] -> {Path.dirname(repositories), read_json(repositories)}
      [] -> nil
    end
  end

  defp image_layers(nil, _image), do: :unknown

  defp image_layers({dir, repositories}, image) do
    with %{"Repositories" => repos} when is_map(repos) <- repositories,
         "sha256:" <> id <- find_id(repos, image),
         true <- hex64?(id),
         %{"rootfs" => %{"diff_ids" => [_ | _] = diff_ids}} <-
           read_json(Path.join([dir, "imagedb", "content", "sha256", id])),
         true <- Enum.all?(diff_ids, &digest?/1),
         {:ok, layers} <- layer_sizes(dir, diff_ids) do
      {:ok, layers}
    else
      _ -> :unknown
    end
  rescue
    # Belt to the checks above: no shape of metadata takes the check down.
    _ in [MatchError, ArgumentError, FunctionClauseError, CaseClauseError] -> :unknown
  end

  defp find_id(repos, image) do
    candidates = [image, docker_name(image)]

    Enum.find_value(repos, fn
      {_repo, tags} when is_map(tags) -> Enum.find_value(candidates, &Map.get(tags, &1))
      _ -> nil
    end)
  end

  defp digest?("sha256:" <> hex), do: hex64?(hex)
  defp digest?(_other), do: false

  defp hex64?(hex), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, hex)

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

      case read_int(Path.join([dir, "layerdb", "sha256", hex_of(chain), "size"])) do
        {:ok, size} -> {:cont, {chain, [{chain, size} | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {_last, layers} -> {:ok, layers}
      :error -> :error
    end
  end

  defp hex_of("sha256:" <> hex), do: hex

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
         {n, ""} when n >= 0 <- Integer.parse(String.trim(text)) do
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
