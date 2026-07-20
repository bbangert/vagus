defmodule Vagus.API.Model do
  @moduledoc """
  `use`-able macro for declaring the exact wire shape of a Supervisor-API
  response model.

  Home Assistant Core deserializes every response through mashumaro
  dataclasses with **no field defaults** — a missing key is a hard crash in
  Core (`docs/contract-2026.7.md` §6). Conversely, project policy here is
  stricter than the real Supervisor: extra/undeclared keys are FORBIDDEN,
  not just tolerated, so a typo or drifted field list gets caught instead of
  silently shipping garbage.

  A model module does:

      defmodule Vagus.API.Models.Example do
        use Vagus.API.Model,
          required: [:always_present],
          nullable: [:optional_but_declared]
      end

  `required` keys must be supplied by the caller of `build!/1` — there is no
  sensible auto-default for them (often because the wire type doesn't allow
  `null`, so silently defaulting to `nil` would ship a type violation).
  `nullable` keys are auto-defaulted to `nil` when the caller omits them,
  but a caller MAY still pass a concrete value for one (`Map.merge/2` lets
  the caller's value win over the `nil` default).

  `build!/1` merges the nullable defaults into the given attrs, then
  verifies the result's key set is EXACTLY `required ∪ nullable` — no
  missing keys, no extra ones. On violation: raises in strict mode
  (`config :vagus, :model_strict`, `true` in `config/test.exs`), or logs an
  error and returns the (possibly wrong) map in lenient mode — a malformed
  response is still preferable to crashing the whole emulator in
  production.
  """

  require Logger

  @strict Application.compile_env(:vagus, :model_strict, false)

  defmacro __using__(opts) do
    required = Keyword.fetch!(opts, :required)
    nullable = Keyword.get(opts, :nullable, [])

    quote do
      @doc """
      Builds and validates a response map for #{inspect(__MODULE__)}.

      `attrs` must supply every required key (#{inspect(unquote(required))});
      nullable keys (#{inspect(unquote(nullable))}) default to `nil` when
      omitted.
      """
      @spec build!(map()) :: map()
      def build!(attrs) when is_map(attrs) do
        Vagus.API.Model.build(attrs, unquote(required), unquote(nullable), __MODULE__)
      end
    end
  end

  @doc false
  @spec build(map(), [atom()], [atom()], module()) :: map()
  def build(attrs, required, nullable, module) do
    defaults = Map.new(nullable, &{&1, nil})
    result = Map.merge(defaults, attrs)

    declared = MapSet.new(required ++ nullable)
    present = MapSet.new(Map.keys(result))

    missing = MapSet.difference(MapSet.new(required), present)
    extra = MapSet.difference(present, declared)

    if MapSet.size(missing) > 0 or MapSet.size(extra) > 0 do
      handle_violation(module, missing, extra)
    end

    result
  end

  defp handle_violation(module, missing, extra) do
    message =
      "#{inspect(module)}.build!/1 violated its declared shape: " <>
        "missing=#{inspect(MapSet.to_list(missing))} extra=#{inspect(MapSet.to_list(extra))}"

    if @strict do
      raise ArgumentError, message
    else
      Logger.error(message)
    end
  end
end
