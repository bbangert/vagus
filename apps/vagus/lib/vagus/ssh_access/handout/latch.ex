defmodule Vagus.SSHAccess.Handout.Latch do
  @moduledoc """
  The file whose presence keeps `Vagus.SSHAccess.Handout` shut for good.
  """

  import Bitwise, only: [band: 2]

  require Logger

  # Fails closed: a board whose /data cannot be read must not hand out its key.
  # path is config-derived (start-up opts / app env), not request input
  # sobelow_skip ["Traversal.FileModule"]
  @spec present?(Path.t()) :: boolean()
  def present?(path) do
    case File.stat(path) do
      {:ok, _stat} ->
        true

      {:error, :enoent} ->
        false

      {:error, reason} ->
        Logger.error(
          "SSH key handout: cannot stat latch #{path} (#{inspect(reason)}), treating it as present"
        )

        true
    end
  end

  @doc """
  Creates the latch, synced so a power cut soon after the first login cannot
  lose it. An existing latch is success: another login won the race.
  `{:error, {:partial, reason}}` means the file exists, so the device is
  latched, but its content or mode is not what was asked for.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec write(Path.t(), iodata()) :: :ok | {:error, {:partial, term()}} | {:error, term()}
  def write(path, content) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- create_synced(path, content) do
      check_mode(path)
    else
      :eexist -> :ok
      {:error, _reason} = error -> error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp create_synced(path, content) do
    case File.open(path, [:write, :binary, :exclusive], fn io ->
           with :ok <- IO.binwrite(io, content), do: :file.datasync(io)
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, {:partial, reason}}
      {:error, :eexist} -> :eexist
      {:error, _reason} = error -> error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp check_mode(path) do
    with :ok <- File.chmod(path, 0o600),
         {:ok, %File.Stat{mode: mode}} <- File.stat(path),
         0o600 <- band(mode, 0o777) do
      :ok
    else
      {:error, reason} -> {:error, {:partial, reason}}
      mode -> {:error, {:partial, {:mode, Integer.to_string(mode, 8)}}}
    end
  end
end
