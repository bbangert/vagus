defmodule Vagus.Test.ContractFixture do
  @moduledoc """
  The one `aiohasupervisor-<version>-contract.json` fixture, shared so that
  every test reading it follows a regenerated fixture without a second edit.
  """

  @glob Path.expand("../fixtures/aiohasupervisor-*-contract.json", __DIR__)

  # Exactly one: a leftover old fixture would otherwise let a test keep
  # checking a stale client version.
  @spec path() :: Path.t()
  def path do
    case Path.wildcard(@glob) do
      [path] -> path
      other -> raise "expected exactly one contract fixture, found: #{inspect(other)}"
    end
  end

  @spec load() :: map()
  def load, do: path() |> File.read!() |> Jason.decode!()

  @spec version() :: String.t()
  def version do
    path()
    |> Path.basename()
    |> String.replace_prefix("aiohasupervisor-", "")
    |> String.replace_suffix("-contract.json", "")
  end
end
