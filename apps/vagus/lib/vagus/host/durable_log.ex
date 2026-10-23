defmodule Vagus.Host.DurableLog do
  @moduledoc """
  Keeps a rotating copy of the log on `/data`, so a board's history survives
  a reboot.

  RingLogger holds the log in RAM only, and a board that went down for three
  hours came back with nothing to say about why. This adds one OTP `:logger`
  handler (`:logger_std_h`, writing `/data/vagus/log/vagus.log`) next to
  RingLogger rather than replacing it: RingLogger stays the fast in-memory
  view, this is the copy that outlives the BEAM. Being a separate handler,
  it sees every event RingLogger sees, including the kernel and syslog lines
  `nerves_logging` forwards into Logger (`application: :"$kmsg"`) — the OOM
  killer's own account of an outage is exactly what this file is for — and
  it never reads the kernel log itself.

  It runs on every flavor. That is a reversible choice: the cap is the only
  thing standing between this and the SD card that rpi3_64 boards boot from,
  so the defaults are small (5 rotated files of 2 MB, gzipped on rotation)
  and lines carry only the `module` metadata. Turning it off is
  `config :vagus, :durable_log, false`.

  Gated by `config :vagus, :durable_log` (only `config/target.exs` sets it),
  so host and test runs never write files. The value may be `true` or a
  keyword list overriding `dir`, `file`, `max_no_bytes`, `max_no_files`,
  `level` and `compress_on_rotate`.

  Nerves mounts `/data` before any application starts, but it can still be
  unwritable (a corrupt or full partition), and losing the log copy must
  never cost the rest of the tree: any failure to create the directory or
  open the file logs one warning and returns `:ignore`.

  The process exists only so that `terminate/2` removes the handler: without
  it a `:vagus` restart would leave a handler pointing at the old config.
  """

  use GenServer

  require Logger

  @handler :vagus_durable

  @defaults [
    dir: "/data/vagus/log",
    file: "vagus.log",
    max_no_bytes: 2_000_000,
    max_no_files: 5,
    level: :info,
    compress_on_rotate: true
  ]

  @doc """
  Starts the handler owner — `:ignore` unless `config :vagus, :durable_log`
  is truthy, or when the log file cannot be opened.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    if Application.get_env(:vagus, :durable_log, false) do
      opts = Keyword.merge(config(), opts)
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @doc "The current (not yet rotated) log file."
  @spec path() :: Path.t()
  def path, do: path(config())

  @doc "The last `n` lines of the current log file, for `vagus eval` over ssh."
  @spec tail(pos_integer()) :: [String.t()] | {:error, File.posix()}
  # path is config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  def tail(n \\ 100) when is_integer(n) and n > 0 do
    # logger_std_h buffers writes; without a sync the newest seconds are missing.
    _ = :logger_std_h.filesync(@handler)

    case File.read(path()) do
      {:ok, contents} -> contents |> String.split("\n", trim: true) |> Enum.take(-n)
      {:error, _} = error -> error
    end
  end

  defp add_handler(opts) do
    config = %{
      level: Keyword.fetch!(opts, :level),
      config: %{
        file: opts |> path() |> String.to_charlist(),
        max_no_bytes: Keyword.fetch!(opts, :max_no_bytes),
        max_no_files: Keyword.fetch!(opts, :max_no_files),
        compress_on_rotate: Keyword.fetch!(opts, :compress_on_rotate)
      },
      formatter:
        Logger.Formatter.new(
          format: "$dateT$timeZ [$level] $metadata$message\n",
          metadata: [:module],
          utc_log: true,
          colors: [enabled: false]
        )
    }

    case :logger.add_handler(@handler, :logger_std_h, config) do
      :ok -> :ok
      # Left behind by an owner that was killed before terminate/2 ran.
      {:error, {:already_exist, @handler}} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl GenServer
  # path is config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  def init(opts) do
    with :ok <- File.mkdir_p(Keyword.fetch!(opts, :dir)),
         :ok <- add_handler(opts) do
      # Without trapping, a supervisor shutdown skips terminate/2 and the handler outlives us.
      Process.flag(:trap_exit, true)
      {:ok, opts}
    else
      {:error, reason} ->
        Logger.warning("durable log disabled: cannot write #{path(opts)}: #{inspect(reason)}")
        :ignore
    end
  end

  @impl GenServer
  def terminate(_reason, _opts) do
    _ = :logger.remove_handler(@handler)
    :ok
  end

  defp config do
    case Application.get_env(:vagus, :durable_log) do
      overrides when is_list(overrides) -> Keyword.merge(@defaults, overrides)
      _ -> @defaults
    end
  end

  defp path(opts), do: Path.join(Keyword.fetch!(opts, :dir), Keyword.fetch!(opts, :file))
end
