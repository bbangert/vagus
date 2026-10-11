defmodule Vagus.API.Authz do
  @moduledoc """
  The evaluator for the Supervisor API and for the Core proxy's REST and
  WebSocket legs: a principal and an action in, a decision out.
  `Vagus.API.Tiers` holds the rules. The ingress proxy and its WebSocket do
  not ask here.

  Nothing is looked up: no registry, no process call, no I/O. A decision that
  depended on runtime state could not be read off the table, and the table
  being diffable against upstream is what this design buys.

  ## Legs

  `{:rest, :supervisor_api, method, segments}` is the Supervisor API,
  `{:rest, :core_api, method, segments}` the proxy into Core's own REST API,
  and `{:ws, :core_api, type, msg}` one command on that proxy's WebSocket.
  Anything else has no clause and raises, deliberately: `:ok` would open a
  leg nobody graded, and a refusal would read as a decision no rule made.

  ## Both spellings of the path

  `Plug.Router` matches percent-decoded segments while `conn.path_info` is
  raw, so `/core/%72estart` is the `/core/.+` family to the table and the
  supervisor-only `/core/restart` to the router. Each spelling chooses a row
  and the caller is held to both, so encoding a path can only cost access.

  The Core proxy forwards the path as written and Core decodes it, so there
  the two spellings are what was sent and what Core will read.

  ## Order on the Supervisor API

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

  ## The Core proxy is inverted

  The proxy speaks to Core as the Supervisor on the caller's behalf, so its
  one question is whether the caller is an app that was granted that:
  `homeassistant_api`. `hassio_api` and the role say nothing about it, and
  the supervisor, which satisfies every tier, is refused: Core does not call
  its own proxy.

  What `Vagus.Core.Reserved` reserves is refused first, whoever asks. A
  WebSocket command is otherwise allowed to a caller this leg admits: a
  denylist, as upstream's is. `supervisor/api` is the exception among the
  reserved commands. For a caller this leg admits it comes back as
  `{:intercept, :supervisor_api}`, which is not `:ok`: the bridge does not
  relay it, and answers it by running the request it names as the app
  (`Vagus.API.CoreProxy.WSDispatch`). Anyone else is refused as for any
  other command.

  That request is then graded on the Supervisor-API leg like any other, for
  the app as it is at that moment. The intercept decides only that the
  command may be answered at all.
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

  def authorize(
        principal,
        {:rest, :core_api, method, segments},
        %{leg: :core_api, decoded_segments: decoded}
      )
      when is_binary(method) and is_list(segments) and is_list(decoded) do
    if segments |> spellings(decoded) |> Enum.any?(&(Tiers.core_api(&1) == :deny)),
      do: {:error, :blacklisted},
      else: core_caller(principal)
  end

  def authorize(principal, {:ws, :core_api, type, _msg}, %{leg: :core_api})
      when is_binary(type) do
    case Tiers.core_ws(type) do
      :deny -> {:error, :blacklisted}
      :allow -> core_caller(principal)
      {:intercept, _target} = intercept -> with :ok <- core_caller(principal), do: intercept
    end
  end

  # A clause of its own for the supervisor, so that nothing here can come to
  # read "the top tier passes".
  defp core_caller(:supervisor), do: {:error, :forbidden}
  defp core_caller(:anonymous), do: {:error, :unauthenticated}

  defp core_caller({:addon, identity} = app) when is_map(identity),
    do: if(Policy.may_call_core?(app), do: :ok, else: {:error, :forbidden})

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
