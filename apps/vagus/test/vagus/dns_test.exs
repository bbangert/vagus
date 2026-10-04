defmodule Vagus.DNSTest do
  @moduledoc "DNS server — static anchors, dynamic add-on records, NXDOMAIN, over UDP loopback."
  use ExUnit.Case, async: false

  alias Vagus.DNS
  alias Vagus.DNS.Message

  setup do
    port = 15_300 + rem(System.unique_integer([:positive]), 2000)
    server = start_supervised!({DNS, name: nil, ip: {127, 0, 0, 1}, port: port, upstream: nil})
    {:ok, sock} = :gen_udp.open(0, [:binary, active: false])
    on_exit(fn -> :gen_udp.close(sock) end)
    %{server: server, port: port, sock: sock}
  end

  defp ask(sock, port, name, qtype \\ 1) do
    labels =
      name
      |> String.split(".")
      |> Enum.map(fn l -> <<byte_size(l)::8, l::binary>> end)
      |> IO.iodata_to_binary()

    packet =
      <<0x2222::16, 0x0100::16, 1::16, 0::16, 0::16, 0::16>> <>
        labels <> <<0, qtype::16, 1::16>>

    :ok = :gen_udp.send(sock, {127, 0, 0, 1}, port, packet)
    {:ok, {_ip, _p, resp}} = :gen_udp.recv(sock, 0, 2000)
    {:ok, q} = Message.parse_query(resp)
    <<_id::16, flags::16, _qd::16, an::16, _::binary>> = resp
    %{qname: q.qname, ancount: an, rcode: Bitwise.band(flags, 0x000F), addr: tail_addr(resp, an)}
  end

  defp tail_addr(_resp, 0), do: nil
  defp tail_addr(resp, _), do: :binary.part(resp, byte_size(resp), -4) |> :binary.bin_to_list()

  # The name half of the add-on contract: `http://supervisor/` resolves here
  # and then dials port 80 on the answer. The Supervisor-API listener vacated
  # 80 for Core and 80 on the anchor is a DNAT now (`Vagus.Network.Nat`), so
  # this record has to keep pointing at the anchor the rewrite matches on —
  # a zone A record carries no port, which is precisely why the DNAT and not a
  # second listener is what serves it.
  test "resolves the supervisor anchor to .2", %{sock: s, port: p} do
    r = ask(s, p, "supervisor")
    assert r.ancount == 1
    assert r.addr == [172, 30, 32, 2]
  end

  test "the hassio alias answers the same anchor", %{sock: s, port: p} do
    assert ask(s, p, "hassio").addr == [172, 30, 32, 2]
  end

  test "resolves the .local.hass.io suffixed form too", %{sock: s, port: p} do
    assert ask(s, p, "hassio.local.hass.io").addr == [172, 30, 32, 2]
  end

  test "homeassistant resolves to the gateway .1", %{sock: s, port: p} do
    assert ask(s, p, "homeassistant").addr == [172, 30, 32, 1]
  end

  test "a registered add-on hostname resolves to its bridge IP", %{server: srv, sock: s, port: p} do
    :ok = DNS.register("core-mosquitto", {172, 30, 33, 0}, srv)
    assert ask(s, p, "core-mosquitto").addr == [172, 30, 33, 0]
    assert ask(s, p, "core-mosquitto.local.hass.io").addr == [172, 30, 33, 0]
  end

  test "unregister removes a dynamic record (→ NXDOMAIN, no upstream)", %{
    server: srv,
    sock: s,
    port: p
  } do
    :ok = DNS.register("temp-addon", {172, 30, 33, 5}, srv)
    assert ask(s, p, "temp-addon").ancount == 1
    :ok = DNS.unregister("temp-addon", srv)
    assert ask(s, p, "temp-addon").rcode == 3
  end

  test "an owned name queried as AAAA is NOERROR with no answers (not NXDOMAIN)", %{
    sock: s,
    port: p
  } do
    r = ask(s, p, "supervisor", 28)
    assert r.rcode == 0
    assert r.ancount == 0
  end

  test "a relay that cannot start (task supervisor down) drops the query, not the server" do
    port = 17_400 + rem(System.unique_integer([:positive]), 2000)

    server =
      start_supervised!(
        {DNS,
         name: nil,
         ip: {127, 0, 0, 1},
         port: port,
         upstream: "127.0.0.1",
         task_supervisor: :vagus_dns_test_no_such_supervisor},
        id: :no_task_supervisor
      )

    {:ok, sock} = :gen_udp.open(0, [:binary, active: false])
    on_exit(fn -> :gen_udp.close(sock) end)
    :ok = DNS.register("kept-addon", {172, 30, 33, 9}, server)

    # A miss with an upstream configured goes to the relay path, which fails.
    query = <<0x3333::16, 0x0100::16, 1::16, 0::16, 0::16, 0::16, 7, "unknown", 0, 1::16, 1::16>>
    :ok = :gen_udp.send(sock, {127, 0, 0, 1}, port, query)
    assert {:error, :timeout} = :gen_udp.recv(sock, 0, 200)

    # Same process, dynamic records intact.
    assert Process.alive?(server)
    assert ask(sock, port, "kept-addon").addr == [172, 30, 33, 9]
  end

  test "a relay killed from outside is counted out of the in-flight set" do
    port = 17_400 + rem(System.unique_integer([:positive]), 2000)
    sup = start_supervised!({Task.Supervisor, name: :vagus_dns_test_relays})

    # TEST-NET-1 upstream: the query goes out but no answer ever comes, so
    # the relay sits in its recv until killed.
    server =
      start_supervised!(
        {DNS,
         name: nil,
         ip: {127, 0, 0, 1},
         port: port,
         upstream: "192.0.2.1",
         task_supervisor: :vagus_dns_test_relays},
        id: :relay_kill
      )

    {:ok, sock} = :gen_udp.open(0, [:binary, active: false])
    on_exit(fn -> :gen_udp.close(sock) end)

    query = <<0x4444::16, 0x0100::16, 1::16, 0::16, 0::16, 0::16, 7, "unknown", 0, 1::16, 1::16>>
    :ok = :gen_udp.send(sock, {127, 0, 0, 1}, port, query)

    assert [relay] = wait_for(fn -> Task.Supervisor.children(sup) end, &(length(&1) == 1))
    assert map_size(:sys.get_state(server).relays) == 1

    # An external kill skips the relay's own cleanup; the monitor still sees it.
    Process.exit(relay, :kill)
    assert wait_for(fn -> map_size(:sys.get_state(server).relays) end, &(&1 == 0)) == 0
  end

  defp wait_for(fun, done?, tries \\ 50) do
    value = fun.()

    cond do
      done?.(value) ->
        value

      tries == 0 ->
        value

      true ->
        Process.sleep(20)
        wait_for(fun, done?, tries - 1)
    end
  end

  test "unknown name with no upstream → NXDOMAIN", %{sock: s, port: p} do
    r = ask(s, p, "nonexistent-thing")
    assert r.ancount == 0
    assert r.rcode == 3
  end

  test "resolve/2 checks the zone without UDP", %{server: srv} do
    assert {:ok, {172, 30, 32, 3}} = DNS.resolve("dns", srv)
    assert :error = DNS.resolve("whatever", srv)
  end

  describe "rebuild from Vagus.Addon.State on (re)start" do
    alias Vagus.Addon.{Config, State}
    alias Vagus.Test.FakeEngine

    defp addon(slug, extra) do
      {:ok, config} =
        Config.parse(
          Map.merge(
            %{
              "name" => slug,
              "version" => "1",
              "slug" => slug,
              "description" => "d",
              "arch" => ["amd64"],
              "image" => "x/y"
            },
            extra
          )
        )

      config
    end

    defp start_dns(st, docker) do
      start_supervised!(
        {DNS,
         name: nil,
         ip: {127, 0, 0, 1},
         port: 15_300 + rem(System.unique_integer([:positive]), 2000),
         upstream: nil,
         addon_state: st,
         docker: docker},
        id: make_ref()
      )
    end

    test "re-registers running add-ons: bridge IP, native anchor, host network skipped" do
      st = start_supervised!({State, name: nil}, id: :addon_state)

      for {config, tok} <- [
            {addon("bridged_one", %{}), "t1"},
            {addon("native_one", %{"backend" => "native"}), "t2"},
            {addon("host_one", %{"host_network" => true}), "t3"}
          ] do
        :ok = State.put(config, :started, server: st, access_token: tok)
      end

      # A stopped add-on is never inspected.
      :ok = State.put(addon("stopped_one", %{}), :stopped, server: st)

      engine =
        FakeEngine.start([
          {200,
           %{"NetworkSettings" => %{"Networks" => %{"hassio" => %{"IPAddress" => "172.30.33.7"}}}}}
        ])

      on_exit(fn -> FakeEngine.stop(engine) end)

      srv = start_dns(st, socket: engine.socket)

      assert {:ok, {172, 30, 33, 7}} = DNS.resolve("bridged-one", srv)
      assert {:ok, {172, 30, 32, 2}} = DNS.resolve("native-one", srv)
      assert :error = DNS.resolve("host-one", srv)
      assert :error = DNS.resolve("stopped-one", srv)

      assert [%{method: :get, path: "/containers/addon_bridged_one/json"}] =
               FakeEngine.requests(engine)
    end

    test "a failed inspect leaves just that add-on out" do
      st = start_supervised!({State, name: nil}, id: :addon_state)
      :ok = State.put(addon("bridged_two", %{}), :started, server: st, access_token: "t")

      engine = FakeEngine.start([{404, %{"message" => "no such container"}}])
      on_exit(fn -> FakeEngine.stop(engine) end)

      srv = start_dns(st, socket: engine.socket)
      assert :error = DNS.resolve("bridged-two", srv)
      assert {:ok, {172, 30, 32, 3}} = DNS.resolve("dns", srv)
    end
  end
end
