defmodule Vagus.Backend.Network.WifiScan do
  @moduledoc """
  Fresh access-point list for `GET network/interface/:ifname/accesspoints`.

  `vintage_net_wifi` only keeps the `access_points` property current while
  wpa_supplicant scans on its own, which it never does with no network
  configured, so reading the property alone answers an empty list. Upstream
  (`NetworkManager.scan_wifi`) requests a scan, sleeps 5 s, then reads; this
  keeps the same 5 s bound but returns once updates stop arriving.

  `vintage_net` is a parameter (the real `VintageNet` on target) because the
  dependency is absent from `:host`, where the tests run.
  """

  require Logger

  @timeout_ms 5_000

  # wpa_supplicant publishes one property update per `CTRL-EVENT-BSS-ADDED`,
  # then a full refresh on `CTRL-EVENT-SCAN-RESULTS`, so the first update is
  # often a partial list. Return once updates have been quiet this long.
  @settle_ms 500

  @spec access_points(String.t(), module(), keyword()) :: [term()]
  def access_points(ifname, vintage_net, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @timeout_ms)
    settle_ms = Keyword.get(opts, :settle_ms, @settle_ms)
    property = ["interface", ifname, "wifi", "access_points"]
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    # Subscribe before the scan so no update can land in between.
    :ok = vintage_net.subscribe(property)

    try do
      if request_scan(vintage_net, ifname) == :ok do
        await_settled(property, deadline, settle_ms, false)
      end

      vintage_net.get(property, [])
    after
      vintage_net.unsubscribe(property)
      flush(property)
    end
  end

  # The ioctl ends in a `:gen_statem.call` to the interface process, which
  # exits when the interface isn't running.
  defp request_scan(vintage_net, ifname) do
    case vintage_net.scan(ifname) do
      :ok -> :ok
      {:ok, _} -> :ok
      # wpa_supplicant's trimmed `SCAN` reply when one is already running;
      # that scan's results still land on the property.
      {:error, "FAIL-BUSY"} -> :ok
      {:error, reason} -> scan_failed(ifname, reason)
    end
  catch
    :exit, reason -> scan_failed(ifname, reason)
  end

  defp scan_failed(ifname, reason) do
    Logger.warning("WiFi scan on #{ifname} failed, answering cached results: #{inspect(reason)}")
    :error
  end

  defp await_settled(property, deadline, settle_ms, seen?) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    wait = if seen?, do: min(remaining, settle_ms), else: remaining

    receive do
      {VintageNet, ^property, _old, _new, _meta} ->
        await_settled(property, deadline, settle_ms, true)
    after
      wait -> :ok
    end
  end

  # A dispatch can race the unsubscribe; the caller is a request process
  # that must not keep it.
  defp flush(property) do
    receive do
      {VintageNet, ^property, _old, _new, _meta} -> flush(property)
    after
      0 -> :ok
    end
  end
end
