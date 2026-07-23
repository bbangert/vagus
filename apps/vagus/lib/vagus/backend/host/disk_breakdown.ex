defmodule Vagus.Backend.Host.DiskBreakdown do
  @moduledoc """
  Storage-usage breakdown for `GET /host/disks/default/usage` — upstream
  `supervisor/api/host.py::disk_usage` + `supervisor/hardware/disk.py::
  get_dir_sizes`. The frontend's Storage page (and the backup-settings
  UI) renders this as the per-directory breakdown chart.

  Shape (frontend `HostDisksUsage`): a root node `{id: "root", label:
  "Root", total_bytes, used_bytes, children}` whose children are a
  synthetic `system` node (used space not attributed to any known dir —
  upstream computes it the same way) plus one node per known data
  directory, each `{id, label, used_bytes}` with nested `children` down
  to `max_depth` (only non-empty subdirectories are listed, upstream
  behavior).

  ## Vagus's path mapping (vs upstream's `sys_config.path_*`)

  Everything lives under the add-on data root (`config :vagus,
  :addon_data_root` — `/root/vagus/addons` on target): `addons/data`
  (per-add-on data), `addon_configs`, `media`, `share`, `backup`, `ssl`.
  The `homeassistant` entry is Core's config, which for Vagus is the
  `vagus-core-config` docker volume — resolved via the engine data root
  (`Vagus.Engine.Manager.data_root/0`); on `:host` dev that path simply
  doesn't exist and honestly reports 0 bytes (upstream does the same for
  a missing dir).

  `total_bytes`/`used_bytes` come from `df` on the data root; used =
  total - free so reserved blocks count as used (upstream deliberately
  does this).

  ## Deviations

  Upstream skips files on a different `st_dev` (nested mounts) during
  the walk; Erlang's `file_info` doesn't expose `st_dev`, and the Vagus
  data-root subtree contains no nested mounts, so this walk only skips
  symlinks (the actual loop hazard). Documented rather than emulated.
  """

  alias Vagus.Backend.Host.DiskUsage
  alias Vagus.Core.Container
  alias Vagus.Engine

  @default_data_root "/data"

  @doc """
  Builds the full response map.

  Options (all injectable for tests):

    * `:max_depth` — how many directory levels of `children` to report
      (sizes are always fully recursive), default `1`.
    * `:data_root` — default `config :vagus, :addon_data_root`.
    * `:homeassistant_path` — default the `vagus-core-config` volume's
      host path under the engine data root.
    * `:df` — arity-1 `path -> {total_bytes, free_bytes}`, default
      `DiskUsage.usage_bytes/1`.
  """
  @spec usage(keyword()) :: map()
  def usage(opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 1)
    data_root = Keyword.get(opts, :data_root, default_data_root())

    homeassistant_path =
      Keyword.get(opts, :homeassistant_path, default_homeassistant_path())

    df = Keyword.get(opts, :df, &DiskUsage.usage_bytes/1)

    {total, free} = df.(data_root)
    used = max(total - free, 0)

    known =
      Enum.map(
        [
          {"addons_data", Path.join(data_root, "addons/data")},
          {"addons_config", Path.join(data_root, "addon_configs")},
          {"media", Path.join(data_root, "media")},
          {"share", Path.join(data_root, "share")},
          {"backup", Path.join(data_root, "backup")},
          {"ssl", Path.join(data_root, "ssl")},
          {"homeassistant", homeassistant_path}
        ],
        fn {id, path} ->
          Map.merge(%{id: id, label: id}, dir_sizes(path, max_depth))
        end
      )

    known_total = known |> Enum.map(& &1.used_bytes) |> Enum.sum()

    %{
      id: "root",
      label: "Root",
      total_bytes: total,
      used_bytes: used,
      children: [
        %{id: "system", label: "System", used_bytes: max(used - known_total, 0)}
        | known
      ]
    }
  end

  # Recursive dir walk — upstream get_dir_structure_sizes/2: size is the
  # full recursive sum regardless of depth; `children` nodes appear only
  # while `depth > 1` and only for non-empty subdirectories; symlinks are
  # skipped entirely (loop safety).
  defp dir_sizes(path, depth) do
    case File.ls(path) do
      {:ok, entries} ->
        {size, children} =
          Enum.reduce(entries, {0, []}, fn entry, {size, children} ->
            child_path = Path.join(path, entry)

            case File.lstat(child_path) do
              {:ok, %File.Stat{type: :symlink}} ->
                {size, children}

              {:ok, %File.Stat{type: :directory}} ->
                child = dir_sizes(child_path, depth - 1)

                children =
                  if child.used_bytes > 0 and depth > 1 do
                    [Map.merge(%{id: entry, label: entry}, child) | children]
                  else
                    children
                  end

                {size + child.used_bytes, children}

              {:ok, %File.Stat{size: file_size}} ->
                {size + file_size, children}

              # Raced deletion or unreadable entry — skip, like upstream.
              {:error, _reason} ->
                {size, children}
            end
          end)

        if children == [] do
          %{used_bytes: size}
        else
          %{used_bytes: size, children: Enum.reverse(children)}
        end

      # Missing/unlistable dir reports honest zero (upstream: not exists).
      {:error, _reason} ->
        %{used_bytes: 0}
    end
  end

  defp default_data_root do
    Application.get_env(:vagus, :addon_data_root, @default_data_root)
  end

  defp default_homeassistant_path do
    Path.join([Engine.Manager.data_root(), "volumes", Container.config_volume(), "_data"])
  end
end
