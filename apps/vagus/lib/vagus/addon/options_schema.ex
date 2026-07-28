defmodule Vagus.Addon.OptionsSchema do
  @moduledoc """
  Validates add-on user options against an add-on's `schema:` DSL and merges
  them over the config defaults — the Elixir re-implementation of the
  Supervisor's `AppOptions` (`supervisor/apps/options.py`), pinned in
  `docs/contract-2026.7-m4-addendum.md` §A2.

  Extractable later as `vagus_schema` (handoff umbrella note); kept in the
  `vagus` app for now.

  ## Schema shape

  A schema is a map of string keys to *elements*, where an element is one of:

    * a **scalar token string** — `"str"`, `"int(0,100)"`, `"list(a|b|c)"`,
      `"bool?"`, … (grammar below), optionally suffixed `?` for optional;
    * a **one-element list** `["<element>"]` — a homogeneous list of that
      element (the single element may itself be a scalar token or a nested map);
    * a **nested map** `%{"k" => <element>, …}` — an object.

  A list may not directly contain another list (matches the Supervisor's
  `SCHEMA_ELEMENT`); nested maps recurse without bound.

  ## Scalar token grammar (`RE_SCHEMA_ELEMENT`, §A2.1)

  `bool`, `email`, `url`, `port`, `device`, `device(subsystem=<x>)`,
  `str`/`str(min,max)`, `password`/`password(min,max)`,
  `int`/`int(min,max)` (negatives allowed), `float`/`float(min,max)`
  (negatives + decimals), `match(<regex>)`, `list(a|b|c)`. Any token may take a
  trailing `?` to mark the key optional. Empty bound = unbounded
  (`int(5,)`, `str(,10)`).

  ## Semantics (pinned)

    * **Merge** (`merge/2`): user options merge over config defaults with
      `deepmerge` semantics — maps merge recursively, lists and scalars are
      overridden wholesale by the user layer.
    * **Coercion**: `int`/`float`/`port` coerce from numeric strings; `bool`
      accepts the usual truthy/falsy spellings; `list(...)` and `match(...)`
      stringify the value first.
    * **Optionality**: a key is optional iff its element is a token ending in
      `?`, or a one-element list whose element string ends in `?`.
    * **Unknown keys** in the value that are absent from the schema are
      **dropped** (with a warning), never an error.
    * **Missing required** key, or a present key whose value is `nil`, is an
      error.
    * `schema: false` (parsed as the boolean `false`) means "no schema" —
      `validate/3` returns the options unchanged.

  `device`/`device(subsystem=…)` cannot be validated without hardware; on the
  host it accepts any string and is a no-op placeholder (§A7#3 — revisit
  on-device). `!secret <name>` is resolved from the optional `:secrets` map
  before typing; an unknown secret is an error.
  """

  require Logger

  # `match(<regex>)` regexes come from untrusted add-on schemas. Cap the input
  # length and bound PCRE's backtracking steps so a catastrophic-backtracking
  # regex can't pin a scheduler (CPU DoS) — there's no AppArmor backstop.
  @max_match_input 4_096
  @match_limit 100_000

  @type element :: String.t() | [element()] | %{optional(String.t()) => element()}
  @type schema :: %{optional(String.t()) => element()} | false
  @type options :: %{optional(String.t()) => term()}

  @doc """
  Merges `user` options over `defaults` (add-on config `options:` block) with
  deepmerge semantics: maps merge recursively; lists and scalars in `user`
  override `defaults` wholesale.
  """
  @spec merge(options(), options()) :: options()
  def merge(defaults, user) when is_map(defaults) and is_map(user) do
    Map.merge(defaults, user, fn _k, d, u ->
      if is_map(d) and is_map(u) and not struct?(d) and not struct?(u), do: merge(d, u), else: u
    end)
  end

  @doc """
  Merges defaults + user (`merge/2`) then validates against `schema`
  (`validate/3`). Mirrors the Supervisor's `write_options` path.
  """
  @spec effective(schema(), options(), options(), keyword()) ::
          {:ok, options()} | {:error, String.t()}
  def effective(schema, defaults, user, opts \\ []) do
    validate(schema, merge(defaults, user), opts)
  end

  @doc """
  Validates `options` against `schema`, returning `{:ok, validated}` with
  coerced values and unknown keys dropped, or `{:error, message}`.

  Options: `:secrets` — a `%{name => value}` map for `!secret <name>`
  resolution (default `%{}`).
  """
  @spec validate(schema(), options()) :: {:ok, options()} | {:error, String.t()}
  def validate(schema, options), do: validate(schema, options, [])

  @spec validate(schema(), options(), keyword()) :: {:ok, options()} | {:error, String.t()}
  def validate(false, options, _opts), do: {:ok, options}

  def validate(schema, options, opts) when is_map(schema) do
    secrets = Keyword.get(opts, :secrets, %{})

    try do
      {:ok, validate_map(schema, options, "", secrets)}
    rescue
      # Defense-in-depth: a malformed schema/value shape that slips past the
      # explicit clauses becomes an error, never a caller crash (schemas are
      # untrusted add-on config).
      e -> {:error, "invalid schema: " <> Exception.message(e)}
    catch
      {:invalid, message} -> {:error, message}
    end
  end

  @doc """
  Renders the raw `config.yaml` schema into the **UI** schema the frontend's
  Configuration form is built from — upstream's `app.schema_ui`
  (`supervisor/apps/options.py::UiOptions`), a flat list of `ha-form` nodes
  rather than the nested token map.

  Lives here, next to `validate/3`, and shares its `parse_token/2` on purpose:
  the form the user is shown and the rules their input is checked against are
  the same grammar, so a type this can render is a type that validates.

  `false` (an add-on that declares no schema, i.e. `schema: false`) renders as
  `nil` — the field's "there is no form", which is what puts the frontend in
  YAML mode. An empty map renders as an empty list, which is a form with no
  fields; those are different things and the frontend treats them differently.

  Element shapes, matching upstream key-for-key:

    * a token (`"str"`, `"int(1,10)"`, `"list(a|b)"`, …) → one node carrying
      `name`/`type`, plus `format` for password/email/url, `options` for a
      select, `lengthMin`/`lengthMax` for a bounded token, and exactly one of
      `required`/`optional` (the trailing `?`).
    * a one-element list (`["str"]`) → that element's node with
      `multiple: true`.
    * a nested map → a `type: "schema"` node whose own `schema` key holds the
      children's nodes.

  A token this module can't parse is **skipped**, not raised on: upstream's
  `_single_ui_option` returns early on a regex miss, and one unrenderable
  field must not cost the user the whole form.
  """
  @spec ui(schema()) :: nil | [map()]
  def ui(false), do: nil

  def ui(schema) when is_map(schema) do
    Enum.flat_map(schema, fn {key, element} -> ui_element(element, key, false) end)
  end

  def ui(_other), do: nil

  ## Internals

  defp ui_element(element, key, multiple) when is_map(element) do
    [
      %{
        "name" => key,
        "type" => "schema",
        "optional" => true,
        "multiple" => multiple,
        "schema" => Enum.flat_map(element, fn {k, v} -> ui_element(v, k, false) end)
      }
    ]
  end

  # `["str"]` is "a list of str". Upstream asserts the nesting never doubles
  # up (a list inside a list), and renders the inner element as `multiple`.
  defp ui_element([inner], key, false), do: ui_element(inner, key, true)

  defp ui_element(token, key, multiple) when is_binary(token) do
    case parse_ui_token(token) do
      nil ->
        []

      node ->
        node = Map.merge(%{"name" => key}, node)
        node = if multiple, do: Map.put(node, "multiple", true), else: node

        [
          if(String.ends_with?(token, "?"),
            do: Map.put(node, "optional", true),
            else: Map.put(node, "required", true)
          )
        ]
    end
  end

  defp ui_element(_other, _key, _multiple), do: []

  defp parse_ui_token(token) do
    token |> String.trim_trailing("?") |> parse_token("ui") |> ui_node()
  catch
    # `parse_token/2` throws on an unknown type. Upstream's equivalent is a
    # regex miss returning early — the field vanishes from the form, the rest
    # of it still renders.
    {:invalid, _message} -> nil
  end

  # Bounds are emitted as floats because upstream does (`float(group_value)`),
  # and the frontend compares them numerically either way.
  defp ui_node(:bool), do: %{"type" => "boolean"}
  defp ui_node(:email), do: %{"type" => "string", "format" => "email"}
  defp ui_node(:url), do: %{"type" => "string", "format" => "url"}
  defp ui_node(:port), do: %{"type" => "integer"}
  defp ui_node({:device, _filter}), do: %{"type" => "select", "options" => []}
  defp ui_node({:match, _regex}), do: %{"type" => "string"}
  defp ui_node({:list, options}), do: %{"type" => "select", "options" => options}
  defp ui_node({:str, min, max}), do: bounds(%{"type" => "string"}, min, max)

  defp ui_node({:password, min, max}),
    do: bounds(%{"type" => "string", "format" => "password"}, min, max)

  defp ui_node({:int, min, max}), do: bounds(%{"type" => "integer"}, min, max)
  defp ui_node({:float, min, max}), do: bounds(%{"type" => "float"}, min, max)

  defp bounds(node, min, max) do
    node
    |> then(&if(is_nil(min), do: &1, else: Map.put(&1, "lengthMin", min / 1)))
    |> then(&if(is_nil(max), do: &1, else: Map.put(&1, "lengthMax", max / 1)))
  end

  defp validate_map(schema, value, path, secrets) when is_map(schema) do
    unless is_map(value), do: invalid("#{root(path)} must be an object")

    validated =
      Enum.reduce(schema, %{}, fn {key, element}, acc ->
        case Map.fetch(value, key) do
          {:ok, nil} ->
            invalid("Missing required option '#{key}' in #{root(path)}")

          {:ok, v} ->
            Map.put(acc, key, validate_element(element, v, join(path, key), secrets))

          :error ->
            if optional?(element),
              do: acc,
              else: invalid("Missing option '#{key}' in #{root(path)}")
        end
      end)

    # Drop (with a warning) any keys the value carries that the schema omits.
    Enum.each(Map.keys(value), fn k ->
      unless Map.has_key?(schema, k),
        do: Logger.warning("Option '#{join(path, k)}' does not exist in the schema; dropped")
    end)

    validated
  end

  defp validate_element(element, value, path, secrets) when is_map(element),
    do: validate_map(element, value, path, secrets)

  defp validate_element([inner], value, path, secrets) do
    unless is_list(value), do: invalid("#{path} must be a list")

    value
    |> Enum.with_index()
    |> Enum.map(fn {item, i} -> validate_element(inner, item, "#{path}[#{i}]", secrets) end)
  end

  defp validate_element(token, value, path, secrets) when is_binary(token) do
    value = resolve_secret(value, secrets, path)

    token
    |> String.trim_trailing("?")
    |> parse_token(path)
    |> apply_token(value, path)
  end

  # Malformed schema element (empty/multi-element list, a bare bool/number,
  # etc.) — an error, not a FunctionClauseError crash.
  defp validate_element(other, _value, path, _secrets) do
    invalid("#{path} has an invalid schema element: #{inspect(other)}")
  end

  # -- token parsing --------------------------------------------------------

  defp parse_token("bool", _path), do: :bool
  defp parse_token("email", _path), do: :email
  defp parse_token("url", _path), do: :url
  defp parse_token("port", _path), do: :port
  defp parse_token("device", _path), do: {:device, nil}

  defp parse_token(token, path) do
    cond do
      caps = Regex.run(~r/^device\(subsystem=([a-z]+)\)$/, token) ->
        {:device, Enum.at(caps, 1)}

      caps = Regex.run(~r/^str\((\d*),(\d*)\)$/, token) ->
        {:str, bound(caps, 1), bound(caps, 2)}

      "str" == token ->
        {:str, nil, nil}

      caps = Regex.run(~r/^password\((\d*),(\d*)\)$/, token) ->
        {:password, bound(caps, 1), bound(caps, 2)}

      "password" == token ->
        {:password, nil, nil}

      caps = Regex.run(~r/^int\((-?\d*),(-?\d*)\)$/, token) ->
        {:int, bound(caps, 1), bound(caps, 2)}

      "int" == token ->
        {:int, nil, nil}

      caps = Regex.run(~r/^float\((-?\d*\.?\d*),(-?\d*\.?\d*)\)$/, token) ->
        {:float, fbound(caps, 1), fbound(caps, 2)}

      "float" == token ->
        {:float, nil, nil}

      caps = Regex.run(~r/^match\((.*)\)$/s, token) ->
        {:match, Enum.at(caps, 1)}

      caps = Regex.run(~r/^list\((.+)\)$/, token) ->
        {:list, String.split(Enum.at(caps, 1), "|")}

      true ->
        invalid("Unknown type '#{token}' at #{path}")
    end
  end

  # Parse a captured bound. The regex can capture forms `String.to_*/1` would
  # raise on (e.g. a bare `"-"`); an unparseable bound is treated as unbounded
  # rather than crashing.
  defp bound(caps, i) do
    case Enum.at(caps, i) do
      "" ->
        nil

      s ->
        case Integer.parse(s) do
          {n, ""} -> n
          _ -> nil
        end
    end
  end

  defp fbound(caps, i) do
    case Enum.at(caps, i) do
      "" ->
        nil

      s ->
        case Float.parse(pad(s)) do
          {n, ""} -> n
          _ -> nil
        end
    end
  end

  # Normalize a regex-allowed float bound (`-?\d*\.?\d*`) into a form
  # `String.to_float/1` accepts: ".5"->"0.5", "-.5"->"-0.5", "1."->"1.0",
  # "0"->"0.0", "-3"->"-3.0".
  defp pad(s) do
    s = String.replace(s, ~r/^(-?)\./, "\\g{1}0.")
    s = if String.ends_with?(s, "."), do: s <> "0", else: s
    if String.contains?(s, "."), do: s, else: s <> ".0"
  end

  # -- token application (coerce + validate) --------------------------------

  defp apply_token(:bool, value, path), do: coerce_bool(value, path)

  defp apply_token({:str, min, max}, value, path), do: check_str(value, min, max, path)
  defp apply_token({:password, min, max}, value, path), do: check_str(value, min, max, path)

  defp apply_token({:int, min, max}, value, path) do
    coerce_int(value, path) |> in_range(min, max, path)
  end

  defp apply_token({:float, min, max}, value, path) do
    coerce_float(value, path) |> in_range(min, max, path)
  end

  defp apply_token(:port, value, path) do
    coerce_int(value, path) |> in_range(1, 65_535, path)
  end

  defp apply_token(:email, value, path) do
    s = check_str(value, nil, nil, path)

    if Regex.match?(~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/, s),
      do: s,
      else: invalid("#{path} is not an email")
  end

  defp apply_token(:url, value, path) do
    s = check_str(value, nil, nil, path)

    if Regex.match?(~r|^[a-z][a-z0-9+.\-]*://.+|i, s),
      do: s,
      else: invalid("#{path} is not a URL")
  end

  defp apply_token({:match, regex}, value, path) do
    s = to_string(value)

    if byte_size(s) > @max_match_input,
      do: invalid("#{path} exceeds the #{@max_match_input}-byte match limit")

    compiled = compile_regex(regex, path)

    # Python re.match: anchored at start, not required to reach the end.
    # `match_limit`/`match_limit_recursion` bound PCRE backtracking so a
    # catastrophic-backtracking regex can't pin the scheduler; exceeding the
    # limit surfaces as `nomatch` (fails validation, as it should).
    opts = [
      {:capture, :none},
      :anchored,
      {:match_limit, @match_limit},
      {:match_limit_recursion, @match_limit}
    ]

    case :re.run(s, compiled, opts) do
      :match -> s
      :nomatch -> invalid("#{path} does not match #{inspect(regex)}")
    end
  end

  defp apply_token({:list, members}, value, path) do
    s = to_string(value)
    if s in members, do: s, else: invalid("#{path} must be one of #{Enum.join(members, ", ")}")
  end

  # device: unvalidatable without hardware — accept any string (§A7#3).
  defp apply_token({:device, _subsystem}, value, path), do: check_str(value, nil, nil, path)

  # -- scalar coercion helpers ----------------------------------------------

  defp check_str(value, min, max, path) do
    unless is_binary(value), do: invalid("#{path} must be a string")
    len = String.length(value)
    if min && len < min, do: invalid("#{path} is shorter than #{min}")
    if max && len > max, do: invalid("#{path} is longer than #{max}")
    value
  end

  defp coerce_bool(v, _path) when is_boolean(v), do: v

  defp coerce_bool(v, path) do
    case v |> to_string() |> String.downcase() do
      t when t in ~w(true yes on 1) -> true
      f when f in ~w(false no off 0) -> false
      _ -> invalid("#{path} must be a boolean")
    end
  end

  defp coerce_int(v, _path) when is_integer(v), do: v

  defp coerce_int(v, path) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> invalid("#{path} must be an integer")
    end
  end

  defp coerce_int(_v, path), do: invalid("#{path} must be an integer")

  defp coerce_float(v, _path) when is_number(v), do: v / 1

  defp coerce_float(v, path) when is_binary(v) do
    case Float.parse(v) do
      {n, ""} -> n
      _ -> invalid("#{path} must be a number")
    end
  end

  defp coerce_float(_v, path), do: invalid("#{path} must be a number")

  defp in_range(n, min, max, path) do
    if min && n < min, do: invalid("#{path} is below #{min}")
    if max && n > max, do: invalid("#{path} is above #{max}")
    n
  end

  # -- misc -----------------------------------------------------------------

  defp optional?(token) when is_binary(token), do: String.ends_with?(token, "?")
  defp optional?([token]) when is_binary(token), do: String.ends_with?(token, "?")
  defp optional?(_), do: false

  defp resolve_secret("!secret " <> name, secrets, path) do
    case Map.fetch(secrets, String.trim(name)) do
      {:ok, value} -> value
      :error -> invalid("Unknown secret '#{String.trim(name)}' at #{path}")
    end
  end

  defp resolve_secret(value, _secrets, _path), do: value

  defp compile_regex(regex, path) do
    case :re.compile(regex) do
      {:ok, compiled} -> compiled
      {:error, _} -> invalid("#{path} has an invalid match() regex")
    end
  end

  defp struct?(%_{}), do: true
  defp struct?(_), do: false

  defp join("", key), do: key
  defp join(path, key), do: "#{path}.#{key}"
  defp root(""), do: "root"
  defp root(path), do: "'#{path}'"

  defp invalid(message), do: throw({:invalid, message})
end
