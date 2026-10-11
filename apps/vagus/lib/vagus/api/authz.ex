defmodule Vagus.API.Authz do
  @moduledoc """
  The evaluator for the Supervisor-API leg: a principal and an action in, a
  decision out. `Vagus.API.Tiers` holds the table and the lattice. The Core
  proxy does not ask here yet.

  Nothing is looked up: no registry, no process call, no I/O. A decision that
  depended on runtime state could not be read off the table, and the table
  being diffable against upstream is what this design buys.

  ## Legs

  Only `{:rest, :supervisor_api, method, segments}` is implemented. The other
  legs have no clause and raise, deliberately: `:ok` would open a leg nobody
  graded, and a refusal would read as a decision the table never made.

  ## Both spellings of the path

  `Plug.Router` matches percent-decoded segments while `conn.path_info` is
  raw, so `/core/%72estart` is the `/core/.+` family to the table and the
  supervisor-only `/core/restart` to the router. Each spelling chooses a row
  and the caller is held to both, so encoding a path can only cost access.

  ## Order

  The blacklist first, before the principal is looked at, so no tier
  satisfies it. Then the lattice, for every spelling, so a caller a tier
  refuses is answered as a tier refuses. `:anonymous` is not a tier: it
  satisfies the `:anonymous` rows only, and is told `:unauthenticated`.

  Then both rows' predicates. They are the one place short of the blacklist
  where the supervisor can be refused: an app's grant is not Core's. A
  predicate reads the decoded segment, the value the handler is given, so
  the gate and the handler's guard cannot disagree about whose slug it is.

  Authorisation ignores the method, as upstream's patterns do. Only a
  refusal's wording is per-method.
  """

  alias Vagus.API.{Refusal, Tiers}
  alias Vagus.App.Policy

  @type principal :: :supervisor | {:addon, map()} | :anonymous

  @type action ::
          {:rest, :supervisor_api | :core_api, method :: String.t(), segments :: [String.t()]}
          | {:ws, :core_api, type :: String.t(), msg :: map()}

  @type ctx :: %{leg: atom(), decoded_segments: [String.t()] | nil}

  # For naming a refusal only; `backup` and `homeassistant` are siblings in the
  # lattice and their order here decides nothing.
  @by_strictness ~w(anonymous bypass default backup homeassistant manager admin supervisor)a

  @type result ::
          :ok
          | {:error, :forbidden | :unauthenticated | :blacklisted}
          | {:intercept, :supervisor_api}

  @spec authorize(principal(), action(), ctx()) :: result()
  def authorize(
        principal,
        {:rest, :supervisor_api, method, segments},
        %{leg: :supervisor_api, decoded_segments: decoded}
      )
      when is_binary(method) and is_list(segments) and is_list(decoded) do
    case decide(principal, segments, decoded) do
      :ok -> :ok
      {error, _why} -> {:error, error}
    end
  end

  @doc """
  What a caller `authorize/3` refused as `:forbidden` is told.

  A predicate's refusal is the route's own handler's, from
  `Vagus.API.Refusal`, so which of the two refused does not show. A method
  the row does not answer has no handler, and gets the router's 404.

  Raises for any other decision: there is nothing to tell a caller who was
  not refused, and a 403 made up here would hide the caller's mistake.
  """
  @spec answer(principal(), action(), ctx()) :: Refusal.t()
  def answer(
        principal,
        {:rest, :supervisor_api, method, segments},
        %{leg: :supervisor_api, decoded_segments: decoded}
      )
      when is_binary(method) and is_list(segments) and is_list(decoded) do
    case decide(principal, segments, decoded) do
      {:forbidden, :tier} ->
        Refusal.answer(:forbidden, method, nil)

      {:forbidden, {:predicate, answers}} ->
        answers |> Map.get(method, :not_found) |> Refusal.answer(method, Enum.at(decoded, 1))

      decision ->
        raise ArgumentError, "answer/3 is for a :forbidden refusal, got #{inspect(decision)}"
    end
  end

  @doc """
  What to count a refusal of `action` under.

  The stricter of the two spellings' requirements and the names of their
  rows' predicates: never the path or the principal, so it is safe to log.
  It says what the path demands, not which demand the caller failed.
  """
  @spec refusal_label(action(), ctx()) :: String.t()
  def refusal_label({:rest, :supervisor_api, _method, segments}, %{
        leg: :supervisor_api,
        decoded_segments: decoded
      })
      when is_list(segments) and is_list(decoded) do
    rows = segments |> spellings(decoded) |> Enum.map(&Tiers.required_with_predicates/1)

    requirement =
      rows
      |> Enum.map(&elem(&1, 0))
      |> Enum.max_by(&Enum.find_index(@by_strictness, fn known -> known == &1 end))

    predicates =
      rows
      |> Enum.flat_map(fn {_requirement, columns} -> Keyword.keys(Tiers.predicates(columns)) end)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.join(["authz/#{requirement}" | predicates], "+")
  end

  defp spellings(same, same), do: [same]
  defp spellings(segments, decoded), do: [decoded, segments]

  defp decide(principal, segments, decoded) do
    spellings = spellings(segments, decoded)
    rows = Enum.map(spellings, &Tiers.required_with_predicates/1)

    cond do
      Enum.any?(spellings, &Tiers.blacklisted?/1) ->
        {:blacklisted, :blacklist}

      not Enum.all?(rows, fn {requirement, _columns} -> tier?(principal, requirement) end) ->
        {refused(principal), :tier}

      true ->
        case Enum.find(rows, &(not held?(&1, principal, decoded))) do
          nil -> :ok
          {_requirement, columns} -> {refused(principal), {:predicate, columns[:answer]}}
        end
    end
  end

  defp tier?(:anonymous, requirement), do: requirement == :anonymous
  defp tier?(principal, requirement), do: Tiers.allows?(Tiers.caller_tier(principal), requirement)

  defp refused(:anonymous), do: :unauthenticated
  defp refused(_principal), do: :forbidden

  defp held?({_requirement, columns}, principal, decoded),
    do: Enum.all?(Tiers.predicates(columns), &holds?(&1, principal, decoded))

  # No catch-all: a predicate this module does not know raises rather than
  # passing. The app-side rules are `Vagus.App.Policy`'s, which the handlers'
  # own guards call too.
  defp holds?({:caller, :supervisor}, principal, _decoded), do: principal == :supervisor

  defp holds?({:subject, :self}, principal, [_family, subject | _rest]),
    do: principal == :supervisor or Policy.own_slug?(principal, subject)

  defp holds?({:requires, :auth_api}, principal, _decoded),
    do: Policy.may_authenticate?(principal)

  defp holds?({:requires, {:services_role, :any}}, principal, [_family, service | _rest]),
    do: Policy.may_read_service?(principal, service)
end
