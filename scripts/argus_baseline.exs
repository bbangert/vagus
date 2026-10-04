# Argus baseline check: fail CI on any argus finding that has not been reviewed.
#
# Why: `argus: [ignore: [files: ...]]` hides every future finding in a file.
# This script instead accepts only individually reviewed findings, listed in
# `.argus-baseline.exs`, each with a `reason:` (false positive or deliberate
# design). Any finding not in the baseline fails, and so does any baseline
# entry that no longer occurs (stale): a leftover entry would otherwise be a
# spare allowance that silently accepts a future, unreviewed finding with
# the same fingerprint. Remove stale entries in the same change that fixes
# or removes their finding.
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
# Printed entries carry an empty `reason: ""`, which the check rejects, so a
# pasted entry cannot pass until someone writes the review down.
#
# Check this script itself (duplicate fingerprints, placeholder reasons):
#
#     elixir scripts/argus_baseline.exs --self-test
#
# Workflow: when CI reports a new finding, fix the code (preferred). Only if
# you have validated that it is a false positive or deliberate design, add
# its entry to `.argus-baseline.exs` with a reason a reviewer can check.
#
# Fingerprint: a finding is identified by `analysis`, `file`, `title`,
# `at_label` and `detail` (from argus' JSON report, `Argus.Report.Json`).
# `title` names only the class of a finding; per that JSON contract the
# values that tell two findings of one class apart live in `at_label` (the
# label of the finding's own line, `null` when it has none) and `detail`.
# A JSON `null` and a baseline entry without `at_label:` are both `nil`.
# Line numbers are never part of the fingerprint, so edits elsewhere in the
# file don't invalidate the baseline; a source location inside `at_label`
# or `detail` (a `.ex`/`.exs`/`.erl`/`.hrl`/`.eex`/`.heex` path's `:N` or
# `:N:M` suffix, or `line N` text) is normalised away for the same reason.
# Other colon-numbers (ports, tuples) stay part of the fingerprint.
#
# Findings and entries are compared as multisets: argus can report the same
# fingerprint at several places in one file, and each baseline entry accepts
# exactly one occurrence. A third identical finding against two entries is
# new; two entries against one remaining finding leave one stale, which
# fails the check.

defmodule ArgusBaseline do
  @keys [:analysis, :file, :title, :at_label, :detail]
  # Keys a finding/entry must carry; `at_label` may be null or absent (nil).
  @required [:analysis, :file, :title, :detail]

  def main(["--print", json]) do
    IO.puts("[")
    json |> findings() |> Enum.each(&print_entry/1)
    IO.puts("]")
  end

  def main(["--self-test"]), do: self_test()

  def main([json]), do: main([json, ".argus-baseline.exs"])

  def main([json, baseline_path]) do
    baseline = load_baseline(baseline_path)
    found = json |> findings() |> Enum.map(&fingerprint/1)
    {new, stale} = compare(found, baseline)

    for entry <- stale do
      IO.puts(
        :stderr,
        "::error::stale argus baseline entry (no longer reported); remove it from " <>
          "#{baseline_path}: " <> describe(entry)
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

    if verdict(new, stale) == :fail, do: System.halt(1)
  end

  def main(_) do
    IO.puts(
      :stderr,
      "usage: elixir scripts/argus_baseline.exs [--print] ARGUS_JSON [BASELINE] | --self-test"
    )

    System.halt(2)
  end

  # Both unreviewed findings and stale entries fail the check.
  def verdict([], []), do: :ok
  def verdict(_new, _stale), do: :fail

  # Multiset difference: each baseline entry accepts one occurrence of its
  # fingerprint. Returns {unaccepted finding fingerprints, unused entries}.
  def compare(found, baseline) do
    {new, unused} =
      Enum.reduce(found, {[], Enum.group_by(baseline, &fingerprint/1)}, fn fp, {new, pool} ->
        case Map.get(pool, fp, []) do
          [_ | rest] -> {new, Map.put(pool, fp, rest)}
          [] -> {[fp | new], pool}
        end
      end)

    {Enum.reverse(new), unused |> Map.values() |> List.flatten()}
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
    |> Enum.map(fn f ->
      f
      |> Map.take(Enum.map(@keys, &Atom.to_string/1))
      |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
      |> take_keys()
    end)
  end

  defp load_baseline(path) do
    {entries, _} = Code.eval_file(path)
    validate_entries(entries)
  end

  @placeholder ~r/^\s*(TODO|FIXME|TBD)\b/i

  def validate_entries(entries) do
    for entry <- entries do
      reason = Map.get(entry, :reason)

      unless is_binary(reason) and String.trim(reason) != "" and
               not Regex.match?(@placeholder, reason),
             do: raise("baseline entry without a reviewed reason: " <> describe(entry))

      take_keys(entry)
    end
  end

  # The fingerprint keys of a finding or entry: required keys must be
  # present; a missing `at_label` is nil, the same as a JSON null.
  defp take_keys(map) do
    for key <- @required, not Map.has_key?(map, key) do
      raise "argus finding/baseline entry without #{inspect(key)}: #{inspect(map)}"
    end

    Map.new(@keys, &{&1, Map.get(map, &1)})
  end

  defp self_test do
    f = %{
      analysis: "a",
      file: "lib/x.ex",
      title: "T",
      at_label: "message {:a, _} sent here",
      detail: "M.f/1 at lib/x.ex:12"
    }

    g = %{f | detail: "M.g/1"}
    h = %{f | at_label: "message {:b, _} sent here"}
    unlabelled = %{f | at_label: nil}
    reviewed = Map.put(f, :reason, "reviewed")
    # Baseline entries as load_baseline/1 returns them (reason checked, dropped).
    [entry] = validate_entries([reviewed])
    [h_entry] = validate_entries([Map.put(h, :reason, "reviewed")])
    # An entry written without an `at_label:` key matches a null at_label.
    [nil_entry] = validate_entries([reviewed |> Map.delete(:at_label)])
    fp = fingerprint(f)

    checks = [
      {"one entry accepts one occurrence", compare([fp], [entry]) == {[], []}},
      {"line numbers are ignored",
       compare([fingerprint(%{f | detail: "M.f/1 at lib/x.ex:99"})], [entry]) == {[], []}},
      {"a duplicate finding beyond the entries is new",
       compare([fp, fp, fp], [entry, entry]) == {[fp], []}},
      {"an entry beyond the findings is stale", compare([fp], [entry, entry]) == {[], [entry]}},
      {"matching findings and entries pass", verdict([], []) == :ok},
      {"an unreviewed finding fails", verdict([fp], []) == :fail},
      {"a stale entry fails", verdict([], [entry]) == :fail},
      {"one of two duplicate occurrences disappearing fails",
       compare([fp], [entry, entry]) |> then(fn {n, st} -> verdict(n, st) end) == :fail},
      {"different detail is a different finding",
       compare([fingerprint(g)], [entry]) == {[fingerprint(g)], [entry]}},
      {"different at_label is a different finding",
       compare([fingerprint(h)], [entry]) == {[fingerprint(h)], [entry]} and
         compare([fp], [h_entry]) == {[fp], [h_entry]}},
      {"findings differing only by at_label each match their own entry",
       compare([fingerprint(h), fp], [entry, h_entry]) == {[], []}},
      {"line numbers in at_label are ignored",
       compare([fingerprint(%{f | at_label: "sent at lib/x.ex:7"})], [
         Map.take(%{f | at_label: "sent at lib/x.ex:70"}, @keys)
       ]) == {[], []}},
      {"file:line:col and \"line N\" text normalise",
       fingerprint(%{f | detail: "M.f/1 at lib/x.ex:12:3, see line 40"}) ==
         fingerprint(%{f | detail: "M.f/1 at lib/x.ex:98:1, see line 7"})},
      {"other path extensions normalise",
       fingerprint(%{f | detail: "at src/x.erl:5 and include/x.hrl:6 and t.html.heex:7"}) ==
         fingerprint(%{f | detail: "at src/x.erl:50 and include/x.hrl:60 and t.html.heex:70"})},
      {"non-location numbers stay significant",
       fingerprint(%{f | detail: "dials localhost:4000"}) !=
         fingerprint(%{f | detail: "dials localhost:5000"})},
      {"a source path keeps its name when normalised",
       fingerprint(%{f | detail: "at lib/x.ex:12"}) !=
         fingerprint(%{f | detail: "at lib/y.ex:12"})},
      {"null at_label matches an entry without at_label",
       compare([fingerprint(unlabelled)], [nil_entry]) == {[], []}},
      {"null at_label does not match a labelled entry",
       compare([fingerprint(unlabelled)], [entry]) == {[fingerprint(unlabelled)], [entry]}},
      {"empty reason is rejected", rejects?(Map.put(f, :reason, "  "))},
      {"missing reason is rejected", rejects?(f)},
      {"TODO placeholder is rejected", rejects?(Map.put(f, :reason, "TODO: explain"))},
      {"a real reason is accepted", not rejects?(reviewed)}
    ]

    failed = for {name, false} <- checks, do: name
    Enum.each(failed, &IO.puts(:stderr, "self-test FAILED: " <> &1))

    IO.puts(
      "argus baseline self-test: #{length(checks) - length(failed)}/#{length(checks)} passed"
    )

    if failed != [], do: System.halt(1)
  end

  defp rejects?(entry) do
    validate_entries([entry])
    false
  rescue
    RuntimeError -> true
  end

  defp fingerprint(f), do: Enum.map(@keys, &normalise(&1, Map.get(f, &1)))

  # Only source locations are normalised: a source file path's `:N` / `:N:M`
  # suffix (the path itself is kept) and `line N` / `lines N` text. Other
  # colon-numbers (`localhost:4000`, `{:a, 1}:2`) stay significant.
  @location ~r/(\.(?:exs?|erl|hrl|h?eex)):\d+(?::\d+)?\b|\blines? \d+\b/

  defp normalise(key, text) when key in [:at_label, :detail] and is_binary(text),
    do: Regex.replace(@location, text, "\\1")

  defp normalise(_key, value), do: value

  defp describe(f) do
    label = if f[:at_label], do: " (#{f.at_label})", else: ""
    "[#{f.analysis}] #{f.file}: #{f.title}#{label} -- #{f.detail}"
  end

  defp print_entry(f) do
    IO.puts("""
      %{
        analysis: #{inspect(f.analysis)},
        file: #{inspect(f.file)},
        title: #{inspect(f.title)},
        at_label: #{inspect(f.at_label, printable_limit: :infinity)},
        detail: #{inspect(f.detail, printable_limit: :infinity)},
        reason: ""
      },\
    """)
  end
end

ArgusBaseline.main(System.argv())
