defmodule Vagus.Backup.Walk do
  @moduledoc """
  Walks a directory tree through the `vagus_walk` port program, which opens
  every entry relative to its parent descriptor with
  `RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS`: the kernel, not a path check, keeps
  the walk inside `root` even while the tree's owner swaps a directory for a
  symlink. The BEAM has no descriptor-relative no-follow directory operations,
  hence the port (a port, not a NIF, so a walker bug kills the port and not
  the VM that owns every app process).

  Protocol (`{:packet, 4}` frames, one tag byte then NUL-separated fields):

    * `D rel` - a directory
    * `F rel mode mtime size`, then `C bytes` chunks (at most 64 KiB), then `E`
    * `S rel reason` - skipped (a symlink, fifo, socket or device, an open the
      resolve flags refused, or a name that vanished)
    * `X rel errno` - a real error; the walker exits non-zero after it
    * `Z` - the walk completed

  A file that shrinks while read arrives shorter than its announced `size`;
  the bytes delivered are what was read. The root itself is never emitted.
  """

  @max_bytes 536_870_912
  # Per frame, not per walk: the walker is silent only while blocked in a read.
  @idle_timeout 60_000

  @skip_reasons Map.new(
                  ~w(symlink fifo socket device other eloop exdev enoent changed)a,
                  &{Atom.to_string(&1), &1}
                )
  @errnos Map.new(
            ~w(eio eacces eperm enomem emfile enfile enametoolong enotdir enosys einval estale eother)a,
            &{Atom.to_string(&1), &1}
          )

  @type meta :: %{mode: non_neg_integer(), mtime: integer(), size: non_neg_integer()}
  @type entry ::
          {:dir, String.t()}
          | {:file, String.t(), meta(), binary()}
          | {:skip, String.t(), atom()}
  @type error ::
          :too_large
          | :malformed
          | :timeout
          | {:read, String.t(), atom()}
          | {:walker, non_neg_integer()}

  @doc """
  Reduces `fun` over the entries under `root`. `{:halt, acc}` stops the walk
  early and still returns `{:ok, acc}`. `opts[:max_bytes]` caps the file bytes
  of the whole walk.
  """
  @spec each_entry(Path.t(), acc, (entry(), acc -> {:cont, acc} | {:halt, acc}), keyword()) ::
          {:ok, acc} | {:error, error()}
        when acc: term()
  def each_entry(root, acc, fun, opts \\ []) do
    exe = Keyword.get_lazy(opts, :executable, &walker_path/0)

    port =
      Port.open({:spawn_executable, exe}, [:binary, {:packet, 4}, :exit_status, args: [root]])

    state = %{port: port, fun: fun, budget: Keyword.get(opts, :max_bytes, @max_bytes), file: nil}

    try do
      loop(state, acc)
    after
      close(port)
    end
  end

  @spec walker_path() :: Path.t()
  def walker_path, do: Application.app_dir(:vagus, "priv/vagus_walk")

  defp loop(%{port: port} = state, acc) do
    receive do
      {^port, {:data, frame}} ->
        case frame(frame, state) do
          {:next, state} -> loop(state, acc)
          {:emit, entry, state} -> apply_fun(state, entry, acc)
          :done -> {:ok, acc}
          {:error, _} = error -> error
        end

      {^port, {:exit_status, status}} ->
        {:error, {:walker, status}}
    after
      @idle_timeout -> {:error, :timeout}
    end
  end

  defp apply_fun(state, entry, acc) do
    case state.fun.(entry, acc) do
      {:cont, acc} -> loop(state, acc)
      {:halt, acc} -> {:ok, acc}
    end
  end

  defp frame("C" <> bytes, %{file: {rel, meta, chunks, got}} = state) do
    got = got + byte_size(bytes)

    cond do
      got > meta.size ->
        {:error, :malformed}

      byte_size(bytes) > state.budget ->
        {:error, :too_large}

      true ->
        {:next,
         %{
           state
           | file: {rel, meta, [chunks, bytes], got},
             budget: state.budget - byte_size(bytes)
         }}
    end
  end

  defp frame("E", %{file: {rel, meta, chunks, _got}} = state),
    do: {:emit, {:file, rel, meta, IO.iodata_to_binary(chunks)}, %{state | file: nil}}

  defp frame(_frame, %{file: {_, _, _, _}}), do: {:error, :malformed}

  defp frame("D" <> rel, state) do
    if valid_rel?(rel), do: {:emit, {:dir, rel}, state}, else: {:error, :malformed}
  end

  defp frame("F" <> fields, state) do
    with [rel, mode, mtime, size] <- :binary.split(fields, <<0>>, [:global]),
         true <- valid_rel?(rel),
         {mode, ""} <- Integer.parse(mode),
         {mtime, ""} <- Integer.parse(mtime),
         {size, ""} when size >= 0 <- Integer.parse(size) do
      {:next, %{state | file: {rel, %{mode: mode, mtime: mtime, size: size}, [], 0}}}
    else
      _ -> {:error, :malformed}
    end
  end

  defp frame("S" <> fields, state) do
    with [rel, reason] <- :binary.split(fields, <<0>>),
         true <- valid_rel?(rel),
         {:ok, reason} <- Map.fetch(@skip_reasons, reason) do
      {:emit, {:skip, rel, reason}, state}
    else
      _ -> {:error, :malformed}
    end
  end

  defp frame("X" <> fields, _state) do
    case :binary.split(fields, <<0>>) do
      [rel, errno] -> {:error, {:read, rel, Map.get(@errnos, errno, :eother)}}
      _ -> {:error, :malformed}
    end
  end

  defp frame("Z", _state), do: :done
  defp frame(_frame, _state), do: {:error, :malformed}

  # The tar writer joins `rel` under `data/`, so the walker's output is
  # checked rather than trusted to be a plain relative path.
  defp valid_rel?(rel) do
    rel != "" and not String.contains?(rel, <<0>>) and
      Enum.all?(String.split(rel, "/"), &(&1 not in ["", ".", ".."]))
  end

  # Closing a port that already exited raises, and that exit races any
  # check made first. Its leftover messages would otherwise land in the
  # caller's mailbox.
  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  after
    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end
end
