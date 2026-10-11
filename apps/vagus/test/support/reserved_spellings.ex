defmodule Vagus.ReservedSpellings do
  @moduledoc """
  Spellings of a Core view that read as it only after more than one
  percent-decode: none is the view as written or decoded once. Core decodes a forwarded path once, so none of these is the
  view to Core; upstream refuses them all the same, on the fully decoded path.
  """

  @doc "One byte under `layers` rounds of percent-encoding: `layered(\"h\", 2)` is `%2568`."
  @spec layered(String.t(), pos_integer()) :: String.t()
  def layered(<<byte>>, layers) when layers >= 1 do
    Enum.reduce(2..layers//1, "%" <> Base.encode16(<<byte>>), fn _layer, escape ->
      String.replace(escape, "%", "%25")
    end)
  end

  @doc """
  `{label, tail}` per spelling of `segments`, a view's own segments (what
  follows `api`). A tail is appended to `/core/api/` or `/api/` as it stands.
  """
  @spec multiply_encoded([String.t()]) :: [{String.t(), String.t()}]
  def multiply_encoded([view | more]) do
    <<first::binary-size(1), rest::binary>> = view
    tail = fn spelled -> Enum.join([spelled | more], "/") end
    twice = layered(first, 2) <> rest

    [
      {"first character twice", tail.(twice)},
      {"first character twice, lower-case hex", tail.(String.downcase(twice))},
      {"first character three times", tail.(layered(first, 3) <> rest)},
      {"first character eight times", tail.(layered(first, 8) <> rest)},
      {"every character twice", tail.(each(view, fn char, _at -> layered(char, 2) end))},
      {"every character three times", tail.(each(view, fn char, _at -> layered(char, 3) end))},
      {"once and twice alternating",
       tail.(each(view, fn char, at -> layered(char, rem(at, 2) + 1) end))},
      {"plain, twice and three times in turn",
       tail.(
         each(view, fn char, at ->
           if rem(at, 3) == 0, do: char, else: layered(char, rem(at, 3) + 1)
         end)
       )},
      {"an escape whose own characters are escaped", tail.("%25%36%38" <> rest)},
      {"first character twice, %252F for every slash",
       Enum.join([twice | more], "%252F") <> "%252Fz"},
      {"first character three times, %25252f for every slash",
       Enum.join([layered(first, 3) <> rest | more], "%25252f") <> "%25252fz"},
      {"a leading %252F", "%252F" <> tail.(view)},
      {"behind %252e", "%252e/" <> tail.(view)},
      {"behind %252E, twice", "%252E/" <> tail.(twice)},
      {"behind %252e%252f, twice", "%252e%252f" <> tail.(twice)},
      {"behind `.`, three times", "./" <> tail.(layered(first, 3) <> rest)},
      {"behind `.` and %2e, twice", "./%2e/" <> tail.(twice)}
    ]
  end

  defp each(view, fun) do
    view
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.map_join(fn {char, at} -> fun.(char, at) end)
  end
end
