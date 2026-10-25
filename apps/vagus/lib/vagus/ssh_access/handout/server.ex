defmodule Vagus.SSHAccess.Handout.Server do
  @moduledoc """
  The handout's window. Stopping `:normal` is what closes the handout (see
  `Vagus.SSHAccess.Handout`, whose `on_login/4` writes the latch).
  """

  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @impl true
  def init(opts) do
    state = %{
      port: Keyword.fetch!(opts, :port),
      window_ms: Keyword.fetch!(opts, :window_ms)
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    Process.send_after(self(), :window_elapsed, state.window_ms)

    Logger.info(
      "SSH key handout open: GET http://<board>:#{state.port}/key " <>
        "for #{div(state.window_ms, 1000)}s or until the first SSH login"
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(:window_elapsed, state) do
    Logger.info("SSH key handout closed: window elapsed with no SSH login, reopens next boot")
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast({:login, who}, state) do
    Logger.info("SSH key handout closed: SSH login by #{who}")
    {:stop, :normal, state}
  end
end
