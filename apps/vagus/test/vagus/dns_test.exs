defmodule Vagus.DNSTest do
  @moduledoc "DNS server — static anchors, app records from a directory, NXDOMAIN, over UDP loopback."
  use ExUnit.Case, async: false

  alias Vagus.DNS
  alias Vagus.DNS.Message

  setup do
    port = 15_300 + rem(System.unique_integer([:positive]), 2000)
    directory = :"dns_test_directory_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: directory})

    server =
      start_supervised!(
        {DNS, name: nil, ip: {127, 0, 0, 1}, port: port, upstream: nil, directory: directory}
      )

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
    port = 17_400 + rem(System.unique_integer([:positive]), 2000)

    start_supervised!(
      {DNS,
       name: nil, ip: {127, 0, 0, 1}, port: port, upstream: nil, directory: :no_such_directory},
      id: :no_directory
    )

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
    port = 17_400 + rem(System.unique_integer([:positive]), 2000)

    server =
      start_supervised!(
        {DNS,
         name: nil,
         ip: {127, 0, 0, 1},
         port: port,
         upstream: "127.0.0.1",
         task_supervisor: :vagus_dns_test_no_such_supervisor,
         directory: d},
        id: :no_task_supervisor
      )

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
end
