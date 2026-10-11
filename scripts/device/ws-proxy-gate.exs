# Device gate for the Core-API WebSocket proxy, run INSIDE an app that holds
# `homeassistant_api`: the bench probe apps evaluate this file over their
# /eval endpoint (see ws-proxy-gate.sh). It has to run in the container
# because the proxy authenticates the app's own SUPERVISOR_TOKEN and the
# source guard admits only the hassio bridge.
#
# `observe?` is prepended by the launcher. Each case carries the outcome the
# fixed build produces; any mismatch raises so the eval endpoint reports
# ok:false (unless observing an unfixed build).
#
# Raw frames on purpose: a client library would refuse to send a duplicated
# key or invalid JSON, and those are the cases under test.
recv = fn recv, st, deadline ->
  case st.frames do
    [f | rest] -> {f, %{st | frames: rest}}
    [] ->
      receive do
        msg ->
          case Mint.WebSocket.stream(st.conn, msg) do
            {:ok, conn, resps} ->
              data = for {:data, _, d} <- resps, into: "", do: d
              {:ok, ws, frames} = Mint.WebSocket.decode(st.ws, data)
              if frames == [] and not Mint.HTTP.open?(conn), do: {:tcp_closed_without_close_frame, st}, else: recv.(recv, %{st | conn: conn, ws: ws, frames: frames}, deadline)
            {:error, _conn, reason, _} -> {{:transport_error, reason}, st}
            :unknown -> recv.(recv, st, deadline)
          end
      after deadline -> {:timeout, st}
      end
  end
end
send_text = fn st, text ->
  {:ok, ws, data} = Mint.WebSocket.encode(st.ws, {:text, text})
  {:ok, conn} = Mint.WebSocket.stream_request_body(st.conn, st.ref, data)
  %{st | ws: ws, conn: conn}
end
connect = fn ->
  {:ok, conn} = Mint.HTTP.connect(:http, "supervisor", 80, protocols: [:http1])
  {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/core/websocket", [])
  up = fn up, conn, acc ->
    receive do
      msg ->
        case Mint.WebSocket.stream(conn, msg) do
          {:ok, conn, resps} ->
            acc = acc ++ resps
            if Enum.any?(acc, &match?({:done, _}, &1)), do: {conn, acc}, else: up.(up, conn, acc)
          :unknown -> up.(up, conn, acc)
        end
    after 15_000 -> raise "upgrade timeout"
    end
  end
  {conn, resps} = up.(up, conn, [])
  status = Enum.find_value(resps, fn {:status, _, s} -> s; _ -> nil end)
  headers = Enum.find_value(resps, fn {:headers, _, h} -> h; _ -> nil end)
  {:ok, conn, ws} = Mint.WebSocket.new(conn, ref, status, headers)
  # Mint.HTTP1 keeps bytes that trail the 101 in its own buffer, which
  # Mint.WebSocket.stream/2 never revisits; an auth_required sent in the same
  # TCP read as the 101 would otherwise be lost.
  buffered = case conn do %{buffer: b} when is_binary(b) -> b; _ -> "" end
  left = (for {:data, _, d} <- resps, into: "", do: d) <> buffered
  {:ok, ws, frames} = Mint.WebSocket.decode(ws, left)
  st = %{conn: conn, ref: ref, ws: ws, frames: frames}
  {{:text, a}, st} = recv.(recv, st, 15_000)
  "auth_required" = Jason.decode!(a)["type"]
  st = send_text.(st, Jason.encode!(%{type: "auth", access_token: System.get_env("SUPERVISOR_TOKEN")}))
  {{:text, b}, st} = recv.(recv, st, 15_000)
  {Jason.decode!(b)["type"], st}
end
summ = fn
  {:text, t} ->
    case Jason.decode(t) do
      {:ok, %{} = m} ->
        r = m["result"]
        Map.take(m, ["id", "type", "success"])
        |> Map.put("error", get_in(m, ["error", "code"]))
        |> Map.put("result", cond do is_map(r) -> r |> Map.keys() |> Enum.sort() |> Enum.take(5); is_list(r) -> "list(#{length(r)})"; true -> r end)
      {:ok, other} -> %{"json" => inspect(other) |> String.slice(0, 200)}
      _ -> %{"raw" => String.slice(t, 0, 120)}
    end
  {:close, code, _} -> %{"close" => code}
  other -> %{"other" => inspect(other) |> String.slice(0, 120)}
end
rest = fn method, path ->
  {:ok, s} = :gen_tcp.connect(~c"supervisor", 80, [:binary, active: false], 10_000)
  :ok = :gen_tcp.send(s, "#{method} #{path} HTTP/1.1\r\nHost: supervisor\r\nContent-Length: 0\r\nAuthorization: Bearer #{System.get_env("SUPERVISOR_TOKEN")}\r\nConnection: close\r\n\r\n")
  rd = fn rd, acc -> case :gen_tcp.recv(s, 0, 15_000) do {:ok, d} -> rd.(rd, acc <> d); _ -> acc end end
  resp = rd.(rd, "")
  :gen_tcp.close(s)
  [head, body] = String.split(resp, "\r\n\r\n", parts: 2)
  status = head |> String.split(" ") |> Enum.at(1)
  {status, case Jason.decode(body) do {:ok, m} -> m; _ -> body end}
end
isbar = fn fr, bid -> match?({:text, _}, fr) and match?(%{"type" => "pong", "id" => ^bid}, summ.(fr)) end
# A refusal must not also reach Core: the barrier ping goes down the same socket,
# and Core answers in order, so a relayed copy of the refused frame shows up
# before the pong. Frames the bridge pushes itself (:strict) precede the pong;
# supervisor/api refusals come from a dispatched task racing the relayed ping
# (:free), so either order is legitimate but nothing else may appear.
one = fn frame, barrier, bid ->
  t0 = System.monotonic_time(:millisecond)
  {auth, st} = connect.()
  st = send_text.(st, frame)
  {f, st} = recv.(recv, st, 30_000)
  ms = System.monotonic_time(:millisecond) - t0
  {f, bad, st} =
    if barrier do
      st = send_text.(st, Jason.encode!(%{id: bid, type: "ping"}))
      drain = fn drain, st, acc ->
        cond do
          not match?({:text, _}, List.last(acc)) -> {acc, st}
          Enum.any?(acc, &isbar.(&1, bid)) and (barrier == :strict or length(acc) >= 2) -> {acc, st}
          true -> {n, st} = recv.(recv, st, 30_000); drain.(drain, st, acc ++ [n])
        end
      end
      {frames, st} = drain.(drain, st, [f])
      {pongs, others} = Enum.split_with(frames, &isbar.(&1, bid))
      if length(pongs) == 1 and length(others) == 1 and (barrier == :free or isbar.(List.last(frames), bid)),
        do: {hd(others), nil, st},
        else: {f, Enum.map(frames, summ), st}
    else
      {f, nil, st}
    end
  Mint.HTTP.close(st.conn)
  {auth, f, ms, bad}
end
sup = ~s("type":"supervisor/api","endpoint":"/supervisor/info","method":"get")
api = fn id, endpoint, method -> ~s({"id":#{id},"type":"supervisor/api","endpoint":"#{endpoint}","method":"#{method}"}) end
cases = [
  {"a_batch_reserved", ~s([{"id":1,#{sup}}]), %{"error" => "unauthorized", "success" => false, "id" => nil}, :strict},
  {"b_batch_mixed", ~s([{"id":1,#{sup}},{"id":2,"type":"ping"}]), %{"error" => "unauthorized", "success" => false, "id" => nil}, :strict},
  {"d_dup_type_reserved_last", ~s({"id":6,"type":"ping","endpoint":"/supervisor/info","method":"get","type":"supervisor/api"}), %{"error" => "unauthorized", "success" => false, "id" => 6}, :strict},
  {"e_nonstring_type", ~s({"id":7,"type":5}), %{"error" => "unauthorized", "success" => false, "id" => 7}, :strict},
  {"f_batch_nonobject", ~s([{"id":1,"type":"ping"},5]), %{"error" => "unauthorized", "success" => false, "id" => nil}, :strict},
  {"g_invalid_json", "{not json", %{"close" => 1000}, nil},
  {"h_ordinary_single", ~s({"id":9,"type":"get_config"}), %{"success" => true, "id" => 9}, nil},
  {"i_ordinary_batch", ~s([{"id":10,"type":"ping"}]), %{"type" => "pong", "id" => 10}, nil},
  {"j_call_service", ~s({"id":11,"type":"call_service","domain":"persistent_notification","service":"dismiss","service_data":{"notification_id":"vagus-gate-nonexistent"}}), %{"success" => true, "id" => 11}, nil},
  {"k_supervisor_event", ~s({"id":12,"type":"supervisor/event","data":{"event":"x"}}), %{"error" => "unauthorized", "success" => false, "id" => 12}, :strict},
  {"l_api_ping", api.(20, "/supervisor/ping", "get"), %{"success" => true, "id" => 20}, nil},
  {"m_api_self_info", api.(21, "/addons/self/info", "get"), %{"success" => true, "id" => 21}, nil},
  {"n_api_supervisor_info_no_role", api.(22, "/supervisor/info", "get"), %{"error" => "unauthorized", "success" => false, "id" => 22}, :free},
  {"o_api_foreign_app_info", api.(23, "/addons/core_mqtt/info", "get"), %{"error" => "unauthorized", "success" => false, "id" => 23}, :free},
  {"p_api_reserved_core_view", api.(24, "/core/api/hassio/app/entrypoint.js", "get"), %{"error" => "unauthorized", "success" => false, "id" => 24}, :free},
  {"q_api_core_proxy_family", api.(25, "/core/api/config", "get"), %{"error" => "unknown_error", "success" => false, "id" => 25}, :free},
  {"r_api_logs_follow", api.(26, "/addons/self/logs/follow", "get"), %{"error" => "unknown_error", "success" => false, "id" => 26}, :free},
  {"s_api_encoded_endpoint", api.(27, "/addons/%73elf/info", "get"), %{"error" => "unknown_error", "success" => false, "id" => 27}, :free},
  {"t_api_post_core_check", api.(28, "/core/check", "post"), %{"error" => "unauthorized", "success" => false, "id" => 28}, :free},
  {"u_api_unknown_path", api.(29, "/nope", "get"), %{"error" => "unauthorized", "success" => false, "id" => 29}, :free}
]
results =
  for {{name, frame, _, barrier}, i} <- Enum.with_index(cases) do
    out =
      try do
        {auth, f, ms, bad} = one.(frame, barrier, 9000 + i)
        (if bad, do: %{"unexpected_frames" => bad}, else: summ.(f)) |> Map.put("auth", auth) |> Map.put("ms", ms)
      rescue e -> %{"exception" => Exception.message(e) |> String.slice(0, 200)}
      catch k, r -> %{"caught" => inspect({k, r}) |> String.slice(0, 200)}
      end
    {name, out}
  end
equal =
  try do
    {_a, {:text, t}, _ms, nil} = one.(api.(40, "/addons/self/info", "get"), nil, 0)
    ws = Jason.decode!(t)
    {status, body} = rest.("GET", "/addons/self/info")
    vol = ~w(cpu_percent memory_usage memory_percent network_rx network_tx blk_read blk_write)
    w = Map.drop(ws["result"] || %{}, vol); r = Map.drop((is_map(body) && body["data"]) || %{}, vol)
    %{"ws_success" => ws["success"], "rest_status" => status, "keys" => map_size(w), "data_equal" => w == r, "differing_keys" => (for k <- Map.keys(w) ++ Map.keys(r), w[k] != r[k], uniq: true, do: k)}
  rescue e -> %{"exception" => Exception.message(e) |> String.slice(0, 200)}
  end
rest_checks =
  for {m, p} <- [{"GET", "/supervisor/info"}, {"GET", "/addons/core_mqtt/info"}, {"POST", "/core/check"}],
      do: {m, p, rest.(m, p) |> then(fn {s, b} -> {s, is_map(b) && b["message"]} end)}
mismatches =
  (for {{name, out}, {name, _, exp, _}} <- Enum.zip(results, cases),
       want = Map.put(exp, "auth", "auth_ok"),
       got = Map.take(out, Map.keys(want) ++ ["exception", "caught", "unexpected_frames"]),
       got != want,
       do: {name, want, got}) ++
    (case Map.take(equal, ["ws_success", "rest_status", "data_equal"]) do
       %{"ws_success" => true, "rest_status" => "200", "data_equal" => true} -> []
       got -> [{"self_info_ws_vs_rest", %{"ws_success" => true, "rest_status" => "200", "data_equal" => true}, equal |> Map.take(["exception"]) |> Map.merge(got)}]
     end) ++
    (for {m, p, {s, _}} <- rest_checks, s != "403", do: {"rest_same_token " <> m <> " " <> p, "403", s})
report = %{utc: DateTime.utc_now() |> DateTime.to_iso8601(), slug: System.get_env("HOSTNAME"), cases: results, self_info_ws_vs_rest: equal, rest_same_token: rest_checks, mismatches: mismatches}
if mismatches != [] and not observe?, do: raise("GATE FAILED: " <> inspect(mismatches, limit: :infinity, printable_limit: :infinity)), else: report
