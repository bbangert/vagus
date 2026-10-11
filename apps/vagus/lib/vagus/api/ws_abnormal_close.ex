defmodule Vagus.API.WSAbnormalClose do
  @moduledoc """
  Counts the WebSockets that end abnormally without any log line saying so.

  One kind is a frame Bandit refuses before a `WebSock` handler sees it. A
  caller can send one at will, before authenticating where the handler
  authenticates in-band, so `Vagus.API.Listener` switches off both of
  Bandit's reports of them: one is a line per attempt, the other a crash
  report carrying the caller's bytes and the handler's state.

  The other is a bridge closing because it lost its upstream leg. It stops
  with a `:shutdown` reason, as a crash report there prints the state too.

  Both are counted under a static label, as `Vagus.API.Auth` counts its
  refusals.
  """

  require Logger

  alias Vagus.API.SourceGuard

  @oversize "ws/oversize"
  @protocol "ws/protocol"
  @upstream "ws/upstream"

  # Bandit's wording. Reworded upstream, it is still counted, as @protocol.
  @oversize_message "Received oversize fragmented message"

  @doc """
  Counts `reason`, a `c:WebSock.terminate/2` reason, if it is one of
  Bandit's refusals (an atom from its frame parser, or a string) or a
  bridge's own stop for a lost upstream. Every other way a connection ends
  is left alone.
  """
  @spec count(term()) :: :ok
  def count({:error, :max_frame_size_exceeded}), do: record(@oversize)
  def count({:error, @oversize_message}), do: record(@oversize)

  def count({:error, reason})
      when is_binary(reason) or reason in [:client_frame_without_mask, :deserialization_failed],
      do: record(@protocol)

  def count({:error, {:shutdown, reason}})
      when reason in [:upstream_connect_failed, :upstream_down],
      do: record(@upstream)

  def count(_reason), do: :ok

  @doc """
  Counts an upstream that stopped answering. The bridge then stops
  `:normal`, which `count/1` cannot tell from any other close.
  """
  @spec count_upstream() :: :ok
  def count_upstream, do: record(@upstream)

  # Off device there is no counter and no ring to protect.
  defp record(label) do
    if SourceGuard.enabled?() do
      SourceGuard.record_filtered(:ws, label)
    else
      Logger.warning("Vagus.API.WSAbnormalClose: closed a connection (#{label})")
    end
  end
end
