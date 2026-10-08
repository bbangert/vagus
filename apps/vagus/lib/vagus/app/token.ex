defmodule Vagus.App.Token do
  @moduledoc """
  Where an app's token comes from and how it is kept out of everything but
  its container and the caller's own variables.

  A `:minted` token is made by the action that creates the container and
  exists nowhere else: nothing stores it. Whoever needs it afterwards reads
  the container's environment (`SUPERVISOR_TOKEN`). A `:supervisor` token is
  the Supervisor's own, read through a function the caller is given. A
  profile with `:none` has no token and no step about one.

  A token is hashed before it leaves the function that read it:
  `state/4` answers from digests, and `Vagus.App.AuthIndex` takes its own.
  `guard/1` is around every action and around the read of an instance with
  its environment. A function that raised there would be reported with its
  arguments, the token among them where one is held, so what escapes it is
  the kind of failure and nothing it carried.
  """

  require Logger

  alias Vagus.App.AuthIndex

  @env "SUPERVISOR_TOKEN"

  @typedoc """
  What the token table holds for an app, against the token its instance
  has: `:current` is that token, `:other` another one, `:absent` none.
  `:none` is a profile without a token.
  """
  @type state :: :none | :current | :other | :absent

  @typedoc "`:supervisor` is a function that returns the Supervisor's token, or `nil`."
  @type source :: :minted | {:supervisor, (-> String.t() | nil)} | :none

  @doc "A new token: 256 random bits, in characters a URL and a header carry unchanged."
  @spec mint() :: String.t()
  def mint, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc "The token an instance was given, from its environment or the source's function."
  @spec of(source(), %{optional(String.t()) => String.t()}) :: String.t() | nil
  def of(:minted, env) when is_map(env), do: usable(Map.get(env, @env))
  def of({:supervisor, read}, _env) when is_function(read, 0), do: usable(read.())
  def of(_none, _env), do: nil

  defp usable(token) when is_binary(token) and token != "", do: token
  defp usable(_none), do: nil

  @doc "`token` is `nil` where the instance has none, or there is no instance."
  @spec state(source(), String.t(), String.t() | nil, keyword()) :: state()
  def state(:none, _app, _token, _opts), do: :none

  def state(_source, app, token, opts) do
    held = AuthIndex.digest_of(app, opts)

    cond do
      token != nil and held == {:ok, :crypto.hash(:sha256, token)} -> :current
      held == :error -> :absent
      true -> :other
    end
  end

  @doc """
  Runs `fun`, which may hold a token, and turns anything it raises, throws
  or exits with into an error. What is logged is the kind of failure and
  where it happened, module, function and line: never a message, an
  argument or a reason, any of which may carry the token.

  A raise, a throw, and an exit for any reason not named below is
  `{:error, {:crashed, kind}}`, the exception's module or the kind of exit:
  a defect, and the same again on every attempt.

  An exit that says the process asked was away or slow is
  `{:error, {:exit, why}}` and worth another attempt: `:timeout`, `:noproc`,
  `:normal`, `:shutdown` and `:killed`, alone, as `{:shutdown, _}`, or as
  the reason of a call (`{reason, {module, :call, args}}`). That is a token
  table, a pull worker or a supervisor being replaced, or not answering in
  time.
  """
  @spec guard((-> result)) :: result | {:error, {:crashed, atom()} | {:exit, atom()}}
        when result: term()
  def guard(fun) when is_function(fun, 0) do
    fun.()
  rescue
    exception -> crashed(exception.__struct__, __STACKTRACE__)
  catch
    :exit, reason ->
      case away(reason) do
        nil -> crashed(:exit, __STACKTRACE__)
        why -> exited(why, __STACKTRACE__)
      end

    kind, _reason ->
      crashed(kind, __STACKTRACE__)
  end

  @away [:timeout, :noproc, :normal, :shutdown, :killed]

  defp away({reason, {module, function, args}})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: away(reason)

  defp away({:shutdown, _why}), do: :shutdown
  defp away(reason) when reason in @away, do: reason
  defp away(_reason), do: nil

  defp crashed(kind, stack) do
    Logger.error("a step crashed: #{inspect(kind)} at #{where(stack)}")
    {:error, {:crashed, kind}}
  end

  defp exited(why, stack) do
    Logger.warning("a step's call exited: #{inspect(why)} at #{where(stack)}")
    {:error, {:exit, why}}
  end

  # A stack entry's third element is an arity, or the arguments themselves.
  defp where(stack) do
    stack
    |> Enum.take(6)
    |> Enum.map_join(" < ", fn {module, function, arity, location} ->
      arity = if is_list(arity), do: length(arity), else: arity
      "#{inspect(module)}.#{function}/#{arity}:#{location[:line]}"
    end)
  end
end
