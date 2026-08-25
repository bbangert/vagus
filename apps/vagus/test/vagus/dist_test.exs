defmodule Vagus.DistTest do
  @moduledoc """
  `Vagus.Dist` — runtime Erlang distribution for test work, gated by
  `/data/vagus.cookie` and applied at boot.

  Every test injects seams for the OS-touching edges, so **no test starts real
  distribution, epmd, or reboots anything** — and none writes the developer's
  real `$HOME/.erlang.cookie`.

  **The fakes return what OTP really returns.** An earlier suite's
  `set_cookie_fun`/`net_kernel_start_fun` answered `:ok`/`{:ok, pid}`
  unconditionally, so 23 green tests plus a clean analyzer gate proved nothing
  about the two edges that were wrong. A seam whose fake cannot fail is a seam
  that hides the defect it was cut for, so the VM model here tracks aliveness
  and the cookie together, exactly as a real node does.

  `async: false` is required, not habitual: the supervision test reads the
  global `node()` and `Process.whereis/1`.
  """
  use ExUnit.Case, async: false

  import Bitwise, only: [band: 2]
  import ExUnit.CaptureLog

  alias Vagus.Dist

  @cookie String.duplicate("ab", 32)
  @cookie_atom String.to_atom(@cookie)
  @other_cookie_atom String.to_atom(String.duplicate("cd", 32))

  @eth0 {~c"eth0", [flags: [:up], addr: {192, 168, 2, 58}]}
  @loopback {~c"lo", [flags: [:up], addr: {127, 0, 0, 1}]}
  @epmd_up "epmd: up and running on port 4369 with data:\n"
  @epmd_down "epmd: Cannot connect to local epmd\n"

  setup do
    dir = Path.join(System.tmp_dir!(), "dist_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, path: Path.join(dir, "vagus.cookie"), home: Path.join(dir, ".erlang.cookie")}
  end

  defp start_dist(ctx, opts \\ []) do
    test = self()

    # The VM's distribution state as OTP models it, and as MEASURED on a
    # runtime-started node: net_kernel.start makes it alive, net_kernel.stop
    # makes it not AND resets the cookie to :nocookie. A fake that let a
    # "started" node report not-alive could not express a node dying underneath
    # us, which is a state this module has to notice.
    {:ok, vm} = Agent.start_link(fn -> %{node: nil, cookie: :nocookie} end)
    {:ok, epmd} = Agent.start_link(fn -> false end)
    on_exit(fn -> if Process.alive?(vm), do: Agent.stop(vm) end)
    on_exit(fn -> if Process.alive?(epmd), do: Agent.stop(epmd) end)

    {:ok, pid} =
      Dist.start_link(
        name: :"dist_#{System.unique_integer([:positive])}",
        cookie_path: Keyword.get(opts, :cookie_path, ctx.path),
        chmod_fun: Keyword.get(opts, :chmod_fun, &File.chmod/2),
        ifaddrs_fun: Keyword.get(opts, :ifaddrs_fun, fn -> [@loopback, @eth0] end),
        put_env_fun: fn key, value -> record(test, {:put_env, key, value}) end,
        # NEVER defaulted: the real seam derives $HOME, and a test that let it
        # would overwrite the developer's own Erlang cookie at mode 0400.
        erlang_cookie_path_fun:
          Keyword.get(opts, :erlang_cookie_path_fun, fn -> {:ok, ctx.home} end),
        set_cookie_fun:
          Keyword.get(opts, :set_cookie_fun, fn cookie ->
            Agent.update(vm, &%{&1 | cookie: cookie})
            record(test, {:set_cookie, cookie})
          end),
        get_cookie_fun: Keyword.get(opts, :get_cookie_fun, fn -> Agent.get(vm, & &1.cookie) end),
        net_kernel_start_fun:
          Keyword.get(opts, :net_kernel_start_fun, fn name, kernel_opts ->
            record(test, {:net_kernel_start, name, kernel_opts})
            Agent.update(vm, &%{&1 | node: name})
            {:ok, self()}
          end),
        net_kernel_stop_fun:
          Keyword.get(opts, :net_kernel_stop_fun, fn ->
            Agent.update(vm, fn _ -> %{node: nil, cookie: :nocookie} end)
            record(test, {:net_kernel_stop})
          end),
        alive_fun: Keyword.get(opts, :alive_fun, fn -> Agent.get(vm, & &1.node) != nil end),
        self_node_fun:
          Keyword.get(opts, :self_node_fun, fn -> Agent.get(vm, & &1.node) || :nonode@nohost end),
        epmd_fun:
          Keyword.get(opts, :epmd_fun, fn args, env ->
            record(test, {:epmd, args, env})

            case args do
              ["-daemon"] -> Agent.update(epmd, fn _ -> true end) && {"", 0}
              ["-kill"] -> Agent.update(epmd, fn _ -> false end) && {"Killed\n", 0}
              ["-names"] -> if Agent.get(epmd, & &1), do: {@epmd_up, 0}, else: {@epmd_down, 1}
            end
          end),
        reboot_fun: Keyword.get(opts, :reboot_fun, fn -> record(test, {:reboot}) end)
      )

    on_exit(fn -> stop(pid) end)
    pid
  end

  # A cookie on disk at start_link time is what makes the BOOT path run.
  defp boot!(ctx, opts \\ []) do
    seed_cookie!(ctx)
    start_dist(ctx, opts)
  end

  defp seed_cookie!(ctx, cookie \\ @cookie) do
    File.write!(ctx.path, cookie)
    File.chmod!(ctx.path, 0o600)
  end

  defp record(test, step) do
    send(test, Tuple.insert_at(step, 0, :step))
    :ok
  end

  # Narrow: catching every exit reason would swallow a genuine crash during
  # cleanup and report the run green.
  defp stop(pid) do
    GenServer.stop(pid)
  catch
    :exit, :noproc -> :ok
    :exit, {:noproc, _call} -> :ok
    :exit, {:normal, _call} -> :ok
    :exit, {:shutdown, _call} -> :ok
  end

  defp flush do
    receive do
      _anything -> flush()
    after
      0 -> :ok
    end
  end

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    band(mode, 0o777)
  end

  describe "start_link/1 gating" do
    test "is :ignore when no cookie path is configured" do
      assert :ignore == Dist.start_link([])
    end

    test "starts idle when the path is set but no cookie file exists", ctx do
      pid = start_dist(ctx)
      status = Dist.status(pid)

      refute status.alive?
      refute status.cookie_present?
      assert status.node == nil
      assert status.ports == 9100..9105
      assert status.last_error == nil

      refute_received {:step, :epmd, _, _}
      refute_received {:step, :net_kernel_start, _, _}
      refute_received {:step, :reboot}
    end
  end

  describe "enable/1" do
    test "mints a 0600 cookie, returns what you need to connect, and reboots", ctx do
      pid = start_dist(ctx)

      assert {:ok, %{cookie: cookie, node: nil, ports: 9100..9105}} = Dist.enable(pid)
      assert String.match?(cookie, ~r/^[0-9a-f]{64}$/)
      assert File.read!(ctx.path) == cookie
      assert mode(ctx.path) == 0o600

      # The reboot is what applies it — nothing was started here.
      assert_received {:step, :reboot}
      refute_received {:step, :net_kernel_start, _, _}
      refute_received {:step, :epmd, _, _}

      # $HOME/.erlang.cookie is the boot path's job, seeded immediately before
      # net_kernel.start because that is when `auth` reads it.
      refute File.exists?(ctx.home)
    end

    test "is idempotent and does not reboot a board that is already distributed", ctx do
      pid = boot!(ctx)
      assert Dist.status(pid).alive?
      flush()

      assert {:ok, %{cookie: @cookie, node: :"vagus@192.168.2.58"}} = Dist.enable(pid)
      refute_received {:step, :reboot}
    end

    test "a cookie problem is reported and nothing reboots", ctx do
      seed_cookie!(ctx, "not-a-valid-cookie")
      pid = start_dist(ctx)

      assert {:error, :cookie_malformed} = Dist.enable(pid)
      refute_received {:step, :reboot}
    end
  end

  describe "disable/1" do
    test "deletes both cookie files and reboots", ctx do
      pid = boot!(ctx)
      # status/0 is a synchronous round-trip, so it cannot answer before
      # handle_continue/2 has run.
      assert Dist.status(pid).alive?
      assert File.exists?(ctx.path)
      assert File.exists?(ctx.home)
      flush()

      assert :ok = Dist.disable(pid)

      refute File.exists?(ctx.path)
      refute File.exists?(ctx.home)
      assert_received {:step, :reboot}
    end

    test "does NOT reboot while a cookie file survives", ctx do
      # Rebooting with the gate still open would bring distribution straight
      # back, which is the opposite of what was asked for.
      File.mkdir_p!(ctx.path)
      on_exit(fn -> File.rm_rf!(ctx.path) end)

      pid = start_dist(ctx)

      assert {:error, {:cookie_not_removed, _path, _reason}} = Dist.disable(pid)
      refute_received {:step, :reboot}
    end

    test "a missing cookie file is not a failure", ctx do
      pid = start_dist(ctx)
      assert :ok = Dist.disable(pid)
    end

    test "a retry pending across disable/1 must not re-mint the cookie", ctx do
      # The retry has to go through boot/1, where the cookie-presence gate
      # lives. Reaching read_or_mint/1 directly would see :enoent and MINT,
      # silently re-enabling the next boot after a disable that answered :ok.
      pid = boot!(ctx, ifaddrs_fun: fn -> [@loopback] end)

      refute Dist.status(pid).alive?
      assert :ok = Dist.disable(pid)
      refute File.exists?(ctx.path)

      send(pid, :retry_start)
      refute Dist.status(pid).alive?
      refute File.exists?(ctx.path)
      refute File.exists?(ctx.home)
    end
  end

  describe "the boot sequence" do
    test "pins ports and starts epmd before net_kernel, then applies the cookie", ctx do
      pid = boot!(ctx)
      assert Dist.status(pid).node == :"vagus@192.168.2.58"

      # Order is the point, and assert_received consumes in mailbox order, so
      # these passing in sequence IS the ordering proof. inet_tcp_dist reads the
      # port range from the kernel app env at LISTEN time.
      assert_received {:step, :put_env, :inet_dist_listen_min, 9100}
      assert_received {:step, :put_env, :inet_dist_listen_max, 9105}
      assert_received {:step, :epmd, ["-names"], []}
      assert_received {:step, :epmd, ["-daemon"], []}

      assert_received {:step, :net_kernel_start, :"vagus@192.168.2.58",
                       %{name_domain: :longnames}}

      # AFTER net_kernel, because set_cookie/1 before it raises.
      assert_received {:step, :set_cookie, @cookie_atom}
    end

    test "no ERL_EPMD_ADDRESS and no interface pin — the listener is the wildcard", ctx do
      pid = boot!(ctx)
      assert Dist.status(pid).alive?

      assert_received {:step, :epmd, ["-daemon"], []}
      refute_received {:step, :put_env, :inet_dist_use_interface, _}
    end

    test "the $HOME cookie is on disk before net_kernel starts", ctx do
      # The whole reason for pre-seeding: auth:init_cookie/0 reads that file
      # while net_kernel comes up, so there is no window in which the node is
      # live on the LAN under a secret we did not choose.
      test = self()

      pid =
        boot!(ctx,
          net_kernel_start_fun: fn name, opts ->
            record(test, {:home_cookie, File.read(ctx.home)})
            record(test, {:net_kernel_start, name, opts})
            {:ok, self()}
          end
        )

      refute Dist.status(pid).alive?
      assert_received {:step, :home_cookie, {:ok, @cookie}}
      assert mode(ctx.home) == 0o400
    end

    test "refuses when $HOME cannot be derived, and rolls epmd back", ctx do
      pid = boot!(ctx, erlang_cookie_path_fun: fn -> {:error, :no_home} end)

      assert Dist.status(pid).last_error == {:erlang_cookie_path, :no_home}
      refute_received {:step, :net_kernel_start, _, _}
      assert_received {:step, :epmd, ["-daemon"], []}
      assert_received {:step, :epmd, ["-kill"], []}
    end

    test "replaces an epmd it did not launch", ctx do
      test = self()

      epmd = fn args, env ->
        record(test, {:epmd, args, env})
        if args == ["-names"], do: {@epmd_up, 0}, else: {"", 0}
      end

      pid = boot!(ctx, epmd_fun: epmd)
      assert Dist.status(pid).alive?

      assert_received {:step, :epmd, ["-names"], []}
      assert_received {:step, :epmd, ["-kill"], []}
      assert_received {:step, :epmd, ["-daemon"], []}
    end

    test "a failing epmd -daemon stops the sequence", ctx do
      test = self()

      epmd = fn args, env ->
        record(test, {:epmd, args, env})

        case args do
          ["-daemon"] -> {"cannot bind", 1}
          ["-names"] -> {@epmd_down, 1}
          ["-kill"] -> {"", 0}
        end
      end

      pid = boot!(ctx, epmd_fun: epmd)

      assert Dist.status(pid).last_error == {:epmd_failed, 1, "cannot bind"}
      refute_received {:step, :net_kernel_start, _, _}
    end
  end

  describe "the node name" do
    test "carries a reachable address so connecting needs no lookup", ctx do
      pid = boot!(ctx)
      assert Dist.status(pid).node == :"vagus@192.168.2.58"
    end

    test "skips loopback, link-local, container and wildcard addresses", ctx do
      # A name on any of these is unreachable from the LAN the operator is
      # calling from. Nothing else is ranked or preferred.
      unusable = [
        @loopback,
        {~c"lo2", [addr: {0, 0, 0, 0}]},
        {~c"wlan9", [addr: {169, 254, 3, 4}]},
        {~c"hassio", [addr: {172, 30, 32, 2}]},
        {~c"balena0", [addr: {172, 17, 0, 1}]}
      ]

      pid = boot!(ctx, ifaddrs_fun: fn -> unusable end)

      assert Dist.status(pid).last_error == :no_address
      refute_received {:step, :net_kernel_start, _, _}
    end

    test "retries until an address appears, and never gives up", ctx do
      pid = boot!(ctx, ifaddrs_fun: fn -> [@loopback] end)

      assert Dist.status(pid).last_error == :no_address
      assert is_reference(:sys.get_state(pid).retry_ref)
    end
  end

  describe "the cookie read-back" do
    test "stops the node and refuses when get_cookie disagrees with the file", ctx do
      # Exactly what a pre-seed written to a path `auth` does not read looks
      # like from here. A node alive under a cookie that is not ours is the one
      # state this must never leave behind.
      pid = boot!(ctx, get_cookie_fun: fn -> @other_cookie_atom end)

      assert Dist.status(pid).last_error == :cookie_not_applied
      assert_received {:step, :net_kernel_stop}
      refute Dist.status(pid).alive?
    end

    test "a raising set_cookie stops the node it already started", ctx do
      # net_kernel is ALREADY live by the time set_cookie runs, so the raise
      # must not walk past the read-back and leave distribution up under a
      # cookie nobody verified.
      pid = boot!(ctx, set_cookie_fun: fn _cookie -> raise "set_cookie/1 blew up" end)

      refute Dist.status(pid).alive?
      assert Process.alive?(pid)
      assert_received {:step, :net_kernel_start, :"vagus@192.168.2.58", _opts}
      assert_received {:step, :net_kernel_stop}
    end

    test "a crash on the boot path never writes the cookie to the log", ctx do
      # MEASURED: an Erlang stacktrace carries a frame's ARGUMENTS for
      # function_clause and BIF badarg, and the cookie is an argument the whole
      # length of the start. Formatting one verbatim printed the secret.
      log =
        capture_log(fn ->
          pid = boot!(ctx, set_cookie_fun: fn :never_matches -> :ok end)
          refute Dist.status(pid).alive?
        end)

      assert log =~ "FunctionClauseError"
      refute log =~ @cookie
    end

    test "the real seam defaults cannot pass the read-back on an undistributed VM" do
      # Pins the shape of the raw-OTP defaults the fakes stand in for: a default
      # that echoed set_cookie/1 back would make this pass when it should not.
      assert :erlang.get_cookie() != @cookie_atom
    end

    test "the default $HOME derivation is the file `auth` actually reads" do
      # The single assumption the pre-seed rests on: auth:init_cookie/0 derives
      # the path from init:get_argument(home), not from the OS environment.
      assert {:ok, path} = Dist.erlang_cookie_path()
      assert {:ok, [[home] | _]} = :init.get_argument(:home)
      assert path == Path.join(List.to_string(home), ".erlang.cookie")
    end
  end

  describe "reconciling an already-live node" do
    test "an alive VM short-circuits the whole bring-up", ctx do
      # net_kernel survives a GenServer crash-restart while init/1 rebuilds
      # state.node as nil. Node.self/0 is authoritative; this module's
      # bookkeeping is not.
      pid =
        boot!(ctx,
          alive_fun: fn -> true end,
          self_node_fun: fn -> :"vagus@192.168.2.58" end
        )

      assert Dist.status(pid).node == :"vagus@192.168.2.58"
      refute_received {:step, :epmd, _, _}
      refute_received {:step, :put_env, _, _}
      refute_received {:step, :net_kernel_start, _, _}
    end

    test "adopts the live node when net_kernel answers already_started", ctx do
      # Measured: net_kernel answers this even under a DIFFERENT name, so a
      # restart that also changed address lands here.
      test = self()

      pid =
        boot!(ctx,
          net_kernel_start_fun: fn name, opts ->
            record(test, {:net_kernel_start, name, opts})
            {:error, {:already_started, self()}}
          end,
          self_node_fun: fn -> :"vagus@10.9.9.9" end
        )

      assert Dist.status(pid).node == :"vagus@10.9.9.9"
      assert Dist.status(pid).last_error == nil
    end
  end

  describe "status/1" do
    test "alive? comes from the VM, not from cached bookkeeping", ctx do
      {:ok, vm} = Agent.start_link(fn -> true end)
      on_exit(fn -> if Process.alive?(vm), do: Agent.stop(vm) end)

      pid =
        boot!(ctx,
          alive_fun: fn -> Agent.get(vm, & &1) end,
          self_node_fun: fn -> :"vagus@192.168.2.58" end
        )

      assert Dist.status(pid).alive?

      # net_kernel can be stopped from anywhere on the board; state.node
      # outlives it and would keep answering yes.
      Agent.update(vm, fn _ -> false end)
      refute Dist.status(pid).alive?
      assert Dist.status(pid).node == :"vagus@192.168.2.58"
    end
  end

  describe "the cookie file is not operator-editable" do
    test "an empty file is corruption, not a request to start", ctx do
      File.write!(ctx.path, "")
      pid = start_dist(ctx)

      assert {:error, :cookie_empty} = Dist.enable(pid)
      assert File.read!(ctx.path) == ""
    end

    test "a wrong mode is refused WITHOUT being read", ctx do
      File.write!(ctx.path, @cookie)
      File.chmod!(ctx.path, 0o644)
      pid = start_dist(ctx)

      assert {:error, {:mode_unproven, 0o644}} = Dist.enable(pid)
      assert File.read!(ctx.path) == @cookie
    end

    test "an unreadable cookie surfaces :cookie_unreadable", ctx do
      File.mkdir_p!(ctx.path)
      File.write!(Path.join(ctx.path, "entry"), "x")
      File.chmod!(ctx.path, 0o600)
      on_exit(fn -> File.chmod(ctx.path, 0o755) end)

      pid = start_dist(ctx)
      assert {:error, {:cookie_unreadable, :eisdir}} = Dist.enable(pid)
    end

    test "an unwritable directory surfaces :cookie_unwritable", ctx do
      locked = Path.join(ctx.dir, "locked")
      File.mkdir_p!(locked)
      File.chmod!(locked, 0o500)
      on_exit(fn -> File.chmod(locked, 0o755) end)

      pid = start_dist(ctx, cookie_path: Path.join(locked, "vagus.cookie"))
      assert {:error, {:cookie_unwritable, :eacces}} = Dist.enable(pid)
    end

    test "a symlink swapped in under the temp file is caught by the mode read-back", ctx do
      # W4's threat run for real: this writes as root on a board, so a symlink
      # planted at the destination would be followed.
      chmod = fn tmp, _mode ->
        File.rm!(tmp)
        File.ln_s!(Path.join(ctx.dir, "nowhere"), tmp)
        :ok
      end

      pid = start_dist(ctx, chmod_fun: chmod)
      assert {:error, {:cookie_unwritable, {:mode_unproven, :enoent}}} = Dist.enable(pid)
      refute File.exists?(ctx.path)
    end
  end

  describe "in the application supervision tree" do
    test "the app-started child is :ignore and the node stays down on :host" do
      # config/test.exs leaves :dist_cookie_path unset, which is what makes the
      # unconditional child a no-op. Shipping the capability has to be
      # observably inert.
      assert Application.get_env(:vagus, :dist_cookie_path) == nil
      assert Process.whereis(Dist) == nil
      assert node() == :nonode@nohost
    end
  end

  describe "run/1" do
    test "sets async_dist on the CALLING process — the one that sends" do
      # Under :erpc.call/5 the caller is the erpc-spawned process, and the
      # payload leaves the node as ITS exit reason. Flagging a child Task would
      # flag a process whose only send is local.
      previous = Process.flag(:async_dist, false)
      caller = self()

      {flag_while_running, runner} =
        Dist.run(fn -> {:erlang.process_flag(:async_dist, true), self()} end)

      assert flag_while_running
      assert runner == caller

      Process.flag(:async_dist, previous)
    end

    test "a raise inside the fun propagates to the caller unchanged" do
      assert_raise RuntimeError, "boom", fn -> Dist.run(fn -> raise "boom" end) end
    end

    test "an exit inside the fun propagates to the caller unchanged" do
      assert :nope == catch_exit(Dist.run(fn -> exit(:nope) end))
    end
  end
end
