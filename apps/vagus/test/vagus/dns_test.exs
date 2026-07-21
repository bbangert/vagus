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

  test "resolves the supervisor anchor to .2", %{sock: s, port: p} do
    r = ask(s, p, "supervisor")
    assert r.ancount == 1
    assert r.addr == [172, 30, 32, 2]
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
