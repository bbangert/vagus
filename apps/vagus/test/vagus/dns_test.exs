defmodule Vagus.DNSTest do
  @moduledoc "DNS server — static anchors, dynamic add-on records, NXDOMAIN, over UDP loopback."
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

    defp start_dns(st, docker, opts \\ []) do
      start_supervised!(
        {DNS,
         [
           name: nil,
           ip: {127, 0, 0, 1},
           port: 15_300 + rem(System.unique_integer([:positive]), 2000),
           upstream: nil,
           addon_state: st,
           docker: docker
         ] ++ opts},
        id: make_ref()
      )
    end

    # The rebuild task's reply precedes its exit, so once the test has seen
    # the task down the server's mailbox holds the outcome ahead of the next
    # call. A killed task's `:DOWN` reaches the test and the server
    # independently, hence asking again rather than once.
    defp await_rebuild(srv, sup) do
      # `handle_continue` runs before this call is served: the task exists.
      _ = :sys.get_state(srv)

      for pid <- Task.Supervisor.children(sup) do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      end

      assert Enum.any?(1..1_000, fn _ -> :sys.get_state(srv).rebuild == nil end),
             "DNS rebuild never finished"
    end

    defp bridged_ip(ip),
      do: %{"NetworkSettings" => %{"Networks" => %{"hassio" => %{"IPAddress" => ip}}}}

    # One bridged add-on whose inspect the engine holds until `release/1`:
    # the rebuild is provably in flight for as long as the test wants.
    defp held_rebuild(sup) do
      st = start_supervised!({State, name: nil}, id: :addon_state)
      :ok = State.put(addon("bridged_slow", %{}), :started, server: st, access_token: "t")

      engine = FakeEngine.start([{200, bridged_ip("172.30.33.9"), gate: self()}])
      on_exit(fn -> FakeEngine.stop(engine) end)

      srv = start_dns(st, [socket: engine.socket], task_supervisor: sup)
      assert_receive {:fake_engine_held, responder}, 5_000
      {srv, responder}
    end

    defp release(responder), do: send(responder, :release)

    # Dies on the `running/1` call itself, so the caller's exit is never the
    # quiet `:noproc` of a State that isn't there.
    defp dying_state do
      spawn(fn ->
        receive do
          {:"$gen_call", _from, :running} -> exit(:state_went_away)
        end
      end)
    end

    setup do
      %{sup: start_supervised!({Task.Supervisor, name: nil}, id: :rebuild_sup)}
    end

    test "re-registers running add-ons: bridge IP, native anchor, host network skipped", %{
      sup: sup
    } do
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

      engine = FakeEngine.start([{200, bridged_ip("172.30.33.7")}])

      on_exit(fn -> FakeEngine.stop(engine) end)

      srv = start_dns(st, [socket: engine.socket], task_supervisor: sup)
      await_rebuild(srv, sup)

      assert {:ok, {172, 30, 33, 7}} = DNS.resolve("bridged-one", srv)
      assert {:ok, {172, 30, 32, 2}} = DNS.resolve("native-one", srv)
      assert :error = DNS.resolve("host-one", srv)
      assert :error = DNS.resolve("stopped-one", srv)

      assert [%{method: :get, path: "/containers/addon_bridged_one/json"}] =
               FakeEngine.requests(engine)
    end

    test "a failed inspect leaves just that add-on out", %{sup: sup} do
      st = start_supervised!({State, name: nil}, id: :addon_state)
      :ok = State.put(addon("bridged_bad", %{}), :started, server: st, access_token: "t1")
      :ok = State.put(addon("bridged_good", %{}), :started, server: st, access_token: "t2")

      engine =
        FakeEngine.start([
          {404, %{"message" => "no such container"}},
          {200, bridged_ip("172.30.33.8")}
        ])

      on_exit(fn -> FakeEngine.stop(engine) end)

      srv = start_dns(st, [socket: engine.socket], task_supervisor: sup)
      await_rebuild(srv, sup)

      # The script is positional, so pin which add-on got the 404.
      assert [
               %{path: "/containers/addon_bridged_bad/json"},
               %{path: "/containers/addon_bridged_good/json"}
             ] = FakeEngine.requests(engine)

      assert :error = DNS.resolve("bridged-bad", srv)
      assert {:ok, {172, 30, 33, 8}} = DNS.resolve("bridged-good", srv)
    end

    test "a held inspect doesn't block queries or registrations meanwhile", %{sup: sup} do
      {srv, responder} = held_rebuild(sup)

      # Short timeouts: a server doing the inspect itself can't answer until
      # the release below.
      assert {:ok, {172, 30, 32, 3}} = GenServer.call(srv, {:resolve, "dns"}, 500)
      assert :ok = GenServer.call(srv, {:register, "other-addon", {172, 30, 33, 2}}, 500)
      assert :error = GenServer.call(srv, {:resolve, "bridged-slow"}, 500)

      release(responder)
      await_rebuild(srv, sup)
      assert {:ok, {172, 30, 33, 9}} = DNS.resolve("bridged-slow", srv)
      assert {:ok, {172, 30, 33, 2}} = DNS.resolve("other-addon", srv)
    end

    test "a register during the rebuild wins over the rebuilt record", %{sup: sup} do
      {srv, responder} = held_rebuild(sup)
      :ok = DNS.register("bridged-slow", {172, 30, 33, 50}, srv)

      release(responder)
      await_rebuild(srv, sup)
      assert {:ok, {172, 30, 33, 50}} = DNS.resolve("bridged-slow", srv)
    end

    test "an unregister during the rebuild isn't undone by it", %{sup: sup} do
      {srv, responder} = held_rebuild(sup)
      :ok = DNS.unregister("bridged-slow", srv)

      release(responder)
      await_rebuild(srv, sup)
      assert :error = DNS.resolve("bridged-slow", srv)
    end

    test "a crashed rebuild task leaves the server up with what it has", %{sup: sup} do
      {srv, _responder} = held_rebuild(sup)
      :ok = DNS.register("other-addon", {172, 30, 33, 2}, srv)

      log =
        capture_log(fn ->
          for pid <- Task.Supervisor.children(sup), do: Process.exit(pid, :kill)
          await_rebuild(srv, sup)
        end)

      assert log =~ "add-on record rebuild failed"
      assert Process.alive?(srv)
      assert :error = DNS.resolve("bridged-slow", srv)
      assert {:ok, {172, 30, 33, 2}} = DNS.resolve("other-addon", srv)
    end

    test "a State call that exits is logged and rebuilds nothing" do
      log =
        capture_log(fn ->
          assert :error = DNS.resolve("anything", start_dns(dying_state(), []))
        end)

      assert log =~ "Vagus.DNS: rebuild from State failed"
    end

    test "a State that isn't running rebuilds nothing, quietly" do
      missing = :"no_state_#{System.unique_integer([:positive])}"

      log = capture_log(fn -> assert :error = DNS.resolve("anything", start_dns(missing, [])) end)

      refute log =~ "rebuild from State failed"
    end

    # Stands in front of `State`, holding each `running/1` read until the
    # test lets it go: the test sees every rebuild attempt and decides when
    # it proceeds, whatever the retry timer does.
    defp gated_state(st) do
      test = self()
      spawn_link(fn -> gated_state_loop(st, test) end)
    end

    defp gated_state_loop(st, test) do
      receive do
        {:"$gen_call", from, :running} ->
          send(test, {:state_read, self()})

          receive do
            :release -> GenServer.reply(from, State.running(st))
          end

          gated_state_loop(st, test)
      end
    end

    defp next_attempt do
      assert_receive {:state_read, gate}, 5_000
      gate
    end

    defp no_supervisor, do: :"no_sup_#{System.unique_integer([:positive])}"

    test "a rebuild task that can't start is retried off the server, never run inline" do
      st = start_supervised!({State, name: nil}, id: :addon_state)
      :ok = State.put(addon("bridged_late", %{}), :started, server: st, access_token: "t")

      # Gated, so an inspect made on the server process would hold it.
      engine = FakeEngine.start([{200, bridged_ip("172.30.33.11"), gate: self()}])
      on_exit(fn -> FakeEngine.stop(engine) end)

      sup = no_supervisor()

      srv =
        start_dns(gated_state(st), [socket: engine.socket],
          task_supervisor: sup,
          rebuild_retry_ms: 1
        )

      capture_log(fn ->
        # Queued behind the first attempt, so it is served the moment that
        # attempt's failed task start returns.
        first = next_attempt()
        query = :gen_server.send_request(srv, {:resolve, "dns"})
        release(first)
        assert {:reply, {:ok, {172, 30, 32, 3}}} = :gen_server.receive_response(query, 500)

        retry = next_attempt()
        assert [] = FakeEngine.requests(engine)

        start_supervised!({Task.Supervisor, name: sup}, id: :late_sup)
        release(retry)
      end)

      assert_receive {:fake_engine_held, responder}, 5_000
      release(responder)
      await_rebuild(srv, sup)
      assert {:ok, {172, 30, 33, 11}} = DNS.resolve("bridged-late", srv)
    end

    test "a rebuild task that never starts is given up on after a bounded retry" do
      st = start_supervised!({State, name: nil}, id: :addon_state)
      :ok = State.put(addon("bridged_never", %{}), :started, server: st, access_token: "t")

      engine = FakeEngine.start([{200, bridged_ip("172.30.33.12"), gate: self()}])
      on_exit(fn -> FakeEngine.stop(engine) end)

      srv =
        start_dns(gated_state(st), [socket: engine.socket],
          task_supervisor: no_supervisor(),
          rebuild_retry_ms: 0
        )

      log =
        capture_log(fn ->
          for _attempt <- 1..5, do: release(next_attempt())

          # Two round trips: a sixth attempt would be queued by the end of the
          # first and holding the server at the gate during the second.
          _ = :sys.get_state(srv)
          assert :error = GenServer.call(srv, {:resolve, "bridged-never"}, 500)
        end)

      refute_received {:state_read, _gate}
      assert log =~ "giving up"
      assert Process.alive?(srv)
      assert [] = FakeEngine.requests(engine)
    end

    test "the rebuild task dies with its server", %{sup: sup} do
      {srv, _responder} = held_rebuild(sup)
      assert [task] = Task.Supervisor.children(sup)
      ref = Process.monitor(task)

      Process.exit(srv, :kill)
      assert_receive {:DOWN, ^ref, :process, ^task, :killed}, 5_000
    end
  end
end
