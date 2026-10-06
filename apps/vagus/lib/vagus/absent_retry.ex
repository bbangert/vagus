defmodule Vagus.AbsentRetry do
  @moduledoc """
  Calls a named server that may be mid-restart, retrying while it is absent.

  A lookup is not liveness, so `call/2` just calls and catches the exit:

    * absent or going away (`:noproc`, `:normal`, `:shutdown`,
      `{:shutdown, _}`, `:killed`) — retried for the whole budget;
    * any other crash (`:server_down`) — retried once per `call/2`, however
      many absences come between: if the call itself is what crashes the
      server, it alternates crash and absence, and every further attempt
      spends one of its supervisor's restarts;
    * `:timeout` — never retried: the server is alive, and the caller would
      wait a full call timeout again.

  Only the exit's tag is returned. The reason carries the call's arguments
  and can carry the server's state — tokens, passwords — so it must not reach
  a log.
  """

  @type budget :: {attempts :: pos_integer(), delay_ms :: non_neg_integer()}
  @type tag :: :timeout | :noproc | :normal | :shutdown | :killed | :server_down

  @absent [:noproc, :normal, :shutdown, :killed]

  @spec call((-> result), budget()) :: {:ok, result} | {:error, tag()} when result: term()
  def call(fun, {attempts, delay_ms}), do: call(fun, attempts, delay_ms, false)

  defp call(fun, attempts, delay_ms, crashed?) do
    {:ok, fun.()}
  catch
    :exit, reason ->
      case tag(reason) do
        :timeout ->
          {:error, :timeout}

        tag when attempts <= 1 or (tag == :server_down and crashed?) ->
          {:error, tag}

        tag ->
          Process.sleep(delay_ms)
          call(fun, attempts - 1, delay_ms, crashed? or tag == :server_down)
      end
  end

  @doc false
  @spec tag(term()) :: tag()
  def tag({:timeout, _call}), do: :timeout
  def tag({tag, _call}) when tag in @absent, do: tag
  def tag({{:shutdown, _}, _call}), do: :shutdown
  def tag(_crash), do: :server_down
end
