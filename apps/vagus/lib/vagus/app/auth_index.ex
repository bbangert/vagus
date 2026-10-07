defmodule Vagus.App.AuthIndex do
  @moduledoc """
  Which app a token belongs to: the table API auth reads on every request.

  This process owns the table and is its only writer. `lookup/2` is a table
  read in the caller and never waits for it. A token has one app and an app
  one token: `put/3` for an app replaces the token it had, so nothing is
  left of an earlier instance of it.

  Neither the table nor this process ever holds a token. A row is keyed by
  the token's SHA-256, taken in the caller, so what a crash report, a
  trace of the mailbox or a dump of the table shows cannot be presented as
  a credential, and how long a lookup takes says nothing about how much of
  a guess was right.

  What an app may do with its token is not here: the caller reads that
  from the App resource, as it is now.

  ## When this process is absent

  The table is gone with it. `lookup/2` answers `:error`, so every app's
  request is refused until its token is put again; `put/3` and `remove/2`
  answer `{:error, :unavailable}`, also when the call timed out, in which
  case the write may have been made. The replacement starts with an empty
  table. It stands before the controllers under a `:rest_for_one`
  supervisor, so they are replaced with it, and a runtime that starts looks
  at every app: each pass finds its app's token missing and puts it back.
  """

  use GenServer

  alias Vagus.Resource

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    instance = instance(opts)
    GenServer.start_link(__MODULE__, instance, name: name(instance))
  end

  @spec name(atom()) :: atom()
  def name(instance), do: Module.concat(instance, AuthIndex)

  @doc "The table of `{sha256(token), app}` rows."
  @spec table(atom()) :: atom()
  def table(instance), do: Module.concat(instance, AuthTokens)

  @doc "The app `token` belongs to."
  @spec lookup(term(), keyword()) :: {:ok, Resource.name()} | :error
  def lookup(token, opts \\ [])

  def lookup(token, opts) when is_binary(token) and token != "" do
    case :ets.lookup(table(instance(opts)), digest(token)) do
      [{_digest, app}] -> {:ok, app}
      [] -> :error
    end
  rescue
    # No table: nobody is known.
    ArgumentError -> :error
  end

  def lookup(_token, _opts), do: :error

  @doc """
  Makes `token` the token of `app`, and the only one. Returns once a
  `lookup/2` finds it. Options: `:instance`, and `:timeout` for the call
  (5 s).
  """
  @spec put(Resource.name(), String.t(), keyword()) :: :ok | {:error, :unavailable}
  def put(app, token, opts \\ []) when is_binary(app) and is_binary(token) and token != "",
    do: call(opts, {:put, app, digest(token)})

  @doc "Forgets the token of `app`, if it has one."
  @spec remove(Resource.name(), keyword()) :: :ok | {:error, :unavailable}
  def remove(app, opts \\ []) when is_binary(app), do: call(opts, {:remove, app})

  # Caught, not left to exit: the exit of a call names the request, and a
  # step that died of it would be logged with it.
  defp call(opts, request) do
    GenServer.call(name(instance(opts)), request, Keyword.get(opts, :timeout, 5_000))
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp digest(token), do: :crypto.hash(:sha256, token)
  defp instance(opts), do: Keyword.get(opts, :instance, Resource)

  # In `init/1`: whoever starts after this reads the table.
  @impl true
  def init(instance) do
    table =
      :ets.new(table(instance), [:named_table, :set, :protected, read_concurrency: true])

    {:ok, %{table: table, digests: %{}}}
  end

  @impl true
  def handle_call({:put, app, digest}, _from, state) do
    forget(state, app, digest)
    # A token another app had put is that app's no longer.
    digests = Map.reject(state.digests, fn {other, held} -> other != app and held == digest end)
    :ets.insert(state.table, {digest, app})
    {:reply, :ok, %{state | digests: Map.put(digests, app, digest)}}
  end

  def handle_call({:remove, app}, _from, state) do
    forget(state, app, nil)
    {:reply, :ok, %{state | digests: Map.delete(state.digests, app)}}
  end

  # Not when it is the one being put: deleted and inserted again, the row
  # would be missing to a reader in between.
  defp forget(state, app, keep) do
    case state.digests do
      %{^app => held} when held != keep -> :ets.delete(state.table, held)
      _none -> :ok
    end
  end
end
