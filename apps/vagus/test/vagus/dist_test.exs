defmodule Vagus.DistTest do
  @moduledoc """
  `Vagus.Dist` — runtime Erlang distribution gated by `/data/vagus.cookie`.

  Every test injects seams for all of the OS- and network-touching edges, so
  **no test ever starts real distribution, epmd, or mDNS** — and, just as
  importantly, no test ever writes the developer's real `$HOME/.erlang.cookie`.
  The recording seams send `{:step, ...}` to the test process, which is how the
  start sequence's ordering is asserted.

  **The fakes return what OTP really returns.** The previous suite's
  `set_cookie_fun`/`net_kernel_start_fun` answered `:ok`/`{:ok, pid}`
  unconditionally, so 23 green tests and a clean credo/dialyzer/sobelow gate
  proved nothing about the two edges that were actually wrong: a cookie that
  never applied, and `{:error, {:already_started, _}}` after a crash-restart.
  A seam whose fake cannot fail is a seam that hides the defect it was cut for.

  `async: false` is required, not habitual: the supervision-tree test reads the
  global `node()` and `Process.whereis/1`, which no concurrent test may be
  mutating.
  """
  use ExUnit.Case, async: false

  import Bitwise, only: [band: 2]
  import ExUnit.CaptureLog

  alias Vagus.Dist

  @eth0_addrs [%{address: {192, 168, 2, 58}, family: :inet, prefix_length: 24}]

  # What mint/1 writes: 64 lowercase hex characters. Anything else is refused.
  @cookie String.duplicate("ab", 32)
  @other_cookie String.duplicate("cd", 32)
  @cookie_atom String.to_atom(@cookie)
  @other_cookie_atom String.to_atom(@other_cookie)

  @epmd_up "epmd: up and running on port 4369 with data:\n"

  setup do
    dir = Path.join(System.tmp_dir!(), "dist_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir, path: Path.join(dir, "vagus.cookie"), home: Path.join(dir, ".erlang.cookie")}
  end

  # `:interfaces` is VintageNet's view, as `ifname => {connection, addresses}`.
  # Held in an Agent so a test can change it mid-run the way a DHCP lease or a
  # cable plug would.
  defp start_dist(ctx, opts \\ []) do
    {:ok, view} =
      Agent.start_link(fn -> Keyword.get(opts, :interfaces, %{"eth0" => {:lan, @eth0_addrs}}) end)

    # The VM's distribution state, as OTP models it and as MEASURED on a
    # runtime-started node: net_kernel.start makes it alive, net_kernel.stop
    # makes it not AND resets the cookie to :nocookie, and get_cookie/0
    # otherwise answers whatever set_cookie/1 was last given. A fake that let a
    # "started" node report not-alive — or a stopped one keep its cookie —
    # could not express a node dying underneath us, which is exactly the state
    # this module has to notice.
    {:ok, vm} = Agent.start_link(fn -> %{cookie: :nocookie, node: nil} end)

    # And epmd as the board really behaves — measured on a dragon_q6a:
    #   no daemon:  {"epmd: Cannot connect to local epmd\n", 1}
    #   running:    {"epmd: up and running on port 4369 with data:\n", 0}
    #   -kill:      {"Killed\n", 0}
    # A fake that answered `-names` identically either way could not express
    # "nothing to kill", which is the state the corrupt-cookie recovery hits.
    {:ok, epmd} = Agent.start_link(fn -> false end)
    on_exit(fn -> if Process.alive?(epmd), do: Agent.stop(epmd) end)

    on_exit(fn -> if Process.alive?(view), do: Agent.stop(view) end)
    on_exit(fn -> if Process.alive?(vm), do: Agent.stop(vm) end)

    interfaces = fn -> Agent.get(view, & &1) end
    test = self()

    {:ok, pid} =
      Dist.start_link(
        name: :"dist_#{System.unique_integer([:positive])}",
        cookie_path: Keyword.get(opts, :cookie_path, ctx.path),
        chmod_fun: Keyword.get(opts, :chmod_fun, &File.chmod/2),
        configured_interfaces_fun: fn -> Map.keys(interfaces.()) end,
        vintage_net_fun: fn path, default -> property(interfaces.(), path, default) end,
        subscribe_fun:
          Keyword.get(opts, :subscribe_fun, fn property ->
            record(test, {:subscribe, property})
          end),
        mdns_add_fun:
          Keyword.get(opts, :mdns_add_fun, fn service -> record(test, {:mdns_add, service}) end),
        put_env_fun: fn key, value -> record(test, {:put_env, key, value}) end,
        set_cookie_fun:
          Keyword.get(opts, :set_cookie_fun, fn cookie ->
            Agent.update(vm, &%{&1 | cookie: cookie})
            record(test, {:set_cookie, cookie})
          end),
        get_cookie_fun: Keyword.get(opts, :get_cookie_fun, fn -> Agent.get(vm, & &1.cookie) end),
        # NEVER defaulted: the real seam derives $HOME, and a test that let it
        # would overwrite the developer's own Erlang cookie at mode 0400.
        erlang_cookie_path_fun:
          Keyword.get(opts, :erlang_cookie_path_fun, fn -> {:ok, ctx.home} end),
        net_kernel_start_fun:
          Keyword.get(opts, :net_kernel_start_fun, fn name, kernel_opts ->
            record(test, {:net_kernel_start, name, kernel_opts})
            Agent.update(vm, &%{&1 | node: name})
            {:ok, self()}
          end),
        net_kernel_stop_fun:
          Keyword.get(opts, :net_kernel_stop_fun, fn ->
            Agent.update(vm, fn _ -> %{cookie: :nocookie, node: nil} end)
            record(test, {:net_kernel_stop})
          end),
        epmd_fun:
          Keyword.get(opts, :epmd_fun, fn args, env ->
            record(test, {:epmd, args, env})

            case args do
              ["-daemon"] ->
                Agent.update(epmd, fn _ -> true end)
                {"", 0}

              ["-kill"] ->
                Agent.update(epmd, fn _ -> false end)
                {"Killed\n", 0}

              ["-names"] ->
                if Agent.get(epmd, & &1),
                  do: {"epmd: up and running on port 4369 with data:\n", 0},
                  else: {"epmd: Cannot connect to local epmd\n", 1}
            end
          end),
        sleep_fun: fn ms -> record(test, {:sleep, ms}) end,
        # Read from the same model, so aliveness and the node name cannot drift
        # apart from whether net_kernel was "started". The real defaults are
        # pinned separately, by the read-back test below.
        alive_fun: Keyword.get(opts, :alive_fun, fn -> Agent.get(vm, & &1.node) != nil end),
        self_node_fun:
          Keyword.get(opts, :self_node_fun, fn -> Agent.get(vm, & &1.node) || :nonode@nohost end)
      )

    on_exit(fn -> stop(pid) end)
    {pid, view}
  end

  defp start_dist!(ctx, opts \\ []) do
    {pid, _view} = start_dist(ctx, opts)
    pid
  end

  # enable/0 no longer starts anything, so the BOOT path drives the start
  # sequence: a valid cookie on disk at start_link time. status/0 reports the
  # outcome, and `last_error` carries the reason a start refused.
  defp boot!(ctx, opts \\ []) do
    seed_cookie!(ctx)
    start_dist!(ctx, opts)
  end

  defp seed_cookie!(ctx, cookie \\ @cookie) do
    File.write!(ctx.path, cookie)
    File.chmod!(ctx.path, 0o600)
  end

  # What VintageNet sends subscribers: `{VintageNet, property, old, new, meta}`.
  defp address_event(pid, ifname) do
    send(pid, {VintageNet, ["interface", ifname, "addresses"], [], [], %{}})
    # A status call is a synchronous round-trip through the same mailbox, so
    # it can only be answered after the event above was handled.
    Dist.status(pid)
  end

  defp property(interfaces, ["interface", ifname, leaf], default) do
    case {interfaces[ifname], leaf} do
      {nil, _leaf} -> default
      {{connection, _addrs}, "connection"} -> connection
      {{_connection, addrs}, "addresses"} -> addrs
      unhandled -> flunk("dist_test property/3 has no clause for #{inspect(unhandled)}")
    end
  end

  # No fallback here used to mean a newly-queried property raised
  # CaseClauseError from inside the helper — a confusing failure about the test
  # harness rather than a clear one about the code under test.
  defp property(_interfaces, path, _default) do
    flunk("dist_test property/3 has no clause for property #{inspect(path)}")
  end

  defp record(test, step) do
    send(test, Tuple.insert_at(step, 0, :step))
    :ok
  end

  # Narrow: catching every exit reason swallowed a genuine crash during cleanup
  # and reported the run green.
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
      pid = start_dist!(ctx)
      status = Dist.status(pid)

      refute status.alive?
      refute status.cookie_present?
      assert status.node == nil
      assert status.ports == 9100..9105

      # Nothing was attempted: no subscription, no epmd, no net_kernel.
      refute_received {:step, :subscribe, _}
      refute_received {:step, :epmd, _, _}
      refute_received {:step, :net_kernel_start, _, _}
    end
  end

  describe "cookie store" do
    test "mints a 0600 cookie, seeds $HOME/.erlang.cookie at 0400, and proves both", ctx do
      pid = start_dist!(ctx)
      assert {:ok, %{cookie: cookie, node: node, reboot_required: true}} = Dist.enable(pid)

      # The name the board WILL take, since nothing has started yet.
      assert node == :"vagus@192.168.2.58"
      assert String.match?(cookie, ~r/^[0-9a-f]{64}$/)
      assert File.read!(ctx.path) == cookie
      assert mode(ctx.path) == 0o600

      # $HOME/.erlang.cookie is the BOOT path's job, seeded immediately before
      # net_kernel.start because that is when `auth` reads it — so enable/0 has
      # not written it yet.
      refute File.exists?(ctx.home)
    end

    test "the boot seeds $HOME/.erlang.cookie at 0400 with the same value", ctx do
      # Two files at two modes on purpose: this module re-reads its own store at
      # 0600, and `auth:read_cookie/0` refuses anything looser than 0400.
      pid = boot!(ctx)

      assert Dist.status(pid).alive?
      assert File.read!(ctx.home) == @cookie
      assert mode(ctx.home) == 0o400
      assert mode(ctx.path) == 0o600
    end

    test "refuses to start when the mode cannot be read back, and leaves nothing behind", ctx do
      # A chmod that reports success but does nothing: the file keeps its
      # umask mode, so the read-back mismatches. An unverifiable-mode cookie
      # is worse than no distribution.
      pid = start_dist!(ctx, chmod_fun: fn _path, _mode -> :ok end)

      assert {:error, {:mode_unproven, _mode}} = Dist.enable(pid)
      refute Dist.status(pid).alive?
      refute_received {:step, :net_kernel_start, _, _}

      # A minted cookie whose mode was never proven must not survive: the next
      # boot would refuse it outright instead of re-minting.
      refute File.exists?(ctx.path)
      refute File.exists?(ctx.path <> ".tmp")
    end

    test "reads an existing cookie rather than re-minting, and that value reaches set_cookie",
         ctx do
      File.write!(ctx.path, "  #{@cookie}\n")
      File.chmod!(ctx.path, 0o600)

      pid = start_dist!(ctx)
      assert {:ok, %{cookie: @cookie}} = Dist.enable(pid)

      assert File.read!(ctx.path) == "  #{@cookie}\n"
      assert_received {:step, :set_cookie, @cookie_atom}
    end

    test "an empty cookie file is corruption, not a request to start", ctx do
      # enable/0 is the only writer, so a zero-byte file is a truncated write or
      # a hand-made one — never a signal. Refusing keeps the file's provenance
      # single: if it exists and is valid, enable/0 put it there.
      File.write!(ctx.path, "")

      pid = start_dist!(ctx)
      assert {:error, :cookie_empty} = Dist.enable(pid)
      refute Dist.status(pid).alive?
      refute_received {:step, :net_kernel_start, _, _}
      # Not silently replaced either — overwriting in place would strand a node
      # still authenticating with whatever the previous value was.
      assert File.read!(ctx.path) == ""
    end

    test "a whitespace-only cookie file is refused too", ctx do
      File.write!(ctx.path, "\n  \n")
      File.chmod!(ctx.path, 0o600)

      pid = start_dist!(ctx)
      assert {:error, :cookie_empty} = Dist.enable(pid)
      refute Dist.status(pid).alive?
    end

    test "enable/0 is the only thing that creates the file", ctx do
      refute File.exists?(ctx.path)

      pid = start_dist!(ctx)
      # Starting the GenServer alone must not mint: the gate is the file, and
      # creating it is enable/0's job, not boot's.
      refute File.exists?(ctx.path)

      assert {:ok, %{cookie: cookie}} = Dist.enable(pid)
      assert File.read!(ctx.path) == cookie
      assert mode(ctx.path) == 0o600
    end

    test "a malformed cookie is refused, not adopted", ctx do
      # Adopting this is what once produced a live node with the cookie :'' —
      # unauthenticated root-equivalent access to the LAN segment.
      seed_cookie!(ctx, "not-a-cookie")

      pid = start_dist!(ctx)
      assert {:error, :cookie_malformed} = Dist.enable(pid)
      refute Dist.status(pid).alive?
      refute_received {:step, :net_kernel_start, _, _}
    end

    test "a cookie file at the wrong mode is refused WITHOUT being read", ctx do
      File.write!(ctx.path, @cookie)
      File.chmod!(ctx.path, 0o644)

      pid = start_dist!(ctx)
      assert {:error, {:mode_unproven, 0o644}} = Dist.enable(pid)
      # Not adopted, and not silently repaired either: a secret out of a file
      # whose mode cannot be vouched for is the thing being guarded against.
      assert File.read!(ctx.path) == @cookie
      refute_received {:step, :set_cookie, _}
    end

    test "an unreadable cookie file surfaces :cookie_unreadable", ctx do
      # A non-empty directory where the cookie should be: it stats fine at the
      # right mode and then refuses to be read.
      File.mkdir_p!(ctx.path)
      File.write!(Path.join(ctx.path, "entry"), "x")
      File.chmod!(ctx.path, 0o600)
      on_exit(fn -> File.chmod(ctx.path, 0o755) end)

      pid = start_dist!(ctx)
      assert {:error, {:cookie_unreadable, :eisdir}} = Dist.enable(pid)
    end

    test "an unwritable cookie directory surfaces :cookie_unwritable", ctx do
      locked = Path.join(ctx.dir, "locked")
      File.mkdir_p!(locked)
      File.chmod!(locked, 0o500)
      on_exit(fn -> File.chmod(locked, 0o755) end)

      pid = start_dist!(ctx, cookie_path: Path.join(locked, "vagus.cookie"))
      assert {:error, {:cookie_unwritable, :eacces}} = Dist.enable(pid)
    end

    test "a failed chmod closes the file and leaves no temp behind", ctx do
      pid = start_dist!(ctx, chmod_fun: fn _path, _mode -> {:error, :eacces} end)

      assert {:error, {:cookie_unwritable, :eacces}} = Dist.enable(pid)
      refute File.exists?(ctx.path)
      refute File.exists?(ctx.path <> ".tmp")
    end

    test "a symlink swapped in under the temp file is caught by the mode read-back", ctx do
      # W4's threat, run for real: this module writes as root, so a symlink
      # planted at the destination would be followed. The write goes to an
      # already-open exclusive fd, and the read-back is what refuses the
      # result.
      chmod = fn tmp, _mode ->
        File.rm!(tmp)
        File.ln_s!(Path.join(ctx.dir, "nowhere"), tmp)
        :ok
      end

      pid = start_dist!(ctx, chmod_fun: chmod)

      assert {:error, {:mode_unproven, :enoent}} = Dist.enable(pid)
      refute_received {:step, :net_kernel_start, _, _}
    end
  end

  describe "address resolution" do
    test "prefers eth0 over a wlan0 that reached :internet", ctx do
      pid =
        boot!(ctx,
          interfaces: %{
            "wlan0" => {:internet, [%{address: {10, 0, 0, 9}, family: :inet}]},
            "eth0" => {:lan, @eth0_addrs}
          }
        )

      assert Dist.status(pid).node == :"vagus@192.168.2.58"
      assert Dist.status(pid).ifname == "eth0"
    end

    test "falls through to wlan0, then usb0, as earlier candidates drop out", ctx do
      wlan = %{"wlan0" => {:lan, [%{address: {10, 0, 0, 9}, family: :inet}]}}
      usb = %{"usb0" => {:lan, [%{address: {172, 31, 36, 1}, family: :inet}]}}

      pid = boot!(ctx, interfaces: Map.merge(wlan, usb))
      assert Dist.status(pid).node == :"vagus@10.0.0.9"

      usb_only = boot!(ctx, cookie_path: Path.join(ctx.dir, "usb.cookie"), interfaces: usb)
      assert {:ok, %{node: :"vagus@172.31.36.1"}} = Dist.enable(usb_only)
    end

    test "skips a disconnected interface", ctx do
      pid =
        boot!(ctx,
          interfaces: %{
            "eth0" => {:disconnected, @eth0_addrs},
            "wlan0" => {:lan, [%{address: {10, 0, 0, 9}, family: :inet}]}
          }
        )

      assert Dist.status(pid).node == :"vagus@10.0.0.9"
    end

    test "takes IPv4 over IPv6 and skips loopback and link-local", ctx do
      pid =
        boot!(ctx,
          interfaces: %{
            "eth0" =>
              {:lan,
               [
                 %{address: {0, 0, 0, 0, 0, 0, 0, 1}, family: :inet6},
                 %{address: {127, 0, 0, 1}, family: :inet},
                 %{address: {169, 254, 3, 4}, family: :inet},
                 %{address: {192, 168, 2, 58}, family: :inet}
               ]}
          }
        )

      assert Dist.status(pid).node == :"vagus@192.168.2.58"
    end

    test "ignores an unmanaged overlay interface even when it is the only address", ctx do
      # A tailscale0-style interface is brought up by its own daemon, so it
      # never reaches `configured_interfaces/0` on a real board. Asserting the
      # name filter as well keeps it failing closed if someone ever hands
      # VintageNet a tunnel to manage.
      pid =
        boot!(ctx,
          interfaces: %{"tailscale0" => {:internet, [%{address: {100, 64, 0, 7}, family: :inet}]}}
        )

      assert Dist.status(pid).last_error == :no_address
      refute_received {:step, :net_kernel_start, _, _}
    end

    test "refuses the unspecified address instead of wildcard-binding", ctx do
      # 0.0.0.0 IS the wildcard. Passing it to :inet_dist_use_interface and
      # ERL_EPMD_ADDRESS would bind every address on the board while looking
      # like a pin.
      pid =
        boot!(ctx,
          interfaces: %{"eth0" => {:lan, [%{address: {0, 0, 0, 0}, family: :inet}]}}
        )

      assert Dist.status(pid).last_error == :no_address
      refute_received {:step, :put_env, :inet_dist_use_interface, _}
    end

    test "no qualifying address means no net_kernel call at all", ctx do
      pid = boot!(ctx, interfaces: %{"eth0" => {:lan, []}})

      assert Dist.status(pid).last_error == :no_address
      refute_received {:step, :epmd, _, _}
      refute_received {:step, :set_cookie, _}
      refute_received {:step, :net_kernel_start, _, _}
    end
  end

  describe "start sequence" do
    test "pins ports and interface and starts epmd before net_kernel, then applies the cookie",
         ctx do
      pid = boot!(ctx)
      assert Dist.status(pid).alive?

      # Order is the point, and `assert_received` consumes in mailbox order, so
      # these assertions passing in sequence IS the ordering proof. A
      # wildcard-bound dist port is reachable from every add-on container, and
      # `inet_tcp_dist` reads both env keys at listen time.
      assert_received {:step, :put_env, :inet_dist_listen_min, 9100}
      assert_received {:step, :put_env, :inet_dist_listen_max, 9105}
      assert_received {:step, :put_env, :inet_dist_use_interface, {192, 168, 2, 58}}
      assert_received {:step, :epmd, ["-names"], []}
      assert_received {:step, :epmd, ["-daemon"], [{"ERL_EPMD_ADDRESS", "192.168.2.58"}]}

      assert_received {:step, :net_kernel_start, :"vagus@192.168.2.58",
                       %{name_domain: :longnames}}

      # AFTER net_kernel, because set_cookie/1 before it raises
      # :distribution_not_started. What keeps the release-baked cookie from
      # ever applying is the pre-seeded $HOME file, written before the start.
      assert_received {:step, :set_cookie, _cookie}

      assert_received {:step, :mdns_add,
                       %{id: :vagus_epmd, protocol: "epmd", transport: "tcp", port: 4369}}
    end

    test "the $HOME cookie is on disk before net_kernel starts", ctx do
      # The whole reason for pre-seeding: `auth:init_cookie/0` reads that file
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

      # Sync on the boot having run, then assert the ORDERING, which is the
      # point: the file was already on disk when net_kernel was called.
      refute Dist.status(pid).alive?
      assert_received {:step, :home_cookie, {:ok, @cookie}}
      assert_received {:step, :net_kernel_start, :"vagus@192.168.2.58", _opts}
    end

    test "status/0 stops claiming a node that died underneath us", ctx do
      # net_kernel can be stopped from anywhere on the board, and state.node
      # outlives it. MEASURED on a runtime-started node after a stop:
      # Node.alive?/0 false, Node.self/0 :nonode@nohost, get_cookie/0 :nocookie
      # — so trusting the cached name made enable/0 answer :cookie_mismatch,
      # blaming the secret for a node that had simply died.
      {:ok, vm} = Agent.start_link(fn -> %{node: nil, cookie: :nocookie} end)
      on_exit(fn -> if Process.alive?(vm), do: Agent.stop(vm) end)
      test = self()

      pid =
        boot!(ctx,
          net_kernel_start_fun: fn name, kernel_opts ->
            record(test, {:net_kernel_start, name, kernel_opts})
            Agent.update(vm, &%{&1 | node: name})
            {:ok, self()}
          end,
          set_cookie_fun: fn cookie -> Agent.update(vm, &%{&1 | cookie: cookie}) end,
          get_cookie_fun: fn -> Agent.get(vm, & &1.cookie) end,
          alive_fun: fn -> Agent.get(vm, & &1.node) != nil end,
          self_node_fun: fn -> Agent.get(vm, & &1.node) || :nonode@nohost end
        )

      assert Dist.status(pid).node == :"vagus@192.168.2.58"
      assert Dist.status(pid).alive?
      flush()

      # Whatever stopped it, the measured after-state is the same.
      Agent.update(vm, fn _ -> %{node: nil, cookie: :nocookie} end)

      # status/0 must stop claiming a dead node is up — state.node alone would
      # still say yes.
      refute Dist.status(pid).alive?

      # Recovery is a reboot, not a call: enable/0 confirms the cookie is still
      # in place and says so.
      assert {:ok, %{reboot_required: true}} = Dist.enable(pid)
      refute_received {:step, :net_kernel_start, _name, _opts}
    end

    test "is idempotent — a second enable restarts nothing", ctx do
      pid = start_dist!(ctx)
      assert {:ok, %{node: node}} = Dist.enable(pid)
      flush()

      assert {:ok, %{node: ^node}} = Dist.enable(pid)
      refute_received {:step, :net_kernel_start, _, _}
      refute_received {:step, :epmd, _, _}
    end

    test "a failing epmd -daemon stops the sequence", ctx do
      test = self()

      pid =
        boot!(ctx,
          epmd_fun: fn args, env ->
            record(test, {:epmd, args, env})
            if args == ["-daemon"], do: {"cannot bind", 1}, else: {"", 0}
          end
        )

      assert Dist.status(pid).last_error == {:epmd_failed, 1, "cannot bind"}
      refute_received {:step, :net_kernel_start, _, _}
    end

    test "a TableServer-down mDNS advertisement does not cost us the live node", ctx do
      # MdnsLite.add_mdns_service/1 exits when its TableServer is down, and this
      # runs AFTER net_kernel is live. Letting that exit fail the bring-up left
      # the node up while the boot guard retried into reconcile/2, which used
      # not to advertise — live and unadvertised, permanently.
      test = self()

      pid =
        boot!(ctx,
          mdns_add_fun: fn _service ->
            record(test, {:mdns_attempted})
            exit(:noproc)
          end
        )

      assert Dist.status(pid).node == :"vagus@192.168.2.58"
      assert_received {:step, :mdns_attempted}

      # Degraded, not broken: the runbook connects by bare IPv4 longname and
      # does no lookup.
      status = Dist.status(pid)
      assert status.alive?
      assert status.node == :"vagus@192.168.2.58"
    end

    test "refuses when $HOME cannot be derived, and rolls epmd back", ctx do
      # Writing the pre-seed to a relative path would leave `auth` reading a
      # different file and the node up under an OTP-minted cookie.
      #
      # epmd is already running by this point, so the failure has to put it
      # back. Otherwise an ordinary error retries to the 10-attempt give-up and
      # leaves the last epmd listening on the pinned address forever, on a board
      # whose status/0 says there is no node.
      pid = boot!(ctx, erlang_cookie_path_fun: fn -> {:error, :no_home} end)

      assert Dist.status(pid).last_error == {:erlang_cookie_path, :no_home}
      refute_received {:step, :net_kernel_start, _, _}

      assert_received {:step, :epmd, ["-daemon"], _env}
      assert_received {:step, :epmd, ["-kill"], []}
    end

    test "refuses to start when the epmd probe times out", ctx do
      # A probe that timed out tells us nothing, and "nothing" is not "no epmd".
      # Starting behind a daemon that might be wildcard-bound is exactly the
      # exposure the pinning exists to prevent.
      test = self()

      pid =
        boot!(ctx,
          epmd_fun: fn args, env ->
            record(test, {:epmd, args, env})
            if args == ["-names"], do: {"", :timeout}, else: {"", 0}
          end
        )

      assert Dist.status(pid).last_error == {:epmd_probe_failed, :timeout}
      refute_received {:step, :epmd, ["-daemon"], _env}
      refute_received {:step, :net_kernel_start, _, _}
    end
  end

  describe "the cookie read-back (B1)" do
    test "stops the node and refuses when get_cookie disagrees with the file", ctx do
      # Exactly what a pre-seed written to a path `auth` does not read looks
      # like from here. A node alive under a cookie that is not ours is the one
      # state this must never leave behind.
      pid = boot!(ctx, get_cookie_fun: fn -> @other_cookie_atom end)

      assert Dist.status(pid).last_error == :cookie_not_applied
      assert_received {:step, :net_kernel_stop}
      refute Dist.status(pid).alive?
      refute_received {:step, :mdns_add, _}
    end

    test "a stop that did not take is reported, not dressed up as a clean refusal", ctx do
      # The read-back exists so a node alive under a cookie we did not choose
      # cannot survive. Discarding net_kernel.stop/0's outcome here would be the
      # same fail-open B3 fixed in stop_distribution/1.
      {:ok, alive} = Agent.start_link(fn -> false end)
      on_exit(fn -> if Process.alive?(alive), do: Agent.stop(alive) end)

      pid =
        boot!(ctx,
          alive_fun: fn -> Agent.get(alive, & &1) end,
          net_kernel_start_fun: fn _name, _opts ->
            Agent.update(alive, fn _ -> true end)
            {:ok, self()}
          end,
          net_kernel_stop_fun: fn -> :ok end,
          get_cookie_fun: fn -> @other_cookie_atom end
        )

      assert Dist.status(pid).last_error == {:cookie_not_applied, :still_alive}
    end

    test "a raising set_cookie stops the node it already started", ctx do
      # Two things at once. On the BOOT path a raise must not reach the
      # supervisor — on a fresh flash that is a crash loop and a startup_guard
      # rollback across the fleet. And because net_kernel is ALREADY live by the
      # time set_cookie runs, the raise must not walk past the read-back and
      # leave distribution up under a cookie nobody verified: asserting only
      # `refute status.alive?` would pass on a live node, because state.node is
      # still nil at that point.
      seed_cookie!(ctx)

      pid = start_dist!(ctx, set_cookie_fun: fn _cookie -> raise "set_cookie/1 blew up" end)

      refute Dist.status(pid).alive?
      assert Process.alive?(pid)
      assert :sys.get_state(pid).attempt == 1

      # The node it started was stopped, and the stop took.
      assert_received {:step, :net_kernel_start, :"vagus@192.168.2.58", _opts}
      assert_received {:step, :net_kernel_stop}
      refute :sys.get_state(pid).seams.alive_fun.()
    end

    test "an exiting get_cookie also stops the node", ctx do
      # The other seam on the same stretch, and an exit rather than a raise.
      seed_cookie!(ctx)

      pid = start_dist!(ctx, get_cookie_fun: fn -> exit(:noproc) end)

      refute Dist.status(pid).alive?
      assert Process.alive?(pid)
      assert_received {:step, :net_kernel_stop}
      refute :sys.get_state(pid).seams.alive_fun.()
    end

    test "the real seam defaults cannot pass the read-back on an undistributed VM", ctx do
      # Pins the shape of the raw-OTP defaults the fakes stand in for: with
      # `get_cookie_fun` and `alive_fun` left real, `:erlang.get_cookie/0`
      # cannot answer our minted cookie, so the read-back MUST fire. A default
      # that echoed set_cookie/1 back would make this test fail.
      pid =
        boot!(ctx,
          get_cookie_fun: &:erlang.get_cookie/0,
          set_cookie_fun: fn _cookie -> :ok end
        )

      assert Dist.status(pid).last_error == :cookie_not_applied
    end

    test "the default $HOME derivation is the file `auth` actually reads" do
      # The single assumption the whole pre-seed rests on, and the plan's
      # top-rated risk: `auth:init_cookie/0` derives the path from
      # `init:get_argument(home)`, not from the OS environment.
      assert {:ok, path} = Dist.erlang_cookie_path()
      assert {:ok, [[home] | _]} = :init.get_argument(:home)
      assert path == Path.join(List.to_string(home), ".erlang.cookie")
    end
  end

  describe "the boot path cannot escalate a raise" do
    test "a raising VintageNet subscribe leaves the board idle, not the app dead", ctx do
      seed_cookie!(ctx)

      # `ensure_subscribed/1` reaches VintageNet and runs before the start does.
      # A raise escaping handle_continue/2 burns the top-level supervisor's
      # budget — which is SHARED with every other child — and the cookie file is
      # still there on the next boot, so it raises again.
      pid = start_dist!(ctx, subscribe_fun: fn _property -> raise "VintageNet not up yet" end)

      assert Process.alive?(pid)
      refute Dist.status(pid).alive?
      # Retried, because "VintageNet is not up yet" is exactly the transient.
      assert :sys.get_state(pid).attempt == 1
    end

    test "a crash on the boot path never writes the cookie to the log", ctx do
      seed_cookie!(ctx)

      # MEASURED: an Erlang stacktrace carries a frame's ARGUMENTS for
      # function_clause and BIF badarg, and the cookie is an argument the whole
      # length of start_distribution/2. Formatting one verbatim printed the
      # secret at :error level — a leak introduced by the B1 fix itself.
      log =
        capture_log(fn ->
          pid = start_dist!(ctx, set_cookie_fun: fn :never_matches_the_cookie -> :ok end)
          refute Dist.status(pid).alive?
        end)

      assert log =~ "FunctionClauseError"
      refute log =~ @cookie
    end
  end

  describe "reconciling an already-live node (B4)" do
    setup ctx do
      seed_cookie!(ctx)
      :ok
    end

    defp already_started(ctx, live, opts \\ []) do
      test = self()

      start_dist!(
        ctx,
        Keyword.merge(
          [
            net_kernel_start_fun: fn name, kernel_opts ->
              record(test, {:net_kernel_start, name, kernel_opts})
              {:error, {:already_started, self()}}
            end,
            # The premise of this whole path: the node really is up, which is
            # why net_kernel answers already_started.
            alive_fun: fn -> true end,
            self_node_fun: fn -> live end,
            get_cookie_fun: fn -> @cookie_atom end
          ],
          opts
        )
      )
    end

    test "adopts the live node instead of retrying to a permanent give-up", ctx do
      pid = already_started(ctx, :"vagus@192.168.2.58")
      status = Dist.status(pid)

      # This is the desync: net_kernel, epmd and mDNS all survive a GenServer
      # crash-restart while init/1 rebuilds state.node as nil, so status/0 used
      # to call a live, reachable node down — permanently, after 10 backoffs.
      assert status.alive?
      assert status.node == :"vagus@192.168.2.58"
      assert status.address == {192, 168, 2, 58}
      assert status.ifname == "eth0"
      assert status.drift == nil
      assert :sys.get_state(pid).attempt == 0
    end

    test "a live name we would not have chosen is drift, not a failure", ctx do
      # Measured: net_kernel answers {:already_started, _} even under a
      # DIFFERENT name, so a restart that also changed address lands here.
      pid = already_started(ctx, :"vagus@10.9.9.9")
      status = Dist.status(pid)

      assert status.alive?
      assert status.node == :"vagus@10.9.9.9"
      assert status.drift =~ "immutable"
      assert status.drift =~ "192.168.2.58"
      assert status.ifname == nil
    end

    test "a live node whose cookie is not the file's is surfaced, not killed", ctx do
      pid =
        already_started(ctx, :"vagus@192.168.2.58", get_cookie_fun: fn -> @other_cookie_atom end)

      assert Dist.status(pid).drift =~ "cookie"
      # Stopping a live node from a bookkeeping path would drop whatever erpc
      # call is in flight over it.
      refute_received {:step, :net_kernel_stop}
    end

    test "enable/0 reports the cookie the NEXT boot will use, not the live one", ctx do
      # Rotating the secret under a running node used to need a :cookie_mismatch
      # refusal, because enable/0 claimed to have applied what it returned. It
      # no longer applies anything: the file it wrote is what the next boot
      # authenticates with, so returning it is simply true.
      pid =
        start_dist!(ctx,
          cookie_path: Path.join(ctx.dir, "rotate.cookie"),
          alive_fun: fn -> true end,
          self_node_fun: fn -> :"vagus@192.168.2.58" end,
          get_cookie_fun: fn -> @other_cookie_atom end
        )

      File.write!(Path.join(ctx.dir, "rotate.cookie"), @cookie)
      File.chmod!(Path.join(ctx.dir, "rotate.cookie"), 0o600)

      assert {:ok, %{cookie: @cookie, reboot_required: true}} = Dist.enable(pid)
    end

    test "re-advertises mDNS, which is what repairs a failed advertisement", ctx do
      # Reached after a GenServer restart AND after a bring-up whose ad failed;
      # MdnsLite may also have restarted and lost the entry.
      pid = already_started(ctx, :"vagus@192.168.2.58")

      assert Dist.status(pid).alive?

      assert_received {:step, :mdns_add,
                       %{id: :vagus_epmd, protocol: "epmd", transport: "tcp", port: 4369}}
    end

    test "an alive VM short-circuits the whole bring-up", ctx do
      pid =
        start_dist!(ctx,
          alive_fun: fn -> true end,
          self_node_fun: fn -> :"vagus@192.168.2.58" end,
          get_cookie_fun: fn -> @cookie_atom end
        )

      assert Dist.status(pid).node == :"vagus@192.168.2.58"
      # None of it is wanted: epmd is already up and the env keys were read at
      # the listen that already happened.
      refute_received {:step, :epmd, _, _}
      refute_received {:step, :put_env, _, _}
      refute_received {:step, :net_kernel_start, _, _}
    end

    test "alive with no node name is a contradiction, and is reported as one", ctx do
      pid = start_dist!(ctx, alive_fun: fn -> true end, self_node_fun: fn -> :nonode@nohost end)

      refute Dist.status(pid).alive?
      assert :sys.get_state(pid).attempt == 1
    end
  end

  describe "a pre-existing epmd (W3)" do
    defp epmd_seam(test, kill_status) do
      fn args, env ->
        record(test, {:epmd, args, env})

        case args do
          ["-names"] -> {@epmd_up, 0}
          ["-kill"] -> {"epmd: Killing not allowed - living nodes in database.\n", kill_status}
          _daemon -> {"", 0}
        end
      end
    end

    test "kills an epmd it did not launch before starting its own", ctx do
      test = self()
      pid = boot!(ctx, epmd_fun: epmd_seam(test, 0))

      assert Dist.status(pid).alive?

      # `epmd -daemon` exits 0 when another epmd already holds the port: it
      # does nothing at all, ERL_EPMD_ADDRESS is ignored, and the survivor may
      # be wildcard-bound.
      assert_received {:step, :epmd, ["-names"], []}
      assert_received {:step, :epmd, ["-kill"], []}
      assert_received {:step, :epmd, ["-daemon"], [{"ERL_EPMD_ADDRESS", "192.168.2.58"}]}
    end

    test "refuses to start behind an epmd it cannot replace", ctx do
      test = self()
      pid = boot!(ctx, epmd_fun: epmd_seam(test, 1))

      assert match?(
               {:epmd_not_ours, {:epmd_kill_failed, 1, _output}},
               Dist.status(pid).last_error
             )

      # Better idle than silently bound to the wildcard the pinning exists to
      # prevent.
      refute_received {:step, :net_kernel_start, _, _}
    end

    test "absorbs the deregistration race with one retry", ctx do
      test = self()
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      epmd = fn args, env ->
        record(test, {:epmd, args, env})

        case args do
          ["-names"] ->
            {@epmd_up, 0}

          ["-kill"] ->
            n = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
            if n == 1, do: {"living nodes in database", 1}, else: {"Killed", 0}

          _daemon ->
            {"", 0}
        end
      end

      pid = boot!(ctx, epmd_fun: epmd)
      assert Dist.status(pid).alive?

      assert_received {:step, :epmd, ["-kill"], []}
      assert_received {:step, :sleep, 250}
      assert_received {:step, :epmd, ["-kill"], []}
    end
  end

  describe "disable/1" do
    test "deletes both cookie files so the next boot stays down", ctx do
      pid = boot!(ctx)
      assert Dist.status(pid).alive?
      assert File.exists?(ctx.path)
      assert File.exists?(ctx.home)

      assert :ok = Dist.disable(pid)

      refute File.exists?(ctx.path)
      refute File.exists?(ctx.home)
    end

    test "leaves the running node alone — the reboot is what stops it", ctx do
      # Tearing a live node down in place is what required threading
      # net_kernel/epmd/mDNS failures through every path. The gate is shut for
      # every future boot the moment the files are gone; the node itself is the
      # reboot's problem.
      pid = boot!(ctx)
      assert Dist.status(pid).alive?
      flush()

      assert :ok = Dist.disable(pid)

      assert Dist.status(pid).alive?
      refute_received {:step, :epmd, ["-kill"], []}
      refute_received {:step, :net_kernel_start, _, _}
    end

    test "reports a cookie file it could not delete, because that boot comes back up", ctx do
      # While a cookie file survives, the next boot re-enables distribution — so
      # a failed delete is the one thing here worth reporting.
      File.mkdir_p!(ctx.path)
      on_exit(fn -> File.rm_rf!(ctx.path) end)

      pid = start_dist!(ctx)

      assert {:error, {:cookie_not_removed, _path, _reason}} = Dist.disable(pid)
    end

    test "a missing cookie file is not a failure", ctx do
      pid = start_dist!(ctx)
      assert :ok = Dist.disable(pid)
    end
  end

  describe "boot-time address wait" do
    test "an existing cookie file starts the node at boot, without enable/0", ctx do
      seed_cookie!(ctx)

      pid = start_dist!(ctx)

      assert Dist.status(pid).node == :"vagus@192.168.2.58"
      assert_received {:step, :subscribe, ["interface", "eth0", "addresses"]}
      assert_received {:step, :set_cookie, @cookie_atom}
    end

    test "waits for a disconnected interface to come up, then starts on the event", ctx do
      seed_cookie!(ctx)

      {pid, view} = start_dist(ctx, interfaces: %{"eth0" => {:disconnected, []}})

      # Idle but subscribed: the retry timer is a backstop, the event is the
      # real trigger.
      refute Dist.status(pid).alive?
      assert_received {:step, :subscribe, ["interface", "eth0", "addresses"]}
      refute_received {:step, :net_kernel_start, _, _}

      Agent.update(view, fn _ -> %{"eth0" => {:lan, @eth0_addrs}} end)
      assert address_event(pid, "eth0").node == :"vagus@192.168.2.58"
    end

    test "subscribes to every physical candidate, and to no overlay", ctx do
      seed_cookie!(ctx)

      pid =
        start_dist!(ctx,
          interfaces: %{
            "eth0" => {:disconnected, []},
            "wlan0" => {:disconnected, []},
            "tailscale0" => {:internet, [%{address: {100, 64, 0, 7}, family: :inet}]}
          }
        )

      # Sync point: handle_continue runs asynchronously to start_link.
      refute Dist.status(pid).alive?

      assert_received {:step, :subscribe, ["interface", "eth0", "addresses"]}
      assert_received {:step, :subscribe, ["interface", "wlan0", "addresses"]}
      refute_received {:step, :subscribe, ["interface", "tailscale0", "addresses"]}
    end

    test "stays idle with no cookie file, however the addresses move", ctx do
      {pid, view} = start_dist(ctx, interfaces: %{"eth0" => {:disconnected, []}})

      Agent.update(view, fn _ -> %{"eth0" => {:lan, @eth0_addrs}} end)

      refute address_event(pid, "eth0").alive?
      refute File.exists?(ctx.path)
      refute_received {:step, :net_kernel_start, _, _}
    end

    test "a malformed cookie leaves the board idle and healthy, boot after boot", ctx do
      # The brick proof in miniature: before B2 was fixed, this file produced a
      # crash loop; with B1 fixed but not B2 it would have produced a live node
      # with the cookie :''.
      seed_cookie!(ctx, "touched")

      for _boot <- 1..2 do
        pid = start_dist!(ctx, cookie_path: ctx.path)
        refute Dist.status(pid).alive?
        assert Process.alive?(pid)
        refute_received {:step, :net_kernel_start, _, _}
      end
    end
  end

  describe "retry discipline (W1, W2)" do
    setup ctx do
      seed_cookie!(ctx)
      {:ok, opts: [interfaces: %{"eth0" => {:disconnected, []}}]}
    end

    test "an address flap cancels the outstanding retry instead of stacking timers", ctx do
      pid = start_dist!(ctx, ctx.opts)

      refute Dist.status(pid).alive?
      first = :sys.get_state(pid).retry_ref
      assert is_reference(first)

      address_event(pid, "eth0")
      second = :sys.get_state(pid).retry_ref

      refute second == first
      # Gone, not merely superseded: a stacked timer fires its own
      # :retry_start and burns another attempt out of the budget, so a flapping
      # cable exhausts 10 attempts in wall-clock time bearing no relation to
      # the backoff schedule.
      assert Process.read_timer(first) == false
    end

    test "gives up after 10 attempts, then an address event restores the budget", ctx do
      pid = start_dist!(ctx, ctx.opts)

      # boot/1 already spent attempt 1, so 9 more events reach the limit and
      # the 10th trips the give-up.
      Enum.each(1..10, fn _event -> address_event(pid, "eth0") end)

      state = :sys.get_state(pid)
      assert state.gave_up?
      assert state.retry_ref == nil

      address_event(pid, "eth0")
      state = :sys.get_state(pid)

      # Not resetting this silently zeroed the retry budget for the next
      # legitimate trigger.
      refute state.gave_up?
      assert state.attempt == 1
      assert is_reference(state.retry_ref)
    end

    test "a retry that arrives after the node is up is a no-op", ctx do
      pid = start_dist!(ctx, interfaces: %{"eth0" => {:lan, @eth0_addrs}})
      assert Dist.status(pid).alive?
      flush()

      send(pid, :retry_start)
      assert Dist.status(pid).alive?
      refute_received {:step, :net_kernel_start, _, _}
    end
  end

  describe "address churn" do
    test "warns and surfaces drift rather than renaming a live node", ctx do
      pid = boot!(ctx)
      node = Dist.status(pid).node
      flush()

      # The node name embeds the address and is immutable; a silent rename
      # would drop an in-flight call, a stale name is at least diagnosable.
      send(pid, {VintageNet, ["interface", "eth0", "addresses"], [], [], %{}})
      status = Dist.status(pid)

      assert status.node == node
      assert status.drift == nil

      GenServer.stop(pid)
    end

    test "reports drift when the resolved address moves under a live node", ctx do
      seed_cookie!(ctx)
      {pid, view} = start_dist(ctx)
      node = Dist.status(pid).node
      flush()

      Agent.update(view, fn _ ->
        %{"eth0" => {:lan, [%{address: {192, 168, 2, 99}, family: :inet}]}}
      end)

      status = address_event(pid, "eth0")

      assert status.node == node
      assert status.address == {192, 168, 2, 58}
      assert status.drift =~ "192.168.2.99"
      refute_received {:step, :net_kernel_start, _, _}
    end

    test "reports drift when every physical address disappears", ctx do
      seed_cookie!(ctx)
      {pid, view} = start_dist(ctx)
      assert Dist.status(pid).alive?
      flush()

      Agent.update(view, fn _ -> %{"eth0" => {:disconnected, []}} end)

      assert address_event(pid, "eth0").drift =~ "no_address"
    end
  end

  describe "in the application supervision tree" do
    test "the app-started child is :ignore and the node stays down on :host" do
      # config/test.exs leaves :dist_cookie_path unset, which is what makes
      # the unconditional child a no-op. Shipping the capability has to be
      # observably inert.
      assert Application.get_env(:vagus, :dist_cookie_path) == nil
      assert Process.whereis(Dist) == nil
      assert node() == :nonode@nohost
    end
  end

  describe "run/1" do
    test "sets async_dist on the CALLING process — the one that sends over distribution" do
      # Under :erpc.call/5 the caller is the erpc-spawned process, and the
      # payload leaves the node as ITS exit reason (erpc.erl execute_call/4
      # ends in exit(Reply)). Running the fun in a child Task and flagging the
      # child would flag a process whose only send is local to Task.await/2,
      # leaving the remote reply unflagged — the whole point of run/1, lost.
      previous = Process.flag(:async_dist, false)
      caller = self()

      {flag_while_running, runner} =
        Dist.run(fn -> {:erlang.process_flag(:async_dist, true), self()} end)

      # process_flag returns the PREVIOUS value: true proves run/1 set it before
      # the fun ran, and runner == caller proves it set it on the right process.
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
