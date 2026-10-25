defmodule Vagus.SSHAccess.HandoutTest do
  # Tests calling `on_login/3` use the default names and the global app env.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Bitwise, only: [band: 2]
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Vagus.SSHAccess
  alias Vagus.SSHAccess.Handout
  alias Vagus.SSHAccess.Handout.Latch

  # Answers `Vagus.SSHAccess.private_key/1` only when the test says so.
  defmodule BlockingKey do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

    def release(server), do: send(server, :release)

    @impl true
    def init(opts), do: {:ok, %{test: opts[:test], from: nil}}

    @impl true
    def handle_call(:private_key, from, state) do
      send(state.test, {:key_requested, self()})
      {:noreply, %{state | from: from}}
    end

    @impl true
    def handle_info(:release, state) do
      GenServer.reply(state.from, {:ok, "-----BEGIN OPENSSH PRIVATE KEY-----\n"})
      {:noreply, state}
    end
  end

  setup do
    n = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "ssh_handout_test_#{n}")
    File.mkdir_p!(dir)
    ssh_access = :"ssh_handout_access_#{n}"

    start_supervised!(
      {SSHAccess,
       name: ssh_access,
       table: :"ssh_handout_table_#{n}",
       dets_path: Path.join(dir, "ssh_access.dets"),
       authorize_fun: fn _ -> :ok end}
    )

    on_exit(fn -> File.rm_rf!(dir) end)

    name = :"ssh_handout_#{n}"

    on_exit(fn ->
      :persistent_term.erase(closed_key(name))
      :persistent_term.erase(closed_key(Handout))
    end)

    # `on_login/3,4` latches at the configured path, as on a board.
    claimed_path = Path.join([dir, "latch", "ssh_handout.claimed"])
    prev = Application.fetch_env(:vagus, :ssh_handout)
    Application.put_env(:vagus, :ssh_handout, claimed_path: claimed_path)

    on_exit(fn ->
      case prev do
        {:ok, value} -> Application.put_env(:vagus, :ssh_handout, value)
        :error -> Application.delete_env(:vagus, :ssh_handout)
      end
    end)

    {:ok,
     opts: [
       name: name,
       ssh_access: ssh_access,
       port: 0,
       ip: {127, 0, 0, 1},
       window_ms: 60_000,
       claimed_path: claimed_path
     ],
     ssh_access: ssh_access}
  end

  test "serves the access key with no-store inside the window", %{opts: opts, ssh_access: sa} do
    port = start_handout(opts)

    {resp, log} = with_log(fn -> Req.get!("http://127.0.0.1:#{port}/key", retry: false) end)

    assert resp.status == 200
    assert {:ok, resp.body} == SSHAccess.private_key(sa)
    assert resp.headers["cache-control"] == ["no-store"]
    assert resp.headers["connection"] == ["close"]
    assert resp.headers["content-type"] == ["text/plain; charset=utf-8"]
    assert log =~ "SSH access key fetched by 127.0.0.1"
  end

  test "503 when the access key is unavailable", %{opts: opts} do
    n = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "ssh_handout_degraded_#{n}")
    on_exit(fn -> File.rm_rf!(dir) end)
    degraded = :"ssh_handout_degraded_#{n}"

    start_supervised!(
      Supervisor.child_spec(
        {SSHAccess,
         name: degraded,
         table: :"ssh_handout_degraded_table_#{n}",
         dets_path: Path.join(dir, "ssh_access.dets"),
         chmod_fun: fn _path, _mode -> {:error, :eperm} end},
        id: :degraded
      )
    )

    port = start_handout(Keyword.put(opts, :ssh_access, degraded))

    assert %{status: 503} = Req.get!("http://127.0.0.1:#{port}/key", retry: false)
  end

  test "404 for another path, 405 for another method", %{opts: opts} do
    port = start_handout(opts)

    assert %{status: 404} = Req.get!("http://127.0.0.1:#{port}/", retry: false)
    assert %{status: 404} = Req.get!("http://127.0.0.1:#{port}/key/x", retry: false)

    assert %{status: 405} = resp = Req.post!("http://127.0.0.1:#{port}/key", retry: false)
    assert resp.headers["allow"] == ["GET"]
  end

  test "a clean stop leaves the handout down for good" do
    assert Handout.child_spec([]).restart == :transient
  end

  test "the window elapsing closes the listener for good", %{opts: opts} do
    {wrapper, port} = start_wrapped_handout(opts)
    handout_ref = Process.monitor(Process.whereis(opts[:name]))
    server = Process.whereis(Module.concat(opts[:name], Server))
    server_ref = Process.monitor(server)

    send(server, :window_elapsed)

    assert_receive {:DOWN, ^server_ref, :process, _, :normal}
    assert_receive {:DOWN, ^handout_ref, :process, _, :shutdown}
    assert [{Handout, :undefined, :supervisor, _}] = Supervisor.which_children(wrapper)

    assert_refused(port)

    refute Process.whereis(Module.concat(opts[:name], "Listener.Bandit"))
    refute File.exists?(opts[:claimed_path])
  end

  test "a Server crash keeps the original deadline", %{opts: opts} do
    start_handout(opts)
    name = Module.concat(opts[:name], Server)
    old = Process.whereis(name)
    old_state = :sys.get_state(old)
    remaining = Process.read_timer(old_state.timer)

    # A re-armed full window only outlasts the original once time has passed.
    Process.sleep(20)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}

    # On one node the kill's EXIT is queued at the supervisor before this call.
    Supervisor.which_children(opts[:name])
    new = Process.whereis(name)
    assert is_pid(new) and new != old
    new_state = :sys.get_state(new)

    assert new_state.deadline == old_state.deadline
    # 20 ms passed since `remaining`; 10 of slack covers ms rounding.
    assert Process.read_timer(new_state.timer) <= remaining - 10
  end

  test "a Server restarted after a login whose cast missed it closes", %{opts: opts} do
    start_handout(opts)
    handout_ref = Process.monitor(Process.whereis(opts[:name]))
    File.mkdir_p!(Path.dirname(opts[:claimed_path]))
    File.write!(opts[:claimed_path], "claimed\n")

    Process.exit(Process.whereis(Module.concat(opts[:name], Server)), :kill)

    assert_receive {:DOWN, ^handout_ref, :process, _, :shutdown}
    refute Process.whereis(Module.concat(opts[:name], "Listener.Bandit"))
  end

  test "an SSH login latches the handout shut", %{opts: opts} do
    # Default names: `on_login/3` is exactly what the daemon calls.
    opts = Keyword.delete(opts, :name)
    port = start_handout(opts)
    ref = Process.monitor(Process.whereis(Handout))

    {:ok, log} =
      with_log(fn ->
        assert :ok = Handout.on_login(~c"root", {{192, 168, 1, 5}, 50_000}, ~c"publickey")
        assert_receive {:DOWN, ^ref, :process, _, :shutdown}, 2_000
        :ok
      end)

    assert log =~ ~s[SSH login by ~c"root" from 192.168.1.5 (~c"publickey")]
    assert {:ok, %File.Stat{mode: mode}} = File.stat(opts[:claimed_path])
    assert band(mode, 0o777) == 0o600

    assert {:ok, _, _} =
             opts[:claimed_path] |> File.read!() |> String.trim() |> DateTime.from_iso8601()

    assert_refused(port)

    refute Process.whereis(Handout.Listener.Bandit)
  end

  test "a latched device starts no listener", %{opts: opts} do
    File.mkdir_p!(Path.dirname(opts[:claimed_path]))
    File.write!(opts[:claimed_path], "claimed\n")

    assert :ignore = Handout.start_link(opts)
    refute Process.whereis(opts[:name])
    refute Process.whereis(Module.concat(opts[:name], "Listener.Bandit"))
  end

  test "anything at the latch path counts as latched", %{opts: opts} do
    File.mkdir_p!(opts[:claimed_path])

    assert :ignore = Handout.start_link(opts)
  end

  test "a latch path that cannot be checked fails closed", %{opts: opts} do
    File.write!(Path.dirname(opts[:claimed_path]), "not a dir")

    assert :ignore = Handout.start_link(opts)
    assert :ok = Handout.on_login(~c"root", {{127, 0, 0, 1}, 1}, ~c"publickey")
  end

  test "a login after the window closed still latches", %{opts: opts} do
    start_supervised!({Handout, opts})
    server = Module.concat(opts[:name], Server)
    pid = Process.whereis(server)
    ref = Process.monitor(pid)
    send(pid, :window_elapsed)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    refute File.exists?(opts[:claimed_path])

    assert :ok = Handout.on_login(~c"root", {{10, 0, 0, 9}, 4_000}, ~c"publickey", server)

    assert {:ok, %File.Stat{mode: mode}} = File.stat(opts[:claimed_path])
    assert band(mode, 0o777) == 0o600
    assert :ignore = Handout.start_link(opts)
  end

  test "on_login/3 with no handout running still latches", %{opts: opts} do
    refute Process.whereis(Handout.Server)
    assert :ok = Handout.on_login(~c"root", {{127, 0, 0, 1}, 1}, ~c"publickey")
    assert File.exists?(opts[:claimed_path])
  end

  test "on_login latches whatever the peer and user look like", %{opts: opts} do
    server = Module.concat(opts[:name], Server)

    assert :ok = Handout.on_login(~c"root", :garbage, ~c"password", server)
    assert File.exists?(opts[:claimed_path])

    assert :ok = Handout.on_login([0x110000, ?\n], {{1, 2, 3}, 1}, ~c"password", server)
  end

  test "on_login with the latch already present leaves it alone", %{opts: opts} do
    File.mkdir_p!(Path.dirname(opts[:claimed_path]))
    File.write!(opts[:claimed_path], "first\n")
    File.touch!(opts[:claimed_path], {{2020, 1, 1}, {0, 0, 0}})
    before = File.stat!(opts[:claimed_path])

    assert :ok = Handout.on_login(~c"root", {{127, 0, 0, 1}, 1}, ~c"publickey")

    assert File.stat!(opts[:claimed_path]).mtime == before.mtime
    assert File.read!(opts[:claimed_path]) == "first\n"
  end

  test "a latch another login already created is success", %{opts: opts} do
    File.mkdir_p!(Path.dirname(opts[:claimed_path]))
    File.write!(opts[:claimed_path], "first\n")

    assert :ok = Latch.write(opts[:claimed_path], "second\n")
    assert File.read!(opts[:claimed_path]) == "first\n"
  end

  test "a login whose latch cannot be written still closes the handout", %{opts: opts} do
    start_handout(opts)
    server = Module.concat(opts[:name], Server)
    ref = Process.monitor(Process.whereis(server))
    dir = Path.dirname(opts[:claimed_path])
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o500)
    on_exit(fn -> File.chmod(dir, 0o700) end)

    assert :ok = Handout.on_login(~c"root", {{127, 0, 0, 1}, 1}, ~c"publickey", server)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    refute File.exists?(opts[:claimed_path])
  end

  test "a login whose latch raises still closes the handout", %{opts: opts} do
    start_handout(opts)
    server = Module.concat(opts[:name], Server)
    ref = Process.monitor(Process.whereis(server))
    # Not a path: every file call on it raises.
    Application.put_env(:vagus, :ssh_handout, claimed_path: 123)

    assert :ok = Handout.on_login(~c"root", {{127, 0, 0, 1}, 1}, ~c"publickey", server)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
  end

  test "a latch whose write fails after the create is partial", %{opts: opts} do
    # Not iodata, so the write fails once the exclusive create has succeeded.
    assert {:error, {:partial, :badarg}} = Latch.write(opts[:claimed_path], [:not_iodata])
    assert File.exists?(opts[:claimed_path])
  end

  test "a request in flight when the handout closes gets no key", %{opts: opts} do
    assert_in_flight_refused(opts)
  end

  test "a request in flight when an unlatchable login closes it gets no key", %{opts: opts} do
    dir = Path.dirname(opts[:claimed_path])
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o500)
    on_exit(fn -> File.chmod(dir, 0o700) end)

    assert_in_flight_refused(opts)
    refute File.exists?(opts[:claimed_path])
  end

  test "a key fetch that waits out the closure is refused", %{opts: opts} do
    stand_in = :"#{opts[:name]}_blocking_key"
    start_supervised!({BlockingKey, name: stand_in, test: self()})
    port = start_handout(Keyword.put(opts, :ssh_access, stand_in))
    server = Module.concat(opts[:name], Server)
    ref = Process.monitor(Process.whereis(server))

    request =
      Task.async(fn -> Req.get("http://127.0.0.1:#{port}/key", retry: false) end)

    assert_receive {:key_requested, _}
    assert :ok = Handout.on_login(~c"root", {{127, 0, 0, 1}, 1}, ~c"publickey", server)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    BlockingKey.release(stand_in)

    case Task.await(request) do
      {:ok, resp} ->
        assert resp.status == 410
        refute resp.body =~ "PRIVATE KEY"

      {:error, _closed} ->
        :ok
    end
  end

  test "a closed window refuses the key with no latch on disk", %{opts: opts} do
    start_handout(opts)
    server = Process.whereis(Module.concat(opts[:name], Server))
    ref = Process.monitor(server)
    send(server, :window_elapsed)
    assert_receive {:DOWN, ^ref, :process, _, :normal}

    assert :persistent_term.get(closed_key(opts[:name])) == true
    refute File.exists?(opts[:claimed_path])

    plug =
      Handout.Plug.init(
        ssh_access: opts[:ssh_access],
        claimed_path: opts[:claimed_path],
        deadline: System.monotonic_time(:millisecond) + 60_000,
        closed_key: closed_key(opts[:name])
      )

    assert Handout.Plug.call(Plug.Test.conn(:get, "/key"), plug).status == 410
  end

  test "the plug refuses the key past the deadline or once latched", %{opts: opts} do
    open = [
      ssh_access: opts[:ssh_access],
      claimed_path: opts[:claimed_path],
      closed_key: closed_key(opts[:name])
    ]

    now = System.monotonic_time(:millisecond)

    past = Handout.Plug.init([deadline: now] ++ open)
    conn = Handout.Plug.call(Plug.Test.conn(:get, "/key"), past)
    assert conn.status == 410
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
    assert conn.resp_body == "handout closed\n"

    future = Handout.Plug.init([deadline: now + 60_000] ++ open)
    assert Handout.Plug.call(Plug.Test.conn(:get, "/key"), future).status == 200

    File.mkdir_p!(Path.dirname(opts[:claimed_path]))
    File.write!(opts[:claimed_path], "claimed\n")
    assert Handout.Plug.call(Plug.Test.conn(:get, "/key"), future).status == 410
  end

  # The request's headers are unfinished when the handout closes, so the plug
  # runs only afterwards.
  defp assert_in_flight_refused(opts) do
    port = start_handout(opts)
    server = Module.concat(opts[:name], Server)
    ref = Process.monitor(Process.whereis(server))
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    :ok = :gen_tcp.send(socket, "GET /key HTTP/1.1\r\nhost: 127.0.0.1\r\n")

    assert :ok = Handout.on_login(~c"root", {{127, 0, 0, 1}, 1}, ~c"publickey", server)
    assert_receive {:DOWN, ^ref, :process, _, :normal}

    case :gen_tcp.send(socket, "\r\n") do
      :ok ->
        case recv_all(socket, "") do
          "" ->
            :closed

          response ->
            assert response =~ ~r{\AHTTP/1.1 410 }
            refute response =~ "PRIVATE KEY"
        end

      {:error, reason} ->
        assert reason in [:closed, :econnreset]
    end
  end

  defp closed_key(name), do: {Handout, name, :closed}

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, _} -> acc
    end
  end

  # The Listener binds in its handle_continue; a sys call returns only after
  # it, and port 0 means the bound port has to be asked for.
  defp start_handout(opts) do
    start_supervised!({Handout, opts})
    name = Keyword.get(opts, :name, Handout)
    :sys.get_state(Module.concat(name, Listener))
    {:ok, {_ip, port}} = ThousandIsland.listener_info(Module.concat(name, "Listener.Bandit"))
    port
  end

  # A listen socket closes asynchronously after its owner exits, so a connect
  # racing the close can be reset rather than refused; neither is served.
  defp assert_refused(port) do
    assert {:error, reason} = :gen_tcp.connect({127, 0, 0, 1}, port, [active: false], 500)
    assert reason in [:econnrefused, :econnreset]
  end

  # Under a supervisor the test can ask whether it restarted the handout.
  defp start_wrapped_handout(opts) do
    wrapper =
      start_supervised!(%{
        id: :wrapper,
        type: :supervisor,
        start: {Supervisor, :start_link, [[{Handout, opts}], [strategy: :one_for_one]]}
      })

    :sys.get_state(Module.concat(opts[:name], Listener))

    {:ok, {_ip, port}} =
      ThousandIsland.listener_info(Module.concat(opts[:name], "Listener.Bandit"))

    {wrapper, port}
  end
end
