defmodule Vagus.Runtime.Logs.Follow do
  @moduledoc """
  One live `docker logs --follow` stream, held by a per-connection GenServer
  — the streaming half of `/logs/follow` (§A5). Started by the router with
  an `owner:` (the Plug process serving the chunked response); payload
  batches go to the owner as `{:log_chunk, binary}` and stream end as
  `:log_eof`.

  ## Backpressure — ack-gated re-arm, not full active mode

  Unlike `Vagus.Runtime.Events` (low-rate container events, full active
  mode), a log follow can be arbitrarily high-rate while the HTTP client is
  arbitrarily slow — full active mode would queue unbounded chunks in this
  process's mailbox. The Mint connection is opened in active mode, but Mint
  only re-arms the socket (`{active, :once}` underneath) inside
  `Mint.HTTP.stream/2` — so *deferring* that call IS the gate:

    * after forwarding `{:log_chunk, _}` to the owner, this process stops
      calling `stream/2` until the owner sends `:log_ack` (i.e. after
      `chunk/2` flushed to the client — Bandit blocking there is the true
      backpressure signal);
    * at most ONE raw socket message can arrive in the meantime (the socket
      was re-armed once by the previous `stream/2` call); it's stashed and
      processed on ack. Beyond that single message the kernel TCP buffer
      backpressures the docker daemon naturally.

  ## Lifecycle

  No reconnect: a finished follow means the container exited (or the ref
  never existed — a non-200 status ends the stream the same honest way).
  The owner is monitored; owner death closes the docker connection
  (held-connection leak is the load-bearing risk, plan §risk-2). The
  partial-frame remainder is capped by `Logs.demux_stream/2`
  (`:pending_overflow` closes the stream) so an adversarial stream can't
  balloon a 1GB device.

  Backfill note: the docker query carries `tail=N`, so backfill and live
  lines arrive on one stream with no gap or duplication — the router must
  NOT also write a separate backfill body for container-backed follows
  (recorded in the plan scratchpad).
  """

  use GenServer, restart: :temporary

  require Logger

  alias Vagus.Runtime.Docker
  alias Vagus.Runtime.Logs

  # Same container-ref allowlist as Vagus.Runtime.Docker's @ref_re — this
  # module interpolates `ref` into the request path.
  @ref_re ~r/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Acks the previous `{:log_chunk, _}` — the owner calls this after flushing."
  @spec ack(pid()) :: :ok
  def ack(pid) do
    send(pid, :log_ack)
    :ok
  end

  @impl GenServer
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)

    state = %{
      owner: owner,
      owner_ref: Process.monitor(owner),
      ref: Keyword.fetch!(opts, :ref),
      tail: Keyword.get(opts, :tail, 100),
      timestamps: Keyword.get(opts, :timestamps, false),
      socket: Keyword.get(opts, :socket, Docker.socket_path()),
      conn: nil,
      request_ref: nil,
      pending: "",
      status: nil,
      awaiting_ack?: false,
      stashed: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    with true <- Regex.match?(@ref_re, state.ref),
         {:ok, conn} <-
           Mint.HTTP.connect(:http, {:local, state.socket}, 0,
             hostname: "localhost",
             mode: :active
           ),
         {:ok, conn, request_ref} <- request_logs(conn, state) do
      {:noreply, %{state | conn: conn, request_ref: request_ref}}
    else
      false ->
        Logger.warning("Vagus.Runtime.Logs.Follow: rejected container ref #{inspect(state.ref)}")
        stop_with_eof(state)

      {:error, reason} ->
        Logger.debug("Vagus.Runtime.Logs.Follow: connect failed (#{inspect(reason)})")
        stop_with_eof(state)

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        Logger.debug("Vagus.Runtime.Logs.Follow: request failed (#{inspect(reason)})")
        stop_with_eof(state)
    end
  end

  defp request_logs(conn, state) do
    path =
      "/containers/#{state.ref}/logs?follow=true&stdout=true&stderr=true" <>
        "&tail=#{state.tail}&timestamps=#{state.timestamps}"

    Mint.HTTP.request(conn, "GET", path, [], "")
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    {:stop, :normal, state}
  end

  def handle_info(:log_ack, %{stashed: nil} = state) do
    {:noreply, %{state | awaiting_ack?: false}}
  end

  def handle_info(:log_ack, %{stashed: msg} = state) do
    process_socket_msg(msg, %{state | awaiting_ack?: false, stashed: nil})
  end

  def handle_info(msg, %{conn: conn} = state) when not is_nil(conn) do
    case state do
      # Socket was re-armed exactly once by the previous stream/2 call, so
      # exactly one message can land while awaiting the ack. Matching on
      # `stashed: nil` makes a violation of that Mint invariant crash this
      # :temporary process loudly (owner gets :DOWN via its link/monitor)
      # instead of silently overwriting — and desyncing — the HTTP parse.
      %{awaiting_ack?: true, stashed: nil} ->
        {:noreply, %{state | stashed: msg}}

      %{awaiting_ack?: false} ->
        process_socket_msg(msg, state)
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Socket message processing

  defp process_socket_msg(msg, state) do
    case Mint.HTTP.stream(state.conn, msg) do
      {:ok, conn, responses} ->
        continue_or_stop(responses, %{state | conn: conn}, _stream_error? = false)

      {:error, conn, _reason, responses} ->
        continue_or_stop(responses, %{state | conn: conn}, _stream_error? = true)

      :unknown ->
        {:noreply, state}
    end
  end

  defp continue_or_stop(responses, state, stream_error?) do
    {state, payloads, terminal?} = handle_responses(responses, state)

    cond do
      terminal? or stream_error? -> stop_with_eof(state, payloads)
      payloads != [] -> {:noreply, deliver(payloads, state)}
      true -> {:noreply, state}
    end
  end

  # Folds Mint responses into {state, collected_payloads, terminal?}.
  defp handle_responses(responses, state) do
    Enum.reduce(responses, {state, [], false}, fn response, {state, payloads, terminal?} ->
      handle_response(response, state, payloads, terminal?)
    end)
  end

  defp handle_response({:status, ref, status}, %{request_ref: ref} = state, payloads, terminal?) do
    # A non-200 (404 unknown container, 500) ends the stream honestly —
    # docker's error body must not be forwarded as log lines.
    {%{state | status: status}, payloads, terminal? or status != 200}
  end

  defp handle_response(
         {:data, ref, data},
         %{request_ref: ref, status: 200} = state,
         payloads,
         terminal?
       ) do
    case Logs.demux_stream(state.pending, data) do
      {:error, :pending_overflow} ->
        Logger.warning(
          "Vagus.Runtime.Logs.Follow: partial-frame buffer exceeded cap for #{state.ref}; closing stream"
        )

        {%{state | pending: ""}, payloads, true}

      {chunk_payloads, pending} ->
        {%{state | pending: pending}, payloads ++ [chunk_payloads], terminal?}
    end
  end

  defp handle_response({:done, ref}, %{request_ref: ref} = state, payloads, _terminal?) do
    {state, payloads, true}
  end

  defp handle_response({:error, ref, _reason}, %{request_ref: ref} = state, payloads, _terminal?) do
    {state, payloads, true}
  end

  defp handle_response(_other, state, payloads, terminal?), do: {state, payloads, terminal?}

  ## Delivery / teardown

  defp deliver(payloads, state) do
    send(state.owner, {:log_chunk, IO.iodata_to_binary(payloads)})
    %{state | awaiting_ack?: true}
  end

  defp stop_with_eof(state, payloads \\ []) do
    case IO.iodata_to_binary(payloads) do
      "" -> :ok
      final -> send(state.owner, {:log_chunk, final})
    end

    send(state.owner, :log_eof)
    if state.conn, do: Mint.HTTP.close(state.conn)
    {:stop, :normal, %{state | conn: nil}}
  end
end
