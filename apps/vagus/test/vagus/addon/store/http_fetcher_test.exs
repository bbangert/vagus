defmodule Vagus.Addon.Store.HTTPFetcherTest do
  use ExUnit.Case, async: true

  alias Vagus.Addon.Store.HTTPFetcher

  @repo %{slug: "core", url: "https://github.com/home-assistant/addons"}

  # Sends a byte every 20 ms: each arrives well inside the receive timeout,
  # so only a limit on the whole response can end the request early.
  defp trickling_server(bytes) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test = self()

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _request} = :gen_tcp.recv(socket, 0)
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: #{bytes}\r\n\r\n")
        send(test, {:trickled, trickle(socket, bytes)})
      end)

    on_exit(fn -> Process.exit(server, :kill) end)
    "http://127.0.0.1:#{port}"
  end

  defp trickle(_socket, 0), do: :all

  defp trickle(socket, left) do
    receive do
    after
      20 -> :ok
    end

    case :gen_tcp.send(socket, "x") do
      :ok -> trickle(socket, left - 1)
      {:error, _closed} -> {:closed_with, left}
    end
  end

  test "a download slower than its total limit is an error, and the connection is closed" do
    base = trickling_server(100)

    assert {:error, %{reason: :timeout}} =
             HTTPFetcher.fetch(@repo, base: base, request_timeout: 100)

    assert_receive {:trickled, {:closed_with, left}}, 5_000
    assert left > 0
  end
end
