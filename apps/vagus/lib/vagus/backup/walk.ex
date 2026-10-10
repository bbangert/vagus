defmodule Vagus.Backup.Walk do
  @moduledoc """
  Walks a directory tree through the `vagus_walk` port program, which opens
  every entry relative to its parent descriptor with
  `RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_XDEV`: the kernel, not a
  path check, keeps the walk inside `root` even while the tree's owner swaps a
  directory for a symlink. The BEAM has no descriptor-relative no-follow
  directory operations, hence the port (a port, not a NIF, so a walker bug
  kills the port and not the VM that owns every app process).

  Protocol (`{:packet, 4}` frames, one tag byte then NUL-separated fields):

    * `D rel` - a directory
    * `F rel mode mtime size`, then `C bytes` chunks (at most 64 KiB), then `E`
    * `S rel reason` - skipped (a symlink, fifo, socket or device, a directory
      nested deeper than 64 levels, a mount point, an open the resolve flags
      refused, or a name that vanished)
    * `X rel errno` - a real error; the walker exits non-zero after it
    * `Z` - the walk completed

  The walker waits for an ack (an empty frame) after every frame but `X` and
  `Z`. It is sent once the frame is consumed (a chunk spooled, an entry's
  callback returned), so at most one frame is ever queued and a slow consumer
  slows the walker instead of filling the mailbox.

  A file that shrinks while read arrives shorter than its announced `size`;
  the bytes delivered are what was read. The root itself is never emitted.
  """

  @max_bytes 536_870_912
  # Per frame, not per walk: the walker is silent only while blocked in a read.
  @idle_timeout 60_000

  # Fixed lists, never String.to_atom: the names come from the walker.
  @skips ~w(symlink fifo socket device other depth eloop exdev enoent changed)a
  @errnos ~w(eio eacces eperm enomem emfile enfile enametoolong enotdir enosys einval estale
             enoent eloop exdev)a

  @type meta :: %{mode: 0..0o7777, mtime: integer(), size: non_neg_integer()}
  @type entry ::
          {:dir, String.t()}
          | {:file, String.t(), meta(), Path.t()}
          | {:skip, String.t(), atom()}
  @type error ::
          :too_large
          | :malformed
          | :timeout
          | :no_walker
          | {:read, String.t(), atom()}
          | {:spool, File.posix()}
          | {:walker, non_neg_integer() | atom()}
  @type step(acc) :: {:cont, acc} | {:cont, acc, :keep} | {:halt, acc}

  @doc """
  Reduces `fun` over the entries under `root`. `{:halt, acc}` stops the walk
  early and still returns `{:ok, acc}`.

  A file's bytes are spooled to a file in `opts[:spool_dir]` (required: the
  caller's private staging directory), whose path the `{:file, ...}` entry
  carries. It is deleted once `fun` returns, unless `fun` returns
  `{:cont, acc, :keep}`, which means `fun` has renamed it away; a spool
  file still in place then fails the next file's spool with `:eexist`.
  `opts[:max_bytes]` caps the spooled bytes of the whole walk.
  """
  @spec each_entry(Path.t(), acc, (entry(), acc -> step(acc)), keyword()) ::
          {:ok, acc} | {:error, error()}
        when acc: term()
  # The spool path is under the caller's own staging directory, not input.
  # sobelow_skip ["Traversal.FileModule"]
  def each_entry(root, acc, fun, opts) do
    spool =
      Path.join(Keyword.fetch!(opts, :spool_dir), ".walk-#{System.unique_integer([:positive])}")

    exe = Keyword.get_lazy(opts, :executable, &walker_path/0)

    if File.regular?(exe) do
      port =
        Port.open({:spawn_executable, exe}, [:binary, {:packet, 4}, :exit_status, args: [root]])

      {:os_pid, pid} = Port.info(port, :os_pid) || {:os_pid, nil}
      budget = Keyword.get(opts, :max_bytes, @max_bytes)
      state = %{port: port, pid: pid, fun: fun, spool: spool, budget: budget, file: nil}

      try do
        loop(state, acc)
      after
        close(port)
        File.rm(spool)
      end
    else
      {:error, :no_walker}
    end
  end

  @spec walker_path() :: Path.t()
  def walker_path, do: Application.app_dir(:vagus, "priv/vagus_walk")

  defp loop(%{port: port} = state, acc) do
    receive do
      {^port, {:data, frame}} ->
        case frame(frame, state) do
          {:next, state} -> next(state, acc)
          {:emit, entry, state} -> apply_fun(state, entry, acc)
          :done -> {:ok, acc}
          {:error, _} = error -> stop(state, error)
        end

      {^port, {:exit_status, status}} ->
        stop(state, {:error, {:walker, status}})

      {:EXIT, ^port, reason} ->
        stop(state, {:error, {:walker, reason}})
    after
      @idle_timeout -> state |> kill() |> stop({:error, :timeout})
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp apply_fun(state, entry, acc) do
    case state.fun.(entry, acc) do
      {:cont, acc, :keep} -> next(state, acc)
      {:cont, acc} -> next(tap(state, &File.rm(&1.spool)), acc)
      {:halt, acc} -> stop(kill(state), {:ok, acc})
    end
  end

  # A send, not Port.command, which raises once the walker's exit has closed
  # the port. A walker that died before reading its ack makes the write fail
  # with EPIPE and the port exit :epipe, which kills a caller not trapping exits.
  defp next(state, acc) do
    send(state.port, {self(), {:command, ""}})
    loop(state, acc)
  end

  # Closing the port only closes the walker's pipes, which a walker blocked
  # in a read never notices. Killed before the close, while the pid is
  # certainly still the walker's.
  defp kill(%{pid: nil} = state), do: state
  # pid is the integer Port.info returned, not input. :os.cmd over
  # System.cmd because a best-effort kill must never raise.
  # sobelow_skip ["CI.OS"]
  # credo:disable-for-next-line Credo.Check.Warning.UnsafeExec
  defp kill(%{pid: pid} = state), do: tap(state, fn _ -> :os.cmd(~c"kill -9 #{pid}") end)

  defp stop(%{file: {_, _, io, _}}, result), do: tap(result, fn _ -> File.close(io) end)
  defp stop(_state, result), do: result

  defp frame("C" <> bytes, %{file: {rel, meta, io, got}} = state) do
    got = got + byte_size(bytes)
    budget = state.budget - byte_size(bytes)

    cond do
      got > meta.size ->
        {:error, :malformed}

      budget < 0 ->
        {:error, :too_large}

      true ->
        spooled(:file.write(io, bytes), %{state | file: {rel, meta, io, got}, budget: budget})
    end
  end

  defp frame("E", %{file: {rel, meta, _io, _got}} = state),
    do: stop(state, {:emit, {:file, rel, meta, state.spool}, %{state | file: nil}})

  # A read error ends a file without its E.
  defp frame("X" <> fields, _state) do
    case :binary.split(fields, <<0>>) do
      [rel, errno] -> {:error, {:read, rel, known(errno, @errnos) || :eother}}
      _ -> {:error, :malformed}
    end
  end

  defp frame(_frame, %{file: {_, _, _, _}}), do: {:error, :malformed}

  defp frame("D" <> rel, state) do
    if valid_rel?(rel), do: {:emit, {:dir, rel}, state}, else: {:error, :malformed}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp frame("F" <> fields, state) do
    with [rel, mode, mtime, size] <- :binary.split(fields, <<0>>, [:global]),
         true <- valid_rel?(rel),
         {mode, ""} when mode in 0..0o7777 <- Integer.parse(mode),
         {mtime, ""} <- Integer.parse(mtime),
         {size, ""} when size >= 0 <- Integer.parse(size),
         # :exclusive: the spool directory is private, so a file in the way is
         # one a consumer kept (:keep) without moving it away.
         {:ok, io} <- File.open(state.spool, [:write, :raw, :binary, :exclusive]) do
      {:next, %{state | file: {rel, %{mode: mode, mtime: mtime, size: size}, io, 0}}}
    else
      {:error, _} = error -> spooled(error, state)
      _ -> {:error, :malformed}
    end
  end

  defp frame("S" <> fields, state) do
    with [rel, reason] <- :binary.split(fields, <<0>>),
         true <- valid_rel?(rel),
         reason when reason != nil <- known(reason, @skips) do
      {:emit, {:skip, rel, reason}, state}
    else
      _ -> {:error, :malformed}
    end
  end

  defp frame("Z", _state), do: :done
  defp frame(_frame, _state), do: {:error, :malformed}

  defp spooled(:ok, state), do: {:next, state}
  defp spooled({:error, reason}, _state), do: {:error, {:spool, reason}}

  defp known(name, atoms), do: Enum.find(atoms, &(Atom.to_string(&1) == name))

  # The tar writer joins `rel` under `data/`, so the walker's output is
  # checked rather than trusted to be a plain relative path.
  defp valid_rel?(rel) do
    rel != "" and not String.contains?(rel, <<0>>) and
      Enum.all?(String.split(rel, "/"), &(&1 not in ["", ".", ".."]))
  end

  # Once unlinked no EXIT from the port can still arrive (Port.close sends
  # one asynchronously to a caller that traps exits), so the flush is final.
  # Closing a port that already exited raises.
  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  after
    Process.unlink(port)
    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
      {:EXIT, ^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end
end
