defmodule Vagus.Addon.Store.AssetMode do
  @moduledoc """
  Picks how `Vagus.Addon.Store` retains repository assets (icon, logo,
  changelog, documentation) — `:memory` or `:disk` — once, at boot.

  `config :vagus, :store_asset_mode` takes `:auto | :memory | :disk` and
  defaults to `:auto`, which reads `MemTotal` via `Vagus.Platform.Memory`:
  **less than 1 GiB → `:disk`**, otherwise `:memory`. A board that reports
  nothing usable fails open to `:memory` — today's behaviour — because
  silently switching a device to disk writes on the strength of a failed
  probe is the worse mistake.

  The threshold reads as an off-by-one trap and isn't: a "1 GB" rpi3
  reports ~0.93–0.95 GiB of `MemTotal` (kernel reservation plus `gpu_mem`),
  so a strict `<` puts it on the `:disk` side, which is the intent. The
  Dragon Q6A (8/16 GB) and host dev both land on `:memory`.

  This is resolved into `Vagus.Addon.Store`'s GenServer state rather than
  written back with `Application.put_env/3`: the repo has no
  runtime-mutated app env anywhere, and a target file
  (`config/rpi3_64.exs`, `config/dragon_q6a.exs`) can pin the mode outright
  if detection ever misjudges a board.

  Disk mode reduces **steady-state retention, not peak fetch memory** — see
  `Vagus.Addon.Store`'s moduledoc.
  """

  require Logger

  alias Vagus.Platform.Memory

  @threshold_bytes 1024 * 1024 * 1024

  @typedoc "What the config key accepts."
  @type configured :: :auto | :memory | :disk

  @typedoc "What the store actually runs with."
  @type t :: :memory | :disk

  @doc """
  Resolves `configured` (defaulting to `config :vagus, :store_asset_mode`)
  to `:memory` or `:disk`, logging the decision and the `MemTotal` behind it
  at `:info`. That log line is the field-debug anchor: it is the only way to
  tell from a boot log which mode a board chose and why.

  `opts[:total_bytes]` is a 0-arity function returning
  `{:ok, bytes} | :error`, for tests that need a specific board's memory
  without a real `/proc/meminfo`.
  """
  @spec resolve(configured() | nil, keyword()) :: t()
  def resolve(configured \\ nil, opts \\ [])

  def resolve(nil, opts) do
    resolve(Application.get_env(:vagus, :store_asset_mode, :auto), opts)
  end

  def resolve(:auto, opts) do
    total_bytes = Keyword.get(opts, :total_bytes, &Memory.total_bytes/0)

    case total_bytes.() do
      {:ok, bytes} when bytes < @threshold_bytes ->
        log(:disk, "MemTotal #{bytes} bytes < #{@threshold_bytes} threshold")

      {:ok, bytes} ->
        log(:memory, "MemTotal #{bytes} bytes >= #{@threshold_bytes} threshold")

      :error ->
        log(:memory, "MemTotal unavailable, failing open")
    end
  end

  def resolve(mode, _opts) when mode in [:memory, :disk] do
    log(mode, "configured explicitly")
  end

  def resolve(other, opts) do
    Logger.warning(
      "Vagus.Addon.Store.AssetMode: ignoring invalid :store_asset_mode " <>
        "#{inspect(other)} (expected :auto, :memory or :disk)"
    )

    resolve(:auto, opts)
  end

  @doc "The `MemTotal` below which `:auto` chooses `:disk`."
  @spec threshold_bytes() :: pos_integer()
  def threshold_bytes, do: @threshold_bytes

  defp log(mode, why) do
    Logger.info("Vagus.Addon.Store: store asset mode #{inspect(mode)} (#{why})")
    mode
  end
end
