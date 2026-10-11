# Device gate for the Core-API WebSocket proxy, run INSIDE an app that holds
# `homeassistant_api`: the bench probe apps evaluate this file over their
# /eval endpoint (see ws-proxy-gate.sh). It has to run in the container
# because the proxy authenticates the app's own SUPERVISOR_TOKEN and the
# source guard admits only the hassio bridge.
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
one = fn frame ->
  t0 = System.monotonic_time(:millisecond)
  {auth, st} = connect.()
  st = send_text.(st, frame)
  {f, st} = recv.(recv, st, 30_000)
  Mint.HTTP.close(st.conn)
  {auth, f, System.monotonic_time(:millisecond) - t0}
end
sup = ~s("type":"supervisor/api","endpoint":"/supervisor/info","method":"get")
api = fn id, endpoint, method -> ~s({"id":#{id},"type":"supervisor/api","endpoint":"#{endpoint}","method":"#{method}"}) end
cases = [
  {"a_batch_reserved", ~s([{"id":1,#{sup}}])},
  {"b_batch_mixed", ~s([{"id":1,#{sup}},{"id":2,"type":"ping"}])},
  {"d_dup_type_reserved_last", ~s({"id":6,"type":"ping","endpoint":"/supervisor/info","method":"get","type":"supervisor/api"})},
  {"e_nonstring_type", ~s({"id":7,"type":5})},
  {"f_batch_nonobject", ~s([{"id":1,"type":"ping"},5])},
  {"g_invalid_json", "{not json"},
  {"h_ordinary_single", ~s({"id":9,"type":"get_config"})},
  {"i_ordinary_batch", ~s([{"id":10,"type":"ping"}])},
  {"j_call_service", ~s({"id":11,"type":"call_service","domain":"persistent_notification","service":"dismiss","service_data":{"notification_id":"vagus-gate-nonexistent"}})},
  {"k_supervisor_event", ~s({"id":12,"type":"supervisor/event","data":{"event":"x"}})},
  {"l_api_ping", api.(20, "/supervisor/ping", "get")},
  {"m_api_self_info", api.(21, "/addons/self/info", "get")},
  {"n_api_supervisor_info_no_role", api.(22, "/supervisor/info", "get")},
  {"o_api_foreign_app_info", api.(23, "/addons/core_mqtt/info", "get")},
  {"p_api_reserved_core_view", api.(24, "/core/api/hassio/app/entrypoint.js", "get")},
  {"q_api_core_proxy_family", api.(25, "/core/api/config", "get")},
  {"r_api_logs_follow", api.(26, "/addons/self/logs/follow", "get")},
  {"s_api_encoded_endpoint", api.(27, "/addons/%73elf/info", "get")},
  {"t_api_post_core_restart", api.(28, "/core/restart", "post")},
  {"u_api_unknown_path", api.(29, "/nope", "get")}
]
results =
  for {name, frame} <- cases do
    out =
      try do
        {auth, f, ms} = one.(frame)
        summ.(f) |> Map.put("auth", auth) |> Map.put("ms", ms)
      rescue e -> %{"exception" => Exception.message(e) |> String.slice(0, 200)}
      catch k, r -> %{"caught" => inspect({k, r}) |> String.slice(0, 200)}
      end
    {name, out}
  end
equal =
  try do
    {_a, {:text, t}, _ms} = one.(api.(40, "/addons/self/info", "get"))
    ws = Jason.decode!(t)
    {status, body} = rest.("GET", "/addons/self/info")
    vol = ~w(cpu_percent memory_usage memory_percent network_rx network_tx blk_read blk_write)
    w = Map.drop(ws["result"] || %{}, vol); r = Map.drop((is_map(body) && body["data"]) || %{}, vol)
    %{"ws_success" => ws["success"], "rest_status" => status, "keys" => map_size(w), "data_equal" => w == r, "differing_keys" => (for k <- Map.keys(w) ++ Map.keys(r), w[k] != r[k], uniq: true, do: k)}
  rescue e -> %{"exception" => Exception.message(e) |> String.slice(0, 200)}
  end
rest_checks =
  for {m, p} <- [{"GET", "/supervisor/info"}, {"GET", "/addons/core_mqtt/info"}, {"POST", "/core/restart"}],
      do: {m, p, rest.(m, p) |> then(fn {s, b} -> {s, is_map(b) && b["message"]} end)}
%{utc: DateTime.utc_now() |> DateTime.to_iso8601(), slug: System.get_env("HOSTNAME"), cases: results, self_info_ws_vs_rest: equal, rest_same_token: rest_checks}
