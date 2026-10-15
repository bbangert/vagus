defmodule Vagus.Runtime.Engine do
  @moduledoc """
  The container-engine seam: callers state intent in Vagus terms and each
  engine adapter translates once. No HTTP status, transport struct or engine
  JSON crosses it; anything an adapter cannot classify is
  `{:failed, verb, detail}`.

  Every call takes `opts`; `opts[:engine]` overrides the configured
  `:engine` per call, which is how async tests inject `Engine.Fake`. Every
  adapter must honour:

    * `:timeout_ms` (every callback but `follow_logs`, whose stream lives as
      long as its owner wants): bounds the whole call; past it the call
      returns `{:error, :timeout}`.
    * `:timeout_s` (`stop`, `restart`, `stop_all`): the grace before kill;
      `:timeout_ms` never cuts it short, nor a stop below the engine's grace
      floor when `:timeout_s` is absent.
    * `:force` (`remove`, default true): removes a running container.
    * `:all` (default false), `:name_prefix` (`list`).
    * `:tail` (default 100), `:timestamps` (`logs`, `follow_logs`).
    * `:capture` (`exec`, default true).
    * `:platform` (`pull`).

  Any other key is adapter-specific (e.g. `socket:` for `Engine.Docker`).
  """

  import Kernel, except: [inspect: 2]

  alias Vagus.Runtime.Engine.{Container, ContainerSpec, NetworkSpec}

  @type error ::
          :not_found
          | :conflict
          | :in_use
          # Another operation holds the container (lock/permit); retryable.
          | :busy
          | :timeout
          | :unavailable
          | {:pull_failed, term()}
          | {:failed, verb :: atom(), detail :: term()}

  @type name :: String.t()
  @type stats :: %{
          cpu_percent: float(),
          memory_usage: non_neg_integer(),
          memory_limit: non_neg_integer(),
          memory_percent: float(),
          network_rx: non_neg_integer(),
          network_tx: non_neg_integer(),
          blk_read: non_neg_integer(),
          blk_write: non_neg_integer()
        }

  @callback ready(keyword()) :: :ok | {:error, error()}
  @callback pull(String.t(), keyword()) :: :ok | {:error, error()}
  @callback image_present?(String.t(), keyword()) :: boolean() | {:error, error()}
  @doc "An absent image is `:ok`."
  @callback remove_image(String.t(), keyword()) :: :ok | {:error, error()}
  @callback create(ContainerSpec.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  @doc "An already-running container is `:ok`."
  @callback start(name(), keyword()) :: :ok | {:error, error()}
  @doc "An already-stopped container is `:ok`."
  @callback stop(name(), keyword()) :: :ok | {:error, error()}
  @doc """
  `timeout_s` is each container's grace. An absent container counts as
  stopped. Order is not guaranteed and an adapter may stop concurrently.
  """
  @callback stop_all([name()], timeout_s :: non_neg_integer(), keyword()) ::
              {:ok, stopped :: [name()], failed :: [{name(), error()}]}
  @callback restart(name(), keyword()) :: :ok | {:error, error()}
  @doc "An absent container is `:ok`."
  @callback remove(name(), keyword()) :: :ok | {:error, error()}
  @callback inspect(name(), keyword()) :: {:ok, Container.t()} | {:error, error()}
  @callback list(keyword()) :: {:ok, [Container.t()]} | {:error, error()}
  @doc "Plain text: any engine framing is already stripped."
  @callback logs(name(), keyword()) :: {:ok, binary()} | {:error, error()}
  @doc """
  Streams to `owner` as `{:log_chunk, binary}` then `:log_eof`, sending the
  next chunk only after `owner` sends `:log_ack` (`Vagus.Runtime.Logs.Follow.ack/1`).
  The streamer is linked to the caller, which stops it by unlinking and
  exiting it with `:shutdown`; a streamer holding an external handle (e.g. a
  Port's OS process) must trap exits and close it in `terminate/2`.
  """
  @callback follow_logs(name(), owner :: pid(), keyword()) :: {:ok, pid()} | {:error, error()}
  @callback stats(name(), keyword()) :: {:ok, stats()} | {:error, error()}
  @doc "Any exit code is `{:ok, _}`; `output` is plain text, `\"\"` when `capture: false`."
  @callback exec(name(), argv :: [String.t()], keyword()) ::
              {:ok, %{exit_code: integer(), output: binary()}} | {:error, error()}
  @doc """
  Runs one check now and returns its verdict; may block up to the check's
  own timeout. An engine that schedules checks itself may return its latest
  verdict instead.
  """
  @callback healthcheck(name(), keyword()) ::
              {:ok, Container.health()} | {:error, :no_healthcheck | error()}
  @callback event_source() :: module()

  @doc "Creates the network unless it exists; losing a create race is `:ok`."
  @callback ensure_network(NetworkSpec.t(), keyword()) :: :ok | {:error, error()}

  def ready(opts \\ []), do: impl(opts).ready(opts)
  def pull(image, opts \\ []), do: impl(opts).pull(image, opts)
  def image_present?(image, opts \\ []), do: impl(opts).image_present?(image, opts)
  def remove_image(image, opts \\ []), do: impl(opts).remove_image(image, opts)
  def create(%ContainerSpec{} = spec, opts \\ []), do: impl(opts).create(spec, opts)
  def start(name, opts \\ []), do: impl(opts).start(name, opts)
  def stop(name, opts \\ []), do: impl(opts).stop(name, opts)
  def stop_all(names, timeout_s, opts \\ []), do: impl(opts).stop_all(names, timeout_s, opts)
  def restart(name, opts \\ []), do: impl(opts).restart(name, opts)
  def remove(name, opts \\ []), do: impl(opts).remove(name, opts)
  def inspect(name, opts \\ []), do: impl(opts).inspect(name, opts)
  def list(opts \\ []), do: impl(opts).list(opts)
  def logs(name, opts \\ []), do: impl(opts).logs(name, opts)
  def follow_logs(name, owner, opts \\ []), do: impl(opts).follow_logs(name, owner, opts)
  def stats(name, opts \\ []), do: impl(opts).stats(name, opts)
  def exec(name, argv, opts \\ []) when is_list(argv), do: impl(opts).exec(name, argv, opts)
  def healthcheck(name, opts \\ []), do: impl(opts).healthcheck(name, opts)

  def ensure_network(%NetworkSpec{} = spec, opts \\ []),
    do: impl(opts).ensure_network(spec, opts)

  @spec event_source(keyword()) :: module()
  def event_source(opts \\ []), do: impl(opts).event_source()

  defp impl(opts),
    do: opts[:engine] || Application.get_env(:vagus, :engine, Vagus.Runtime.Engine.Docker)
end
