defmodule Vagus.DNS.Message do
  @moduledoc """
  Minimal DNS wire codec for `Vagus.DNS` — just enough to answer the `A`
  queries the `hassio` naming plan needs (`docs/contract-2026.7-m4-addendum.md`
  §A6) and to relay everything else upstream verbatim.

  We parse a query's header + first question, and build a response that echoes
  the question section unchanged and appends `A` answers via a compression
  pointer to the question name at offset 12 (`0xC00C`). Anything we don't parse
  (non-`A`, malformed) is handled by the server forwarding the raw packet, so
  this module never has to encode the general case.
  """

  @typedoc "Parsed query: id, lowercased dotted qname (no trailing dot), qtype, raw question bytes."
  @type query :: %{
          id: non_neg_integer(),
          qname: String.t(),
          qtype: non_neg_integer(),
          question: binary()
        }

  @type_a 1
  @class_in 1

  @doc """
  Parses a DNS query packet. Returns `{:ok, query}` for a single-question
  packet, `{:error, reason}` otherwise (the caller forwards those upstream).
  """
  @spec parse_query(binary()) :: {:ok, query()} | {:error, atom()}
  def parse_query(<<id::16, _flags::16, qdcount::16, _an::16, _ns::16, _ar::16, rest::binary>>)
      when qdcount == 1 do
    case parse_question(rest) do
      {:ok, qname, qtype, _qclass, question_bytes} ->
        {:ok, %{id: id, qname: qname, qtype: qtype, question: question_bytes}}

      :error ->
        {:error, :bad_question}
    end
  end

  def parse_query(_packet), do: {:error, :unsupported}

  @doc "The `A` record type number (1)."
  @spec type_a() :: non_neg_integer()
  def type_a, do: @type_a

  @doc """
  Builds a response for `query` answering with `ips` (a list of `{a,b,c,d}`
  tuples) as `A` records. An empty list yields an authoritative `NOERROR` with
  no answers (an existing name, no A record); use `nxdomain/1` for an unknown
  name.
  """
  @spec answer(query(), [:inet.ip4_address()]) :: binary()
  def answer(%{id: id, question: question}, ips) do
    # QR=1, AA=1, RD=1, RA=1, RCODE=0
    header = <<id::16, 0x8580::16, 1::16, length(ips)::16, 0::16, 0::16>>
    answers = for ip <- ips, into: <<>>, do: a_record(ip)
    header <> question <> answers
  end

  @doc "Builds an authoritative `NXDOMAIN` response for `query`."
  @spec nxdomain(query()) :: binary()
  def nxdomain(%{id: id, question: question}) do
    # QR=1, AA=1, RD=1, RA=1, RCODE=3 (NXDOMAIN)
    <<id::16, 0x8583::16, 1::16, 0::16, 0::16, 0::16>> <> question
  end

  ## Internals

  # An A answer: name pointer to the question (offset 12), TYPE A, CLASS IN,
  # TTL, RDLENGTH 4, the 4 address octets.
  defp a_record({a, b, c, d}) do
    <<0xC00C::16, @type_a::16, @class_in::16, 30::32, 4::16, a, b, c, d>>
  end

  # Walk the QNAME labels by index into the original buffer (so the echoed
  # question bytes are sliced from the right offset), then read QTYPE/QCLASS.
  # Compression pointers (`0xC0`) don't occur in a query's question, so a byte
  # that isn't a 1..63 length or the `0` terminator is rejected.
  defp parse_question(data), do: parse_q(data, 0, [])

  # Out of bytes before a terminator → malformed. The explicit guard keeps every
  # `:binary.at`/`binary_part` below in-bounds, so no rescue-as-control-flow.
  defp parse_q(data, pos, _acc) when pos >= byte_size(data), do: :error

  defp parse_q(data, pos, acc) do
    case :binary.at(data, pos) do
      0 when byte_size(data) >= pos + 5 ->
        qtype = :binary.decode_unsigned(binary_part(data, pos + 1, 2))
        qclass = :binary.decode_unsigned(binary_part(data, pos + 3, 2))
        name = acc |> Enum.reverse() |> Enum.join(".") |> String.downcase()
        {:ok, name, qtype, qclass, binary_part(data, 0, pos + 5)}

      len when len in 1..63 and byte_size(data) >= pos + 1 + len ->
        parse_q(data, pos + 1 + len, [binary_part(data, pos + 1, len) | acc])

      _ ->
        :error
    end
  end
end
