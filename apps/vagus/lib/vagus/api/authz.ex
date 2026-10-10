defmodule Vagus.API.Authz do
  @moduledoc """
  The one place a principal and an action become a decision.

  `Vagus.API.Tiers` holds the table and the lattice; this module is the only
  code that applies them. Every app-reachable leg asks here, so there is one
  evaluation order to get right instead of one per leg.

  ## Nothing is looked up

  `authorize/3` decides from its arguments alone: no registry, no process
  call, no I/O. Resolving a token to a principal is the caller's job. A
  decision that depended on runtime state could not be read off the table,
  and the table being diffable against upstream is what this design buys.

  ## Legs

  An action names its leg. Only `{:rest, :supervisor_api, method, segments}`
  is implemented. The other legs have no clause and raise, deliberately: a
  catch-all would have to answer something, and both answers are wrong. `:ok`
  opens a leg nobody graded; a refusal reads as a decision the table never
  made, and would stay green in a caller wired up before its rows existed.

  ## Order, for the Supervisor API

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

  @type result ::
          :ok
          | {:error, :forbidden | :unauthenticated | :blacklisted}
          | {:intercept, :supervisor_api}

  @spec authorize(principal(), action(), ctx()) :: result()
  def authorize(principal, {:rest, :supervisor_api, method, segments}, %{leg: _leg})
      when is_binary(method) and is_list(segments) do
    if Tiers.blacklisted?(segments) do
      {:error, :blacklisted}
    else
      grade(principal, Tiers.required(segments))
    end
  end

  @doc """
  What to count a refusal of `action` under.

  Built from the requirement the table holds, never from the path, so it is
  safe to log as it stands.
  """
  @spec refusal_label(action()) :: String.t()
  def refusal_label({:rest, :supervisor_api, _method, segments}) when is_list(segments),
    do: "authz/" <> Atom.to_string(Tiers.required(segments))

  defp grade(:anonymous, :anonymous), do: :ok
  defp grade(:anonymous, _requirement), do: {:error, :unauthenticated}

  defp grade(principal, requirement) do
    if Tiers.allows?(Tiers.caller_tier(principal), requirement),
      do: :ok,
      else: {:error, :forbidden}
  end
end
