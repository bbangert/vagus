defmodule Vagus.DNSTest do
  @moduledoc "DNS server — static anchors, app records from a directory, NXDOMAIN, over UDP loopback."
  use ExUnit.Case, async: false

  alias Vagus.DNS
  alias Vagus.DNS.Message

  setup do
    directory = :"dns_test_directory_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: directory})

    server =
      start_supervised!(
        {DNS, name: nil, ip: {127, 0, 0, 1}, port: 0, upstream: nil, directory: directory}
      )

    port = bound_port(server)

    {:ok, sock} = :gen_udp.open(0, [:binary, active: false])
    on_exit(fn -> :gen_udp.close(sock) end)
    %{server: server, port: port, sock: sock, directory: directory}
  end

  # An app process stands behind each name: the key is its, valued with the
  # IP, and goes when it does.
  defp app_record(directory, name, ip) do
    test = self()

    owner =
      spawn(fn ->
        {:ok, _} = Registry.register(directory, {:dns, name}, ip)
        send(test, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered
    on_exit(fn -> Process.exit(owner, :kill) end)
    owner
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

  test "an app's name resolves to the IP its key holds", %{directory: d, sock: s, port: p} do
    app_record(d, "core-mosquitto", "172.30.33.0")
    assert ask(s, p, "core-mosquitto").addr == [172, 30, 33, 0]
    assert ask(s, p, "core-mosquitto.local.hass.io").addr == [172, 30, 33, 0]
  end

  test "a name goes with its app's process (→ NXDOMAIN, no upstream)", %{
    directory: d,
    sock: s,
    port: p
  } do
    owner = app_record(d, "temp-app", "172.30.33.5")
    assert ask(s, p, "temp-app").ancount == 1

    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    # The partition drops the key on the owner's exit, after its DOWN here.
    assert wait_for(fn -> Registry.lookup(d, {:dns, "temp-app"}) end, &(&1 == [])) == []
    assert ask(s, p, "temp-app").rcode == 3
  end

  test "an app record wins over an anchor of the same name", %{directory: d, sock: s, port: p} do
    app_record(d, "observer", "172.30.33.6")
    assert ask(s, p, "observer").addr == [172, 30, 33, 6]
  end

  test "a value that is not an address answers as if absent, and the server goes on", %{
    directory: d,
    sock: s,
    port: p
  } do
    app_record(d, "bad-app", "not-an-ip")
    app_record(d, "hassio", {172, 30, 33, 7})
    app_record(d, "v6-app", "::1")

    assert ask(s, p, "bad-app").rcode == 3
    assert ask(s, p, "v6-app").rcode == 3
    assert ask(s, p, "hassio").addr == [172, 30, 32, 2]
    assert ask(s, p, "supervisor").addr == [172, 30, 32, 2]
  end

  test "an app's name queried as AAAA is NOERROR with no answers", %{
    directory: d,
    sock: s,
    port: p
  } do
    app_record(d, "core-ssh", "172.30.33.8")
    r = ask(s, p, "core-ssh", 28)
    assert {r.rcode, r.ancount} == {0, 0}
  end

  test "with no directory to read, the anchors still answer" do
    server =
      start_supervised!(
        {DNS,
         name: nil, ip: {127, 0, 0, 1}, port: 0, upstream: nil, directory: :no_such_directory},
        id: :no_directory
      )

    port = bound_port(server)

    {:ok, sock} = :gen_udp.open(0, [:binary, active: false])
    on_exit(fn -> :gen_udp.close(sock) end)
    assert ask(sock, port, "supervisor").addr == [172, 30, 32, 2]
    assert ask(sock, port, "core-ssh").rcode == 3
  end

  test "an owned name queried as AAAA is NOERROR with no answers (not NXDOMAIN)", %{
    sock: s,
    port: p
  } do
    r = ask(s, p, "supervisor", 28)
    assert r.rcode == 0
    assert r.ancount == 0
  end

  test "a relay that cannot start (task supervisor down) drops the query, not the server", %{
    directory: d
  } do
    server =
      start_supervised!(
        {DNS,
         name: nil,
         ip: {127, 0, 0, 1},
         port: 0,
         upstream: "127.0.0.6",
         task_supervisor: :vagus_dns_test_no_such_supervisor,
         directory: d},
        id: :no_task_supervisor
      )

    port = bound_port(server)

    {:ok, sock} = :gen_udp.open(0, [:binary, active: false])
    on_exit(fn -> :gen_udp.close(sock) end)
    app_record(d, "kept-app", "172.30.33.9")

    # A miss with an upstream configured goes to the relay path, which fails.
    query = <<0x3333::16, 0x0100::16, 1::16, 0::16, 0::16, 0::16, 7, "unknown", 0, 1::16, 1::16>>
    :ok = :gen_udp.send(sock, {127, 0, 0, 1}, port, query)
    assert {:error, :timeout} = :gen_udp.recv(sock, 0, 200)

    assert Process.alive?(server)
    assert ask(sock, port, "kept-app").addr == [172, 30, 33, 9]
  end

  test "a relay killed from outside is counted out of the in-flight set" do
    sup = start_supervised!({Task.Supervisor, name: :vagus_dns_test_relays})

    # The query goes out but no answer ever comes, so the relay sits in its
    # recv until killed.
    upstream_port = black_hole({127, 0, 0, 6})

    server =
      start_supervised!(
        {DNS,
         name: nil,
         ip: {127, 0, 0, 1},
         port: 0,
         upstream: "127.0.0.6",
         upstream_port: upstream_port,
         task_supervisor: :vagus_dns_test_relays},
        id: :relay_kill
      )

    port = bound_port(server)

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

  # A bound socket that never reads, so a query to it is never answered and
  # never refused. `port` defaults to a fresh one.
  defp black_hole(ip, port \\ 0) do
    {:ok, port} = :inet.port(black_hole_socket(ip, port))
    port
  end

  defp black_hole_socket(ip, port) do
    {:ok, s} = :gen_udp.open(port, [:binary, {:ip, ip}, active: false])
    on_exit(fn -> :gen_udp.close(s) end)
    s
  end

  defp bound_port(server), do: :sys.get_state(server).port

  # Free for the fake upstreams, unlike a fixed range another run on the
  # machine may hold.
  defp free_port do
    {:ok, l} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(l)
    :gen_tcp.close(l)
    port
  end

  defp tcp_client(port) do
    {:ok, tcp} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: 2, active: false])
    on_exit(fn -> :gen_tcp.close(tcp) end)
    tcp
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

  describe "forwarding" do
    # A resolver on `ip`:`port` answering every A query with `answer`.
    defp fake_upstream(ip, port, answer) do
      test = self()

      pid =
        spawn(fn ->
          {:ok, s} = :gen_udp.open(port, [:binary, {:ip, ip}, active: false])
          send(test, :upstream_ready)
          serve(s, answer)
        end)

      assert_receive :upstream_ready
      on_exit(fn -> Process.exit(pid, :kill) end)
    end

    # Every answer truncated and empty, as a reply too large for UDP comes.
    defp truncating_upstream(ip, port) do
      test = self()

      pid =
        spawn(fn ->
          {:ok, s} = :gen_udp.open(port, [:binary, {:ip, ip}, active: false])
          send(test, :upstream_ready)
          truncate(s)
        end)

      assert_receive :upstream_ready
      on_exit(fn -> Process.exit(pid, :kill) end)
    end

    defp truncate(s) do
      {:ok, {host, port, packet}} = :gen_udp.recv(s, 0)
      {:ok, query} = Message.parse_query(packet)
      <<id::16, flags::16, rest::binary>> = Message.answer(query, [])
      :ok = :gen_udp.send(s, host, port, <<id::16, Bitwise.bor(flags, 0x0200)::16, rest::binary>>)
      truncate(s)
    end

    defp tcp_upstream(ip, port, answer) do
      test = self()

      pid =
        spawn(fn ->
          {:ok, l} =
            :gen_tcp.listen(port, [:binary, packet: 2, active: false, ip: ip, reuseaddr: true])

          send(test, :upstream_ready)
          tcp_serve(l, answer)
        end)

      assert_receive :upstream_ready
      on_exit(fn -> Process.exit(pid, :kill) end)
    end

    defp tcp_serve(l, answer) do
      {:ok, c} = :gen_tcp.accept(l)
      {:ok, packet} = :gen_tcp.recv(c, 0)
      {:ok, query} = Message.parse_query(packet)
      :ok = :gen_tcp.send(c, Message.answer(query, [answer]))
      :gen_tcp.close(c)
      tcp_serve(l, answer)
    end

    defp serve(s, answer) do
      {:ok, {host, port, packet}} = :gen_udp.recv(s, 0)
      {:ok, query} = Message.parse_query(packet)
      :ok = :gen_udp.send(s, host, port, Message.answer(query, [answer]))
      serve(s, answer)
    end

    defp forwarding_server(name_servers, upstream, extra \\ []) do
      upstream_port = free_port()
      start_supervised!({Task.Supervisor, name: :vagus_dns_forward_relays})

      server =
        start_supervised!(
          {DNS,
           [
             name: nil,
             ip: {127, 0, 0, 1},
             port: 0,
             upstream: upstream,
             upstream_port: upstream_port,
             name_servers: name_servers,
             task_supervisor: :vagus_dns_forward_relays,
             directory: :no_such_directory
           ] ++ extra},
          id: :forwarding
        )

      {:ok, sock} = :gen_udp.open(0, [:binary, active: false])
      on_exit(fn -> :gen_udp.close(sock) end)
      %{server: server, port: bound_port(server), upstream_port: upstream_port, sock: sock}
    end

    test "a miss goes to the LAN's name servers, not the fallback" do
      lan = [%{address: {127, 0, 0, 2}, from: ["eth0"]}]
      %{port: p, upstream_port: up, sock: s} = forwarding_server(fn -> lan end, "127.0.0.4")
      fake_upstream({127, 0, 0, 2}, up, {10, 0, 0, 2})
      fake_upstream({127, 0, 0, 4}, up, {10, 0, 0, 4})

      assert ask(s, p, "nas.lan").addr == [10, 0, 0, 2]
    end

    test "a lease change reaches the next query" do
      servers = Agent.start_link(fn -> [{127, 0, 0, 2}] end) |> elem(1)
      read = fn -> Agent.get(servers, & &1) end
      %{port: p, upstream_port: up, sock: s} = forwarding_server(read, nil)
      fake_upstream({127, 0, 0, 2}, up, {10, 0, 0, 2})
      fake_upstream({127, 0, 0, 3}, up, {10, 0, 0, 3})

      assert ask(s, p, "nas.lan").addr == [10, 0, 0, 2]
      Agent.update(servers, fn _ -> [{127, 0, 0, 3}] end)
      assert ask(s, p, "nas.lan").addr == [10, 0, 0, 3]
    end

    test "with no LAN server but itself, the fallback answers" do
      own = [{127, 0, 0, 1}, {172, 30, 32, 3}, {0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}]

      %{port: p, upstream_port: up, sock: s} =
        forwarding_server(fn -> Enum.map(own, &%{address: &1}) end, "127.0.0.4")

      fake_upstream({127, 0, 0, 4}, up, {10, 0, 0, 4})

      assert ask(s, p, "example.com").addr == [10, 0, 0, 4]
    end

    test "a LAN server that never answers gives way to the next" do
      %{port: p, upstream_port: up, sock: s} =
        forwarding_server(fn -> [{127, 0, 0, 7}, {127, 0, 0, 2}] end, nil)

      black_hole({127, 0, 0, 7}, up)
      fake_upstream({127, 0, 0, 2}, up, {10, 0, 0, 2})

      assert ask_raw(s, p, 3_000) =~ <<10, 0, 0, 2>>
    end

    test "with every LAN server dead, the fallback still answers" do
      %{port: p, upstream_port: up, sock: s} =
        forwarding_server(fn -> [{127, 0, 0, 7}] end, "127.0.0.4")

      black_hole({127, 0, 0, 7}, up)
      fake_upstream({127, 0, 0, 4}, up, {10, 0, 0, 4})

      assert ask_raw(s, p, 3_000) =~ <<10, 0, 0, 4>>
    end

    test "the server that answered last is asked first" do
      %{port: p, upstream_port: up, sock: s} =
        forwarding_server(fn -> [{127, 0, 0, 7}, {127, 0, 0, 2}] end, nil)

      black_hole({127, 0, 0, 7}, up)
      fake_upstream({127, 0, 0, 2}, up, {10, 0, 0, 2})

      assert ask_raw(s, p, 3_000) =~ <<10, 0, 0, 2>>
      # Well inside the dead server's slice: it was not asked first again.
      assert ask_raw(s, p, 500) =~ <<10, 0, 0, 2>>
    end

    test "one relay's deadline bounds every server it tries" do
      dead = for n <- 7..9, do: {127, 0, 0, n}
      %{port: p, upstream_port: up, sock: s} = forwarding_server(fn -> dead end, nil)
      Enum.each(dead, &black_hole(&1, up))

      started = System.monotonic_time(:millisecond)
      :ok = :gen_udp.send(s, {127, 0, 0, 1}, p, query("nas"))
      wait_for(fn -> relays() end, &(&1 == 1))
      wait_for(fn -> relays() end, &(&1 == 0), 400)
      elapsed = System.monotonic_time(:millisecond) - started

      # Three dead servers at a full slice each would be 4.5 s.
      assert relays() == 0
      assert elapsed < 4_400
    end

    test "queries shed at the in-flight cap are counted into one warning" do
      %{port: p, upstream_port: up, sock: s} =
        forwarding_server(fn -> [{127, 0, 0, 7}] end, nil, drop_report_ms: 200)

      black_hole({127, 0, 0, 7}, up)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..67, do: :ok = :gen_udp.send(s, {127, 0, 0, 1}, p, query("nas"))
          Process.sleep(500)
        end)

      assert [_one] = Regex.scan(~r/queries shed/, log)
      assert log =~ "3 queries shed at the in-flight caps"
    end

    test "a public fallback that answered is still asked after the LAN" do
      %{port: p, upstream_port: up, sock: s} =
        forwarding_server(fn -> [{127, 0, 0, 7}] end, "127.0.0.4")

      hole = black_hole_socket({127, 0, 0, 7}, up)
      fake_upstream({127, 0, 0, 4}, up, {10, 0, 0, 4})
      assert ask_raw(s, p, 4_000) =~ <<10, 0, 0, 4>>

      # The LAN server recovers: its answer, not the fallback's, comes back.
      :gen_udp.close(hole)
      fake_upstream({127, 0, 0, 7}, up, {10, 0, 0, 7})
      assert ask_raw(s, p, 4_000) =~ <<10, 0, 0, 7>>
    end

    test "after three dead LAN servers the fallback still has time to answer" do
      dead = for n <- 7..9, do: {127, 0, 0, n}

      %{port: p, upstream_port: up, sock: s} =
        forwarding_server(fn -> dead end, "127.0.0.4")

      Enum.each(dead, &black_hole(&1, up))
      fake_upstream({127, 0, 0, 4}, up, {10, 0, 0, 4})

      assert ask_raw(s, p, 4_500) =~ <<10, 0, 0, 4>>
    end

    test "a truncated UDP answer is had whole over TCP" do
      %{port: p, upstream_port: up, sock: s} = forwarding_server(fn -> [{127, 0, 0, 2}] end, nil)
      truncating_upstream({127, 0, 0, 2}, up)
      tcp_upstream({127, 0, 0, 2}, up, {10, 0, 0, 2})

      <<_id::16, flags::16, _::binary>> = ask_raw(s, p, 3_000)
      assert Bitwise.band(flags, 0x0200) != 0

      tcp = tcp_client(p)
      :ok = :gen_tcp.send(tcp, query("nas"))
      assert {:ok, resp} = :gen_tcp.recv(tcp, 0, 3_000)
      <<_id::16, flags::16, _qd::16, 1::16, _::binary>> = resp
      assert Bitwise.band(flags, 0x0200) == 0
      assert :binary.part(resp, byte_size(resp), -4) == <<10, 0, 0, 2>>
    end
  end

  defp relays, do: length(Task.Supervisor.children(:vagus_dns_forward_relays))

  defp query(name),
    do:
      <<0x5555::16, 0x0100::16, 1::16, 0::16, 0::16, 0::16, byte_size(name), name::binary, 0,
        1::16, 1::16>>

  defp ask_raw(s, port, timeout) do
    :ok = :gen_udp.send(s, {127, 0, 0, 1}, port, query("nas"))
    {:ok, {_, _, resp}} = :gen_udp.recv(s, 0, timeout)
    resp
  end

  describe "over TCP" do
    test "an owned name is answered from the zone", %{port: p} do
      tcp = tcp_client(p)
      :ok = :gen_tcp.send(tcp, query("supervisor"))
      assert {:ok, resp} = :gen_tcp.recv(tcp, 0, 2_000)
      assert :binary.part(resp, byte_size(resp), -4) == <<172, 30, 32, 2>>

      # The connection stays open for the next query.
      :ok = :gen_tcp.send(tcp, query("nonexistent-thing"))
      assert {:ok, <<_id::16, flags::16, _::binary>>} = :gen_tcp.recv(tcp, 0, 2_000)
      assert Bitwise.band(flags, 0x000F) == 3
    end

    test "an idle connection, or one whose frame never arrives whole, is closed" do
      %{port: p} = forwarding_server(fn -> [] end, nil, tcp_idle_ms: 200)

      idle = tcp_client(p)
      assert {:error, :closed} = :gen_tcp.recv(idle, 0, 2_000)

      {:ok, raw} = :gen_tcp.connect({127, 0, 0, 1}, p, [:binary, active: false])
      :ok = :gen_tcp.send(raw, <<100::16, "short">>)
      assert {:error, :closed} = :gen_tcp.recv(raw, 0, 2_000)
    end

    test "connections past the cap are refused and counted" do
      %{port: p, server: server} = forwarding_server(fn -> [] end, nil, drop_report_ms: 200)

      held = for _ <- 1..16, do: tcp_client(p)
      wait_for(fn -> map_size(:sys.get_state(server).conns) end, &(&1 == 16))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          over = tcp_client(p)
          assert {:error, :closed} = :gen_tcp.recv(over, 0, 2_000)
          Process.sleep(400)
        end)

      assert log =~ "1 queries shed at the in-flight caps"

      # The held ones are still served.
      :ok = :gen_tcp.send(hd(held), query("supervisor"))
      assert {:ok, _resp} = :gen_tcp.recv(hd(held), 0, 2_000)
    end
  end
end
