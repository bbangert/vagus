defmodule Vagus.ConnectionLog do
  @moduledoc """
  Picks out of a captured log what one Thousand Island connection process
  wrote, so a test's bound on it does not move with whatever else logged
  meanwhile. Capture with `metadata: [:pid]`.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  @doc "Call before connecting. Each connection then announces itself to the test."
  @spec attach() :: :ok
  def attach do
    id = "connection-log-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(id, [:thousand_island, :connection, :start], &__MODULE__.report/4, self())

    on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def report(_event, _measurements, metadata, test),
    do: send(test, {:connection, metadata.remote_port, self()})

  @doc "The process serving the client `socket`, which may have exited already."
  @spec pid(:gen_tcp.socket()) :: pid()
  def pid(socket) do
    {:ok, local_port} = :inet.port(socket)
    assert_receive {:connection, ^local_port, connection}, 30_000
    connection
  end

  @spec entries(String.t(), pid()) :: [String.t()]
  def entries(log, pid) do
    "#PID" <> id = inspect(pid)

    log
    |> String.split(~r/\n(?=\d\d:\d\d:\d\d\.\d+ )/)
    |> Enum.filter(&String.contains?(&1, "pid=#{id} "))
  end
end
