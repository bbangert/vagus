defmodule Vagus.Core.Supervisor do
  @moduledoc """
  Isolated supervisor for the Core-facing token handshake and event-push
  machinery (P3), plus Core's version state (P2): `Vagus.Core.TokenStore`, a
  small `Finch` pool for outbound HTTP to Core, `Vagus.Core.Versions`
  (installed/latest version persistence), `Vagus.Core.Client` (lazy
  access-token exchange), and `Vagus.Core.EventPusher` (persistent WS
  client manager).

  Mirrors `Vagus.Engine.DaemonSupervisor`/`Vagus.API.Supervisor`'s
  isolation rationale: a crash anywhere in this subtree has its own
  bounded restart budget (`max_restarts: 5, max_seconds: 30`) and can
  never escalate to take down the rest of `Vagus.Supervisor`.

  Start order matters: `TokenStore` must already be registered before
  `EventPusher`'s `init/1` calls `TokenStore.subscribe/1` and
  `TokenStore.get_refresh_token/1` synchronously, and `Finch` must be up
  before `Client` (or `EventPusher`'s WS connection, via `Client`) makes
  its first HTTP call — though not at `Client`'s own `init/1`, since the
  token exchange is lazy. `Versions` is placed right after `Finch`, the
  first point at which its own (lazy, on-demand) upstream fetch could use
  the pool — it has no dependency on `TokenStore` or `Client` and nothing
  downstream depends on it either, so its exact position among the
  Finch-dependent children doesn't matter beyond "after Finch".

  `:rest_for_one`, not `:one_for_one`: a `TokenStore` restart wipes its
  in-memory subscriber set (`EventPusher`'s subscription among them), so
  `TokenStore` restarting must also restart every child listed after it
  (`Finch`, `Versions`, `Client`, `EventPusher`) — `EventPusher`'s `init/1`
  then re-subscribes and re-reads the refresh token from the fresh
  `TokenStore`, instead of being left permanently unsubscribed. `Versions`
  restarting along with it just means its in-memory 24h latest-version
  cache is dropped (harmless — the next `latest/1` call simply re-fetches);
  its persisted installed version is re-read from disk at `init/1`.
  """

  use Supervisor

  @doc "Starts the Core supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      Vagus.Core.TokenStore,
      {Finch, name: Vagus.Core.Finch, pools: %{default: [size: 2]}},
      Vagus.Core.Versions,
      Vagus.Core.Client,
      Vagus.Core.EventPusher
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 30)
  end
end
