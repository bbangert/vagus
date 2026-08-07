defmodule Vagus.Core.ApiSocketTest do
  @moduledoc """
  `Vagus.Core.ApiSocket`'s "never raises" contract (S1).

  `async: false`: `:core_socket_path` is process-global application env.
  """
  use ExUnit.Case, async: false

  alias Vagus.Core.ApiSocket

  defmodule FakeCore do
    @moduledoc "Answers on the Supervisor socket, echoing the status the path asks for."
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/ok" do
      send_resp(conn, 200, ~s({"ok":true}))
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end

  setup do
    prev = Application.get_env(:vagus, :core_socket_path)
    on_exit(fn -> Application.put_env(:vagus, :core_socket_path, prev) end)
    :ok
  end

  defp socket_path do
    path =
      Path.join(System.tmp_dir!(), "vagus_api_socket_#{System.unique_integer([:positive])}.sock")

    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "post/3 with no socket to dial" do
    test "an explicit nil socket is an error tuple, not a raised Mint address" do
      # `Mint.HTTP.connect(:http, {:local, nil}, 0, ...)` raises. A caller
      # that resolved a path, saw it vanish, and passed the result on must
      # get `{:error, _}` back — this module documents that it never raises.
      assert ApiSocket.post("/ok", %{}, socket: nil) == {:error, :no_socket}
    end

    test "an unresolvable configured path is the same error" do
      Application.put_env(:vagus, :core_socket_path, nil)

      assert ApiSocket.path() == nil
      assert ApiSocket.post("/ok", %{}) == {:error, :no_socket}
    end

    test "a configured path with nothing bound to it is a connect error" do
      Application.put_env(:vagus, :core_socket_path, socket_path())

      assert {:error, {:connect, _reason}} = ApiSocket.post("/ok", %{}, socket: socket_path())
    end
  end

  describe "post/3 over a live socket" do
    setup do
      path = socket_path()

      start_supervised!(
        {Bandit,
         plug: FakeCore,
         port: 0,
         thousand_island_options: [num_acceptors: 1, transport_options: [ip: {:local, path}]]}
      )

      Application.put_env(:vagus, :core_socket_path, path)
      %{socket: path}
    end

    test "the threaded :socket option is what gets dialed", %{socket: path} do
      assert ApiSocket.post("/ok", %{"a" => 1}, socket: path) == {:ok, 200}
      assert ApiSocket.post("/nope", %{}, socket: path) == {:ok, 404}
    end

    test "with no :socket option the configured path is resolved", %{socket: path} do
      assert ApiSocket.path() == path
      assert ApiSocket.post("/ok", %{}) == {:ok, 200}
    end
  end
end
