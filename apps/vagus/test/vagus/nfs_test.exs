defmodule Vagus.NFSTest do
  use ExUnit.Case, async: true

  alias Vagus.NFS

  @nfsd_start ["-N", "2", "-N", "3", "--no-udp", "-G", "10", "4"]
  @rw "rw,sync,no_root_squash,no_subtree_check,insecure"

  setup do
    base = Path.join(System.tmp_dir!(), "vagus-nfs-#{System.unique_integer([:positive])}")
    root = Path.join(base, "nfs")
    target = Path.join(root, "t1")
    File.mkdir_p!(target)
    on_exit(fn -> File.rm_rf!(base) end)

    %{base: base, root: root, target: target, state_dir: Path.join(base, "state")}
  end

  # `fail` maps {bin, args} to a canned non-zero result.
  defp start_nfs(ctx, extra \\ []) do
    test = self()
    fail = Keyword.get(extra, :fail, %{})

    cmd = fn bin, args ->
      send(test, {:cmd, bin, args})
      Map.get(fail, {bin, args}, {"", 0})
    end

    daemon = fn
      :start, args ->
        pid = spawn(fn -> Process.sleep(:infinity) end)
        send(test, {:daemon_start, args, pid})
        Keyword.get(extra, :daemon_result, {:ok, pid})

      :stop, pid ->
        send(test, {:daemon_stop, pid})
        :ok
    end

    name = :"nfs_#{System.unique_integer([:positive])}"

    opts = [
      name: name,
      enabled: true,
      root: ctx.root,
      state_dir: ctx.state_dir,
      cmd: cmd,
      daemon: daemon,
      nfsd_mounted?: fn -> Keyword.get(extra, :mounted, false) end
    ]

    start_supervised!({NFS, opts})
    [server: name]
  end

  defp assert_cmd(bin, args), do: assert_received({:cmd, ^bin, ^args})

  test "start_link/1 is :ignore when not enabled (the default on the host flavor)" do
    assert NFS.start_link([]) == :ignore
    assert NFS.start_link(enabled: false) == :ignore
  end

  test "the API returns an error rather than exiting when no server runs" do
    server = [server: :nfs_absent]
    assert NFS.status(server) == {:error, :not_running}
    assert NFS.export("/data/vagus/nfs/x", "10.0.0.1", server) == {:error, :not_running}
    assert NFS.unexport("/data/vagus/nfs/x", server) == {:error, :not_running}
  end

  test "the first export starts the server, in order", ctx do
    s = start_nfs(ctx)

    assert NFS.export(ctx.target, "10.42.0.0/24", s) == :ok

    assert_cmd("modprobe", ["nfsd"])
    assert_cmd("mount", ["-t", "nfsd", "nfsd", "/proc/fs/nfsd"])
    assert_received {:daemon_start, ["-F", "-N", "2", "-N", "3"], _pid}
    assert_cmd("rpc.nfsd", @nfsd_start)
    assert_cmd("exportfs", ["-o", @rw, "10.42.0.0/24:" <> ctx.target])

    assert Bitwise.band(File.stat!(ctx.state_dir).mode, 0o777) == 0o700
    assert File.exists?(Path.join(ctx.state_dir, "etab"))
    assert File.exists?(Path.join(ctx.state_dir, "rmtab"))

    assert NFS.status(s) == %{
             running: true,
             exports: [%{path: ctx.target, client: "10.42.0.0/24", options: @rw}]
           }
  end

  test "nfsd is not mounted again when it already is", ctx do
    s = start_nfs(ctx, mounted: true)
    assert NFS.export(ctx.target, "10.42.0.7", s) == :ok
    refute_received {:cmd, "mount", _}
  end

  test "a second export reuses the running server; ro flips rw", ctx do
    s = start_nfs(ctx)
    other = Path.join(ctx.root, "t2")
    File.mkdir_p!(other)

    :ok = NFS.export(ctx.target, "10.42.0.7", s)
    flush()

    assert NFS.export(other, "10.42.0.8", Keyword.put(s, :ro, true)) == :ok

    assert_cmd("exportfs", [
      "-o",
      "ro,sync,no_root_squash,no_subtree_check,insecure",
      "10.42.0.8:" <> other
    ])

    refute_received {:cmd, "modprobe", _}
    refute_received {:daemon_start, _, _}
    assert length(NFS.status(s).exports) == 2
  end

  test "re-exporting identically is a no-op; differently is refused", ctx do
    s = start_nfs(ctx)
    :ok = NFS.export(ctx.target, "10.42.0.7", s)
    flush()

    assert NFS.export(ctx.target, "10.42.0.7", s) == :ok
    refute_received {:cmd, _, _}

    assert {:error, {:already_exported, %{client: "10.42.0.7"}}} =
             NFS.export(ctx.target, "10.42.0.9", s)
  end

  test "unexport of the last entry stops the server", ctx do
    s = start_nfs(ctx)
    other = Path.join(ctx.root, "t2")
    File.mkdir_p!(other)
    :ok = NFS.export(ctx.target, "10.42.0.7", s)
    :ok = NFS.export(other, "10.42.0.8", s)
    assert_received {:daemon_start, _, mountd}
    flush()

    assert NFS.unexport(other, s) == :ok
    assert_cmd("exportfs", ["-u", "10.42.0.8:" <> other])
    refute_received {:cmd, "rpc.nfsd", _}
    refute_received {:daemon_stop, _}

    assert NFS.unexport(ctx.target, s) == :ok
    assert_cmd("exportfs", ["-u", "10.42.0.7:" <> ctx.target])
    assert_cmd("rpc.nfsd", ["0"])
    assert_received {:daemon_stop, ^mountd}
    assert NFS.status(s) == %{running: false, exports: []}

    assert NFS.unexport(ctx.target, s) == {:error, :not_exported}
  end

  test "paths outside the root, missing, files and symlinks are refused", ctx do
    s = start_nfs(ctx)
    file = Path.join(ctx.root, "file")
    File.write!(file, "")
    link = Path.join(ctx.root, "link")
    File.ln_s!(ctx.target, link)

    assert NFS.export(ctx.base, "10.0.0.1", s) == {:error, :outside_root}
    assert NFS.export(ctx.root, "10.0.0.1", s) == {:error, :outside_root}
    assert NFS.export(Path.join(ctx.target, "../../x"), "10.0.0.1", s) == {:error, :outside_root}
    assert NFS.export(ctx.root <> "-evil/x", "10.0.0.1", s) == {:error, :outside_root}
    assert NFS.export(Path.join(ctx.root, "missing"), "10.0.0.1", s) == {:error, :not_a_directory}
    assert NFS.export(file, "10.0.0.1", s) == {:error, :not_a_directory}
    assert NFS.export(link, "10.0.0.1", s) == {:error, :not_a_directory}
    refute_received {:cmd, _, _}
  end

  test "clients must be an IPv4 address or CIDR", ctx do
    s = start_nfs(ctx)

    for bad <- [
          "",
          "*",
          "host.lan",
          "10.0.0.256",
          "10.0.0.0/33",
          "10.0.0.0/",
          "10.0.0.0/8/1",
          "::1",
          "10.0.0.0/x"
        ] do
      assert NFS.export(ctx.target, bad, s) == {:error, :invalid_client}, bad
    end

    refute_received {:cmd, _, _}
    assert NFS.export(ctx.target, "10.0.0.0/8", s) == :ok
  end

  test "a failed command returns its result and changes nothing", ctx do
    s = start_nfs(ctx, fail: %{{"modprobe", ["nfsd"]} => {"modprobe: not found", 1}})

    assert NFS.export(ctx.target, "10.0.0.1", s) ==
             {:error, {"modprobe", ["nfsd"], "modprobe: not found", 1}}

    refute_received {:daemon_start, _, _}
    assert NFS.status(s) == %{running: false, exports: []}
  end

  test "a failed rpc.nfsd stops the mountd it just started", ctx do
    s = start_nfs(ctx, fail: %{{"rpc.nfsd", @nfsd_start} => {"no sockets", 1}})

    assert NFS.export(ctx.target, "10.0.0.1", s) ==
             {:error, {"rpc.nfsd", @nfsd_start, "no sockets", 1}}

    assert_received {:daemon_start, _, mountd}
    assert_received {:daemon_stop, ^mountd}
    refute_received {:cmd, "exportfs", _}
    assert NFS.status(s) == %{running: false, exports: []}
  end

  test "a failed first exportfs stops the server again", ctx do
    spec = "10.0.0.1:" <> ctx.target
    s = start_nfs(ctx, fail: %{{"exportfs", ["-o", @rw, spec]} => {"bad", 1}})

    assert NFS.export(ctx.target, "10.0.0.1", s) ==
             {:error, {"exportfs", ["-o", @rw, spec], "bad", 1}}

    assert_cmd("rpc.nfsd", ["0"])
    assert_received {:daemon_stop, _}
    assert NFS.status(s) == %{running: false, exports: []}
  end

  test "a failed exportfs -u keeps the export", ctx do
    spec = "10.0.0.1:" <> ctx.target
    s = start_nfs(ctx, fail: %{{"exportfs", ["-u", spec]} => {"busy", 1}})
    :ok = NFS.export(ctx.target, "10.0.0.1", s)

    assert NFS.unexport(ctx.target, s) == {:error, {"exportfs", ["-u", spec], "busy", 1}}
    assert %{running: true, exports: [_]} = NFS.status(s)
  end

  test "a mountd that fails to start is an error", ctx do
    s = start_nfs(ctx, daemon_result: {:error, :enoent})
    assert NFS.export(ctx.target, "10.0.0.1", s) == {:error, {"rpc.mountd", :enoent}}
    refute_received {:cmd, "rpc.nfsd", _}
  end

  test "exports left by a previous instance are dropped at start", ctx do
    File.mkdir_p!(ctx.state_dir)
    File.write!(Path.join(ctx.state_dir, "etab"), "/data/vagus/nfs/t1\t10.0.0.1(rw)\n")

    s = start_nfs(ctx)
    # status/1 is served after handle_continue, so the reset has run.
    assert NFS.status(s) == %{running: false, exports: []}
    assert_cmd("exportfs", ["-ua"])
    assert_cmd("rpc.nfsd", ["0"])
  end

  test "no reset runs on a clean start", ctx do
    s = start_nfs(ctx)
    NFS.status(s)
    refute_received {:cmd, _, _}
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
