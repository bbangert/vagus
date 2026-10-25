defmodule Vagus.SSHAccess.Handout.Latch do
  @moduledoc """
  The file whose presence keeps `Vagus.SSHAccess.Handout` shut for good.
  """

  import Bitwise, only: [band: 2]

  # path is config-derived (start-up opts / app env), not request input
  # sobelow_skip ["Traversal.FileModule"]
  @spec present?(Path.t()) :: boolean()
  def present?(path), do: File.exists?(path)

  # Synced: a power cut soon after the first login must not lose it.
  # sobelow_skip ["Traversal.FileModule"]
  @spec write(Path.t(), iodata()) :: :ok | {:error, term()}
  def write(path, content) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- write_synced(path, content),
         :ok <- File.chmod(path, 0o600),
         {:ok, %File.Stat{mode: mode}} <- File.stat(path) do
      if band(mode, 0o777) == 0o600,
        do: :ok,
        else: {:error, {:mode, Integer.to_string(band(mode, 0o777), 8)}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_synced(path, content) do
    case File.open(path, [:write, :binary], fn io ->
           with :ok <- IO.binwrite(io, content), do: :file.datasync(io)
         end) do
      {:ok, result} -> result
      {:error, _reason} = error -> error
    end
  end
end
