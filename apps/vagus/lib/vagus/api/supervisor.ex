defmodule Vagus.API.Supervisor do
  @moduledoc """
  Isolated supervisor for the Supervisor-API emulator's HTTP surface.

  Holds the `Bandit` server (`plug: Vagus.API.Router`) under its own
  bounded restart budget, mirroring `Vagus.Engine.DaemonSupervisor`'s
  isolation rationale: a Bandit crash-loop must never escalate past this
  subtree and bring down the rest of `Vagus.Supervisor`.

  RAM discipline: `thousand_island_options: [num_acceptors: 2]` — no
  per-request processes or Registry/ETS are needed for this static-data
  Phase 2 surface.

  `config :vagus, :api_server_enabled` (default `true`) gates whether
  Bandit is actually started — `false` in `config/test.exs` so `mix test`
  never binds a port at all (contract tests exercise `Vagus.API.Router`
  directly via `Plug.Test`, with no listening server involved).
  """

  use Supervisor

  @doc "Starts the API supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children =
      if server_enabled?() do
        # Provision the bearer token eagerly so the persisted file exists
        # before anything (dev script, on-device Core launch) needs to read
        # it — lazy first-request provisioning left /data/vagus/token absent
        # until the first Bearer-carrying request (found on device 2026-07-20).
        _token = Vagus.API.Token.get()
        port = Application.get_env(:vagus, :api_port, 8888)

        [
          {Bandit,
           plug: Vagus.API.Router, port: port, thousand_island_options: [num_acceptors: 2]}
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 30)
  end

  defp server_enabled?, do: Application.get_env(:vagus, :api_server_enabled, true)
end
