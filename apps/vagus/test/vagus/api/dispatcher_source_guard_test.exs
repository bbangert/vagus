defmodule Vagus.API.DispatcherSourceGuardTest do
  @moduledoc """
  The source allowlist must cover **everything Bandit serves**, which is
  `Vagus.API.Dispatcher` — not `Vagus.API.Router`.

  This file exists because of a real miss: the guard originally lived as a
  router plug, and the dispatcher's ingress clause forwards
  `["ingress", token | _]` to `Vagus.API.IngressProxy` without ever entering
  the router pipeline. So `/supervisor/ping` was refused from a foreign host
  while `/ingress/{token}/…` — a cookie-authenticated reverse proxy into an
  add-on's web UI, with a WebSocket upgrade — stayed open to the LAN.
  Nothing in the suite pinned the pipeline's *reach*, so everything passed.

  Every test here therefore goes through `Dispatcher.call/2`, the real entry
  point, and at least one exercises the ingress branch specifically.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vagus.API.{Dispatcher, SourceGuard}

  @opts Dispatcher.init([])

  setup do
    prev = Application.get_env(:vagus, :api_source_guard)
    Application.put_env(:vagus, :api_source_guard, true)
    # Only loopback is local; anything else is "another host on the LAN".
    :persistent_term.put({SourceGuard, :local_addresses}, MapSet.new([{127, 0, 0, 1}]))

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

  defp call(path, remote_ip) do
    :get
    |> conn(path)
    |> Map.put(:remote_ip, remote_ip)
    |> Dispatcher.call(@opts)
  end

  @foreign {192, 168, 2, 12}
  @local {127, 0, 0, 1}

  describe "a foreign source is refused on every branch of the dispatcher" do
    test "the ingress proxy branch — the one that used to be open" do
      # A bogus token still takes the ingress clause (it isn't one of the
      # three router literals), so this proves the guard runs BEFORE the
      # dispatch decision. Before the fix this answered 401 from the proxy.
      conn = call("/ingress/deadbeefdeadbeefdeadbeefdeadbeef/", @foreign)

      assert conn.status == 403
      assert conn.resp_body == ""
      assert conn.halted
    end

    test "the router branch" do
      conn = call("/supervisor/ping", @foreign)

      assert conn.status == 403
      assert conn.halted
    end

    test "the ingress literals that are real router routes" do
      # `panels`/`session`/`validate_session` go to the router, not the proxy.
      for path <- ["/ingress/panels", "/ingress/session", "/ingress/validate_session"] do
        assert call(path, @foreign).status == 403
      end
    end
  end

  describe "a local source reaches its handler" do
    test "the ingress branch is reached, not refused" do
      # Anything but 403 proves the guard let it through to the proxy; the
      # proxy's own answer (401 for an unknown token) is not this test's
      # business.
      conn = call("/ingress/deadbeefdeadbeefdeadbeefdeadbeef/", @local)

      refute conn.status == 403
    end

    test "the router branch is reached, not refused" do
      conn = call("/supervisor/ping", @local)

      refute conn.status == 403
    end
  end

  test "with the guard off, a foreign source reaches its handler" do
    Application.put_env(:vagus, :api_source_guard, false)

    refute call("/supervisor/ping", @foreign).status == 403
    refute call("/ingress/deadbeefdeadbeefdeadbeefdeadbeef/", @foreign).status == 403
  end

  test "a nil peer is refused with a 403, not a crash" do
    # `:inet.ntoa(nil)` raises; formatting a refusal must not turn the
    # decision the guard made into a 500.
    conn = call("/supervisor/ping", nil)

    assert conn.status == 403
  end
end
