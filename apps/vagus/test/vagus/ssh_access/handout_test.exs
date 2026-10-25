defmodule Vagus.SSHAccess.HandoutTest do
  # Tests calling `on_login/3` use the default names and the global app env.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Bitwise, only: [band: 2]
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Vagus.SSHAccess
  alias Vagus.SSHAccess.Handout
  alias Vagus.SSHAccess.Handout.Latch

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
       name: :"ssh_handout_#{n}",
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

  test "on_login returns :ok when the latch cannot be written", %{opts: opts} do
    dir = Path.dirname(opts[:claimed_path])
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o500)
    on_exit(fn -> File.chmod(dir, 0o700) end)

    assert :ok = Handout.on_login(~c"root", {{127, 0, 0, 1}, 1}, ~c"publickey")
    refute File.exists?(opts[:claimed_path])
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
