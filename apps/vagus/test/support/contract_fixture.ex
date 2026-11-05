defmodule Vagus.Test.ContractFixture do
  @moduledoc """
  The one versioned fixture of each kind, shared so that every test reading
  one follows a regeneration without a second edit:

    * `aiohasupervisor-<version>-contract.json` — the typed client Core uses
    * `frontend-<tag>-hassio-endpoints.json` — the frontend's untyped calls
  """

  @client "aiohasupervisor-*-contract.json"
  @frontend "frontend-*-hassio-endpoints.json"

  @spec path() :: Path.t()
  def path, do: only!(@client)

  @spec load() :: map()
  def load, do: path() |> File.read!() |> Jason.decode!()

  @spec version() :: String.t()
  def version do
    path()
    |> Path.basename()
    |> String.replace_prefix("aiohasupervisor-", "")
    |> String.replace_suffix("-contract.json", "")
  end

  @spec frontend_path() :: Path.t()
  def frontend_path, do: only!(@frontend)

  @spec load_frontend() :: map()
  def load_frontend, do: frontend_path() |> File.read!() |> Jason.decode!()

  @spec frontend_tag() :: String.t()
  def frontend_tag do
    frontend_path()
    |> Path.basename()
    |> String.replace_prefix("frontend-", "")
    |> String.replace_suffix("-hassio-endpoints.json", "")
  end

  # Exactly one: a leftover old fixture would otherwise let a test keep
  # checking a stale version.
  defp only!(glob) do
    case Path.wildcard(Path.expand("../fixtures/" <> glob, __DIR__)) do
      [path] -> path
      other -> raise "expected exactly one #{glob} fixture, found: #{inspect(other)}"
    end
  end
end
