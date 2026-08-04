defmodule Vagus.OS.UpdaterTest do
  @moduledoc """
  `Vagus.OS.Updater` — every public function takes an opts keyword whose
  `:updater` entry is the whole `nerves_github_updater` seam
  (`check/0`/`state/0`/`install_latest/0`, arity-0 — the real library
  exposes default-arg versions), so these tests never start that
  GenServer. `install/2` runs entirely in the caller's process (a plain
  function call chain, `Process.sleep`-based polling, no
  cast/message-passing to another process), so `StubUpdater` below reads
  and writes the *calling* process's dictionary — safe under `async:
  true` because ExUnit runs each test in its own process.
  """
  use ExUnit.Case, async: true

  alias Vagus.OS.Updater

  # `config/host.exs` seeds `"a.nerves_fw_platform" => "host"` into the
  # InMemory KV and `"nerves_fw_active" => "a"`, so
  # `Vagus.Backend.OS.FirmwareKV.active_slot/0` resolves `"a"` and
  # `match_firmware_asset/2` (real code, not stubbed — it isn't part of
  # the `:updater` seam) looks for exactly `"vagus_host.fw"`. See
  # test/vagus/backend/os/firmware_kv_test.exs for the same fact.
  @asset_name "vagus_host.fw"
  @headroom_bytes 64 * 1024 * 1024

  defmodule StubUpdater do
    @moduledoc """
    The `:updater` seam, backed by the calling process's dictionary.
    `:stub_state` is a static snapshot; `:stub_state_fn` (checked first)
    is a `-> map()` closure for tests that need `state/0` to answer
    differently across successive calls (simulating a check settling).
    """

    def check do
      Process.put(:stub_calls, Process.get(:stub_calls, []) ++ [:check])
      :ok
    end

    def install_latest do
      Process.put(:stub_calls, Process.get(:stub_calls, []) ++ [:install_latest])
      Process.get(:stub_install_latest_result, :ok)
    end

    def state do
      case Process.get(:stub_state_fn) do
        fun when is_function(fun, 0) -> fun.()
        _ -> Process.get(:stub_state)
      end
    end
  end

  describe "start_link/1 (disabled mode)" do
    test "returns :ignore when :os_updater is not configured (test env default)" do
      assert Application.get_env(:vagus, :os_updater) in [nil, false]
      assert :ignore = Updater.start_link([])
    end
  end

  describe "version_latest/1" do
    test "nil before any check has ever settled" do
      Process.put(:stub_state, %{phase: :idle, last_error: nil, last_release: nil})
      assert Updater.version_latest(updater: StubUpdater) == nil
    end

    test "the cached release's tag once one exists" do
      Process.put(:stub_state, %{
        phase: :idle,
        last_error: nil,
        last_release: %{tag_name: "0.4.0"}
      })

      assert Updater.version_latest(updater: StubUpdater) == "0.4.0"
    end
  end

  describe "update_available?/1" do
    test "true when the feed's tag differs from the running version" do
      Process.put(:stub_state, %{
        phase: :idle,
        last_error: nil,
        last_release: %{tag_name: "0.4.0"}
      })

      assert Updater.update_available?(
               updater: StubUpdater,
               current_version_fn: fn -> "0.3.0" end
             )
    end

    test "false when the feed's tag matches the running version" do
      Process.put(:stub_state, %{
        phase: :idle,
        last_error: nil,
        last_release: %{tag_name: "0.4.0"}
      })

      refute Updater.update_available?(
               updater: StubUpdater,
               current_version_fn: fn -> "0.4.0" end
             )
    end

    test "false while either side is unknown (never sprouts an update button that can't work)" do
      Process.put(:stub_state, %{phase: :idle, last_error: nil, last_release: nil})

      refute Updater.update_available?(
               updater: StubUpdater,
               current_version_fn: fn -> "0.3.0" end
             )

      Process.put(:stub_state, %{
        phase: :idle,
        last_error: nil,
        last_release: %{tag_name: "0.4.0"}
      })

      refute Updater.update_available?(updater: StubUpdater, current_version_fn: fn -> nil end)
    end
  end

  describe "busy?/1" do
    test "true for every real busy phase plus the synthetic :installing" do
      for phase <- [:checking, :verifying, :downloading, :flashing, :installing] do
        Process.put(:stub_state, %{phase: phase, last_error: nil, last_release: nil})
        assert Updater.busy?(updater: StubUpdater), "expected #{phase} to read busy"
      end
    end

    test "false for :idle and :error" do
      for phase <- [:idle, :error] do
        Process.put(:stub_state, %{phase: phase, last_error: nil, last_release: nil})
        refute Updater.busy?(updater: StubUpdater), "expected #{phase} to read idle"
      end
    end
  end

  describe "check_now/1" do
    test "delegates to the injected updater's check/0" do
      Process.put(:stub_calls, [])
      assert Updater.check_now(updater: StubUpdater) == :ok
      assert Process.get(:stub_calls) == [:check]
    end
  end

  describe "install/2" do
    test "refuses with :busy without ever calling check" do
      Process.put(:stub_calls, [])
      Process.put(:stub_state, %{phase: :downloading, last_error: nil, last_release: nil})

      assert Updater.install(nil, updater: StubUpdater) == {:error, :busy}
      assert Process.get(:stub_calls) == []
    end

    test "runs a fresh check, waits for it to settle, and only then installs" do
      Process.put(:stub_calls, [])
      counter = :counters.new(1, [])

      # call 0 is install/2's own busy?/1 precheck (must read non-busy so
      # the install proceeds); call 1 simulates the just-cast check still
      # in flight; call 2+ simulates it settling with a cached release —
      # `install_latest/0` must not appear in :stub_calls before that.
      Process.put(:stub_state_fn, fn ->
        n = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        cond do
          n == 0 -> %{phase: :idle, last_error: nil, last_release: nil}
          n == 1 -> %{phase: :checking, last_error: nil, last_release: nil}
          true -> %{phase: :idle, last_error: nil, last_release: release()}
        end
      end)

      assert Updater.install(nil,
               updater: StubUpdater,
               poll_ms: 1,
               free_bytes_fn: fn -> plenty_of_space() end
             ) == :ok

      assert Process.get(:stub_calls) == [:check, :install_latest]
    end

    test "surfaces a failed fresh check rather than falling back to a stale cache" do
      Process.put(:stub_calls, [])
      Process.put(:stub_state, %{phase: :error, last_error: :nxdomain, last_release: nil})

      assert Updater.install(nil, updater: StubUpdater, poll_ms: 1) ==
               {:error, {:check_failed, :nxdomain}}

      assert Process.get(:stub_calls) == [:check]
    end

    test "refuses when the settled check has no cached release" do
      Process.put(:stub_calls, [])
      Process.put(:stub_state, %{phase: :idle, last_error: nil, last_release: nil})

      assert Updater.install(nil, updater: StubUpdater, poll_ms: 1) ==
               {:error, :no_release_cached}

      assert Process.get(:stub_calls) == [:check]
    end

    test "refuses a requested_version that differs from the feed's latest" do
      Process.put(:stub_calls, [])
      Process.put(:stub_state, %{phase: :idle, last_error: nil, last_release: release()})

      assert Updater.install("9.9.9", updater: StubUpdater, poll_ms: 1) ==
               {:error, {:version_mismatch, "0.4.0"}}

      refute :install_latest in Process.get(:stub_calls)
    end

    test "proceeds when requested_version equals the feed's latest" do
      Process.put(:stub_calls, [])
      Process.put(:stub_state, %{phase: :idle, last_error: nil, last_release: release()})

      assert Updater.install("0.4.0",
               updater: StubUpdater,
               poll_ms: 1,
               free_bytes_fn: fn -> plenty_of_space() end
             ) == :ok
    end

    test "refuses when the release has no asset for this platform" do
      Process.put(:stub_calls, [])

      Process.put(:stub_state, %{
        phase: :idle,
        last_error: nil,
        last_release: %{
          tag_name: "0.4.0",
          assets: [%{name: "vagus_some_other_platform.fw", size: 1024}]
        }
      })

      assert Updater.install(nil, updater: StubUpdater, poll_ms: 1) ==
               {:error, :no_asset_for_target}

      refute :install_latest in Process.get(:stub_calls)
    end

    test "refuses when free_bytes_fn reports too little headroom" do
      Process.put(:stub_calls, [])
      asset_size = 1024

      Process.put(:stub_state, %{phase: :idle, last_error: nil, last_release: release(asset_size)})

      needed = asset_size + @headroom_bytes
      free = needed - 1

      assert Updater.install(nil, updater: StubUpdater, poll_ms: 1, free_bytes_fn: fn -> free end) ==
               {:error, {:insufficient_space, needed, free}}

      refute :install_latest in Process.get(:stub_calls)
    end

    test "proceeds when free_bytes_fn reports exactly enough headroom" do
      Process.put(:stub_calls, [])
      asset_size = 1024

      Process.put(:stub_state, %{phase: :idle, last_error: nil, last_release: release(asset_size)})

      needed = asset_size + @headroom_bytes

      assert Updater.install(nil,
               updater: StubUpdater,
               poll_ms: 1,
               free_bytes_fn: fn -> needed end
             ) ==
               :ok
    end

    test "returns whatever install_latest/0 returns on the happy path" do
      Process.put(:stub_calls, [])
      Process.put(:stub_state, %{phase: :idle, last_error: nil, last_release: release()})
      Process.put(:stub_install_latest_result, {:error, :fwup_failed})

      assert Updater.install(nil,
               updater: StubUpdater,
               poll_ms: 1,
               free_bytes_fn: fn -> plenty_of_space() end
             ) == {:error, :fwup_failed}
    end
  end

  defp release(asset_size \\ 1024) do
    %{tag_name: "0.4.0", assets: [%{name: @asset_name, size: asset_size}]}
  end

  defp plenty_of_space, do: 10 * 1024 * 1024 * 1024
end
