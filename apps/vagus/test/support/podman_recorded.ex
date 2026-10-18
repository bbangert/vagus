defmodule Vagus.Test.PodmanRecorded do
  @moduledoc """
  What a real podman printed, from `test/fixtures/podman/cli_results.txt`,
  keyed by the command line after `podman `.
  """

  @fixture Path.expand("../fixtures/podman/cli_results.txt", __DIR__)
  @external_resource @fixture

  @recorded @fixture
            |> File.read!()
            |> String.split(~r/^\$ podman /m, trim: true)
            |> Map.new(fn entry ->
              [cmd, "[exit " <> rest] = String.split(entry, "\n", parts: 2)
              [code, output] = String.split(rest, "]\n", parts: 2)
              {cmd, {String.to_integer(code), output}}
            end)

  @spec fetch!(String.t()) :: {non_neg_integer(), String.t()}
  def fetch!(cmd), do: Map.fetch!(@recorded, cmd)
end
