defmodule Vagus.Runtime.Mountinfo do
  @moduledoc """
  Reads `/proc/self/mountinfo`: one line per mount, the fifth field its
  mount point with spaces and the like written as octal escapes, the
  fstype first after the ` - ` separator.
  """

  @spec read(Path.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, File.posix()}
  # The path is a module default or a test's temp file, never request input.
  # sobelow_skip ["Traversal.FileModule"]
  def read(path) do
    with {:ok, text} <- File.read(path), do: {:ok, parse(text)}
  end

  @doc "`{mount_point, fstype}` per line, in the file's order; malformed lines are skipped."
  @spec parse(String.t()) :: [{String.t(), String.t()}]
  def parse(text) do
    for line <- String.split(text, "\n", trim: true),
        [fields, after_sep] <- [String.split(line, " - ", parts: 2)],
        [_id, _parent, _dev, _root, point | _] <- [String.split(fields, " ")],
        [fstype | _] <- [String.split(after_sep, " ")],
        do: {unescape(point), fstype}
  end

  @spec unescape(String.t()) :: String.t()
  def unescape(point) do
    Regex.replace(~r/\\([0-7]{3})/, point, fn _, octal -> <<String.to_integer(octal, 8)>> end)
  end
end
