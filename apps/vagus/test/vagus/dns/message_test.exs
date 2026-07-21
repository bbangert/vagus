defmodule Vagus.DNS.MessageTest do
  @moduledoc "DNS wire codec (parse A queries, build answers/NXDOMAIN)."
  use ExUnit.Case, async: true

  alias Vagus.DNS.Message

  # Build an A query for `name` with id `id`.
  defp query(name, id \\ 0x1234) do
    labels =
      name
      |> String.split(".")
      |> Enum.map(fn l -> <<byte_size(l)::8, l::binary>> end)
      |> IO.iodata_to_binary()

    <<id::16, 0x0100::16, 1::16, 0::16, 0::16, 0::16>> <> labels <> <<0, 1::16, 1::16>>
  end

  test "parses a single-question A query" do
    assert {:ok, q} = Message.parse_query(query("core-mosquitto.local.hass.io"))
    assert q.id == 0x1234
    assert q.qname == "core-mosquitto.local.hass.io"
    assert q.qtype == Message.type_a()
  end

  test "lowercases the qname" do
    assert {:ok, %{qname: "supervisor"}} = Message.parse_query(query("SuperVisor"))
  end

  test "rejects multi-question / malformed packets" do
    assert {:error, _} = Message.parse_query(<<0::16, 0::16, 2::16, 0::16, 0::16, 0::16>>)
    assert {:error, _} = Message.parse_query(<<1, 2, 3>>)
  end

  test "answer echoes the question and appends an A record" do
    {:ok, q} = Message.parse_query(query("supervisor", 0xABCD))
    resp = Message.answer(q, [{172, 30, 32, 2}])

    <<id::16, flags::16, qd::16, an::16, _ns::16, _ar::16, _rest::binary>> = resp
    assert id == 0xABCD
    # QR + AA set, ANCOUNT 1
    assert Bitwise.band(flags, 0x8000) != 0
    assert qd == 1
    assert an == 1
    # the 4 address octets are present at the tail
    assert :binary.part(resp, byte_size(resp), -4) == <<172, 30, 32, 2>>
  end

  test "answer with no ips is NOERROR with zero answers" do
    {:ok, q} = Message.parse_query(query("x"))
    <<_id::16, _flags::16, _qd::16, an::16, _::binary>> = Message.answer(q, [])
    assert an == 0
  end

  test "nxdomain sets RCODE 3 and no answers" do
    {:ok, q} = Message.parse_query(query("nope"))
    <<_id::16, flags::16, _qd::16, an::16, _::binary>> = Message.nxdomain(q)
    assert Bitwise.band(flags, 0x000F) == 3
    assert an == 0
  end
end
