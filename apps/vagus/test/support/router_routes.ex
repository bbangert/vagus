defmodule Vagus.RouterRoutes do
  @moduledoc """
  Every route `Vagus.API.Router` registers, read from its source.

  `Plug.Router` compiles routes into function clauses and keeps no list, so
  the source is the only place to enumerate them. Anything route-shaped this
  cannot read raises instead of being skipped: a skipped route is one no
  test grades.
  """

  @router Path.expand("../../lib/vagus/api/router.ex", __DIR__)
  @external_resource @router

  @verbs ~w(get post put patch delete options head)a

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
  def routes do
    {:ok, {:defmodule, _meta, [_alias, [do: {:__block__, _block_meta, body}]]}} =
      @router |> File.read!() |> Code.string_to_quoted()

    Enum.flat_map(body, &route/1)
  end

  defp route({verb, _meta, [path | _rest]}) when verb in @verbs and is_binary(path),
    do: [{verb |> Atom.to_string() |> String.upcase(), path}]

  # The catch-all 404 is not a route.
  defp route({:match, _meta, [{:_, _var_meta, _context} | _rest]}), do: []

  defp route({macro, meta, _args}) when macro in [:match, :forward] or macro in @verbs,
    do: raise("#{@router}:#{meta[:line]}: #{macro} is a route this module cannot read")

  defp route(_other), do: []

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
