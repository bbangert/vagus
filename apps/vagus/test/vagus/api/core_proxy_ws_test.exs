defmodule Vagus.API.CoreProxyWSTest do
  @moduledoc """
  Phase 3 (WS leg) tests for `Vagus.API.CoreProxy.WSBridge` /
  `Vagus.API.CoreProxy.WSBridge.Upstream`
  (`.claude/plans/vagus-core-api-proxy/plan.md`), following
  `Vagus.Ingress.WSBridgeTest`'s harness precedent: a fake Core (a real
  `Bandit`-served `Plug.Router` playing Core's own WS handshake role), the
  real proxy stack (`Bandit` serving `Vagus.API.Dispatcher`), and the
  hand-rolled Mint `Client` above standing in for the caller.

  The 400/405 (non-upgrade / wrong-method) cases don't need a real socket —
  those are plain HTTP responses answered before any upgrade is attempted —
  so they use `Plug.Test` directly against `Dispatcher`, same convention as
  `Vagus.API.CoreProxyTest`'s own non-streaming cases.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  # issue #1: the suite's WS deadlines already baseline at 60s (config/test.exs)
  # for starved-CI headroom — ExUnit's own 60s default per-test timeout must
  # sit above that, not equal to it.
  @moduletag timeout: 120_000

  import ExUnit.CaptureLog
  import Vagus.AppFixtures

  alias Vagus.API.CoreProxy.WSBridge
  alias Vagus.API.CoreProxyWSTest.{Client, CoreAuthScript, DialCounter, FakeCore}
  alias Vagus.API.{Dispatcher, SourceGuard, Token}

  @opts Dispatcher.init([])
  @expected_core_token "core-access-token"

  # Real-socket wait bound for every handshake/close frame. Deliberately
  # generous: a terminal close code propagates over FOUR hops (Core → the
  # `Upstream` GenServer → `WSBridge` → the caller socket), across two real
  # Bandit servers, and a tighter 2s bound flaked on a loaded CI runner
  # (never locally — 25× file repeats stayed green) on the Core-auth-failure
  # close-propagation test. Nothing here should ever legitimately approach 5s.
  @recv_timeout 30_000

  setup do
    start_supervised!(DialCounter)
    start_supervised!(CoreAuthScript)
    start_supervised!({Finch, name: Vagus.API.CoreProxy.Finch})

    test_pid = self()
    Application.put_env(:vagus, :core_ws_test_pid, test_pid)
    Application.put_env(:vagus, :core_ws_expected_token, @expected_core_token)

    fake_core_pid =
      start_supervised!(
        {Bandit, plug: FakeCore, port: 0, thousand_island_options: [num_acceptors: 1]},
        id: :fake_core_bandit
      )

    proxy_pid =
      start_supervised!(
        {Bandit, plug: Dispatcher, port: 0, thousand_island_options: [num_acceptors: 1]},
        id: :proxy_bandit
      )

    fake_core_port = listening_port(fake_core_pid)
    proxy_port = listening_port(proxy_pid)

    prev_base_url = Application.get_env(:vagus, :core_base_url)
    Application.put_env(:vagus, :core_base_url, "http://127.0.0.1:#{fake_core_port}")

    Application.put_env(:vagus, :core_proxy_access_token_fun, fn ->
      {:ok, @expected_core_token}
    end)

    # issue #1: these three carry a config/test.exs baseline (60_000, not the
    # library default) — `delete_env` would strip that baseline for the rest
    # of the suite after this file's first test runs, not just restore the
    # library default. Save/restore-prior instead, same discipline as
    # `prev_base_url` above.
    prev_auth_timeout = Application.get_env(:vagus, :core_ws_auth_timeout)
    prev_handoff_timeout = Application.get_env(:vagus, :core_ws_handoff_timeout)
    prev_send_timeout = Application.get_env(:vagus, :core_ws_send_timeout)

    on_exit(fn ->
      if is_nil(prev_base_url),
        do: Application.delete_env(:vagus, :core_base_url),
        else: Application.put_env(:vagus, :core_base_url, prev_base_url)

      if is_nil(prev_auth_timeout),
        do: Application.delete_env(:vagus, :core_ws_auth_timeout),
        else: Application.put_env(:vagus, :core_ws_auth_timeout, prev_auth_timeout)

      if is_nil(prev_handoff_timeout),
        do: Application.delete_env(:vagus, :core_ws_handoff_timeout),
        else: Application.put_env(:vagus, :core_ws_handoff_timeout, prev_handoff_timeout)

      if is_nil(prev_send_timeout),
        do: Application.delete_env(:vagus, :core_ws_send_timeout),
        else: Application.put_env(:vagus, :core_ws_send_timeout, prev_send_timeout)

      Application.delete_env(:vagus, :core_proxy_access_token_fun)
      Application.delete_env(:vagus, :core_ws_test_pid)
      Application.delete_env(:vagus, :core_ws_expected_token)
      Application.delete_env(:vagus, :core_ws_pending_max_frames)
      Application.delete_env(:vagus, :core_ws_pending_max_bytes)
    end)

    %{proxy_host: "127.0.0.1", proxy_port: proxy_port}
  end

  ## Helpers

  defp listening_port(bandit_pid) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit_pid)
    port
  end

  defp addon_token(slug, grants \\ %{}),
    do:
      register_app_token(app_config(slug),
        token: "core-ws-tok-#{System.unique_integer([:positive])}",
        identity: grants
      )

  defp decode_text({:text, data}), do: Jason.decode!(data)

  # The fake Cores' magic words, as the only shape the bridge relays: a
  # well-formed command.
  defp word(type), do: ~s({"type":"#{type}"})

  # A caller that has completed both handshakes and is in `:relaying` — the
  # inline version of section 1's first half, for tests whose subject is what
  # happens to frames afterwards.
  defp relaying_client(host, port, slug) do
    token = addon_token(slug, %{homeassistant_api: true})

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)

    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})
    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert Jason.decode!(raw)["type"] == "auth_ok"

    assert_receive {:core_init, _core_pid}, @recv_timeout
    client
  end

  ## 1. Accept: full handshake + text/binary relay both ways

  test "a caller with a flagged add-on token completes the handshake and relays both ways", %{
    proxy_host: host,
    proxy_port: port
  } do
    token = addon_token("cp_ws_accept", %{homeassistant_api: true})

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")

    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    auth_required = Jason.decode!(raw)
    assert auth_required["type"] == "auth_required"
    assert Map.has_key?(auth_required, "ha_version")

    # Fact 8: no `"type"` field is required on the caller's own message —
    # deliberately omitted here to prove that.
    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})

    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    auth_ok = Jason.decode!(raw)
    assert auth_ok["type"] == "auth_ok"
    assert Map.has_key?(auth_ok, "ha_version")

    assert_receive {:core_init, _core_pid}, @recv_timeout
    assert DialCounter.count() == 1

    client = Client.send_frame(client, {:text, word("hello")})
    {frame, client} = Client.next_frame(client, @recv_timeout)
    assert frame == {:text, "world"}

    payload = :crypto.strong_rand_bytes(10_000)
    expected_sha = :crypto.hash(:sha256, payload)
    client = Client.send_frame(client, {:binary, payload})
    {frame, _client} = Client.next_frame(client, @recv_timeout)

    assert {:binary, echoed} = frame
    assert :crypto.hash(:sha256, echoed) == expected_sha
  end

  ## 1b. Core's reserved `hassio*` commands are refused here, never relayed
  ##
  ## `Upstream` authenticates to Core as the Supervisor, so a relayed
  ## `hassio/*` frame passes Core's own `only_supervisor` / `is_admin` gates
  ## truthfully — `hassio/api` would call the Supervisor API with Core's
  ## token and hand the caller the `:supervisor` tier. `Vagus.Core.Reserved`
  ## has the full chain.

  test "supervisor/api is refused with an unauthorized result and never reaches Core", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_reserved_api")

    client =
      Client.send_frame(
        client,
        {:text,
         Jason.encode!(%{
           "id" => 7,
           "type" => "supervisor/api",
           "endpoint" => "/addons/evil/install",
           "method" => "post"
         })}
      )

    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)

    assert %{
             "id" => 7,
             "type" => "result",
             "success" => false,
             "error" => %{"code" => "unauthorized"}
           } = Jason.decode!(raw)

    # Had the frame been relayed, the fake Core's echo of it would be sitting
    # in the queue ahead of this round trip — so `"world"` arriving proves
    # the frame died here rather than merely being answered here.
    client = Client.send_frame(client, {:text, word("hello")})
    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert frame == {:text, "world"}
  end

  test "supervisor/event is refused too — the whole prefix is reserved, not one command", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_reserved_event")

    client =
      Client.send_frame(
        client,
        {:text, Jason.encode!(%{"id" => 1, "type" => "supervisor/event", "data" => %{}})}
      )

    {{:text, raw}, _client} = Client.next_frame(client, @recv_timeout)
    assert %{"success" => false, "error" => %{"code" => "unauthorized"}} = Jason.decode!(raw)
  end

  # The reason `screen/1` always decodes instead of pre-filtering
  # on a raw "hassio" substring: these bytes contain no such substring, and
  # Core's own JSON decoder resolves them straight back to `hassio/api`.
  test "a JSON-escaped command type is refused — matched after decoding, like Core matches it", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_reserved_escaped")

    escaped = ~s({"id":2,"type":"\\u0073upervisor/api","endpoint":"/addons","method":"get"})
    refute String.contains?(escaped, "supervisor")

    client = Client.send_frame(client, {:text, escaped})
    {{:text, raw}, _client} = Client.next_frame(client, @recv_timeout)
    assert %{"success" => false, "error" => %{"code" => "unauthorized"}} = Jason.decode!(raw)
  end

  test "an ordinary Core command still relays untouched", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_reserved_control")

    assert_relayed(client, Jason.encode!(%{"id" => 3, "type" => "get_states"}))
  end

  ## 1c. Batches and malformed frames. Core dispatches each element of a JSON
  ## array as its own command, so a reserved one is as live inside a batch
  ## as alone; anything that cannot be read as a command is refused too.

  @ordinary ~s({"id":99,"type":"get_states"})

  # The fake Core reports every frame it receives, in order — so `@ordinary`,
  # sent second, being the FIRST one reported proves `frame` never arrived,
  # where a bare `refute_receive` would only prove it hadn't arrived yet.
  defp send_refused(client, frame) do
    client = Client.send_frame(client, {:text, frame})
    client = Client.send_frame(client, {:text, @ordinary})

    assert_receive {:core_frame, :text, first}, @recv_timeout
    assert first == @ordinary, "a frame the bridge must refuse reached Core"

    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    {Jason.decode!(raw), client}
  end

  defp assert_unauthorized(reply, id) do
    assert %{
             "id" => ^id,
             "type" => "result",
             "success" => false,
             "error" => %{"code" => "unauthorized"}
           } = reply
  end

  defp assert_relayed(client, frame) do
    client = Client.send_frame(client, {:text, frame})

    assert_receive {:core_frame, :text, received}, @recv_timeout
    assert received == frame

    {echoed, client} = Client.next_frame(client, @recv_timeout)
    assert echoed == {:text, frame}
    client
  end

  test "a reserved command inside an array frame is refused and never reaches Core", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_batch_reserved")

    {reply, client} =
      send_refused(
        client,
        ~s([{"id":1,"type":"supervisor/api","endpoint":"/supervisor/info","method":"get"}])
      )

    assert_unauthorized(reply, nil)

    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert frame == {:text, @ordinary}
  end

  test "one reserved element refuses the whole batch, with a single result", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_batch_mixed")

    batch =
      Jason.encode!([
        %{"id" => 1, "type" => "call_service", "domain" => "light", "service" => "turn_on"},
        %{"id" => 2, "type" => "hassio/update/core"}
      ])

    {reply, client} = send_refused(client, batch)
    assert_unauthorized(reply, nil)

    # A second result would sit here, ahead of the echo.
    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert frame == {:text, @ordinary}
  end

  defp assert_each_refused(client, cases) do
    Enum.reduce(cases, client, fn {frame, id}, client ->
      {reply, client} = send_refused(client, frame)
      assert_unauthorized(reply, id)

      {echo, client} = Client.next_frame(client, @recv_timeout)
      assert echo == {:text, @ordinary}
      client
    end)
  end

  test "an object without a string type is refused under its own id", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_type_not_string")

    assert_each_refused(client, [{~s({"id":7,"type":5}), 7}, {~s({"id":1}), 1}])
  end

  test "a batch with an element that is not an object is refused", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_batch_non_object")

    assert_each_refused(client, [
      {~s([{"id":1,"type":"get_states"}, 5]), nil},
      {~s([[{"id":1,"type":"supervisor/api"}]]), nil}
    ])
  end

  test "a JSON scalar is refused as one malformed command", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_scalar")

    client =
      Enum.reduce(["5", ~s("supervisor/api"), "null"], client, fn scalar, client ->
        client = Client.send_frame(client, {:text, scalar})
        {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
        assert_unauthorized(Jason.decode!(raw), nil)
        client
      end)

    # First frame Core reports, so none of the scalars got there.
    assert_relayed(client, @ordinary)
  end

  test "invalid JSON closes both legs without reaching Core", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_invalid_json")

    client = Client.send_frame(client, {:text, ~s({"id":1,"type":)})
    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert {:close, 1000, _reason} = frame

    # The fake Core's own `terminate/2` — everything it ever received was
    # reported before this.
    assert_receive {:core_terminate, _reason}, @recv_timeout
    refute_received {:core_frame, _opcode, _data}
  end

  test "a binary frame is relayed unscreened, even one that is not JSON", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_binary_unscreened")

    payload = <<0, 255>> <> ~s({"id":1,"type":)
    client = Client.send_frame(client, {:binary, payload})

    assert_receive {:core_frame, :binary, ^payload}, @recv_timeout
    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert frame == {:binary, payload}
  end

  # Core's decoder keeps the LAST of two duplicate keys, so that is the
  # command it would dispatch; Jason keeps the first.
  test "a duplicated type key whose LAST value is reserved is refused", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_dup_type_last")

    {reply, _client} =
      send_refused(client, ~s({"id":3,"type":"get_states","type":"supervisor/api"}))

    assert_unauthorized(reply, 3)
  end

  test "a duplicated type key whose FIRST value is reserved is refused", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_dup_type_first")

    {reply, _client} =
      send_refused(client, ~s({"id":3,"type":"supervisor/api","type":"get_states"}))

    assert_unauthorized(reply, 3)
  end

  test "a repeated type key is refused even when both values are ordinary", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_dup_type_ordinary")

    {reply, _client} =
      send_refused(client, ~s({"id":3,"type":"get_states","type":"get_states"}))

    assert_unauthorized(reply, 3)
  end

  test "a repeated type key inside a batch element refuses the batch", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_dup_type_batch")

    {reply, _client} =
      send_refused(client, ~s([{"id":3,"type":"get_states","type":"supervisor/api"}]))

    assert_unauthorized(reply, nil)
  end

  test "a repeated type key is caught when one spelling is JSON-escaped", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_dup_type_escaped")

    frames = [
      ~s({"id":3,"type":"get_states","\\u0074ype":"supervisor/api"}),
      ~s({"id":3,"\\u0074ype":"get_states","type":"supervisor/api"})
    ]

    Enum.reduce(frames, client, fn frame, client ->
      assert String.contains?(frame, "\\u0074ype")

      {reply, client} = send_refused(client, frame)
      assert_unauthorized(reply, 3)

      {echo, client} = Client.next_frame(client, @recv_timeout)
      assert echo == {:text, @ordinary}
      client
    end)
  end

  test "the refusal answers under the last of a repeated id", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_dup_id")

    {reply, _client} = send_refused(client, ~s({"id":1,"type":"supervisor/api","id":2}))
    assert_unauthorized(reply, 2)
  end

  # Only a command's own `"type"` is dispatched on. The frame goes out as the
  # bytes that came in, never re-encoded, so Core still sees the repeat.
  test "a repeated type key in a nested object relays byte-for-byte", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_dup_type_nested")

    assert_relayed(
      client,
      ~s({"id":4, "type":"call_service","domain":"light","service":"turn_on",) <>
        ~s("service_data":{"type":"a","type":"supervisor/api","rgb":[1,2,{"type":"x"}]}})
    )
  end

  # Masked with an all-zero key, so the payload goes out as written.
  defp send_fragmented(%Client{conn: conn} = client, first, rest) do
    frame = fn byte, data -> <<byte, 1::1, 127::7, byte_size(data)::64, 0::32, data::binary>> end
    socket = Mint.HTTP.get_socket(conn)
    :ok = :gen_tcp.send(socket, [frame.(0x01, first), frame.(0x80, rest)])
    client
  end

  # Each fragment is under the per-frame cap; only their sum is over it.
  test "a fragmented message is capped at Core's own message size", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_fragmented")

    client = send_fragmented(client, ~s({"id":99,), ~s("type":"get_states"}))
    assert_receive {:core_frame, :text, @ordinary}, @recv_timeout
    {echo, client} = Client.next_frame(client, @recv_timeout)
    assert echo == {:text, @ordinary}

    half = String.duplicate("a", 2_500_000)
    client = send_fragmented(client, ~s({"type":"get_states","pad":") <> half, half <> ~s("}))

    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert {:close, 1009, _reason} = frame
    refute_received {:core_frame, _opcode, _data}
  end

  test "a batch of ordinary commands, and an empty one, still relay untouched", %{
    proxy_host: host,
    proxy_port: port
  } do
    client = relaying_client(host, port, "cp_ws_batch_ordinary")

    batch =
      Jason.encode!([
        %{"id" => 1, "type" => "get_states"},
        %{"id" => 2, "type" => "call_service", "domain" => "light", "service" => "turn_on"}
      ])

    client = assert_relayed(client, batch)
    assert_relayed(client, "[]")
  end

  ## 1d. The principal is set once, at the handshake, and every command is
  ## put to `Vagus.API.Authz` as that principal. Driven through the callbacks
  ## where the state itself is the subject.

  test "the handshake keeps the caller's principal, and no later frame replaces it" do
    token = addon_token("cp_ws_principal", %{homeassistant_api: true})
    other = addon_token("cp_ws_principal_other", %{homeassistant_api: true})

    assert {:ok, state} = WSBridge.init([])
    assert state.principal == nil

    assert {:push, {:text, _auth_ok}, state} =
             WSBridge.handle_in(
               {Jason.encode!(%{"access_token" => token}), [opcode: :text]},
               state
             )

    assert {:addon, %{slug: "cp_ws_principal", homeassistant_api: true}} = state.principal
    assert_receive {:core_init, _core_pid}, @recv_timeout

    # A second auth message is one more command to relay.
    for credential <- [other, Token.get()] do
      frame = Jason.encode!(%{"id" => 1, "type" => "auth", "access_token" => credential})
      assert WSBridge.handle_in({frame, [opcode: :text]}, state) == {:ok, state}
      assert_receive {:core_frame, :text, ^frame}, @recv_timeout
    end

    WSBridge.terminate(:normal, state)
  end

  test "a refused handshake leaves no principal behind" do
    token = addon_token("cp_ws_principal_refused")
    assert {:ok, state} = WSBridge.init([])

    for refused <- [token, Token.get(), "not-a-real-token"] do
      frame = {Jason.encode!(%{"access_token" => refused}), [opcode: :text]}

      assert {:stop, :normal, {1000, ""}, [_auth_invalid], after_refusal} =
               WSBridge.handle_in(frame, state)

      assert after_refusal.principal == nil
      assert after_refusal.phase == :awaiting_auth
    end
  end

  # The one test here that tells this bridge from one that screens frames
  # without asking `Vagus.API.Authz`: an ordinary command, refused because of
  # who the state says is asking. No `Upstream` behind these states, so a
  # frame the bridge tried to relay would not come back as a result.
  test "every command is put to the evaluator as the principal in state" do
    frame = {~s({"id":4,"type":"get_states"}), [opcode: :text]}

    for principal <- [
          :supervisor,
          :anonymous,
          {:addon, %{slug: "cp_ws_no_flag", hassio_api: true, hassio_role: "admin"}}
        ] do
      state = %{
        phase: :relaying,
        upstream: nil,
        principal: principal,
        ha_version: nil,
        closing?: false
      }

      capture_log(fn ->
        assert {:push, {:text, raw}, ^state} = WSBridge.handle_in(frame, state)
        assert %{"id" => 4, "error" => %{"code" => "unauthorized"}} = Jason.decode!(raw)
      end)
    end
  end

  test "an intercepted command is answered alone, refused in a batch, and never relayed" do
    app = {:addon, %{slug: "cp_ws_intercept", homeassistant_api: true}}

    assert Vagus.API.Authz.authorize(app, {:ws, :core_api, "supervisor/api", %{}}, %{
             leg: :core_api,
             decoded_segments: nil
           }) == {:intercept, :supervisor_api}

    call = ~s({"id":7,"type":"supervisor/api","endpoint":"/supervisor/info","method":"get"})

    assert {:call, 7, %{method: "GET", path: "/supervisor/info"}} = WSBridge.screen(call, app)

    # Not a call Core's schema would accept: refused as before.
    assert WSBridge.screen(~s({"id":7,"type":"supervisor/api"}), app) == {:refuse, 7}

    assert WSBridge.screen("[#{call}]", app) == {:refuse, nil}
    assert WSBridge.screen(~s([{"id":1,"type":"get_states"},#{call}]), app) == {:refuse, nil}

    assert WSBridge.screen(~s([{"id":1,"type":"get_states"}]), app) == :relay
  end

  test "a frame is never relayed for a principal that is not one" do
    for principal <- [nil, {:addon, nil}, :core] do
      for frame <- [~s({"id":1,"type":"get_states"}), ~s([{"id":1,"type":"get_states"}])] do
        relayed? =
          try do
            WSBridge.screen(frame, principal) == :relay
          rescue
            FunctionClauseError -> false
          end

        refute relayed?
      end
    end
  end

  test "on device, a refused frame is cast to the guard and logs nothing" do
    prev = Application.get_env(:vagus, :api_source_guard)
    Application.put_env(:vagus, :api_source_guard, true)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:vagus, :api_source_guard),
        else: Application.put_env(:vagus, :api_source_guard, prev)
    end)

    # The test stands in for the guard: the real one reports and resets on a
    # timer.
    Process.register(self(), SourceGuard)

    state = %{
      phase: :relaying,
      upstream: nil,
      principal: {:addon, %{slug: "cp_ws_counted_device", homeassistant_api: true}},
      ha_version: nil,
      closing?: false
    }

    log =
      capture_log(fn ->
        for frame <- [~s({"id":7,"type":"supervisor/api","endpoint":"/zz-marker"}), ~s([5])] do
          assert {:push, {:text, _unauthorized}, ^state} =
                   WSBridge.handle_in({frame, [opcode: :text]}, state)
        end
      end)

    refute log =~ "authz"

    for _frame <- 1..2 do
      assert_received {:"$gen_cast", {:filtered, :authz, "authz/core_ws"}}
    end

    refute_received {:"$gen_cast", _other}
  end

  # Off device there is no counter, and a refusal is a log line instead.
  test "off device, a refused frame is logged under a static label, and none of it", %{
    proxy_host: host,
    proxy_port: port
  } do
    refute SourceGuard.enabled?()
    client = relaying_client(host, port, "cp_ws_counted")

    log =
      capture_log(fn ->
        assert_each_refused(client, [
          {~s({"id":7,"type":"supervisor/api","endpoint":"/zz-marker"}), 7},
          {~s([{"id":1,"type":"zz-marker"},{"id":2,"type":"hassio/update/core"}]), nil},
          {~s({"id":3,"zz-marker":true}), 3}
        ])
      end)

    assert log =~ "authz/core_ws"
    refute log =~ "zz-marker"
  end

  test "a relayed frame is not counted", %{proxy_host: host, proxy_port: port} do
    refute SourceGuard.enabled?()
    client = relaying_client(host, port, "cp_ws_uncounted")
    log = capture_log(fn -> assert_relayed(client, @ordinary) end)

    refute log =~ "authz"
  end

  test "a handshake refused to a known principal is counted; a stranger's is not", %{
    proxy_host: host,
    proxy_port: port
  } do
    refute SourceGuard.enabled?()
    no_flag = addon_token("cp_ws_handshake_counted", %{hassio_api: true, hassio_role: "admin"})

    refused = fn token ->
      capture_log(fn ->
        {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
        {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)
        client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})
        {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
        assert Jason.decode!(raw)["type"] == "auth_invalid"
        {frame, _client} = Client.next_frame(client, @recv_timeout)
        assert match?({:close, 1000, _}, frame)
      end)
    end

    for token <- [no_flag, Token.get()] do
      log = refused.(token)
      assert log =~ "authz/core_api"
      refute log =~ token
    end

    refute refused.("not-a-real-token") =~ "authz"
    assert DialCounter.count() == 0
  end

  ## 2. Rejections at the caller handshake — fake Core never dialed

  test "an unknown token -> auth_invalid then close, fake Core never dialed", %{
    proxy_host: host,
    proxy_port: port
  } do
    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)

    client =
      Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => "not-a-real-token"})})

    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert decode_text({:text, raw})["type"] == "auth_invalid"

    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert match?({:close, 1000, _}, frame)
    assert DialCounter.count() == 0
  end

  test "a registered add-on token WITHOUT homeassistant_api -> auth_invalid then close, fake Core never dialed",
       %{proxy_host: host, proxy_port: port} do
    token = addon_token("cp_ws_no_flag")
    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)

    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})

    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert decode_text({:text, raw})["type"] == "auth_invalid"

    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert match?({:close, 1000, _}, frame)
    assert DialCounter.count() == 0
  end

  test "the supervisor token -> auth_invalid then close, fake Core never dialed",
       %{proxy_host: host, proxy_port: port} do
    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)

    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => Token.get()})})

    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert decode_text({:text, raw})["type"] == "auth_invalid"

    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert match?({:close, 1000, _}, frame)
    assert DialCounter.count() == 0
  end

  ## 3. api_password field

  test "a flagged add-on token via the api_password field also succeeds", %{
    proxy_host: host,
    proxy_port: port
  } do
    token = addon_token("cp_ws_api_password", %{homeassistant_api: true})

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)

    client = Client.send_frame(client, {:text, Jason.encode!(%{"api_password" => token})})

    {{:text, raw}, _client} = Client.next_frame(client, @recv_timeout)
    assert decode_text({:text, raw})["type"] == "auth_ok"

    # `DialCounter` is bumped by `FakeCore`'s route handler, which runs
    # before `CoreHandshakeHandler.init/1` sends `:core_init` — waiting for
    # that message is what makes the count assertion below race-free
    # instead of racing `Upstream`'s own asynchronous dial.
    assert_receive {:core_init, _core_pid}, @recv_timeout
    assert DialCounter.count() == 1
  end

  ## 4. Timeout — deterministic: the deadline is shrunk to 100ms and the
  ## client simply waits (up to 2s) for the guaranteed-to-fire local timer;
  ## no sleep, no race — `Process.send_after/3` fires unconditionally once
  ## armed in `WSBridge.init/1`.

  test "the caller-auth deadline closes the connection when the caller sends nothing", %{
    proxy_host: host,
    proxy_port: port
  } do
    Application.put_env(:vagus, :core_ws_auth_timeout, 100)

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)

    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert decode_text({:text, raw})["type"] == "auth_invalid"

    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert match?({:close, 1000, _}, frame)
    assert DialCounter.count() == 0
  end

  ## 5. Close propagation

  test "a Core-initiated close with code 4002 propagates to the caller verbatim", %{
    proxy_host: host,
    proxy_port: port
  } do
    token = addon_token("cp_ws_close_code", %{homeassistant_api: true})

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)
    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})
    {{:text, _auth_ok}, client} = Client.next_frame(client, @recv_timeout)

    client = Client.send_frame(client, {:text, word("close:4002:bye")})
    {frame, _client} = Client.next_frame(client, @recv_timeout)

    assert {:close, 4002, "bye"} = frame
  end

  test "a caller-initiated close tears down the Core-side leg deterministically", %{
    proxy_host: host,
    proxy_port: port
  } do
    token = addon_token("cp_ws_caller_close", %{homeassistant_api: true})

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)
    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})
    {{:text, _auth_ok}, client} = Client.next_frame(client, @recv_timeout)

    assert_receive {:core_init, _core_pid}, @recv_timeout

    _client = Client.send_frame(client, :close)

    assert_receive {:core_terminate, _reason}, @recv_timeout
  end

  ## 6. Aliases

  test "/core/api/websocket reaches the same handshake", %{
    proxy_host: host,
    proxy_port: port
  } do
    assert_receive_auth_required(host, port, "/core/api/websocket")
  end

  test "/homeassistant/websocket reaches the same handshake", %{
    proxy_host: host,
    proxy_port: port
  } do
    assert_receive_auth_required(host, port, "/homeassistant/websocket")
  end

  test "/homeassistant/api/websocket reaches the same handshake", %{
    proxy_host: host,
    proxy_port: port
  } do
    assert_receive_auth_required(host, port, "/homeassistant/api/websocket")
  end

  defp assert_receive_auth_required(host, port, path) do
    {:ok, client, _headers} = Client.connect(host, port, path)
    {{:text, raw}, _client} = Client.next_frame(client, @recv_timeout)
    assert Jason.decode!(raw)["type"] == "auth_required"
  end

  ## 7. Non-upgrade / wrong-method — plain HTTP, no socket needed

  test "a non-upgrade GET /core/websocket gets a plain-text 400" do
    conn = Plug.Test.conn(:get, "/core/websocket")
    conn = Dispatcher.call(conn, @opts)

    assert conn.status == 400
    assert conn.resp_body == "Bad Request"
  end

  test "POST /core/websocket -> 405 Method Not Allowed" do
    conn = Plug.Test.conn(:post, "/core/websocket")
    conn = Dispatcher.call(conn, @opts)

    assert conn.status == 405
  end

  ## 8. Core-side handshake failure — both legs close, but the caller has
  ## already seen its own auth_ok by the time it happens (moduledoc's
  ## "auth_ok is sent before Core is known to be reachable at all").

  test "Core replying auth_invalid instead of auth_ok closes both legs after the caller's own auth_ok",
       %{proxy_host: host, proxy_port: port} do
    CoreAuthScript.set(:invalid)
    token = addon_token("cp_ws_core_rejects", %{homeassistant_api: true})

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)
    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})

    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert Jason.decode!(raw)["type"] == "auth_ok"

    assert_receive {:core_init, _core_pid}, @recv_timeout
    assert DialCounter.count() == 1

    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert match?({:close, 1011, _}, frame)
  end

  ## 9. Pending-buffer cap (review W3) — a caller flooding frames before Core
  ## finishes its own handshake overflows the bounded `pending` buffer and is
  ## closed 1011 rather than growing it without limit.

  test "a flood before Core's auth_ok overflows the pending cap and closes the caller 1011",
       %{proxy_host: host, proxy_port: port} do
    # Core dials + upgrades but STALLS its `auth_ok`, so `Upstream` stays
    # `ha_ready?: false` and every caller frame below buffers in `pending`.
    CoreAuthScript.set(:stall)
    # A tiny cap so a handful of frames overflow it; the 4th trips `frames > 3`.
    Application.put_env(:vagus, :core_ws_pending_max_frames, 3)
    token = addon_token("cp_ws_pending_flood", %{homeassistant_api: true})

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)
    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})

    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert Jason.decode!(raw)["type"] == "auth_ok"

    assert_receive {:core_init, _core_pid}, @recv_timeout

    # Exactly cap+1 frames: the 4th overflows and triggers the close. No frame
    # is sent AFTER the overflow-triggering one, so no send races a socket the
    # server is already tearing down.
    client =
      Enum.reduce(1..4, client, fn i, c ->
        Client.send_frame(c, {:text, word("flood-#{i}")})
      end)

    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert match?({:close, 1011, _}, frame)
  end

  ## 10-11 (issue #37): steady-state backpressure — a stalled Core wedges the
  ## Mint send, closing the caller with 1011 either via `Upstream`'s own
  ## `send_timeout` (test 10, the normal resolution) or via `WSBridge`'s own
  ## call timeout backstopping a send_timeout that hasn't fired yet (test 11).
  ## Both need Core to actually stop reading — a dedicated `FakeCore` with
  ## small kernel socket buffers, so the wedge establishes after a frame or
  ## two rather than however much a default ~200KB buffer can absorb.

  test "a stalled Core wedges the send; Upstream's own send_timeout closes the caller 1011", %{
    proxy_host: host,
    proxy_port: port
  } do
    start_stall_core()
    Application.put_env(:vagus, :core_ws_send_timeout, 200)

    token = addon_token("cp_ws_stall_send_timeout", %{homeassistant_api: true})

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)
    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})
    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert Jason.decode!(raw)["type"] == "auth_ok"

    client = Client.send_frame(client, {:text, word("stall")})

    payload = :crypto.strong_rand_bytes(256 * 1024)
    _client = flood_ignoring_send_errors(client, payload, 20)

    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert match?({:close, 1011, _}, frame)
  end

  test "a stalled Core wedges the send; WSBridge's own handoff timeout backstops it and closes the caller 1011",
       %{proxy_host: host, proxy_port: port} do
    start_stall_core()
    Application.put_env(:vagus, :core_ws_send_timeout, 60_000)
    Application.put_env(:vagus, :core_ws_handoff_timeout, 200)

    token = addon_token("cp_ws_stall_handoff_timeout", %{homeassistant_api: true})

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)
    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})
    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert Jason.decode!(raw)["type"] == "auth_ok"

    client = Client.send_frame(client, {:text, word("stall")})

    payload = :crypto.strong_rand_bytes(256 * 1024)
    _client = flood_ignoring_send_errors(client, payload, 20)

    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert match?({:close, 1011, _}, frame)
  end

  # A dedicated `FakeCore` with small kernel socket buffers (recbuf/buffer
  # 4096), so a stalled `CoreHandshakeHandler` wedges the Mint send after a
  # frame or two rather than however much a default ~200KB buffer can absorb
  # before backpressure reaches `Upstream`'s own `:gen_tcp.send`. Points
  # `:core_base_url` at it for the rest of the test — the outer `setup`'s own
  # `on_exit` already restores the pre-test value regardless of what a test
  # itself later puts there.
  defp start_stall_core do
    stall_core_pid =
      start_supervised!(
        {Bandit,
         plug: FakeCore,
         port: 0,
         thousand_island_options: [
           num_acceptors: 1,
           transport_options: [recbuf: 4096, buffer: 4096]
         ]},
        id: :stall_core_bandit
      )

    stall_core_port = listening_port(stall_core_pid)
    Application.put_env(:vagus, :core_base_url, "http://127.0.0.1:#{stall_core_port}")
    stall_core_port
  end

  # Sends up to `n` frames, one at a time, tolerating the connection closing
  # partway through — once the wedged send trips a close, the caller-facing
  # socket can itself start refusing writes (the cascading backpressure this
  # whole test is about), and that's success, not a test failure: the
  # `assert_receive`-equivalent `Client.next_frame/2` right after this call is
  # what actually proves the close arrived.
  defp flood_ignoring_send_errors(client, _payload, 0), do: client

  defp flood_ignoring_send_errors(client, payload, n) do
    case safe_send_frame(client, {:binary, payload}) do
      {:ok, client} -> flood_ignoring_send_errors(client, payload, n - 1)
      :error -> client
    end
  end

  defp safe_send_frame(%Client{} = c, frame) do
    {:ok, websocket, data} = Mint.WebSocket.encode(c.websocket, frame)

    case Mint.WebSocket.stream_request_body(c.conn, c.ref, data) do
      {:ok, conn} -> {:ok, %{c | conn: conn, websocket: websocket}}
      {:error, _conn, _reason} -> :error
    end
  rescue
    _ -> :error
  end

  ## 8. The Supervisor↔Core unix socket (A2/A3)

  # Points `Vagus.Core.Transport` at a handshake-free fake Core on a real
  # unix socket. The TCP fake Core from `setup` stays up on `:core_base_url`
  # and shares `DialCounter`, so a dial landing on the wrong one would still
  # be visible.
  defp start_core_socket do
    path =
      Path.join(
        System.tmp_dir!(),
        "vagus_core_ws_#{System.unique_integer([:positive])}.sock"
      )

    start_supervised!(
      {Bandit,
       plug: Vagus.API.CoreProxyWSTest.FakeCoreSocket,
       port: 0,
       thousand_island_options: [num_acceptors: 1, transport_options: [ip: {:local, path}]]},
      id: :fake_core_socket_bandit
    )

    Application.put_env(:vagus, :core_socket_path, path)

    on_exit(fn ->
      Application.put_env(:vagus, :core_socket_path, nil)
      File.rm(path)
    end)

    path
  end

  # The caller-facing half is unchanged by the transport: this proxy still
  # runs Core's handshake against the CALLER itself (fact 8).
  defp authenticate_caller(host, port, token) do
    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert Jason.decode!(raw)["type"] == "auth_required"

    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})
    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert Jason.decode!(raw)["type"] == "auth_ok"

    client
  end

  test "on the socket the proxy relays without ever running Core's auth handshake", %{
    proxy_host: host,
    proxy_port: port
  } do
    start_core_socket()

    # Would raise if the Core-side credential were resolved at all — on the
    # socket it must not be.
    Application.put_env(:vagus, :core_proxy_access_token_fun, fn ->
      raise "access token resolved on the socket path"
    end)

    token = addon_token("cp_ws_socket", %{homeassistant_api: true})
    client = authenticate_caller(host, port, token)

    assert_receive {:core_socket_init, _core_pid}, @recv_timeout

    client = Client.send_frame(client, {:text, word("hello")})
    {frame, client} = Client.next_frame(client, @recv_timeout)
    assert frame == {:text, "world"}

    payload = :crypto.strong_rand_bytes(4_096)
    client = Client.send_frame(client, {:binary, payload})
    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert frame == {:binary, payload}

    refute_received {:core_socket_unexpected_auth, _data}
  end

  test "a handshake frame Core sends on the socket anyway is swallowed, not relayed", %{
    proxy_host: host,
    proxy_port: port
  } do
    start_core_socket()
    token = addon_token("cp_ws_socket_auth_frame", %{homeassistant_api: true})
    client = authenticate_caller(host, port, token)

    assert_receive {:core_socket_init, _core_pid}, @recv_timeout

    client = Client.send_frame(client, {:text, word("auth-then-hello")})

    # The caller already had its own `auth_ok` from this proxy — the one
    # Core just emitted must never reach it.
    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert frame == {:text, "world"}
  end

  test "frames sent before Core's socket upgrade completes are still delivered in order", %{
    proxy_host: host,
    proxy_port: port
  } do
    start_core_socket()
    token = addon_token("cp_ws_socket_pending", %{homeassistant_api: true})
    client = authenticate_caller(host, port, token)

    # `auth_ok` is pushed to the caller before `Upstream` has upgraded, so
    # these land in `pending` and are flushed on `{:done, ref}` — the socket
    # path's flush point.
    client = Client.send_frame(client, {:text, word("one")})
    client = Client.send_frame(client, {:text, word("two")})

    {frame1, client} = Client.next_frame(client, @recv_timeout)
    {frame2, _client} = Client.next_frame(client, @recv_timeout)

    assert frame1 == {:text, word("one")}
    assert frame2 == {:text, word("two")}
  end

  ## 9. `auth_required` is pushed a message after `init/1` (see `WSBridge`'s
  ## "Why the prompt is one message late"). The interleaving that deferral
  ## newly allows — the caller answering before the prompt runs — is driven
  ## through the callbacks directly rather than by racing a real socket: a
  ## timing-based version would only sometimes hit the window it claims to
  ## cover.

  test "the deferred prompt still precedes auth_ok, and nothing prompts again after it", %{
    proxy_host: host,
    proxy_port: port
  } do
    token = addon_token("cp_ws_prompt_order", %{homeassistant_api: true})

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert Jason.decode!(raw)["type"] == "auth_required"

    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})
    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert Jason.decode!(raw)["type"] == "auth_ok"

    # A late prompt would be ordered ahead of this round trip on the same
    # socket, so `"world"` arriving next is proof there wasn't one.
    client = Client.send_frame(client, {:text, word("hello")})
    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert frame == {:text, "world"}
  end

  test "a caller that answers before the deferred prompt runs authenticates, and is never prompted" do
    token = addon_token("cp_ws_prompt_early_auth", %{homeassistant_api: true})

    assert {:ok, state} = WSBridge.init([])
    assert_receive :push_auth_required, @recv_timeout

    assert {:push, {:text, raw}, state} =
             WSBridge.handle_in(
               {Jason.encode!(%{"access_token" => token}), [opcode: :text]},
               state
             )

    assert Jason.decode!(raw)["type"] == "auth_ok"
    assert state.phase == :relaying

    assert WSBridge.handle_info(:push_auth_required, state) == {:ok, state}

    WSBridge.terminate(:normal, state)
  end

  test "the deferred prompt is a no-op once relaying, and once closing" do
    relaying = %{phase: :relaying, upstream: nil, ha_version: "2026.7.3", closing?: false}
    assert WSBridge.handle_info(:push_auth_required, relaying) == {:ok, relaying}

    closing = %{phase: :awaiting_auth, upstream: nil, ha_version: "2026.7.3", closing?: true}
    assert WSBridge.handle_info(:push_auth_required, closing) == {:ok, closing}
  end

  ## fix/ws-1011-flake: `Vagus.API.CoreProxy.WSBridge.Upstream` driven
  ## directly against a raw `:gen_tcp` fake Core (over the SAME unix-socket
  ## transport `start_core_socket/0` above uses, so `implicit_auth?` is
  ## true — the branch these two tests exercise) that bundles its 101
  ## response with further WS bytes in a SINGLE `:gen_tcp.send/2`. No
  ## Bandit-backed fake (every other fake Core in this file) can produce
  ## that write boundary; see `Vagus.Ingress.WSBridgeTest`'s equivalent
  ## describe block for the full mechanism this reproduces.

  describe "Upstream direct (fix/ws-1011-flake: leftover bundled with the 101)" do
    setup do
      prev_socket_path = Application.get_env(:vagus, :core_socket_path)

      on_exit(fn ->
        if is_nil(prev_socket_path),
          do: Application.delete_env(:vagus, :core_socket_path),
          else: Application.put_env(:vagus, :core_socket_path, prev_socket_path)
      end)

      :ok
    end

    test "a text frame bundled with the 101 in one TCP write is relayed, not stranded" do
      path = start_raw_fake_core(raw_text_frame("leftover hello"))
      Application.put_env(:vagus, :core_socket_path, path)

      {:ok, pid} = Vagus.API.CoreProxy.WSBridge.Upstream.start_link(%{parent: self()})
      Process.monitor(pid)

      assert_receive {:relay, :text, "leftover hello"}, 5_000
    end

    test "a Close frame bundled with the 101 propagates its own code, without flushing a frame queued before the upgrade completed (Part A ordering, implicit auth)" do
      path = start_raw_fake_core(raw_close_frame(4321, "bye"), sync?: true)
      Application.put_env(:vagus, :core_socket_path, path)

      {:ok, pid} = Vagus.API.CoreProxy.WSBridge.Upstream.start_link(%{parent: self()})
      ref = Process.monitor(pid)

      assert_receive {:raw_fake_core_ready, fake_pid}, 5_000

      # Buffered in `pending` — `ha_ready?` isn't flipped until `:done`
      # fires below, which the fake is deliberately parked before. Under
      # the pre-fix ordering, `implicit_auth?` meant `flush_pending` ran
      # BEFORE the leftover was decoded, so this would reach Core anyway,
      # even though the very next bytes are a Close.
      :ok = GenServer.call(pid, {:frame, :text, "queued-before-upgrade"})

      send(fake_pid, :send_response)

      assert_receive {:upstream_close, 4321, "bye"}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

      # `terminate/2` best-effort sends its OWN close(1000) frame on every
      # stop where `upgraded?` was true, regardless of this fix — so bytes
      # arriving here at all is expected; what must never happen is the
      # queued text frame arriving FIRST (opcode 0x1 text vs 0x8 close).
      assert_receive {:raw_fake_core_after_upgrade, {:ok, <<first_byte, _rest::binary>>}}, 2_000
      assert Bitwise.band(first_byte, 0x0F) == 0x08
    end
  end

  # Same raw-`:gen_tcp` technique as `Vagus.Ingress.WSBridgeTest.
  # start_raw_fake_addon/1`, but as a unix-domain listener (matching
  # `start_core_socket/0`'s transport) since only the implicit-auth branch
  # exercises the Part A ordering this file's second test targets. Returns
  # the socket path (for `:core_socket_path`), not a port.
  defp start_raw_fake_core(extra, opts \\ []) do
    path =
      Path.join(System.tmp_dir!(), "vagus_core_ws_raw_#{System.unique_integer([:positive])}.sock")

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {:local, path}, port: 0])

    sync? = Keyword.get(opts, :sync?, false)
    test_pid = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen, 5_000)
      request = recv_raw_http_headers(socket, "")
      accept = raw_ws_accept(extract_sec_websocket_key(request))

      if sync? do
        send(test_pid, {:raw_fake_core_ready, self()})
        receive(do: (:send_response -> :ok))
      end

      response =
        "HTTP/1.1 101 Switching Protocols\r\n" <>
          "Upgrade: websocket\r\n" <>
          "Connection: Upgrade\r\n" <>
          "Sec-WebSocket-Accept: #{accept}\r\n\r\n"

      :ok = :gen_tcp.send(socket, response <> extra)

      if sync? do
        send(test_pid, {:raw_fake_core_after_upgrade, :gen_tcp.recv(socket, 0, 2_000)})
      end

      :gen_tcp.close(socket)
    end)

    on_exit(fn ->
      :gen_tcp.close(listen)
      File.rm(path)
    end)

    path
  end

  defp recv_raw_http_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      recv_raw_http_headers(socket, acc <> data)
    end
  end

  defp extract_sec_websocket_key(request) do
    [_, key] = Regex.run(~r/[Ss]ec-[Ww]eb[Ss]ocket-[Kk]ey:\s*([^\r\n]+)/, request)
    key
  end

  defp raw_ws_accept(key) do
    :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()
  end

  # Server->client frames are unmasked (RFC 6455 §5.1) — small enough
  # payloads here that the 1-byte length form always applies.
  defp raw_text_frame(payload), do: <<0x81, byte_size(payload)>> <> payload

  defp raw_close_frame(code, reason) do
    <<0x88, 2 + byte_size(reason)>> <> <<code::16>> <> reason
  end
end
