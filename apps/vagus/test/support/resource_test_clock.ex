defmodule Vagus.Resource.TestClock do
  @moduledoc """
  A clock that moves only when a test moves it. `clock/1` is what a process
  under test is given as its `t:Vagus.Resource.Clock.t/0`.
  """

  use Agent

  alias Vagus.Resource.{Clock, Stamp}

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []), do: Agent.start_link(fn -> %Stamp{incarnation: 1, at: 0} end)

  @spec clock(pid()) :: Clock.t()
  def clock(pid), do: fn -> now(pid) end

  @spec now(pid()) :: Stamp.t()
  def now(pid), do: Agent.get(pid, & &1)

  @spec advance(pid(), non_neg_integer()) :: :ok
  def advance(pid, ms), do: Agent.update(pid, &%{&1 | at: &1.at + ms})

  @doc "A reboot: a new incarnation, and a monotonic origin unrelated to the old one."
  @spec restart(pid()) :: :ok
  def restart(pid), do: Agent.update(pid, &%Stamp{incarnation: &1.incarnation + 1, at: 0})
end
