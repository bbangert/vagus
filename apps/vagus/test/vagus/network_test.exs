defmodule Vagus.NetworkTest do
  use ExUnit.Case, async: false

  alias Vagus.Network

  describe "source_bind_opts/0 (ingress client-IP parity)" do
    # Regression guard for a device-found gap: Vagus runs on the host, so
    # without an explicit bind its add-on connections originate from the
    # bridge gateway .1 rather than the supervisor anchor .2. Add-ons that
    # filter on client IP reject that (core_configurator answered 420 and
    # banned .1, surfacing to Core as a 502).
    setup do
      original = Application.get_env(:vagus, :ingress_source_ip)
      on_exit(fn -> Application.put_env(:vagus, :ingress_source_ip, original) end)
      :ok
    end

    test "returns [] when unset, so :host/:test never bind a missing address" do
      Application.delete_env(:vagus, :ingress_source_ip)
      assert Network.source_bind_opts() == []
    end

    test "parses a configured string into an inet tuple" do
      Application.put_env(:vagus, :ingress_source_ip, "172.30.32.2")
      assert Network.source_bind_opts() == [ip: {172, 30, 32, 2}]
    end

    test "the configured value is the supervisor anchor, not the gateway" do
      Application.put_env(:vagus, :ingress_source_ip, Network.supervisor_ip())
      assert Network.source_bind_opts() == [ip: {172, 30, 32, 2}]
      refute Network.source_bind_opts() == [ip: {172, 30, 32, 1}]
    end

    test "wrong-typed config degrades to [] instead of raising" do
      # Regression: the original `case` had only nil/binary/tuple clauses, so
      # any other type raised CaseClauseError and took ingress connection
      # setup down at runtime over a config typo (Copilot, PR #14).
      for bad <- [42, [1, 2, 3], %{a: 1}, :atom, 1.5] do
        Application.put_env(:vagus, :ingress_source_ip, bad)
        assert Network.source_bind_opts() == [], "expected [] for #{inspect(bad)}"
      end
    end

    # The other half of the same rule, and it pulls the opposite way. A
    # `host_network: true` add-on has no bridge address, so the proxy reaches
    # it on the host's own loopback — and binding a non-loopback source there
    # makes the add-on see a peer that isn't local. Device-observed on the
    # rpi3 2026-07-29: byte-identical requests to ESPHome's device builder on
    # 127.0.0.1:63642 got 200 unbound and **403 Forbidden** bound to .2, so
    # the whole dashboard was unreachable through ingress. Both add-ons are
    # real and they want opposite things; the destination decides.
    test "a loopback destination gets no bind, even when one is configured" do
      Application.put_env(:vagus, :ingress_source_ip, "172.30.32.2")

      for dest <- ["127.0.0.1", "127.1.2.3", {127, 0, 0, 1}, "::1", {0, 0, 0, 0, 0, 0, 0, 1}] do
        assert Network.source_bind_opts(dest) == [], "expected no bind for #{inspect(dest)}"
      end
    end

    test "a bridge destination keeps the anchor bind" do
      Application.put_env(:vagus, :ingress_source_ip, "172.30.32.2")

      for dest <- ["172.30.32.5", {172, 30, 32, 5}, "192.168.2.10"] do
        assert Network.source_bind_opts(dest) == [ip: {172, 30, 32, 2}],
               "expected the anchor bind for #{inspect(dest)}"
      end
    end

    # `:ingress_source_ip` and `:api_bind_ip` are both the anchor on target and
    # both now go through the same `parse_ip/1`, which makes them easy to
    # conflate. They answer different questions — where ingress connections
    # come FROM vs. where the Supervisor API listens — so the API's rebind onto
    # an internal port must not drag the ingress source with it.
    test "the source bind is its own key, unaffected by :api_bind_ip" do
      prev = Application.get_env(:vagus, :api_bind_ip)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:vagus, :api_bind_ip),
          else: Application.put_env(:vagus, :api_bind_ip, prev)
      end)

      Application.put_env(:vagus, :api_bind_ip, "10.9.9.9")

      Application.put_env(:vagus, :ingress_source_ip, "172.30.32.2")
      assert Network.source_bind_opts() == [ip: {172, 30, 32, 2}]

      Application.delete_env(:vagus, :ingress_source_ip)
      assert Network.source_bind_opts() == []
    end

    test "an unreadable destination keeps the bind rather than silently dropping it" do
      Application.put_env(:vagus, :ingress_source_ip, "172.30.32.2")
      assert Network.source_bind_opts("not-an-ip") == [ip: {172, 30, 32, 2}]
      refute Network.loopback?("not-an-ip")
    end

    test "loopback?/1 does not mistake a non-loopback address for one" do
      # `172.30.32.1` and `10.x`/`192.168.x` are the addresses that MUST keep
      # the bind — a false positive here silently reintroduces the .1 problem
      # `source_bind_opts/0` exists to fix.
      for ip <- [
            "172.30.32.1",
            "172.30.32.2",
            "192.168.2.149",
            "10.0.0.1",
            "128.0.0.1",
            # Near the boundary on purpose: a `String.starts_with?(ip, "127")`
            # implementation passes every address above but fails these two.
            "12.7.0.1",
            "1.2.7.0"
          ] do
        refute Network.loopback?(ip), "#{ip} was treated as loopback"
      end

      # …and the whole of 127/8 is loopback, not just 127.0.0.1.
      for ip <- ["127.0.0.1", "127.0.0.2", "127.255.255.254", "127.1.1.1"] do
        assert Network.loopback?(ip), "#{ip} was not treated as loopback"
      end
    end

    test "rejects malformed tuples rather than deferring the failure to connect()" do
      # These are tuples, so the old clause passed them straight through as
      # socket opts; the failure then surfaced inside connect() as an opaque
      # :einval. Wrong arity and an out-of-range octet must both be caught.
      for bad <- [{1, 2}, {999, 0, 0, 1}, {-1, 0, 0, 1}, {:a, :b, :c, :d}] do
        Application.put_env(:vagus, :ingress_source_ip, bad)
        assert Network.source_bind_opts() == [], "expected [] for #{inspect(bad)}"
      end
    end

    test "still accepts a valid IPv6 tuple" do
      Application.put_env(:vagus, :ingress_source_ip, {0, 0, 0, 0, 0, 0, 0, 1})
      assert Network.source_bind_opts() == [ip: {0, 0, 0, 0, 0, 0, 0, 1}]
    end

    test "accepts a tuple as-is and ignores an unparseable string" do
      Application.put_env(:vagus, :ingress_source_ip, {172, 30, 32, 2})
      assert Network.source_bind_opts() == [ip: {172, 30, 32, 2}]

      Application.put_env(:vagus, :ingress_source_ip, "not-an-ip")
      assert Network.source_bind_opts() == []
    end
  end

  describe "host_network_ip/1 (which host address a host_network add-on answers on)" do
    # Hermetic on purpose: `172.30.32.1` doesn't exist on a CI host, so the
    # fallback case asserts the *decision*, never a connection to it.
    test "a listening loopback port resolves to loopback" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      on_exit(fn -> :gen_tcp.close(listen) end)
      {:ok, port} = :inet.port(listen)

      assert Network.host_network_ip(port) == "127.0.0.1"
    end

    test "a refused loopback port falls back to the bridge gateway" do
      # Bound then closed, so the port is real, unused, and refuses rather
      # than being some unrelated service a fixed number might have hit.
      {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      {:ok, port} = :inet.port(listen)
      :ok = :gen_tcp.close(listen)

      assert Network.host_network_ip(port) == Network.gateway()
    end
  end

  describe "parse_ip/1 + format_ip/1 (shared by every address config key)" do
    test "parses strings and passes tuples through" do
      assert Network.parse_ip("172.30.32.2") == {:ok, {172, 30, 32, 2}}
      assert Network.parse_ip("::1") == {:ok, {0, 0, 0, 0, 0, 0, 0, 1}}
      assert Network.parse_ip({172, 30, 32, 2}) == {:ok, {172, 30, 32, 2}}
    end

    test "rejects everything that is not an address" do
      for bad <- ["not-an-ip", "", 42, [1, 2, 3], %{a: 1}, :atom, {1, 2}, {999, 0, 0, 1}] do
        assert Network.parse_ip(bad) == :error, "expected :error for #{inspect(bad)}"
      end
    end

    test "format_ip/1 round-trips" do
      assert Network.format_ip({172, 30, 32, 2}) == "172.30.32.2"
      assert {:ok, ip} = Network.parse_ip(Network.supervisor_ip())
      assert Network.format_ip(ip) == Network.supervisor_ip()
    end
  end

  describe "IP plan (hermetic)" do
    test "spec/0 pins the hassio subnet, gateway, dynamic range + bridge name" do
      assert Network.spec() == %Vagus.Runtime.Engine.NetworkSpec{
               name: "hassio",
               driver: :bridge,
               subnet: "172.30.32.0/23",
               gateway: "172.30.32.1",
               ip_range: "172.30.33.0/24",
               interface_name: "hassio"
             }
    end

    test "fixed anchors match the contract" do
      assert Network.anchors() == %{
               gateway: "172.30.32.1",
               supervisor: "172.30.32.2",
               dns: "172.30.32.3",
               audio: "172.30.32.4",
               cli: "172.30.32.5",
               observer: "172.30.32.6"
             }

      assert Network.gateway() == "172.30.32.1"
      assert Network.supervisor_ip() == "172.30.32.2"
      assert Network.dns_ip() == "172.30.32.3"
      assert Network.name() == "hassio"
    end
  end

  describe "container_interface?/1" do
    test "names the engines' bridges, and only those" do
      for name <- ["hassio", "balena0", "br-3f2a", "podman0", "podman12", ~c"podman1"] do
        assert Network.container_interface?(name), inspect(name)
      end

      for name <- ["eth0", "wlan0", "podmanx", "podman", "podman0x", "end0"] do
        refute Network.container_interface?(name), name
      end
    end
  end

  describe "ensure/1 on Engine.Fake" do
    alias Vagus.Runtime.Engine.Fake

    setup do
      fake = Fake.start()
      %{fake: fake, opts: [engine: Fake, fake: fake]}
    end

    test "creates the hassio bridge from spec/0", %{fake: fake, opts: opts} do
      assert Network.ensure(opts) == :ok
      assert [{:ensure_network, [spec]}] = Fake.calls(fake)
      assert spec == Network.spec()
    end

    test "surfaces an engine error", %{fake: fake, opts: opts} do
      Fake.fail_next(fake, :ensure_network, :unavailable)
      assert Network.ensure(opts) == {:error, :unavailable}
    end
  end

  describe "the host-kept bridge (podman)" do
    alias Vagus.Runtime.Engine.Fake

    # Each `ip` call reports itself with the engine calls made before it.
    defp ip_fake(fake, answer \\ fn _args -> {"", 0} end) do
      test = self()

      fn bin, args ->
        send(test, {:ip, bin, args, Fake.calls(fake)})
        answer.(args)
      end
    end

    defp ip_calls do
      receive do
        {:ip, "ip", args, engine_calls} -> [{args, engine_calls} | ip_calls()]
      after
        0 -> []
      end
    end

    setup do
      %{fake: Fake.start()}
    end

    test "is on only on a board, whatever the engine" do
      refute Network.host_bridge?()
      refute Network.host_bridge?(engine: Vagus.Runtime.Engine.Podman)

      previous = Application.fetch_env(:vagus, :runtime_host)
      Application.put_env(:vagus, :runtime_host, true)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:vagus, :runtime_host, value)
          :error -> Application.delete_env(:vagus, :runtime_host)
        end
      end)

      assert Network.host_bridge?(engine: Fake)
      refute Network.host_bridge?(host_bridge: false)
    end

    test "the bridge, its dummy port, the gateway, then both up, in that order" do
      assert Network.bridge_commands() == [
               ["link", "add", "hassio", "type", "bridge"],
               ["link", "add", "hassio-anchor", "type", "dummy"],
               ["link", "set", "hassio-anchor", "master", "hassio", "up"],
               ["addr", "add", "172.30.32.1/23", "dev", "hassio"],
               ["link", "set", "hassio", "up"]
             ]
    end

    test "ensure/1 makes the network first, then runs every bridge command",
         %{fake: fake} do
      assert Network.ensure(engine: Fake, fake: fake, host_bridge: true, ip_cmd: ip_fake(fake)) ==
               :ok

      calls = ip_calls()
      assert Enum.map(calls, &elem(&1, 0)) == Network.bridge_commands()

      for {_args, engine_calls} <- calls,
          do: assert([{:ensure_network, [_spec]}] = engine_calls)
    end

    test "the bridge is made even when the engine could not make its network",
         %{fake: fake} do
      Fake.fail_next(fake, :ensure_network, :unavailable)
      opts = [engine: Fake, fake: fake, host_bridge: true, ip_cmd: ip_fake(fake)]

      assert Network.ensure(opts) == {:error, :unavailable}
      assert length(ip_calls()) == length(Network.bridge_commands())
    end

    test "no bridge command under balena-engine", %{fake: fake} do
      assert Network.ensure(engine: Fake, fake: fake, ip_cmd: ip_fake(fake)) == :ok
      assert ip_calls() == []
    end

    test "what already exists counts as done", %{fake: fake} do
      exists = fn _args -> {"ip: RTNETLINK answers: File exists\n", 2} end
      assert Network.ensure_bridge(ip_cmd: ip_fake(fake, exists)) == :ok
      assert length(ip_calls()) == length(Network.bridge_commands())
    end

    test "ensure/1 logs a bridge it could not keep and answers for the network",
         %{fake: fake} do
      fails = fn _args -> {"ip: RTNETLINK answers: Operation not supported\n", 2} end
      opts = [engine: Fake, fake: fake, host_bridge: true, ip_cmd: ip_fake(fake, fails)]

      log = ExUnit.CaptureLog.capture_log(fn -> assert Network.ensure(opts) == :ok end)
      assert log =~ "the hassio bridge is not kept"
      assert log =~ "Operation not supported"
    end

    test "a real failure stops the steps and is returned", %{fake: fake} do
      no_bridge = fn
        ["link", "add", "hassio", "type", "bridge"] ->
          {"ip: RTNETLINK answers: Operation not supported\n", 2}

        _args ->
          {"", 0}
      end

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {["link", "add", "hassio", "type", "bridge"], "ip: RTNETLINK" <> _, 2}} =
                 Network.ensure_bridge(ip_cmd: ip_fake(fake, no_bridge))
      end)

      assert length(ip_calls()) == 1
    end
  end
end
