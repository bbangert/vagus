defmodule Vagus.NFSTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Vagus.NFS

  @nfsd_start ["-N", "3", "-V", "4.0", "--no-udp", "-G", "10", "-p", "2049", "4"]
  @mountd_args ["-F", "-N", "2", "-N", "3"]
  @rw "rw,sync,no_root_squash,subtree_check,insecure"

  setup do
    base = Path.join(System.tmp_dir!(), "vagus-nfs-#{System.unique_integer([:positive])}")
    root = Path.join(base, "nfs")
    target = Path.join(root, "t1")
    File.mkdir_p!(target)
    on_exit(fn -> File.rm_rf!(base) end)

    %{base: base, root: root, target: target, state_dir: Path.join(base, "state")}
  end

  # `fail` maps {bin, args} to a canned result; `block` names a bin whose
  # call waits for :release. The fake mountd is a real process spawned (and
  # so linked) inside the server, so killing it reaches the EXIT path.
  defp start_nfs(ctx, extra \\ []) do
    test = self()
    fail = Keyword.get(extra, :fail, %{})
    block = Keyword.get(extra, :block)

    cmd = fn bin, args ->
      send(test, {:cmd, bin, args})
      if bin == block, do: receive(do: (:release -> :ok))
      Map.get(fail, {bin, args}, {"", 0})
    end

    daemon = fn
      :start, args ->
        case Keyword.get(extra, :daemon_result) do
          nil ->
            pid = spawn_link(fn -> Process.sleep(:infinity) end)
            send(test, {:daemon_start, args, pid})
            {:ok, pid}

          result ->
            send(test, {:daemon_start, args, nil})
            result
        end

      :stop, pid ->
        send(test, {:daemon_stop, pid})
        Process.unlink(pid)
        Process.exit(pid, :kill)
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

    start_supervised!(Supervisor.child_spec({NFS, opts}, id: name))
    [server: name]
  end

  defp assert_cmd(bin, args), do: assert_received({:cmd, ^bin, ^args})

  # Fake runner messages in arrival order; daemon pids reduced to the args.
  defp events(acc \\ []) do
    receive do
      {:cmd, bin, args} -> events([{bin, args} | acc])
      {:daemon_start, args, _pid} -> events([{:mountd_start, args} | acc])
      {:daemon_stop, _pid} -> events([:mountd_stop | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp mountd_pid(s) do
    s[:server] |> :sys.get_state() |> Map.fetch!(:mountd)
  end

  defp kill_mountd(s) do
    pid = mountd_pid(s)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    # status/1 is served after the EXIT, which was queued first.
    NFS.status(s)
  end

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

  test "a call that outlives its timeout is {:error, :timeout}", ctx do
    s = start_nfs(ctx, block: "modprobe")

    assert NFS.export(ctx.target, "10.0.0.1", Keyword.put(s, :timeout, 50)) ==
             {:error, :timeout}

    send(GenServer.whereis(s[:server]), :release)
    assert %{running: true} = NFS.status(s)
  end

  test "the first export starts the server, in order", ctx do
    s = start_nfs(ctx)

    assert NFS.export(ctx.target, "10.42.0.0/24", s) == :ok

    assert events() == [
             {"modprobe", ["nfsd"]},
             {"mount", ["-t", "nfsd", "nfsd", "/proc/fs/nfsd"]},
             {:mountd_start, @mountd_args},
             {"rpc.nfsd", @nfsd_start},
             {"exportfs", ["-o", @rw, "10.42.0.0/24:" <> ctx.target]}
           ]

    assert Bitwise.band(File.stat!(ctx.state_dir).mode, 0o777) == 0o700
    assert File.exists?(Path.join(ctx.state_dir, "etab"))
    assert File.exists?(Path.join(ctx.state_dir, "rmtab"))

    assert NFS.status(s) == %{
             running: true,
             exports: [
               %{path: ctx.target, export_path: ctx.target, client: "10.42.0.0/24", options: @rw}
             ]
           }
  end

  test "nfsd is not mounted again when it already is", ctx do
    s = start_nfs(ctx, mounted: true)
    assert NFS.export(ctx.target, "10.42.0.7", s) == :ok
    refute_received {:cmd, "mount", _}
  end

  test "a second export reuses the running server; ro and subtree_check: false apply", ctx do
    s = start_nfs(ctx)
    other = Path.join(ctx.root, "t2")
    File.mkdir_p!(other)

    :ok = NFS.export(ctx.target, "10.42.0.7", s)
    flush()

    assert NFS.export(other, "10.42.0.8", Keyword.merge(s, ro: true, subtree_check: false)) == :ok

    assert events() == [
             {"exportfs",
              [
                "-o",
                "ro,sync,no_root_squash,no_subtree_check,insecure",
                "10.42.0.8:" <> other
              ]}
           ]

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
    flush()

    assert NFS.unexport(other, s) == :ok
    assert events() == [{"exportfs", ["-u", "10.42.0.8:" <> other]}]

    assert NFS.unexport(ctx.target, s) == :ok

    assert events() == [
             {"exportfs", ["-u", "10.42.0.7:" <> ctx.target]},
             {"rpc.nfsd", ["0"]},
             :mountd_stop
           ]

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
    assert NFS.export(link, "10.0.0.1", s) == {:error, :symlink}
    refute_received {:cmd, _, _}
  end

  test "a symlink anywhere below the root is refused", ctx do
    s = start_nfs(ctx)
    File.mkdir_p!(Path.join(ctx.base, "outside/etc"))
    File.ln_s!(Path.join(ctx.base, "outside"), Path.join(ctx.root, "link"))

    assert NFS.export(Path.join(ctx.root, "link/etc"), "10.0.0.1", s) == {:error, :symlink}
    refute_received {:cmd, _, _}
  end

  test "a root that is itself a symlink exports the physical path", ctx do
    link_root = Path.join(ctx.base, "linkroot")
    File.ln_s!(ctx.root, link_root)
    s = start_nfs(%{ctx | root: link_root})
    caller = Path.join(link_root, "t1")

    assert NFS.export(caller, "10.0.0.1", s) == :ok
    assert_cmd("exportfs", ["-o", @rw, "10.0.0.1:" <> ctx.target])
    assert [%{path: ^caller, export_path: export_path}] = NFS.status(s).exports
    assert export_path == ctx.target
  end

  # The Nerves layout: /data -> /root.
  defp symlinked_ancestor(ctx) do
    real = Path.join(ctx.base, "real")
    File.mkdir_p!(Path.join(real, "vagus/nfs/t"))
    File.ln_s!("real", Path.join(ctx.base, "data"))

    %{
      root: Path.join(ctx.base, "data/vagus/nfs"),
      caller: Path.join(ctx.base, "data/vagus/nfs/t"),
      physical: Path.join(real, "vagus/nfs/t")
    }
  end

  test "a root reached through a symlinked ancestor exports the physical path", ctx do
    l = symlinked_ancestor(ctx)
    s = start_nfs(%{ctx | root: l.root})

    assert NFS.export(l.caller, "10.0.0.1", s) == :ok
    assert events() |> List.last() == {"exportfs", ["-o", @rw, "10.0.0.1:" <> l.physical]}

    assert NFS.status(s).exports == [
             %{path: l.caller, export_path: l.physical, client: "10.0.0.1", options: @rw}
           ]

    assert NFS.export(l.caller, "10.0.0.1", s) == :ok
    assert NFS.export(l.physical, "10.0.0.1", s) == :ok
    refute_received {:cmd, _, _}

    assert {:error, {:already_exported, _}} = NFS.export(l.physical, "10.0.0.2", s)

    assert NFS.unexport(l.physical, s) == :ok
    assert_cmd("exportfs", ["-u", "10.0.0.1:" <> l.physical])
  end

  test "below a symlinked ancestor, a symlink is still refused", ctx do
    l = symlinked_ancestor(ctx)
    File.mkdir_p!(Path.join(ctx.base, "outside/etc"))
    File.ln_s!(Path.join(ctx.base, "outside"), Path.join(l.root, "link"))
    s = start_nfs(%{ctx | root: l.root})

    assert NFS.export(Path.join(l.root, "link/etc"), "10.0.0.1", s) == {:error, :symlink}

    assert NFS.export(Path.join(l.root, "../../../outside"), "10.0.0.1", s) ==
             {:error, :outside_root}

    refute_received {:cmd, _, _}
  end

  test "a missing or looping root is invalid", ctx do
    loop = Path.join(ctx.base, "loop")
    File.ln_s!(loop, loop)

    for root <- [Path.join(ctx.base, "missing"), Path.join(loop, "nfs")] do
      s = start_nfs(%{ctx | root: root})
      assert NFS.export(Path.join(root, "t1"), "10.0.0.1", s) == {:error, :invalid_root}
    end

    refute_received {:cmd, _, _}
  end

  test "etab entries are adopted by their physical path only", ctx do
    l = symlinked_ancestor(ctx)
    other = Path.join(ctx.base, "real/vagus/nfs/u")
    File.mkdir_p!(other)
    File.mkdir_p!(ctx.state_dir)

    File.write!(Path.join(ctx.state_dir, "etab"), """
    #{l.physical}\t10.0.0.1(rw,sync,insecure,no_root_squash,subtree_check)
    #{Path.join(l.root, "u")}\t10.0.0.2(rw,sync,insecure,no_root_squash,subtree_check)
    """)

    s = start_nfs(%{ctx | root: l.root})

    assert NFS.status(s).exports == [
             %{path: l.physical, export_path: l.physical, client: "10.0.0.1", options: @rw}
           ]

    assert_cmd("exportfs", ["-u", "10.0.0.2:" <> Path.join(l.root, "u")])
    assert NFS.export(l.caller, "10.0.0.1", s) == :ok
  end

  test "paths with ':', whitespace or control bytes are refused", ctx do
    s = start_nfs(ctx)

    for name <- ["a:b", "a b", "a\tb", "a\nb", <<"a", 0, "b">>, <<"a", 0xFF>>] do
      dir = Path.join(ctx.root, name)
      assert NFS.export(dir, "10.0.0.1", s) == {:error, :invalid_path}, inspect(name)
    end

    refute_received {:cmd, _, _}
  end

  test "clients must be an IPv4 address or a CIDR of /8 or narrower", ctx do
    s = start_nfs(ctx)

    for bad <- [
          "",
          "*",
          "host.lan",
          "10.0.0.256",
          "10.0.0.0/33",
          "0.0.0.0/0",
          "10.0.0.0/0",
          "10.0.0.0/7",
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

  test "a failed exportfs leaves the other exports and the server alone", ctx do
    other = Path.join(ctx.root, "t2")
    File.mkdir_p!(other)
    spec = "10.0.0.2:" <> other
    s = start_nfs(ctx, fail: %{{"exportfs", ["-o", @rw, spec]} => {"bad", 1}})
    :ok = NFS.export(ctx.target, "10.0.0.1", s)
    flush()

    assert NFS.export(other, "10.0.0.2", s) == {:error, {"exportfs", ["-o", @rw, spec], "bad", 1}}
    assert events() == [{"exportfs", ["-o", @rw, spec]}]
    assert %{running: true, exports: [%{path: path}]} = NFS.status(s)
    assert path == ctx.target
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

  test "a mountd that exits is restarted and the exports kept", ctx do
    s = start_nfs(ctx)
    :ok = NFS.export(ctx.target, "10.0.0.1", s)
    old = mountd_pid(s)
    flush()

    assert %{running: true, exports: [%{path: path}]} = kill_mountd(s)
    assert path == ctx.target
    assert events() == [{:mountd_start, @mountd_args}]
    assert mountd_pid(s) not in [nil, old]
  end

  test "a mountd that keeps exiting makes the server give up", ctx do
    s = start_nfs(ctx)
    :ok = NFS.export(ctx.target, "10.0.0.1", s)

    for _ <- 1..3, do: assert(%{running: true} = kill_mountd(s))
    flush()

    assert kill_mountd(s) == %{running: false, exports: []}
    assert events() == [{"exportfs", ["-ua"]}, {"rpc.nfsd", ["0"]}]
  end

  test "exports in a previous instance's etab are adopted", ctx do
    File.mkdir_p!(ctx.state_dir)
    gone = Path.join(ctx.root, "gone")

    # The shape putexportent() writes, trimmed of trailing flags.
    File.write!(Path.join(ctx.state_dir, "etab"), """
    #{ctx.target}\t10.42.0.0/24(rw,sync,wdelay,hide,nocrossmnt,insecure,no_root_squash,no_all_squash,subtree_check,secure_locks,acl,no_pnfs,anonuid=65534,anongid=65534,sec=sys,rw,insecure,no_root_squash,no_all_squash)
    #{gone}\t10.42.0.9(ro,sync,wdelay,hide,nocrossmnt,insecure,no_root_squash,no_all_squash,no_subtree_check,secure_locks,acl,no_pnfs,anonuid=65534,anongid=65534,sec=sys,ro,insecure,no_root_squash,no_all_squash)
    """)

    s = start_nfs(ctx)

    # status/1 is served after handle_continue, so adoption has run.
    assert NFS.status(s) == %{
             running: true,
             exports: [
               %{path: ctx.target, export_path: ctx.target, client: "10.42.0.0/24", options: @rw}
             ]
           }

    assert events() == [
             {"exportfs", ["-u", "10.42.0.9:" <> gone]},
             {"modprobe", ["nfsd"]},
             {"mount", ["-t", "nfsd", "nfsd", "/proc/fs/nfsd"]},
             {:mountd_start, @mountd_args},
             {"rpc.nfsd", @nfsd_start},
             {"exportfs", ["-f"]}
           ]

    assert NFS.export(ctx.target, "10.42.0.0/24", s) == :ok
    refute_received {:cmd, _, _}
  end

  defp write_etab(ctx, entries) do
    File.mkdir_p!(ctx.state_dir)

    etab =
      Enum.map_join(entries, fn {path, client} ->
        "#{path}\t#{client}(rw,sync,insecure,no_root_squash,subtree_check)\n"
      end)

    File.write!(Path.join(ctx.state_dir, "etab"), etab)
  end

  test "an exportfs that times out leaves state matching a re-read etab", ctx do
    spec = "10.0.0.1:" <> ctx.target
    s = start_nfs(ctx, fail: %{{"exportfs", ["-o", @rw, spec]} => {"", 124}})
    # The killed exportfs had already written etab.
    write_etab(ctx, [{ctx.target, "10.0.0.1"}])

    assert NFS.export(ctx.target, "10.0.0.1", s) ==
             {:error, {"exportfs", ["-o", @rw, spec], "", 124}}

    assert NFS.status(s) == %{
             running: true,
             exports: [
               %{path: ctx.target, export_path: ctx.target, client: "10.0.0.1", options: @rw}
             ]
           }

    assert events() |> Enum.drop(5) == [
             {"rpc.nfsd", ["0"]},
             :mountd_stop,
             {"modprobe", ["nfsd"]},
             {"mount", ["-t", "nfsd", "nfsd", "/proc/fs/nfsd"]},
             {:mountd_start, @mountd_args},
             {"rpc.nfsd", @nfsd_start},
             {"exportfs", ["-f"]}
           ]
  end

  test "an exportfs -u that times out after landing drops the export", ctx do
    spec = "10.0.0.1:" <> ctx.target
    s = start_nfs(ctx, fail: %{{"exportfs", ["-u", spec]} => {"", 124}})
    :ok = NFS.export(ctx.target, "10.0.0.1", s)
    write_etab(ctx, [])
    flush()

    assert {:error, {"exportfs", _, "", 124}} = NFS.unexport(ctx.target, s)
    assert NFS.status(s) == %{running: false, exports: []}
    assert events() == [{"exportfs", ["-u", spec]}, {"rpc.nfsd", ["0"]}, :mountd_stop]
  end

  test "an empty etab starts nothing", ctx do
    File.mkdir_p!(ctx.state_dir)
    File.write!(Path.join(ctx.state_dir, "etab"), "")
    s = start_nfs(ctx)
    assert NFS.status(s) == %{running: false, exports: []}
    assert events() == []
  end

  test "nothing runs on a clean start", ctx do
    s = start_nfs(ctx)
    NFS.status(s)
    assert events() == []
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
