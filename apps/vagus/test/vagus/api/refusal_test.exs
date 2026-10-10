defmodule Vagus.API.RefusalTest do
  use ExUnit.Case, async: true

  alias Vagus.API.Refusal

  @api Path.expand("../../../lib/vagus/api", __DIR__)

  test "every kind answers, with a status that refuses" do
    for kind <- Refusal.kinds(), method <- ~w(GET POST DELETE PUT) do
      assert {status, message} = Refusal.answer(kind, method, "mqtt")
      assert status in [401, 403, 404]
      assert is_binary(message) and message != ""
    end

    assert_raise FunctionClauseError, fn -> Refusal.answer(:nonsense, "GET", nil) end
  end

  test "the wording upstream's clients and the handlers' callers already see" do
    assert Refusal.answer(:forbidden, "GET", nil) == {403, "unauthorized"}
    assert Refusal.answer(:not_core, "POST", nil) == {401, "unauthorized"}
    assert Refusal.answer(:not_this_app, "GET", nil) == {403, "Not authorized for this add-on"}

    assert Refusal.answer(:self_only, "GET", nil) ==
             {403, "This can be only read by the app itself!"}

    assert Refusal.answer(:no_auth_api, "GET", nil) ==
             {403, "Caller is not allowed to access the auth API"}

    assert Refusal.answer(:not_found, "GET", nil) == {404, "not found"}
    assert Refusal.answer(:service, "GET", "mqtt") == {403, "Caller not authorized for 'mqtt'"}
    assert Refusal.answer(:service, "PUT", "mqtt") == {403, "Caller not authorized for 'mqtt'"}
    assert Refusal.answer(:service, "POST", "mqtt") == {403, "Caller may not provide 'mqtt'"}
    assert Refusal.answer(:service, "DELETE", "mqtt") == {403, "Caller may not delete 'mqtt'"}
  end

  test "a service name JSON cannot hold is not echoed, and the answer still encodes" do
    for name <- [<<0xFF>>, "mq" <> <<0xC3, 0x28>> <> "tt", <<0xED, 0xA0, 0x80>>],
        method <- ~w(GET POST DELETE) do
      assert {403, message} = Refusal.answer(:service, method, name)
      assert message =~ "this service"
      assert {:ok, _json} = Jason.encode(message)
    end

    # Valid UTF-8 is echoed as before, control characters included.
    assert {403, message} = Refusal.answer(:service, "GET", "mqtt\n")
    assert message == "Caller not authorized for 'mqtt\n'"
    assert {:ok, _json} = Jason.encode(message)
  end

  # The gate and the handlers word a refusal alike only while both ask this
  # module. A message written out anywhere else is one that can drift.
  test "no other API module spells a refusal's message out" do
    phrases = [
      "Not authorized for this add-on",
      "only read by the app itself",
      "not allowed to access the auth API",
      "Caller may not provide '",
      "Caller may not delete '",
      "Caller not authorized for",
      ~s("not found", 404)
    ]

    sources = Path.wildcard(Path.join(@api, "**/*.ex")) -- [Path.join(@api, "refusal.ex")]
    assert length(sources) > 10

    for source <- sources, phrase <- phrases do
      refute File.read!(source) =~ phrase,
             "#{Path.relative_to(source, @api)} spells out #{phrase}"
    end

    router = File.read!(Path.join(@api, "router.ex"))

    for kind <- Refusal.kinds() do
      assert router =~ "refuse(conn, :#{kind}", "the router has no guard answering :#{kind}"
    end
  end
end
