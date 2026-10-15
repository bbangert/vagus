defmodule Vagus.Runtime.Events.Source do
  @moduledoc """
  The transport behind `Vagus.Runtime.Events`: one engine's container-event
  stream. Events owns subscribers, routing, the managed gate, resync and
  reconnect backoff; a source only connects, turns the messages its
  connection sends the Events process into notices, and closes.

  Notices, in arrival order:

    * `:answered` — the engine responded; the reconnect backoff resets.
    * `:ready` — the stream is live from here on; also triggers the resync
      that repairs what was missed while it was down.
    * a `Vagus.Runtime.Engine.Event`.

  Events hands the source every message it does not own (its own are tagged
  `{Vagus.Runtime.Events, _}`, plus `:DOWN`s for its own monitors) while
  connected. A timer a source arms must carry a ref minted at `connect/1`
  and be cancelled in `close/1`, so a stale tick can never reach a later
  connection.
  """

  alias Vagus.Runtime.Engine.Event

  @type notice :: :answered | :ready | Event.t()

  @callback init(keyword()) :: term()
  @callback connect(src :: term()) :: {:ok, [notice()], term()} | {:error, reason :: term()}

  @doc """
  `:unknown` for a message that is not this source's. After `{:closed, …}`
  Events calls `close/1` and reconnects with backoff.
  """
  @callback handle_info(msg :: term(), src :: term()) ::
              {:ok, [notice()], term()}
              | {:closed, reason :: term(), [notice()], term()}
              | :unknown

  @doc "Idempotent; returns the source ready for another `connect/1`."
  @callback close(src :: term()) :: term()
end
