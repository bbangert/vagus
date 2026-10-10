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
      spellings
      |> Enum.map(&grade(principal, Tiers.required(&1)))
      |> Enum.find(:ok, &(&1 != :ok))
    end
  end

  @doc """
  What to count a refusal of `action` under.

  Built from the stricter of the requirements the table holds for the two
  spellings, never from the path, so it is safe to log as it stands.
  """
  @spec refusal_label(action(), ctx()) :: String.t()
  def refusal_label({:rest, :supervisor_api, _method, segments}, %{
        leg: :supervisor_api,
        decoded_segments: decoded
      })
      when is_list(segments) and is_list(decoded) do
    requirement =
      segments
      |> spellings(decoded)
      |> Enum.map(&Tiers.required/1)
      |> Enum.max_by(&Enum.find_index(@by_strictness, fn known -> known == &1 end))

    "authz/" <> Atom.to_string(requirement)
  end

  defp spellings(same, same), do: [same]
  defp spellings(segments, decoded), do: [decoded, segments]

  defp grade(:anonymous, :anonymous), do: :ok
  defp grade(:anonymous, _requirement), do: {:error, :unauthenticated}

  defp grade(principal, requirement) do
    if Tiers.allows?(Tiers.caller_tier(principal), requirement),
      do: :ok,
      else: {:error, :forbidden}
  end
end
