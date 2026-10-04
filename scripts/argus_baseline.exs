# Argus baseline check: fail CI on any argus finding that has not been reviewed.
#
# Why: `argus: [ignore: [files: ...]]` hides every future finding in a file.
# This script instead accepts only individually reviewed findings, listed in
# `.argus-baseline.exs`, each with a `reason:` (false positive or deliberate
# design). Any finding not in the baseline fails; baseline entries that no
# longer occur are reported as warnings so they get pruned.
#
# Usage (plain `elixir`, no deps; needs Elixir >= 1.18 for the JSON module):
#
#     mix compile                                   # keep build output out of the JSON
#     mix argus --format json > /tmp/argus.json
#     elixir scripts/argus_baseline.exs /tmp/argus.json [.argus-baseline.exs]
#
# Print the current findings as baseline entries (to review and paste in,
# after filling in each `reason:`) instead of checking:
#
#     elixir scripts/argus_baseline.exs --print /tmp/argus.json
#
# Workflow: when CI reports a new finding, fix the code (preferred). Only if
# you have validated that it is a false positive or deliberate design, add
# its entry to `.argus-baseline.exs` with a reason a reviewer can check.
#
# Fingerprint: a finding is identified by `analysis`, `file`, `title` and
# `detail` (from argus' JSON report, `Argus.Report.Json`). `detail` names the
# modules/functions/messages involved, so it tells findings of one class
# apart. Line numbers are never part of it, so edits elsewhere in the file
# don't invalidate the baseline; any `:N`/`line N` reference inside `detail`
# is normalised away for the same reason.

defmodule ArgusBaseline do
  @keys [:analysis, :file, :title, :detail]

  def main(["--print", json]) do
    IO.puts("[")
    json |> findings() |> Enum.each(&print_entry/1)
    IO.puts("]")
  end

  def main([json]), do: main([json, ".argus-baseline.exs"])

  def main([json, baseline_path]) do
    baseline = load_baseline(baseline_path)
    found = json |> findings() |> Enum.map(&fingerprint/1)
    accepted = MapSet.new(baseline, &fingerprint/1)

    new = Enum.reject(found, &MapSet.member?(accepted, &1))
    stale = Enum.reject(baseline, &(fingerprint(&1) in found))

    for entry <- stale do
      IO.puts(
        :stderr,
        "::warning::stale argus baseline entry (no longer reported), remove it: " <>
          describe(entry)
      )
    end

    for fp <- new do
      IO.puts(
        :stderr,
        "::error::unbaselined argus finding: " <> describe(Map.new(Enum.zip(@keys, fp)))
      )
    end

    IO.puts(
      "argus baseline: #{length(found)} findings, #{length(baseline)} baselined, " <>
        "#{length(new)} new, #{length(stale)} stale"
    )

    if new != [], do: System.halt(1)
  end

  def main(_) do
    IO.puts(:stderr, "usage: elixir scripts/argus_baseline.exs [--print] ARGUS_JSON [BASELINE]")
    System.halt(2)
  end

  # `mix argus --format json` prints the report as one line starting with
  # "["; skip anything else that reached stdout (e.g. compiler output).
  defp findings(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "["))
    |> List.last()
    |> Kernel.||(raise "no JSON findings list in #{path}")
    |> JSON.decode!()
    |> Enum.map(fn f -> Map.new(@keys, &{&1, Map.fetch!(f, Atom.to_string(&1))}) end)
  end

  defp load_baseline(path) do
    {entries, _} = Code.eval_file(path)

    for entry <- entries do
      reason = Map.get(entry, :reason)

      unless is_binary(reason) and String.trim(reason) != "",
        do: raise("baseline entry without a reason: " <> describe(entry))

      Map.take(entry, @keys)
    end
  end

  defp fingerprint(f), do: Enum.map(@keys, &normalise(&1, Map.fetch!(f, &1)))

  defp normalise(:detail, text), do: Regex.replace(~r/(:\d+(:\d+)?\b|\blines? \d+)/, text, "")
  defp normalise(_key, value), do: value

  defp describe(f), do: "[#{f.analysis}] #{f.file}: #{f.title} -- #{f.detail}"

  defp print_entry(f) do
    IO.puts("""
      %{
        analysis: #{inspect(f.analysis)},
        file: #{inspect(f.file)},
        title: #{inspect(f.title)},
        detail: #{inspect(f.detail, printable_limit: :infinity)},
        reason: "TODO: why this is a false positive or deliberate design"
      },\
    """)
  end
end

ArgusBaseline.main(System.argv())
