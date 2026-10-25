defmodule Vagus.SSHAccess.HandoutTest do
  # Tests calling `on_login/3` use the default names and the global app env.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Bitwise, only: [band: 2]

  alias Vagus.SSHAccess
  alias Vagus.SSHAccess.Handout

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

    resp = Req.get!("http://127.0.0.1:#{port}/key", retry: false)

    assert resp.status == 200
    assert {:ok, resp.body} == SSHAccess.private_key(sa)
    assert resp.headers["cache-control"] == ["no-store"]
    assert resp.headers["content-type"] == ["text/plain; charset=utf-8"]
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

  test "the window elapsing closes the listener for good", %{opts: opts} do
    opts = Keyword.put(opts, :window_ms, 200)
    port = start_handout(opts)
    ref = Process.monitor(Process.whereis(opts[:name]))

    assert_receive {:DOWN, ^ref, :process, _, :shutdown}, 2_000

    assert {:error, :econnrefused} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [active: false], 500)

    refute Process.whereis(Module.concat(opts[:name], "Listener.Bandit"))
    refute File.exists?(opts[:claimed_path])
  end

  test "an SSH login latches the handout shut", %{opts: opts} do
    # Default names: `on_login/3` is exactly what the daemon calls.
    opts = Keyword.delete(opts, :name)
    port = start_handout(opts)
    ref = Process.monitor(Process.whereis(Handout))

    assert :ok = Handout.on_login(~c"root", {{192, 168, 1, 5}, 50_000}, ~c"publickey")

    assert_receive {:DOWN, ^ref, :process, _, :shutdown}, 2_000

    assert {:ok, %File.Stat{mode: mode}} = File.stat(opts[:claimed_path])
    assert band(mode, 0o777) == 0o600
    assert File.read!(opts[:claimed_path]) =~ "root from 192.168.1.5 (publickey)"

    assert {:error, :econnrefused} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [active: false], 500)

    refute Process.whereis(Handout.Listener.Bandit)
  end

  test "a latched device starts no listener", %{opts: opts} do
    File.mkdir_p!(Path.dirname(opts[:claimed_path]))
    File.write!(opts[:claimed_path], "claimed\n")

    assert :ignore = Handout.start_link(opts)
    refute Process.whereis(opts[:name])
    refute Process.whereis(Module.concat(opts[:name], "Listener.Bandit"))
  end

  test "a login after the window closed still latches", %{opts: opts} do
    opts = Keyword.put(opts, :window_ms, 200)
    start_supervised!({Handout, opts})
    server = Module.concat(opts[:name], Server)
    ref = Process.monitor(Process.whereis(server))
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 2_000
    refute File.exists?(opts[:claimed_path])

    assert :ok = Handout.on_login(~c"root", {{10, 0, 0, 9}, 4_000}, ~c"publickey", server)

    assert {:ok, %File.Stat{mode: mode}} = File.stat(opts[:claimed_path])
    assert band(mode, 0o777) == 0o600
    assert File.read!(opts[:claimed_path]) =~ "root from 10.0.0.9 (publickey)"
    assert :ignore = Handout.start_link(opts)
  end

  test "on_login/3 with no handout running still latches", %{opts: opts} do
    refute Process.whereis(Handout.Server)
    assert :ok = Handout.on_login(~c"root", {{127, 0, 0, 1}, 1}, ~c"publickey")
    assert File.exists?(opts[:claimed_path])
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

  test "on_login returns :ok when the latch cannot be written", %{opts: opts} do
    # A file where the latch's directory should be: mkdir_p fails.
    File.write!(Path.dirname(opts[:claimed_path]), "not a dir")

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
end
