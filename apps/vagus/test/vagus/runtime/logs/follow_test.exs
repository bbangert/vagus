defmodule Vagus.Runtime.Logs.FollowTest do
  use ExUnit.Case, async: true

  alias Vagus.Runtime.Logs.Follow

  # Fake docker daemon on a unix socket, same shape as events_test.exs:
  # accept the request, speak chunked HTTP, feed multiplexed log frames.

  defp socket_path, do: "/tmp/vagus-lf-#{System.unique_integer([:positive])}.sock"

  defp start_fake_server(path) do
    # A previous BEAM run's socket FILE survives in /tmp (closing the listen
    # socket does not unlink it) and unique_integer restarts per run — rm
    # first or a rerun collides with the leftover (:eaddrinuse flake).
    _ = File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        {:ifaddr, {:local, path}},
        active: false,
        packet: :raw,
        backlog: 1
      ])

    listen
  end

  defp accept_conn(listen, timeout \\ 3_000) do
    {:ok, sock} = :gen_tcp.accept(listen, timeout)
    {sock, read_request_head(sock, "")}
  end

  defp read_request_head(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
      read_request_head(sock, acc <> data)
    end
  end

  defp send_headers(sock, status_line \\ "HTTP/1.1 200 OK") do
    :ok =
      :gen_tcp.send(
        sock,
        status_line <>
          "\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
      )
  end

  defp send_chunk(sock, binary) do
    size_hex = binary |> byte_size() |> Integer.to_string(16)
    :ok = :gen_tcp.send(sock, size_hex <> "\r\n" <> binary <> "\r\n")
  end

  defp send_final_chunk(sock), do: :ok = :gen_tcp.send(sock, "0\r\n\r\n")

  # For tests where the client is EXPECTED to hang up as soon as it has
  # seen the status line (the non-200 path): whether these writes land or
  # hit the already-closed socket is a scheduler race — the close is the
  # asserted behaviour, so both outcomes are legal. CI's slower scheduler
  # loses this race reliably where a dev machine almost never does.
  defp send_chunk_may_close(sock, binary) do
    size_hex = binary |> byte_size() |> Integer.to_string(16)

    case :gen_tcp.send(sock, size_hex <> "\r\n" <> binary <> "\r\n") do
      :ok -> :ok
      {:error, :closed} -> :ok
    end
  end

  defp send_final_chunk_may_close(sock) do
    case :gen_tcp.send(sock, "0\r\n\r\n") do
      :ok -> :ok
      {:error, :closed} -> :ok
    end
  end

  defp frame(type, payload), do: <<type, 0, 0, 0, byte_size(payload)::32, payload::binary>>

  defp setup_stream(_ctx) do
    path = socket_path()
    listen = start_fake_server(path)
    on_exit(fn -> :gen_tcp.close(listen) end)
    %{path: path, listen: listen}
  end

  setup :setup_stream

  test "requests the container's follow URL and streams demuxed chunks", %{
    path: path,
    listen: listen
  } do
    {:ok, _pid} = Follow.start_link(owner: self(), ref: "addon_demo", tail: 5, socket: path)
    {sock, head} = accept_conn(listen)

    assert head =~ "GET /containers/addon_demo/logs?follow=true&stdout=true&stderr=true&tail=5"

    send_headers(sock)
    send_chunk(sock, frame(1, "line1\n"))
    assert_receive {:log_chunk, "line1\n"}, 2_000
  end

  test "ack-gated delivery: a chunk arriving before the ack is held", %{
    path: path,
    listen: listen
  } do
    {:ok, pid} = Follow.start_link(owner: self(), ref: "addon_demo", socket: path)
    {sock, _head} = accept_conn(listen)
    send_headers(sock)

    send_chunk(sock, frame(1, "first\n"))
    assert_receive {:log_chunk, "first\n"}, 2_000

    # No ack yet: the next socket message is stashed, not delivered.
    send_chunk(sock, frame(1, "second\n"))
    refute_receive {:log_chunk, _}, 150

    Follow.ack(pid)
    assert_receive {:log_chunk, "second\n"}, 2_000
  end

  test "stream end sends :log_eof after the final payload", %{path: path, listen: listen} do
    {:ok, pid} = Follow.start_link(owner: self(), ref: "addon_demo", socket: path)
    {sock, _head} = accept_conn(listen)
    send_headers(sock)

    send_chunk(sock, frame(1, "bye\n"))
    assert_receive {:log_chunk, "bye\n"}, 2_000
    Follow.ack(pid)

    send_final_chunk(sock)
    assert_receive :log_eof, 2_000
  end

  test "eof arriving while awaiting ack is held, then delivered after the ack", %{
    path: path,
    listen: listen
  } do
    {:ok, pid} = Follow.start_link(owner: self(), ref: "addon_demo", socket: path)
    {sock, _head} = accept_conn(listen)
    send_headers(sock)

    send_chunk(sock, frame(1, "last\n"))
    assert_receive {:log_chunk, "last\n"}, 2_000

    # Terminal chunk lands while un-acked: it must be stashed, not processed.
    send_final_chunk(sock)
    refute_receive :log_eof, 150

    Follow.ack(pid)
    assert_receive :log_eof, 2_000
  end

  test "owner death closes the held docker connection (no leak)", %{
    path: path,
    listen: listen
  } do
    test_pid = self()

    owner =
      spawn(fn ->
        receive do
          :die -> :ok
        end
      end)

    {:ok, follow} = Follow.start_link(owner: owner, ref: "addon_demo", socket: path)
    follow_ref = Process.monitor(follow)
    {sock, _head} = accept_conn(listen)
    send_headers(sock)

    send(owner, :die)

    # The Follow process stops and the server side sees the socket close.
    assert_receive {:DOWN, ^follow_ref, :process, ^follow, :normal}, 2_000
    spawn(fn -> send(test_pid, {:recv, :gen_tcp.recv(sock, 0, 2_000)}) end)
    assert_receive {:recv, {:error, :closed}}, 3_000
  end

  test "non-200 status ends the stream honestly without forwarding the body", %{
    path: path,
    listen: listen
  } do
    {:ok, _pid} = Follow.start_link(owner: self(), ref: "addon_gone", socket: path)
    {sock, _head} = accept_conn(listen)

    send_headers(sock, "HTTP/1.1 404 Not Found")
    send_chunk_may_close(sock, ~s({"message":"No such container"}))
    send_final_chunk_may_close(sock)

    assert_receive :log_eof, 2_000
    refute_receive {:log_chunk, _}, 100
  end

  test "a ref failing the allowlist never dials the socket", %{path: path, listen: listen} do
    {:ok, _pid} = Follow.start_link(owner: self(), ref: "../etc/evil", socket: path)

    assert_receive :log_eof, 2_000
    assert {:error, :timeout} = :gen_tcp.accept(listen, 200)
    _ = path
  end

  test "an unreachable socket degrades to :log_eof" do
    {:ok, _pid} =
      Follow.start_link(owner: self(), ref: "addon_demo", socket: "/tmp/vagus-lf-missing.sock")

    assert_receive :log_eof, 2_000
  end
end
