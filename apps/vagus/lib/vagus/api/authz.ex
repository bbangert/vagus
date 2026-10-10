defmodule Vagus.API.Authz do
  @moduledoc """
  The evaluator for the Supervisor-API leg: a principal and an action in, a
  decision out.

  `Vagus.API.Tiers` holds the table and the lattice; `Vagus.API.Auth` asks
  here instead of applying them itself. The Core proxy does not ask yet:
  `Vagus.API.Dispatcher` and `Vagus.API.CoreProxy` still check on their own.

  ## Nothing is looked up

  `authorize/3` decides from its arguments alone: no registry, no process
  call, no I/O. Resolving a token to a principal is the caller's job. A
  decision that depended on runtime state could not be read off the table,
  and the table being diffable against upstream is what this design buys.

  ## Legs

  An action names its leg, and the ctx must name the same one. Only
  `{:rest, :supervisor_api, method, segments}` is implemented. The other
  legs have no clause and raise, deliberately: a catch-all would have to
  answer something, and both answers are wrong. `:ok` opens a leg nobody
  graded; a refusal reads as a decision the table never made, and would stay
  green in a caller wired up before its rows existed.

  ## Both spellings of the path

  `Plug.Router` matches percent-decoded segments while `conn.path_info` is
  raw, so `/core/%72estart` is one path to the table and another to the
  router. Graded raw alone it is the `/core/.+` family and then routes to the
  supervisor-only `/core/restart`. The caller therefore passes the segments
  as the router will see them in `ctx.decoded_segments`, and a path is
  graded under both: blacklisted if either spelling is, allowed only if the
  principal satisfies both requirements. Keeping the raw spelling in the
  decision means encoding a path can only ever cost a caller access.

  ## Order

  The blacklist is checked before the principal is looked at, so no tier
  satisfies it, the supervisor's included (see
  `Vagus.API.Tiers.blacklisted?/1`). Then the lattice. `:anonymous` is not a
  tier: it satisfies the `:anonymous` rows and nothing else, and is told
  `:unauthenticated` rather than `:forbidden` so the caller can answer 401.

  Then the row's predicates (`Vagus.API.Tiers`, "Columns"), every one of
  which must hold. They are the one place the supervisor can be refused short
  of the blacklist: a grant only an app can hold is not Core's.

  Both spellings choose a row and both rows' predicates must hold, but a
  predicate that reads a path segment reads the decoded one: that is the
  value the handler is given, so the gate and the handler's own guard cannot
  disagree about whose slug it is. Every spelling is held to the lattice
  before any predicate is tried, so a caller a tier refuses is answered as a
  tier refuses, whichever spelling it was.

  The method rides in the action and no row reads it, as upstream's patterns
  match the path alone.
  """

  alias Vagus.API.Tiers

  @type principal :: :supervisor | {:addon, map()} | :anonymous

  @type action ::
          {:rest, :supervisor_api | :core_api, method :: String.t(), segments :: [String.t()]}
          | {:ws, :core_api, type :: String.t(), msg :: map()}

  @type ctx :: %{leg: atom(), decoded_segments: [String.t()] | nil}

  # For naming a refusal only; `backup` and `homeassistant` are siblings in the
  # lattice and their order here decides nothing.
  @by_strictness ~w(anonymous bypass default backup homeassistant manager admin supervisor)a

  @forbidden {403, "unauthorized"}
  # `Vagus.API.Router`'s catch-all.
  @not_found {404, "not found"}

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
    spellings = spellings(segments, decoded)

    if Enum.any?(spellings, &Tiers.blacklisted?/1) do
      {:error, :blacklisted}
    else
      case refusal(principal, spellings, decoded) do
        nil -> :ok
        {error, _why} -> error
      end
    end
  end

  @doc """
  The status and message for a caller `authorize/3` refused as forbidden.

  A predicate's refusal is worded as its row says for the method, which is
  as the route's own handler words it: the handlers keep their guards, and
  which of the two refused must not show. On a method the row has no answer
  for there is no handler, and the caller gets the 404 the router would have
  given. A service's refusal names the service as the handler does, from the
  decoded segment, so the message carries the caller's bytes exactly where
  the handler's already did. `refusal_label/2` is the one to log.
  """
  @spec answer(principal(), action(), ctx()) :: {401 | 403 | 404, String.t()}
  def answer(
        principal,
        {:rest, :supervisor_api, method, segments},
        %{leg: :supervisor_api, decoded_segments: decoded}
      )
      when is_binary(method) and is_list(segments) and is_list(decoded) do
    with {_error, %{} = answers} <- refusal(principal, spellings(segments, decoded), decoded),
         {status, :service} <- Map.get(answers, method, @not_found) do
      {status, service_refusal(method, Enum.at(decoded, 1))}
    else
      {status, message} when is_binary(message) -> {status, message}
      _tier_refusal_or_none -> @forbidden
    end
  end

  @doc """
  What to count a refusal of `action` under.

  Built from the stricter of the requirements the table holds for the two
  spellings and the names of their rows' predicates, never from the path or
  the principal, so it is safe to log as it stands. It says what the path
  demands, not which demand the caller failed.
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

  # `{error, :tier}`, or `{error, answers}` from the first row with a predicate
  # that does not hold.
  defp refusal(principal, spellings, decoded) do
    rows = Enum.map(spellings, &Tiers.required_with_predicates/1)

    cond do
      not Enum.all?(rows, fn {requirement, _columns} -> tier?(principal, requirement) end) ->
        {tier_error(principal), :tier}

      columns = Enum.find_value(rows, &unheld(&1, principal, decoded)) ->
        {tier_error(principal), Keyword.fetch!(columns, :answer)}

      true ->
        nil
    end
  end

  defp unheld({_requirement, columns}, principal, decoded) do
    if Enum.all?(Tiers.predicates(columns), &holds?(&1, principal, decoded)),
      do: nil,
      else: columns
  end

  defp tier?(:anonymous, requirement), do: requirement == :anonymous
  defp tier?(principal, requirement), do: Tiers.allows?(Tiers.caller_tier(principal), requirement)

  defp tier_error(:anonymous), do: {:error, :unauthenticated}
  defp tier_error(_principal), do: {:error, :forbidden}

  # No catch-all on the predicate itself: one this module does not know
  # raises rather than passing.
  defp holds?({:caller, :supervisor}, principal, _segments), do: principal == :supervisor

  defp holds?({:subject, :self}, :supervisor, _segments), do: true

  defp holds?({:subject, :self}, {:addon, %{slug: own}}, [_family, subject | _rest])
       when is_binary(own),
       do: subject in ["self", own]

  defp holds?({:subject, :self}, _principal, _segments), do: false

  defp holds?({:requires, :auth_api}, principal, _segments),
    do: match?({:addon, %{auth_api: true}}, principal)

  defp holds?({:requires, {:services_role, :any}}, :supervisor, _segments), do: true

  defp holds?({:requires, {:services_role, :any}}, {:addon, %{services_role: roles}}, [
         _family,
         service | _rest
       ])
       when is_map(roles),
       do: Map.has_key?(roles, service)

  defp holds?({:requires, {:services_role, :any}}, _principal, _segments), do: false

  defp service_refusal("POST", service), do: "Caller may not provide '#{service}'"
  defp service_refusal("DELETE", service), do: "Caller may not delete '#{service}'"
  defp service_refusal(_method, service), do: "Caller not authorized for '#{service}'"
end
