defmodule Vagus.Test.PodmanRecorded do
  @moduledoc """
  What a real podman printed, from `test/fixtures/podman/cli_results.txt`,
  keyed by the command line after `podman `.
  """

  @fixture Path.expand("../fixtures/podman/cli_results.txt", __DIR__)
  @external_resource @fixture

  # The fixture records some commands more than once on purpose (a check
  # run three times stays unhealthy), so repeats are kept and only a lookup
  # of one is refused: which run a test meant would be a guess.
  @recorded @fixture
            |> File.read!()
            |> String.split(~r/^\$ podman /m, trim: true)
            |> Enum.map(fn entry ->
              with [cmd, "[exit " <> rest] <- String.split(entry, "\n", parts: 2),
                   [code, output] <- String.split(rest, "]\n", parts: 2),
                   {status, ""} <- Integer.parse(code) do
                {cmd, {status, output}}
              else
                _ ->
                  [first | _] = String.split(entry, "\n", parts: 2)
                  raise "cli_results.txt: malformed entry `podman #{first}`"
              end
            end)
            |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

  @spec fetch!(String.t()) :: {non_neg_integer(), String.t()}
  def fetch!(cmd) do
    case Map.fetch(@recorded, cmd) do
      {:ok, [result]} -> result
      {:ok, results} -> raise "cli_results.txt: `podman #{cmd}` recorded #{length(results)}×"
      :error -> raise "cli_results.txt: no `podman #{cmd}` recorded"
    end
  end
end
