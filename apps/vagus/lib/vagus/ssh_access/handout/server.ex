defmodule Vagus.SSHAccess.Handout.Server do
  @moduledoc """
  Owns the handout's lifetime: stopping `:normal` is what closes it (see
  `Vagus.SSHAccess.Handout.drop/0`, which writes the latch and calls here).
  """

  use GenServer

  require Logger

  alias Vagus.SSHAccess.Handout.Latch

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @impl true
  def init(opts) do
    state = %{
      port: Keyword.fetch!(opts, :port),
      claimed_path: Keyword.fetch!(opts, :claimed_path),
      closed_key: Keyword.fetch!(opts, :closed_key)
    }

    {:ok, state, {:continue, :open}}
  end

  # A drop that found no Server to call, because this one was being
  # restarted, has already latched or set the flag.
  @impl true
  def handle_continue(:open, state) do
    if :persistent_term.get(state.closed_key, false) or Latch.present?(state.claimed_path) do
      Logger.info("SSH key handout closed: dropped by operator")
      close(state)
      {:stop, :normal, state}
    else
      Logger.info(
        "SSH key handout open: GET http://<board>:#{state.port}/key " <>
          "until Vagus.SSHAccess.Handout.drop/0 is run"
      )

      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:drop, _from, state) do
    Logger.info("SSH key handout closed: dropped by operator")
    close(state)
    {:stop, :normal, :ok, state}
  end

  # The plug's closure signal when no latch could be written. A
  # `:persistent_term` because the request process reads it without a call,
  # it outlives this Server, and it lasts exactly this boot.
  defp close(state), do: :persistent_term.put(state.closed_key, true)
end
