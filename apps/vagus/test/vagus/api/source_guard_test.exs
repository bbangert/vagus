defmodule Vagus.API.SourceGuardTest do
  @moduledoc """
  `Vagus.API.SourceGuard` — who may talk to the Supervisor API.

  The allowlist's shape is a measurement, not a deduction: Core is
  host-networked and targets `172.30.32.2`, which suggests it arrives from the
  bridge, and on hardware it does not — every socket the API accepted from
  Core carried the board's **LAN** address. Hence "local addresses" being an
  allowlist member at all, and hence the test below that pins it.
  """
  use ExUnit.Case, async: false

  alias Vagus.API.SourceGuard

  setup do
    prev = Application.get_env(:vagus, :api_source_guard)
    Application.put_env(:vagus, :api_source_guard, true)

    # The guard's cache is owned by a process that only starts when the config
    # is on, which it isn't in :test — seed it directly.
    on_exit(fn ->
      # `is_nil/1`, not a truthiness check: an explicitly-`false` setting is a
      # real value to restore, and `if prev` would delete it instead — leaking
      # a config change into whatever runs next.
      if is_nil(prev),
        do: Application.delete_env(:vagus, :api_source_guard),
        else: Application.put_env(:vagus, :api_source_guard, prev)

      :persistent_term.erase({SourceGuard, :local_addresses})
    end)

    :ok
  end

  defp seed_local(addresses) do
    :persistent_term.put({SourceGuard, :local_addresses}, MapSet.new(addresses))
  end

  describe "allowed?/1 when the guard is on" do
    test "loopback is allowed, v4 and v6" do
      seed_local([])

      assert SourceGuard.allowed?({127, 0, 0, 1})
      assert SourceGuard.allowed?({127, 12, 3, 4})
      assert SourceGuard.allowed?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "the whole hassio /23 is allowed, before anything is bound" do
      seed_local([])

      assert SourceGuard.allowed?({172, 30, 32, 1})
      assert SourceGuard.allowed?({172, 30, 32, 2})
      # .33.x is the add-on half of the /23 — a mask that only covered .32.x
      # would refuse every container.
      assert SourceGuard.allowed?({172, 30, 33, 7})

      refute SourceGuard.allowed?({172, 30, 34, 1})
      refute SourceGuard.allowed?({172, 31, 32, 1})
    end

    test "this machine's own LAN address is allowed — that is where Core arrives from" do
      seed_local([{192, 168, 2, 149}])

      assert SourceGuard.allowed?({192, 168, 2, 149})
    end

    test "another host on the same LAN is refused" do
      # The point of the guard: same subnet, different machine.
      seed_local([{192, 168, 2, 149}])

      refute SourceGuard.allowed?({192, 168, 2, 12})
      refute SourceGuard.allowed?({10, 0, 0, 5})
    end

    test "an IPv4 peer seen through a dual-stack listener is judged as IPv4" do
      # Plug hands over `::ffff:a.b.c.d` on an IPv6 socket. Every rule has to
      # see through it or the same address would be admitted on one listener
      # and refused on the other.
      seed_local([{192, 168, 2, 149}])

      assert SourceGuard.allowed?({0, 0, 0, 0, 0, 65_535, 0x7F00, 0x0001})
      assert SourceGuard.allowed?({0, 0, 0, 0, 0, 65_535, 0xAC1E, 0x2002})
      assert SourceGuard.allowed?({0, 0, 0, 0, 0, 65_535, 0xC0A8, 0x0295})
      refute SourceGuard.allowed?({0, 0, 0, 0, 0, 65_535, 0xC0A8, 0x020C})
    end

    test "an empty address cache still admits loopback and the bridge" do
      # `getifaddrs` failing must not lock Core out of a running device.
      :persistent_term.erase({SourceGuard, :local_addresses})

      assert SourceGuard.allowed?({127, 0, 0, 1})
      assert SourceGuard.allowed?({172, 30, 32, 2})
      refute SourceGuard.allowed?({192, 168, 2, 12})
    end

    test "a nil remote_ip is refused rather than treated as local" do
      seed_local([{192, 168, 2, 149}])
      refute SourceGuard.allowed?(nil)
    end
  end

  describe "allowed?/1 when the guard is off" do
    setup do
      Application.put_env(:vagus, :api_source_guard, false)
      :ok
    end

    test "everything is allowed, including a nil remote_ip" do
      seed_local([])

      assert SourceGuard.allowed?({192, 168, 2, 12})
      assert SourceGuard.allowed?({8, 8, 8, 8})
      assert SourceGuard.allowed?(nil)
    end

    test "start_link/1 declines to start" do
      assert :ignore = SourceGuard.start_link([])
    end
  end

  describe "the address cache" do
    test "start_link/1 populates it from the real interfaces" do
      pid = start_supervised!({SourceGuard, name: :source_guard_test})
      assert is_pid(pid)

      addresses = :persistent_term.get({SourceGuard, :local_addresses})
      assert MapSet.size(addresses) > 0

      # Whatever this machine's interfaces are, loopback is among them, and
      # it is the one address every host has.
      assert MapSet.member?(addresses, {127, 0, 0, 1})
    end

    test "what the writer stores is what the reader accepts" do
      # Every other test in this file hand-seeds `:persistent_term`, which
      # would keep passing if `read_addresses/0`'s stored shape ever drifted
      # from the seeded shape while production denied everything. This is the
      # one test that runs the real writer and the real reader end to end.
      :persistent_term.erase({SourceGuard, :local_addresses})
      start_supervised!({SourceGuard, name: :source_guard_shape})

      stored = :persistent_term.get({SourceGuard, :local_addresses})

      # Pick a non-loopback address the writer actually recorded, so this
      # doesn't pass via the loopback rule. Skip the assertion on a host with
      # no other interface rather than fail spuriously.
      case Enum.find(stored, &(not match?({127, _, _, _}, &1) and tuple_size(&1) == 4)) do
        nil -> assert MapSet.member?(stored, {127, 0, 0, 1})
        address -> assert SourceGuard.allowed?(address)
      end
    end

    test "refusals are counted and summarised, not logged one per request" do
      import ExUnit.CaptureLog

      start_supervised!({SourceGuard, name: SourceGuard})

      log =
        capture_log(fn ->
          for _ <- 1..50, do: SourceGuard.record_refusal({192, 168, 2, 12})
          # Force the periodic report rather than waiting out the interval.
          send(SourceGuard, :refresh)
          # Round-trip a call so the cast+info are both processed first.
          _ = :sys.get_state(SourceGuard)
        end)

      assert log =~ "refused 50 request(s)"
      assert log =~ "192.168.2.12"
      # One summary line, not fifty.
      assert length(String.split(log, "refused ")) == 2
    end

    test "a nil source in the summary doesn't crash the reporter" do
      import ExUnit.CaptureLog

      start_supervised!({SourceGuard, name: SourceGuard})

      log =
        capture_log(fn ->
          SourceGuard.record_refusal(nil)
          send(SourceGuard, :refresh)
          _ = :sys.get_state(SourceGuard)
        end)

      assert log =~ "unknown"
    end

    test "filtered requests are counted and summarised, not logged one per request" do
      import ExUnit.CaptureLog

      start_supervised!({SourceGuard, name: SourceGuard})
      # Unique per test (testing-phase7.md's CaptureLog lesson): this module
      # is `async: false`, which only protects against *other tests in this
      # file* interleaving, not other test files' concurrent output landing
      # in the same captured region — a distinctive marker keeps the
      # assertion honest either way.
      marker = "unique-sample-#{System.unique_integer([:positive])}"

      log =
        capture_log(fn ->
          for _ <- 1..30, do: SourceGuard.record_filtered(:path, marker)
          for _ <- 1..20, do: SourceGuard.record_filtered(:query, marker)
          send(SourceGuard, :refresh)
          _ = :sys.get_state(SourceGuard)
        end)

      assert log =~ "filtered 50 request(s)"
      assert log =~ "path: 30"
      assert log =~ "query: 20"
      assert log =~ marker
      # One summary line, not fifty.
      assert length(String.split(log, "filtered ")) == 2
    end

    test "record_filtered/2 is a no-op when the guard isn't running" do
      # No `start_supervised!` here — mirrors the existing "safe when
      # disabled" property `record_refusal/1` already has: casting to an
      # unregistered name must not raise.
      assert SourceGuard.record_filtered(:path, "whatever") == :ok
    end
  end
end
