defmodule Vagus.SSHAccess.Handout.Server do
  @moduledoc """
  The handout's window. Stopping `:normal` is what closes the handout (see
  `Vagus.SSHAccess.Handout`, whose `on_login/3` writes the latch). The
  deadline comes from the supervisor, so a restarted Server keeps the
  original window instead of opening a fresh one.
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
      deadline: Keyword.fetch!(opts, :deadline),
      claimed_path: Keyword.fetch!(opts, :claimed_path),
      closed_key: Keyword.fetch!(opts, :closed_key),
      timer: nil
    }

    {:ok, state, {:continue, :open}}
  end

  # A login that raced startup, or one that landed while this Server was
  # being restarted, has latched without a Server to cast to.
  @impl true
  def handle_continue(:open, state) do
    if Latch.present?(state.claimed_path) do
      Logger.info("SSH key handout closed: latched (#{state.claimed_path})")
      close(state)
    else
      remaining = max(state.deadline - System.monotonic_time(:millisecond), 0)
      timer = Process.send_after(self(), :window_elapsed, remaining)

      Logger.info(
        "SSH key handout open: GET http://<board>:#{state.port}/key " <>
          "for #{div(remaining, 1000)}s or until the first SSH login"
      )

      {:noreply, %{state | timer: timer}}
    end
  end

  @impl true
  def handle_info(:window_elapsed, state) do
    Logger.info("SSH key handout closed: window elapsed with no SSH login, reopens next boot")
    close(state)
  end

  @impl true
  def handle_cast({:login, who}, state) do
    Logger.info("SSH key handout closed: SSH login by #{who}")
    close(state)
  end

  # The plug's closure signal when no latch could be written. A
  # `:persistent_term` because the request process reads it without a call,
  # it outlives this Server, and it lasts exactly this boot.
  defp close(state) do
    :persistent_term.put(state.closed_key, true)
    {:stop, :normal, state}
  end
end
