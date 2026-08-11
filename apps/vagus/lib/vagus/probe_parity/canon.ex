defmodule Vagus.ProbeParity.Canon do
  @moduledoc """
  Canonicalises probe captures (container fingerprints and friends) so a capture
  from a real HAOS box and one from a Vagus device can be compared leaf by leaf.

  A capture is decoded JSON — string keys throughout — and canonicalisation is
  entirely allowlist-driven: every field a reviewer has accepted as varying by
  machine is replaced with the `sentinel/0` string, and everything else is
  compared verbatim. That direction matters. A rule that
  *dropped* volatile fields would also drop the evidence that Vagus injects them
  at all, so masking substitutes rather than deletes: a field that disappears
  still diffs (sentinel versus `:absent`).

  The single exception to "allowlist-driven" is sorting. The probe already emits
  `mounts` sorted by target and `interfaces` sorted by name; re-sorting here
  keeps a hand-edited or hand-merged fixture comparable, since list positions are
  part of the diff path.

  ## Paths and patterns

  Captures contain keys that are themselves paths — `well_known` is keyed by
  `"/data"`, `"/ssl"` — so a slash-joined string cannot be split back into the
  segments it came from. Paths are therefore lists of segments everywhere in
  this API, including `t:divergence/0`; `path_to_string/1` renders one for
  display and is deliberately one-way.

  Allowlist patterns stay slash-separated strings, because the allowlist file is
  human-authored. One pattern segment matches one whole key, which means a key
  containing a slash is only reachable through `*`: `well_known/*/mode`, never
  `well_known//data/mode`. Rather than leave that as a pattern that silently
  matches nothing, an empty segment is rejected at load time.
  """

  @sentinel "<volatile>"
  @wildcard "*"

  # Lists whose element order carries no meaning, and the key that orders them.
  # Kept in sync with the probe's own sort so positions line up either way.
  @sorted %{
    ["fingerprint", "mounts"] => "target",
    ["fingerprint", "interfaces"] => "name"
  }

  @type path :: [String.t()]
  @type entry :: %{path: String.t(), reason: String.t()}
  @type allowlist :: [entry | String.t()]
  @type divergence :: %{path: path(), left: term(), right: term()}

  @doc "The value every allowlisted field is replaced with."
  @spec sentinel() :: String.t()
  def sentinel, do: @sentinel

  @doc """
  Renders a path for humans. One-way: a segment may itself contain a slash.
  """
  @spec path_to_string(path()) :: String.t()
  def path_to_string(path), do: Enum.join(path, "/")

  @doc """
  Reads a volatile-field allowlist: a JSON list of `{"path": ..., "reason": ...}`.

  Raises on an entry with a blank reason. Marking a field volatile shrinks what
  the parity measurement covers, so it has to be argued for in the artifact
  itself rather than in a commit message nobody reads at review time.
  """
  @spec load_allowlist!(Path.t()) :: [entry]
  def load_allowlist!(file) do
    case decode!(file) do
      entries when is_list(entries) -> Enum.map(entries, &entry!(&1, file))
      other -> raise ArgumentError, "#{file}: expected a JSON list, got #{inspect(other)}"
    end
  end

  @doc """
  Normalises `capture` for deep comparison against another canonicalised capture.

  `allowlist` is what `load_allowlist!/1` returns; bare pattern strings are also
  accepted so tests can state a pattern without a file. Patterns are
  slash-separated over the nested structure, with `*` matching any single map key
  or list index: `"fingerprint/mounts/*/source"`.
  """
  @spec canonicalize(map(), allowlist()) :: map()
  def canonicalize(capture, allowlist) when is_map(capture) do
    walk(capture, [], Enum.map(allowlist, &pattern!/1))
  end

  @doc """
  Every leaf that differs between two canonicalised captures, sorted by path.

  A leaf missing on one side is a divergence against `:absent` — an atom, so it
  can never collide with a captured JSON value.
  """
  @spec diff(map(), map()) :: [divergence()]
  def diff(left, right) do
    left_leaves = leaves(left)
    right_leaves = leaves(right)

    (Map.keys(left_leaves) ++ Map.keys(right_leaves))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      left_value = Map.get(left_leaves, path, :absent)
      right_value = Map.get(right_leaves, path, :absent)

      if left_value == right_value,
        do: [],
        else: [%{path: path, left: left_value, right: right_value}]
    end)
  end

  defp entry!(%{"path" => path, "reason" => reason}, file)
       when is_binary(path) and is_binary(reason) do
    cond do
      String.trim(path) == "" -> raise ArgumentError, "#{file}: entry with a blank path"
      String.trim(reason) == "" -> raise ArgumentError, "#{file}: #{path} has a blank reason"
      true -> %{path: parsable!(path, file), reason: reason}
    end
  end

  defp entry!(entry, file) do
    raise ArgumentError, "#{file}: entry needs a path and a reason, got #{inspect(entry)}"
  end

  defp decode!(file) do
    with {:ok, body} <- File.read(file),
         {:ok, decoded} <- Jason.decode(body) do
      decoded
    else
      {:error, %Jason.DecodeError{} = error} ->
        raise ArgumentError, "#{file}: invalid JSON: #{Exception.message(error)}"

      {:error, reason} ->
        raise ArgumentError, "#{file}: cannot read: #{inspect(reason)}"
    end
  end

  defp pattern!(%{path: path}), do: segments!(path, "")
  defp pattern!(%{"path" => path}), do: segments!(path, "")
  defp pattern!(path) when is_binary(path), do: segments!(path, "")

  # Parsing a pattern the loader will only use later is what turns an
  # unmatchable pattern into a load-time error naming the file it came from.
  defp parsable!(path, file) do
    segments!(path, "#{file}: ")
    path
  end

  defp segments!(path, prefix) do
    segments = String.split(path, "/")

    if "" in segments do
      raise ArgumentError,
            "#{prefix}#{path}: a pattern segment matches a whole key, so a key that " <>
              "contains a slash (well_known's \"/data\") is reachable only through *"
    end

    segments
  end

  defp walk(value, path, patterns) do
    if Enum.any?(patterns, &matches?(&1, path)),
      do: @sentinel,
      else: descend(value, path, patterns)
  end

  defp descend(value, path, patterns) when is_map(value) do
    Map.new(value, fn {key, child} -> {key, walk(child, path ++ [to_string(key)], patterns)} end)
  end

  defp descend(value, path, patterns) when is_list(value) do
    value
    |> sort(path)
    |> Enum.with_index(fn child, index ->
      walk(child, path ++ [Integer.to_string(index)], patterns)
    end)
  end

  defp descend(value, _path, _patterns), do: value

  # Entries missing the sort key sort last in file order, rather than first as
  # term ordering would have it (nil < any binary): a malformed capture then
  # cannot shove its broken entries in front and renumber everything after them.
  defp sort(list, path) do
    case Map.fetch(@sorted, path) do
      {:ok, key} ->
        if Enum.all?(list, &is_map/1),
          do: Enum.sort_by(list, &{Map.get(&1, key) == nil, Map.get(&1, key)}),
          else: list

      :error ->
        list
    end
  end

  defp matches?([], []), do: true
  defp matches?([@wildcard | patterns], [_segment | path]), do: matches?(patterns, path)
  defp matches?([segment | patterns], [segment | path]), do: matches?(patterns, path)
  defp matches?(_patterns, _path), do: false

  defp leaves(value), do: value |> collect([]) |> Map.new()

  defp collect(value, path) when is_map(value) and map_size(value) > 0 do
    Enum.flat_map(value, fn {key, child} -> collect(child, [to_string(key) | path]) end)
  end

  defp collect([_ | _] = value, path) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, index} -> collect(child, [Integer.to_string(index) | path]) end)
  end

  # An empty map or list is itself the leaf: "no mounts at all" has to be able
  # to diff against "some mounts".
  defp collect(value, path), do: [{Enum.reverse(path), value}]
end
