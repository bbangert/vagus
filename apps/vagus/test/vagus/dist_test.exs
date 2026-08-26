defmodule Vagus.DistTest do
  use ExUnit.Case, async: true

  alias Vagus.Dist

  @cookie_re ~r/\A[0-9a-f]{64}\z/

  setup do
    # Models the VM's distribution state. Every override reads or writes THIS
    # rather than the real node, so the suite can prove bring-up ordering and
    # the cookie read-back without ever starting distribution.
    {:ok, vm} =
      Agent.start_link(fn ->
        %{node: nil, cookie: :nocookie, steps: [], session: :not_requested}
      end)

    {:ok, vm: vm}
  end

  defp record(vm, step), do: Agent.update(vm, &%{&1 | steps: &1.steps ++ [step]})
  defp steps(vm), do: Agent.get(vm, & &1.steps)

  # Fakes that CAN fail: every call takes an override so a test can make one
  # of them return an error without loosening the others.
  defp system(vm, overrides \\ []) do
    defaults = [
      ifaddrs_fun: fn -> [{~c"eth0", [flags: [:up, :running], addr: {192, 168, 2, 58}]}] end,
      put_env_fun: fn key, value ->
        record(vm, {:put_env, key, value})
        :ok
      end,
      epmd_fun: fn args, _env ->
        record(vm, {:epmd, args})
        {"", 0}
      end,
      net_kernel_start_fun: fn name, opts ->
        record(vm, {:net_kernel_start, name, opts})

        if Agent.get(vm, & &1.node) do
          # OTP refuses a second start; a fake that quietly succeeded here would
          # hide every lost-record path.
          {:error, {:already_started, self()}}
        else
          # Starting the node mints a cookie we did not choose.
          Agent.update(vm, &%{&1 | node: name, cookie: :"otp-minted-random"})
          {:ok, self()}
        end
      end,
      net_kernel_stop_fun: fn ->
        record(vm, :net_kernel_stop)
        Agent.update(vm, &%{&1 | node: nil, cookie: :nocookie})
        :ok
      end,
      set_cookie_fun: fn cookie ->
        record(vm, {:set_cookie, cookie})
        Agent.update(vm, &%{&1 | cookie: cookie})
        :ok
      end,
      get_cookie_fun: fn -> Agent.get(vm, & &1.cookie) end,
      alive_fun: fn -> Agent.get(vm, &(&1.node != nil)) end,
      self_node_fun: fn -> Agent.get(vm, & &1.node) end,
      # get_and_update is atomic, which is what makes this a faithful stand-in
      # for :ets.select_replace/2 rather than a check-then-set that would hide
      # the very race the real one exists to close.
      session_claim_fun: fn ->
        Agent.get_and_update(vm, fn st ->
          case st.session do
            :not_requested -> {:claimed, %{st | session: :starting}}
            :starting -> {:starting, st}
            session -> {{:recorded, session}, st}
          end
        end)
      end,
      session_reset_fun: fn ->
        record(vm, :session_reset)
        Agent.update(vm, &%{&1 | session: :not_requested})
        :ok
      end,
      # Replaces the :vagus_dist table, which is global and would break
      # async: true isolation across the suite.
      session_get_fun: fn -> Agent.get(vm, & &1.session) end,
      session_put_fun: fn session ->
        record(vm, {:session_put, session.node})
        Agent.update(vm, &%{&1 | session: session})
        :ok
      end
    ]

    Keyword.merge(defaults, overrides)
  end

  describe "enable/1" do
    test "returns the node, a fresh cookie, and the pinned port range", %{vm: vm} do
      assert {:ok, result} = Dist.enable(system(vm))

      assert result.node == :"vagus@192.168.2.58"
      assert result.cookie =~ @cookie_re
      assert result.ports == 9100..9105
    end

    test "the returned cookie is the one the VM is actually using", %{vm: vm} do
      {:ok, %{cookie: cookie}} = Dist.enable(system(vm))

      assert Agent.get(vm, & &1.cookie) == String.to_atom(cookie)
    end

    test "mints a different cookie on a fresh boot", %{vm: vm} do
      {:ok, %{cookie: first}} = Dist.enable(system(vm))
      # A reboot drops the record and the node with it.
      Agent.update(vm, &%{&1 | node: nil, cookie: :nocookie, session: :not_requested})
      {:ok, %{cookie: second}} = Dist.enable(system(vm))

      refute first == second
    end

    test "records the session so a second call does not start anything", %{vm: vm} do
      {:ok, first} = Dist.enable(system(vm))
      before = steps(vm)

      assert {:ok, ^first} = Dist.enable(system(vm))
      assert steps(vm) == before
    end

    test "repeat calls return the SAME cookie, not a fresh one", %{vm: vm} do
      {:ok, %{cookie: first}} = Dist.enable(system(vm))
      {:ok, %{cookie: again}} = Dist.enable(system(vm))

      assert first == again
    end

    test "nothing is recorded when bring-up fails, so a retry can still work", %{vm: vm} do
      fail = [set_cookie_fun: fn _ -> :ok end]
      assert {:error, :cookie_not_applied} = Dist.enable(system(vm, fail))
      assert %{enabled?: false} = Dist.status(system(vm))

      assert {:ok, %{node: :"vagus@192.168.2.58"}} = Dist.enable(system(vm))
    end
  end

  describe "bring-up ordering" do
    test "ports are pinned BEFORE net_kernel starts", %{vm: vm} do
      {:ok, _} = Dist.enable(system(vm))
      recorded = steps(vm)

      min_at = Enum.find_index(recorded, &match?({:put_env, :inet_dist_listen_min, 9100}, &1))
      max_at = Enum.find_index(recorded, &match?({:put_env, :inet_dist_listen_max, 9105}, &1))
      start_at = Enum.find_index(recorded, &match?({:net_kernel_start, _, _}, &1))

      assert min_at < start_at
      assert max_at < start_at
    end

    test "epmd is started BEFORE net_kernel", %{vm: vm} do
      {:ok, _} = Dist.enable(system(vm))
      recorded = steps(vm)

      assert Enum.find_index(recorded, &match?({:epmd, ["-daemon"]}, &1)) <
               Enum.find_index(recorded, &match?({:net_kernel_start, _, _}, &1))
    end

    test "the cookie is set AFTER net_kernel starts", %{vm: vm} do
      # Not cosmetic: MEASURED on OTP 29, set_cookie/1 raises before
      # distribution is up.
      {:ok, _} = Dist.enable(system(vm))
      recorded = steps(vm)

      assert Enum.find_index(recorded, &match?({:net_kernel_start, _, _}, &1)) <
               Enum.find_index(recorded, &match?({:set_cookie, _}, &1))
    end

    test "starts a longname node named for the chosen address", %{vm: vm} do
      {:ok, _} = Dist.enable(system(vm))

      assert {:net_kernel_start, :"vagus@192.168.2.58", %{name_domain: :longnames}} =
               Enum.find(steps(vm), &match?({:net_kernel_start, _, _}, &1))
    end

    test "passes no ERL_EPMD_ADDRESS, so epmd agrees with the wildcard listener", %{vm: vm} do
      overrides = [
        epmd_fun: fn args, env ->
          record(vm, {:epmd_env, args, env})
          {"", 0}
        end
      ]

      {:ok, _} = Dist.enable(system(vm, overrides))

      assert {:epmd_env, ["-daemon"], []} = Enum.find(steps(vm), &match?({:epmd_env, _, _}, &1))
    end
  end

  describe "the cookie read-back" do
    test "a node left under a cookie the caller was not handed is stopped", %{vm: vm} do
      # The whole safety property of this module.
      overrides = [set_cookie_fun: fn _ -> :ok end]

      assert {:error, :cookie_not_applied} = Dist.enable(system(vm, overrides))
      assert :net_kernel_stop in steps(vm)
      refute Agent.get(vm, & &1.node)
    end

    test "trusts Node.alive? over net_kernel.stop's return value", %{vm: vm} do
      # stop/0 claiming :ok while the node is still up is the case that must not
      # be reported as a clean rollback.
      overrides = [
        set_cookie_fun: fn _ -> :ok end,
        net_kernel_stop_fun: fn -> :ok end
      ]

      assert {:error, {:cookie_not_applied, {:still_alive, :ok}}} =
               Dist.enable(system(vm, overrides))
    end
  end

  describe "failure before the node exists" do
    test "an epmd failure never starts net_kernel", %{vm: vm} do
      overrides = [epmd_fun: fn _args, _env -> {"port 4369 in use", 1} end]

      assert {:error, {:epmd_failed, 1, "port 4369 in use"}} = Dist.enable(system(vm, overrides))
      refute Enum.any?(steps(vm), &match?({:net_kernel_start, _, _}, &1))
    end

    test "no usable address never starts epmd or net_kernel", %{vm: vm} do
      overrides = [ifaddrs_fun: fn -> [] end]

      assert {:error, :no_address} = Dist.enable(system(vm, overrides))
      # Only the claim being released; nothing was started to roll back.
      assert steps(vm) == [:session_reset]
    end

    test "a net_kernel start failure is returned as-is", %{vm: vm} do
      overrides = [net_kernel_start_fun: fn _name, _opts -> {:error, :einval} end]

      assert {:error, :einval} = Dist.enable(system(vm, overrides))
    end

    test "epmd is started exactly once and never killed", %{vm: vm} do
      # dist.ex issues no epmd command other than -daemon; assert on the call
      # log itself rather than on the absence of a call it could never make.
      {:error, _} = Dist.enable(system(vm, set_cookie_fun: fn _ -> :ok end))

      assert Enum.filter(steps(vm), &match?({:epmd, _}, &1)) == [{:epmd, ["-daemon"]}]
    end
  end

  describe "address selection" do
    test "skips interfaces that are not up", %{vm: vm} do
      # A configured address on a DOWN interface fails invisibly: the node
      # starts and the name answers nowhere.
      overrides = [
        ifaddrs_fun: fn ->
          [
            {~c"eth0", [flags: [:broadcast], addr: {10, 0, 0, 5}]},
            {~c"wlan0", [flags: [:up, :running], addr: {192, 168, 2, 58}]}
          ]
        end
      ]

      assert {:ok, %{node: :"vagus@192.168.2.58"}} = Dist.enable(system(vm, overrides))
    end

    for bridge <- ["hassio", "balena0", "br-a1b2c3"] do
      test "skips the #{bridge} container bridge", %{vm: vm} do
        overrides = [
          ifaddrs_fun: fn ->
            [
              {~c"#{unquote(bridge)}", [flags: [:up, :running], addr: {172, 30, 32, 1}]},
              {~c"eth0", [flags: [:up, :running], addr: {192, 168, 2, 58}]}
            ]
          end
        ]

        assert {:ok, %{node: :"vagus@192.168.2.58"}} = Dist.enable(system(vm, overrides))
      end
    end

    test "skips an interface that is up but has no addresses", %{vm: vm} do
      # OBSERVED on a dragon_q6a: wlan0 is up/running with addrs=[]. An
      # address-less interface reports an EMPTY list, which is why there is no
      # 0.0.0.0 case to reject.
      overrides = [
        ifaddrs_fun: fn ->
          [
            {~c"wlan0", [flags: [:up, :broadcast, :running, :multicast]]},
            {~c"eth0", [flags: [:up, :broadcast, :running, :multicast], addr: {192, 168, 2, 58}]}
          ]
        end
      ]

      assert {:ok, %{node: :"vagus@192.168.2.58"}} = Dist.enable(system(vm, overrides))
    end

    test "picks eth0 out of a real dragon_q6a interface list", %{vm: vm} do
      # Captured verbatim from :inet.getifaddrs() on 192.168.2.58 rather than
      # invented: loopback first, an address-less wlan0, and both container
      # bridges the engine actually creates.
      overrides = [
        ifaddrs_fun: fn ->
          [
            {~c"lo",
             [
               flags: [:up, :loopback, :running],
               addr: {127, 0, 0, 1},
               addr: {0, 0, 0, 0, 0, 0, 0, 1}
             ]},
            {~c"eth0",
             [
               flags: [:up, :broadcast, :running, :multicast],
               addr: {192, 168, 2, 58},
               addr: {64_862, 45_261, 12_257, 16_468, 584, 21_759, 65_057, 24_056},
               addr: {65_152, 0, 0, 0, 584, 21_759, 65_057, 24_056}
             ]},
            {~c"wlan0", [flags: [:up, :broadcast, :running, :multicast]]},
            {~c"hassio",
             [
               flags: [:up, :broadcast, :running, :multicast],
               addr: {172, 30, 32, 1},
               addr: {172, 30, 32, 2},
               addr: {172, 30, 32, 3}
             ]},
            {~c"balena0", [flags: [:up, :broadcast, :running, :multicast], addr: {172, 17, 0, 1}]}
          ]
        end
      ]

      assert {:ok, %{node: :"vagus@192.168.2.58"}} = Dist.enable(system(vm, overrides))
    end

    test "keeps a real LAN address inside 172.16/12", %{vm: vm} do
      # Excluding the range instead of the bridge NAMES would strand this board.
      overrides = [
        ifaddrs_fun: fn -> [{~c"eth0", [flags: [:up, :running], addr: {172, 20, 5, 9}]}] end
      ]

      assert {:ok, %{node: :"vagus@172.20.5.9"}} = Dist.enable(system(vm, overrides))
    end

    for {label, addr} <- [
          loopback: {127, 0, 0, 1},
          link_local: {169, 254, 1, 1}
        ] do
      test "skips a #{label} address", %{vm: vm} do
        overrides = [
          ifaddrs_fun: fn ->
            [
              {~c"lo", [flags: [:up, :running], addr: unquote(Macro.escape(addr))]},
              {~c"eth0", [flags: [:up, :running], addr: {192, 168, 2, 58}]}
            ]
          end
        ]

        assert {:ok, %{node: :"vagus@192.168.2.58"}} = Dist.enable(system(vm, overrides))
      end
    end

    test "skips IPv6 addresses", %{vm: vm} do
      overrides = [
        ifaddrs_fun: fn ->
          [
            {~c"eth0",
             [
               flags: [:up, :running],
               addr: {8193, 3512, 0, 0, 0, 0, 0, 1},
               addr: {192, 168, 2, 58}
             ]}
          ]
        end
      ]

      assert {:ok, %{node: :"vagus@192.168.2.58"}} = Dist.enable(system(vm, overrides))
    end
  end

  describe "a live node whose record was lost" do
    # MEASURED on host: Application.stop(:vagus) destroys the :vagus_dist table
    # (its owner is the application master) while net_kernel, owned by :kernel,
    # stays up.
    test "is recovered rather than refused", %{vm: vm} do
      {:ok, first} = Dist.enable(system(vm))
      Agent.update(vm, &%{&1 | session: :not_requested})

      assert {:ok, recovered} = Dist.enable(system(vm))
      assert recovered.node == first.node
    end

    test "gets a FRESH cookie, never the one already in place", %{vm: vm} do
      # The cookie in place may be the weak one OTP invented, left by a caller
      # that died mid-bring-up. Handing it back would launder a bad credential
      # into a recorded session.
      {:ok, first} = Dist.enable(system(vm))
      Agent.update(vm, &%{&1 | session: :not_requested, cookie: :"otp-minted-random"})

      {:ok, recovered} = Dist.enable(system(vm))

      refute recovered.cookie == first.cookie
      refute recovered.cookie == "otp-minted-random"
      assert String.to_atom(recovered.cookie) == Agent.get(vm, & &1.cookie)
    end

    test "does not tear the running node down", %{vm: vm} do
      {:ok, _} = Dist.enable(system(vm))
      Agent.update(vm, &%{&1 | session: :not_requested, steps: []})

      {:ok, _} = Dist.enable(system(vm))

      refute :net_kernel_stop in steps(vm)
    end

    test "records the recovery, so the next call is a plain record hit", %{vm: vm} do
      {:ok, _} = Dist.enable(system(vm))
      Agent.update(vm, &%{&1 | session: :not_requested})
      {:ok, recovered} = Dist.enable(system(vm))
      before = steps(vm)

      assert {:ok, ^recovered} = Dist.enable(system(vm))
      assert steps(vm) == before
    end
  end

  describe "concurrent callers" do
    test "a second caller does not race the first into net_kernel", %{vm: vm} do
      # Claiming is atomic, so only the winner reaches bring-up. Without it the
      # loser hits already_started before the winner has set its cookie and
      # records one that never authenticates.
      Agent.update(vm, &%{&1 | session: :starting})

      assert {:error, :starting} = Dist.enable(system(vm))
      assert steps(vm) == []
    end

    test "the claim is released when bring-up fails, so a retry works", %{vm: vm} do
      assert {:error, :no_address} = Dist.enable(system(vm, ifaddrs_fun: fn -> [] end))
      assert Agent.get(vm, & &1.session) == :not_requested

      assert {:ok, %{node: :"vagus@192.168.2.58"}} = Dist.enable(system(vm))
    end

    test "the claim is released when the cookie read-back fails", %{vm: vm} do
      assert {:error, :cookie_not_applied} =
               Dist.enable(system(vm, set_cookie_fun: fn _ -> :ok end))

      assert Agent.get(vm, & &1.session) == :not_requested
    end
  end

  describe "override validation" do
    test "an unknown or misspelt key raises instead of silently defaulting", %{vm: vm} do
      assert_raise ArgumentError, fn ->
        Dist.status(Keyword.put(system(vm), :alive_func, fn -> true end))
      end
    end
  end

  describe "the real :vagus_dist table" do
    # The system above prove the logic; this proves the DEFAULT wiring, which no
    # faked test would catch if create_session_table/0 were never called.
    test "is created at application start, seeded :not_requested" do
      assert :ets.lookup(:vagus_dist, :session) == [{:session, :not_requested}]
    end

    test "is what status/0 reads when no system are injected" do
      assert %{enabled?: false, alive?: false, node: nil, ports: 9100..9105} = Dist.status()
    end
  end

  describe "status/1" do
    test "reports a board nobody enabled", %{vm: vm} do
      assert %{enabled?: false, alive?: false, node: nil, ports: 9100..9105} =
               Dist.status(system(vm))
    end

    test "reports the node enable/1 produced", %{vm: vm} do
      {:ok, %{node: node}} = Dist.enable(system(vm))

      assert %{enabled?: true, alive?: true, node: ^node} = Dist.status(system(vm))
    end

    test "does not call a board with a lost record 'off' while it answers", %{vm: vm} do
      # Reporting only the record here would be a lie with a live LAN listener
      # behind it.
      {:ok, %{node: node}} = Dist.enable(system(vm))
      Agent.update(vm, &%{&1 | session: :not_requested})

      assert %{enabled?: false, alive?: true, node: ^node} = Dist.status(system(vm))
    end

    test "does not repeat the cookie", %{vm: vm} do
      {:ok, _} = Dist.enable(system(vm))

      refute Map.has_key?(Dist.status(system(vm)), :cookie)
    end
  end

  describe "run/1" do
    test "returns the function's value" do
      assert Dist.run(fn -> {:collected, 42} end) == {:collected, 42}
    end

    test "flags the process that calls it, not the one that spawned that process" do
      task =
        Task.async(fn ->
          Dist.run(fn -> Process.info(self(), :async_dist) end)
        end)

      assert {:async_dist, true} = Task.await(task)
    end

    test "does not flag the caller's caller" do
      # Process-local by design; a leak here would change unrelated processes.
      Task.async(fn -> Dist.run(fn -> :ok end) end) |> Task.await()

      assert {:async_dist, false} = Process.info(self(), :async_dist)
    end
  end
end
