defmodule Vagus.API.Tiers.Row do
  @moduledoc """
  Checks a `Vagus.API.Tiers` row when the table is compiled.

  A column `Vagus.API.Authz` does not recognise is a predicate nobody
  evaluates, so a misspelt one has to stop the build rather than pass.
  """

  alias Vagus.API.Refusal

  @predicates [:subject, :caller, :requires]
  @values %{
    subject: [:self],
    caller: [:supervisor],
    requires: [:auth_api, {:services_role, :any}]
  }
  @methods ~w(GET POST PUT PATCH DELETE HEAD OPTIONS)

  @type t :: {pattern :: list(), requirement :: atom(), columns :: keyword()}

  @spec predicates(keyword()) :: keyword()
  def predicates(columns), do: Keyword.take(columns, @predicates)

  @spec validate!({list(), atom()} | t()) :: t()
  def validate!({pattern, requirement}), do: {pattern, requirement, []}

  def validate!({pattern, requirement, columns}) do
    case column_fault(columns) || pattern_fault(pattern, predicates(columns)) do
      nil -> {pattern, requirement, columns}
      fault -> raise ArgumentError, "#{inspect(pattern)}: #{fault}"
    end
  end

  defp column_fault(columns) do
    keys = Keyword.keys(columns)
    predicates = predicates(columns)
    unknown = keys -- [:answer, :handler | @predicates]

    cond do
      keys != Enum.uniq(keys) ->
        "a column is given twice"

      unknown != [] ->
        "unknown columns #{inspect(unknown)}"

      Keyword.has_key?(columns, :handler) and not is_atom(columns[:handler]) ->
        "handler: takes an atom"

      Keyword.has_key?(columns, :handler) and predicates != [] ->
        "a handler-decided row enforces nothing"

      Keyword.has_key?(columns, :answer) != (predicates != []) ->
        "a row has answers exactly when it has predicates"

      Keyword.has_key?(columns, :answer) and not answers?(columns[:answer]) ->
        "answer: maps #{inspect(@methods)} to #{inspect(Refusal.kinds())}"

      true ->
        case Enum.find(predicates, fn {name, value} -> value not in @values[name] end) do
          nil -> nil
          unknown -> "unknown predicate #{inspect(unknown)}"
        end
    end
  end

  defp pattern_fault(pattern, predicates) do
    cond do
      # `Vagus.API.Authz` reads the subject from the second segment.
      reads_subject?(predicates) and Enum.at(pattern, 1) != :_ ->
        "the subject must be the second segment"

      # Any other wildcard would make the subject's position depend on the path.
      predicates != [] and Enum.any?(pattern, &(&1 in [:+, :*, :slug])) ->
        "a row with predicates matches a fixed number of segments"

      true ->
        nil
    end
  end

  defp answers?(answers) when is_map(answers) and map_size(answers) > 0 do
    Enum.all?(answers, fn {method, kind} -> method in @methods and kind in Refusal.kinds() end)
  end

  defp answers?(_answers), do: false

  defp reads_subject?(predicates),
    do: predicates[:subject] != nil or match?({:services_role, _}, predicates[:requires])
end
