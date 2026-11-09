defmodule Vagus.Backend.Network.WifiScanTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.Backend.Network.WifiScan

  @property ["interface", "wlan0", "wifi", "access_points"]

  # Stands in for `VintageNet`. It runs in the caller (the test process), so
  # the process dictionary scripts it; the property value lives in an Agent
  # so a spawned "wpa_supplicant" can publish into it.
  defmodule FakeVintageNet do
    def subscribe(property), do: record({:subscribe, property})

    def unsubscribe(property) do
      record({:unsubscribe, property})
      Process.get(:on_unsubscribe, fn -> :ok end).()
      :ok
    end

    def scan(ifname) do
      record({:scan, ifname})
      Process.get(:on_scan, fn -> :ok end).()
    end

    def get(["interface", _, "wifi", "access_points"], _default),
      do: Agent.get(Process.get(:store), & &1)

    defp record(call) do
      Process.put(:calls, Process.get(:calls, []) ++ [call])
      :ok
    end
  end

  setup do
    store = start_supervised!({Agent, fn -> [:cached] end})
    Process.put(:store, store)
    %{store: store}
  end

  defp publish(store, subscriber, access_points) do
    old = Agent.get_and_update(store, &{&1, access_points})
    send(subscriber, {VintageNet, @property, old, access_points, %{}})
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started}
  end

  test "subscribes, then requests a scan of the interface, then unsubscribes" do
    WifiScan.access_points("wlan0", FakeVintageNet, timeout_ms: 0)

    assert Process.get(:calls) == [
             {:subscribe, @property},
             {:scan, "wlan0"},
             {:unsubscribe, @property}
           ]
  end

  test "returns the scanned list once updates settle, well before the timeout", %{store: store} do
    me = self()

    Process.put(:on_scan, fn ->
      publish(store, me, [:ap1])
      publish(store, me, [:ap1, :ap2])
      :ok
    end)

    {result, elapsed} =
      timed(fn -> WifiScan.access_points("wlan0", FakeVintageNet, settle_ms: 50) end)

    assert result == [:ap1, :ap2]
    assert elapsed < 1_000
  end

  test "keeps waiting after a partial update until the burst goes quiet", %{store: store} do
    me = self()

    Process.put(:on_scan, fn ->
      spawn(fn ->
        publish(store, me, [:ap1])
        Process.sleep(50)
        publish(store, me, [:ap1, :ap2])
      end)

      :ok
    end)

    assert WifiScan.access_points("wlan0", FakeVintageNet, settle_ms: 300) == [:ap1, :ap2]
  end

  test "answers whatever is cached when no update arrives before the timeout" do
    {result, elapsed} =
      timed(fn -> WifiScan.access_points("wlan0", FakeVintageNet, timeout_ms: 100) end)

    assert result == [:cached]
    assert elapsed >= 100
  end

  test "answers the cache at once when the scan returns an error" do
    Process.put(:on_scan, fn -> {:error, :unconfigured} end)

    log =
      capture_log(fn ->
        {result, elapsed} = timed(fn -> WifiScan.access_points("wlan0", FakeVintageNet) end)
        assert result == [:cached]
        assert elapsed < 1_000
      end)

    assert log =~ "WiFi scan on wlan0 failed"
  end

  test "answers the cache when the interface process is not running" do
    Process.put(:on_scan, fn -> exit({:noproc, {:gen_statem, :call, []}}) end)

    capture_log(fn ->
      assert WifiScan.access_points("wlan0", FakeVintageNet) == [:cached]
    end)

    assert {:unsubscribe, @property} in Process.get(:calls)
  end

  test "leaves no property message in the caller's mailbox", %{store: store} do
    me = self()
    # A dispatch already in flight when the unsubscribe lands.
    Process.put(:on_unsubscribe, fn -> publish(store, me, [:late]) end)

    WifiScan.access_points("wlan0", FakeVintageNet, timeout_ms: 0)

    refute_received {VintageNet, _, _, _, _}
  end
end
