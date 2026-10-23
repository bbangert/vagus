defmodule Vagus.Sysfs do
  @moduledoc """
  The few sysfs reads Vagus does instead of asking udev, which Nerves does
  not run. Shared by `Vagus.Backend.Host.Hardware` and `Vagus.Devices`.

  Every path these take is built from directory enumeration and symlink
  resolution under a fixed root, never from request input, so none of the
  reads below can be steered outside sysfs by a caller.
  """

  @doc "Sorted entries of `path`, `[]` when it cannot be listed."
  @spec ls(Path.t()) :: [String.t()]
  def ls(path) do
    case File.ls(path) do
      {:ok, entries} -> Enum.sort(entries)
      {:error, _reason} -> []
    end
  end

  @doc """
  Resolves a `/sys/class` or `/sys/bus/*/devices` entry to its canonical
  `/sys/devices` path, like udev's `sys_path`. One level is enough: the
  kernel's entries point straight into `/sys/devices`. A non-symlink keeps
  its literal path.
  """
  @spec canonical(Path.t()) :: Path.t()
  def canonical(entry) do
    case File.read_link(entry) do
      {:ok, target} -> Path.expand(target, Path.dirname(entry))
      {:error, _reason} -> entry
    end
  end

  @doc "The device's `uevent` key/values: the kernel's own udev-property subset."
  @spec uevent(Path.t()) :: %{String.t() => String.t()}
  # sobelow_skip ["Traversal.FileModule"]
  def uevent(sysfs) do
    case File.read(Path.join(sysfs, "uevent")) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case String.split(line, "=", parts: 2) do
            [key, value] -> [{key, value}]
            _other -> []
          end
        end)
        |> Map.new()

      {:error, _reason} ->
        %{}
    end
  end

  @doc "A single-value attribute file, trimmed; `nil` when absent or empty."
  @spec attr(Path.t(), String.t()) :: String.t() | nil
  # sobelow_skip ["Traversal.FileModule"]
  def attr(sysfs, name) do
    case File.read(Path.join(sysfs, name)) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> nil
          value -> value
        end

      {:error, _reason} ->
        nil
    end
  end
end
