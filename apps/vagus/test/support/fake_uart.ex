defmodule Vagus.Test.FakeUART do
  @moduledoc """
  Stands in for `Circuits.UART` behind `Vagus.Serial.Capture`'s `:uart_mod`
  seam. `deliver/2` sends `{:circuits_uart, node, data}` to the process that
  opened it, with the node as it was opened, as the real UART does. A node
  whose name contains `FAIL` refuses to open with `:enoent`.
  """

  use GenServer

  def start_link, do: GenServer.start_link(__MODULE__, nil)

  def open(pid, node, opts), do: GenServer.call(pid, {:open, node, opts})
  def configure(pid, opts), do: GenServer.call(pid, {:configure, opts})
  def close(pid), do: GenServer.call(pid, :close)
  def opened(pid), do: GenServer.call(pid, :opened)
  def deliver(pid, data), do: GenServer.call(pid, {:deliver, data})

  @impl true
  def init(nil), do: {:ok, %{node: nil, opts: [], owner: nil}}

  @impl true
  def handle_call({:open, node, opts}, {owner, _}, state) do
    if node =~ "FAIL",
      do: {:reply, {:error, :enoent}, state},
      else: {:reply, :ok, %{state | node: node, opts: opts, owner: owner}}
  end

  def handle_call({:configure, opts}, _from, state),
    do: {:reply, :ok, %{state | opts: Keyword.merge(state.opts, opts)}}

  def handle_call(:close, _from, state), do: {:reply, :ok, %{state | node: nil}}
  def handle_call(:opened, _from, state), do: {:reply, state, state}

  def handle_call({:deliver, data}, _from, %{owner: owner, node: node} = state)
      when is_pid(owner) and is_binary(node) do
    send(owner, {:circuits_uart, node, data})
    {:reply, :ok, state}
  end
end
