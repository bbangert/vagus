defmodule Vagus.RunState do
  @moduledoc """
  Process-restart checkpoints for state that holds credentials (add-on bearer
  tokens, passwords), kept in a tmpfs directory.

  The files live exactly one application run: `reset_dir/0` replaces the
  directory at app start, or turns checkpointing off for the run if it
  cannot, so a file is never older than the app instance reading it. Content
  is `:erlang.term_to_binary/1` of the owner's state.

  A failed `save/2` deletes the existing file as well: an older checkpoint
  can revive a revoked token on the next process restart, while an empty
  reload fails closed. If the delete fails too the older file survives, which
  is a double fault this module does not try to engineer around.

  Every function is non-fatal. Failures are logged by path and reason only,
  never content.
  """

  require Logger

  @spec reset_dir() :: :ok
  def reset_dir do
    case Application.get_env(:vagus, :run_state_dir) do
      nil -> :ok
      dir -> do_reset_dir(dir)
    end
  end

  @spec path(atom()) :: Path.t() | nil
  def path(name) when is_atom(name) do
    case Application.get_env(:vagus, :run_state_dir) do
      nil -> nil
      dir -> Path.join(dir, "#{name}.term")
    end
  end

  @spec load(Path.t() | nil, default) :: term() | default when default: term()
  def load(nil, default), do: default
  def load(path, default), do: do_load(path, default)

  @spec save(Path.t() | nil, term()) :: :ok
  def save(nil, _term), do: :ok
  def save(path, term), do: do_save(path, term)

  # `mkdir` rather than `mkdir_p` for the leaf: it fails on a directory this
  # call did not create, whose contents nobody vetted. On any failure the
  # servers run memory-only rather than load from such a directory.
  #
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp do_reset_dir(dir) do
    with {:ok, _} <- File.rm_rf(dir),
         :ok <- File.mkdir_p(Path.dirname(dir)),
         :ok <- File.mkdir(dir),
         :ok <- File.chmod(dir, 0o700) do
      :ok
    else
      {:error, reason, file} -> disable(dir, "#{inspect(reason)} at #{file}")
      {:error, reason} -> disable(dir, inspect(reason))
    end
  end

  defp disable(dir, detail) do
    Application.put_env(:vagus, :run_state_dir, nil)
    Logger.error("run state dir #{dir} reset failed, checkpointing disabled: #{detail}")
  end

  # path is internal/config-derived, not request input; the file is written
  # only by this VM into a 0700 tmpfs dir and decoded with `[:safe]`
  # sobelow_skip ["Traversal.FileModule", "Misc.BinToTerm"]
  defp do_load(path, default) do
    case File.read(path) do
      {:ok, bin} ->
        try do
          :erlang.binary_to_term(bin, [:safe])
        rescue
          ArgumentError ->
            Logger.warning("run state #{path} unusable: :undecodable")
            default
        end

      {:error, :enoent} ->
        default

      {:error, reason} ->
        Logger.warning("run state #{path} unreadable: #{inspect(reason)}")
        default
    end
  end

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp do_save(path, term) do
    tmp = path <> ".tmp"

    # chmod before the rename so the final name never exists with a wider mode
    with :ok <- File.write(tmp, :erlang.term_to_binary(term)),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(path)
        File.rm(tmp)
        Logger.error("run state #{path} save failed, checkpoint dropped: #{inspect(reason)}")
        :ok
    end
  end
end
