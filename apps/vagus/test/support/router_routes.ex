defmodule Vagus.RouterRoutes do
  @moduledoc """
  Every route `Vagus.API.Router` registers, read from its source.

  `Plug.Router` compiles routes into function clauses and keeps no list, so
  the source is the only place to enumerate them. A route is read only where
  it can be read with certainty: a top-level statement of the module with a
  literal path. A route macro anywhere else in the module (inside a `for`,
  an `if`, a function), or with a computed path, raises instead of being
  skipped, because a skipped route is one no test grades. The catch-all
  `match _` is the one exception.
  """

  @router Path.expand("../../lib/vagus/api/router.ex", __DIR__)
  @external_resource @router

  @verbs ~w(get post put patch delete options head)a
  @macros [:match, :forward | @verbs]

  # `:slug` takes two values because the table grades the literal `self`
  # differently from every other slug.
  @params %{
    "slug" => ["core_ssh", "self"],
    "ifname" => ["eth0"],
    "uuid" => ["8ced93a7"],
    "service" => ["mqtt"],
    "bootid" => ["0"],
    "version" => ["1.2.3"]
  }

  @doc "`{method, pattern}` per route macro, in router order."
  @spec routes() :: [{String.t(), String.t()}]
  def routes, do: @router |> File.read!() |> parse()

  @doc "`routes/0` for any router source."
  @spec parse(String.t()) :: [{String.t(), String.t()}]
  def parse(source) do
    {:defmodule, _meta, [_alias, [do: body]]} = Code.string_to_quoted!(source)

    body
    |> statements()
    |> Enum.flat_map(&route/1)
  end

  defp statements({:__block__, _meta, statements}), do: statements
  defp statements(statement), do: [statement]

  defp route({verb, _meta, [path | rest]}) when verb in @verbs and is_binary(path) do
    refuse_nested(rest)
    [{verb |> Atom.to_string() |> String.upcase(), path}]
  end

  defp route({:match, _meta, [{:_, _var_meta, context} | rest]}) when is_atom(context) do
    refuse_nested(rest)
    []
  end

  defp route(statement) do
    refuse_nested(statement)
    []
  end

  defp refuse_nested(ast) do
    Macro.prewalk(ast, fn
      {macro, meta, args} when macro in @macros and is_list(args) ->
        raise "line #{meta[:line]}: #{macro} is a route this module cannot read"

      node ->
        node
    end)

    :ok
  end

  @doc "`{method, pattern, path}` with every `:param` filled in."
  @spec instances() :: [{String.t(), String.t(), String.t()}]
  def instances do
    for {method, pattern} <- routes(), path <- expand(pattern), do: {method, pattern, path}
  end

  defp expand(pattern) do
    pattern
    |> String.split("/", trim: true)
    |> Enum.map(&values/1)
    |> Enum.reduce([""], fn values, prefixes ->
      for prefix <- prefixes, value <- values, do: prefix <> "/" <> value
    end)
  end

  defp values(":" <> param), do: Map.fetch!(@params, param)
  defp values("*" <> _glob = segment), do: raise("no instance for glob segment #{segment}")
  defp values(literal), do: [literal]
end
