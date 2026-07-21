defmodule Vagus.Targz do
  @moduledoc """
  Bounded in-memory extraction of gzip'd tar archives — the safe alternative to
  `:erl_tar.extract(_, [:memory, :compressed])`, whose gunzip is unbounded and
  can OOM the (root, 1 GB) device on a decompression bomb.

  `extract_capped/2` inflates the gzip incrementally with `:zlib.safeInflate/2`,
  aborting with `{:error, :too_large}` the moment the decompressed total exceeds
  the cap (so a small bomb never materializes in full), then extracts the plain
  tar in memory.
  """

  @doc """
  Gunzips `gz` with a hard `max_bytes` cap on the decompressed size, then
  extracts the tar. Returns `{:ok, [{path, content}]}` or `{:error, reason}`
  (`:too_large` if the cap is exceeded).
  """
  @spec extract_capped(binary(), pos_integer()) ::
          {:ok, [{String.t(), binary()}]} | {:error, term()}
  def extract_capped(gz, max_bytes) when is_binary(gz) and is_integer(max_bytes) do
    with {:ok, tar} <- gunzip_capped(gz, max_bytes) do
      case :erl_tar.extract({:binary, tar}, [:memory]) do
        {:ok, entries} -> {:ok, Enum.map(entries, fn {n, c} -> {to_string(n), c} end)}
        {:error, reason} -> {:error, {:untar, reason}}
      end
    end
  end

  @doc "Gunzip `gz`, aborting at `max_bytes` decompressed. `{:ok, binary}` / `{:error, :too_large}`."
  @spec gunzip_capped(binary(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def gunzip_capped(gz, max_bytes) when is_binary(gz) do
    z = :zlib.open()

    try do
      # 31 = automatic gzip header detection.
      :zlib.inflateInit(z, 31)
      inflate_loop(z, :zlib.safeInflate(z, gz), [], 0, max_bytes)
    rescue
      e -> {:error, {:inflate, Exception.message(e)}}
    after
      :zlib.close(z)
    end
  end

  defp inflate_loop(_z, _step, _acc, total, max) when total > max, do: {:error, :too_large}

  defp inflate_loop(z, {:continue, out}, acc, total, max) do
    chunk = IO.iodata_to_binary(out)
    inflate_loop(z, :zlib.safeInflate(z, []), [acc | [chunk]], total + byte_size(chunk), max)
  end

  defp inflate_loop(_z, {:finished, out}, acc, total, max) do
    chunk = IO.iodata_to_binary(out)

    if total + byte_size(chunk) > max,
      do: {:error, :too_large},
      else: {:ok, IO.iodata_to_binary([acc | [chunk]])}
  end
end
