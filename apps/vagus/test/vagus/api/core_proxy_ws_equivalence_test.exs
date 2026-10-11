defmodule Vagus.API.CoreProxyWSEquivalenceTest.GateOnly do
  @moduledoc """
  `Vagus.API.Router` up to the handler: the gate decides and the route is
  matched, but nothing runs. For the routes whose handlers install, reboot
  or delete.
  """
  @behaviour Plug

  alias Vagus.API.{Auth, Envelope, Router}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = Auth.call(conn, Auth.init([]))

    if conn.halted do
      conn
    else
      case Router.match(conn, []).private.plug_route do
        {"/*_path", _handler} -> Envelope.send_error(conn, "not found", 404)
        {route, _handler} -> Envelope.send_ok(conn, %{"unrun" => route})
      end
    end
  end
end

defmodule Vagus.API.CoreProxyWSEquivalenceTest do
  @moduledoc """
  A `supervisor/api` call must get an app no more than the same request over
  HTTP with its own token gets it.

  Every route in the authorisation fixture, under every method, as every
  kind of app, plus the paths that are not routes at all, is sent both ways:
  through `Vagus.API.Dispatcher` and through the bridge on a real socket.
  A GET runs its handler on both sides; anything else stops at the gate and
  the matched route, on both sides, since its handler would act.

  Set `WS_EQUIV_OUT` to a path to keep every row.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 600_000

  import ExUnit.CaptureLog
  import Mox
  import Plug.Conn
  import Plug.Test
  import Vagus.AppFixtures

  alias Vagus.API.CoreProxy.{WSBridge, WSDispatch}
  alias Vagus.API.CoreProxyWSEquivalenceTest.GateOnly
  alias Vagus.API.CoreProxyWSTest.{Client, Stack}
  alias Vagus.API.{Dispatcher, ExploitFilter, Router}

  @recv_timeout 60_000
  @fixture Path.expand("../../fixtures/vagus-authz-table.json", __DIR__)
  @external_resource @fixture
  @routes @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("routes")

  @methods ~w(GET POST DELETE)

  # Every principal holds `homeassistant_api`: the socket requires it.
  @principals [
    {"none", %{hassio_api: false, hassio_role: "admin"}},
    {"default", %{hassio_role: "default"}},
    {"homeassistant", %{hassio_role: "homeassistant"}},
    {"backup", %{hassio_role: "backup"}},
    {"manager", %{hassio_role: "manager"}},
    {"admin", %{hassio_role: "admin"}},
    {"none_auth", %{hassio_api: false, hassio_role: "default", auth_api: true}},
    {"admin_auth", %{hassio_role: "admin", auth_api: true}},
    {"default_want", %{hassio_role: "default", services_role: %{"mqtt" => "want"}}},
    {"manager_need", %{hassio_role: "manager", services_role: %{"mqtt" => "need"}}},
    {"admin_provide", %{hassio_role: "admin", services_role: %{"mqtt" => "provide"}}},
    {"default_disc", %{hassio_role: "default", discovery: ["mqtt"]}}
  ]

  # The routes whose handler, not the table, decides from the body. Their
  # handlers run on both sides.
  @bodies [
    {"/discovery", %{"service" => "mqtt", "config" => %{"host" => "h"}}},
    {"/discovery", %{"service" => "other", "config" => %{}}},
    {"/services/mqtt", %{"host" => "h", "port" => 1883, "username" => "u", "password" => "p"}},
    {"/services/nosuch", %{"host" => "h", "port" => 1883}},
    {"/ingress/validate_session", %{"session" => "nope"}},
    {"/ingress/session", %{}},
    {"/auth", %{"username" => "u", "password" => "p"}},
    {"/addons/eq_target/security", %{"protected" => false}},
    {"/addons/{OWN}/security", %{"protected" => false}}
  ]

  # `{OWN}` is the calling app's slug.
  @slugs ["core_ssh", "self", "{OWN}", "eq_target", "vagus", "bad!slug"]

  @special [
    "/",
    "/nope",
    "/brand/new/surface",
    "/v2/apps",
    "/addons",
    "/addons/{OWN}",
    "/addons/SELF/info",
    "/addons/{OWN}/info/x",
    # Reserved Core views: plain, encoded, double-encoded, dotted.
    "/core/api/hassio/info",
    "/core/api/hassio_auth",
    "/core/api/hassio_auth/password_reset",
    "/homeassistant/api/hassio_push/discovery/x",
    "/core/api/hassio_ingress/tok/x",
    "/core/api/%68assio/info",
    "/core/api/hassio%2Finfo",
    "/core/api/hassio%5Fauth",
    "/core/api/%2568assio/info",
    "/core/api/./hassio_auth",
    "/core/api/%2e/hassio_auth",
    "/core/api/x/../hassio_auth",
    "/core/./api/hassio_auth",
    "/%63ore/api/hassio_auth",
    # The Core proxy and its WebSocket.
    "/core/api/",
    "/core/api/states",
    "/core/api/config",
    "/homeassistant/api/states",
    "/core/websocket",
    "/homeassistant/websocket",
    "/core/api/websocket",
    # Ingress.
    "/ingress/panels",
    "/ingress/session",
    "/ingress/validate_session",
    "/ingress/Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4",
    "/ingress/Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4/index.html",
    "/ingress/%70anels",
    "/ingress/%73ession",
    # Encoded and double-encoded spellings of real routes.
    "/supervisor/%69nfo",
    "/supervisor/%2569nfo",
    "/%73upervisor/info",
    "/addons/%73elf/info",
    "/addons/{OWN}%2Finfo",
    "/addons/%7BOWN%7D/info",
    "/core/%72estart",
    "/host/%72eboot",
    "/addons/eq_target/%69nfo",
    "/addons/%65q_target/info",
    "/services/mq%74t",
    "/%61uth",
    # Dot and dot-dot segments.
    "/supervisor/./info",
    "/./supervisor/info",
    "/supervisor/../supervisor/info",
    "/addons/../supervisor/info",
    "/addons/eq_target/../{OWN}/info",
    "/addons/./info",
    "/addons/%2e%2e/info",
    "/supervisor/info/.",
    "/supervisor/info/..",
    # Not a bare path.
    "/supervisor/info?x=1",
    "/supervisor/info?",
    "/addons/eq_target/info?slug={OWN}",
    "/supervisor/info#frag",
    "/supervisor/info/",
    "/supervisor//info",
    "//supervisor/info",
    "//evil.example/supervisor/info",
    "http://evil.example/supervisor/info",
    "http://supervisor/addons/eq_target/info",
    "/supervisor/info%00",
    "/supervisor/info%0A",
    "/supervisor/info;x=1",
    "/supervisor/info%3Fx=1",
    "/supervisor/info%23x",
    "/proc/self/environ",
    "/addons/<script>x</script>/info"
  ]

  # A handler's backend is a mock whose stubs belong to whichever test
  # process last claimed Mox's global mode, so they are claimed and set
  # again here: the handlers run in a task, not in this process.
  setup :set_mox_global

  setup do
    stub_with(Vagus.Backend.NetworkMock, Vagus.Backend.Network.HostStub)
    stub_with(Vagus.Backend.HostMock, Vagus.Backend.Host.HostStub)
    stub_with(Vagus.Backend.OSMock, Vagus.Backend.OS.HostStub)
    :ok
  end

  setup do
    start_supervised!({Finch, name: Vagus.API.CoreProxy.Finch})
    Stack.start()
  end

  test "a supervisor/api call never gets an app more than the same HTTP request", ctx do
    install_app(app_config("eq_target"))
    test_pid = self()

    Stack.put_env(:ws_dispatch_fun, fn slug, request ->
      send(test_pid, :dispatched)
      WSDispatch.run(slug, request, plug(request.method, request.path, request.data))
    end)

    callers =
      for {name, grants} <- @principals do
        slug = "eq_" <> name

        token =
          register_app_token(app_config(slug),
            token: "eq-tok-#{name}-#{System.unique_integer([:positive])}",
            identity: Map.merge(%{homeassistant_api: true, hassio_api: true}, grants)
          )

        {name, slug, token}
      end

    # One socket open at a time: a socket's frames are messages to this
    # process, and one read while another socket is being read is lost,
    # which leaves that socket deaf.
    {rows, _log} =
      with_log(fn ->
        Enum.flat_map(callers, fn {name, slug, token} ->
          client = Stack.relaying_client(ctx.proxy_host, ctx.proxy_port, token)

          {rows, {client, _id}} =
            Enum.map_reduce(cases(), {client, 1}, fn {method, template, body}, state ->
              path = String.replace(template, "{OWN}", slug)
              {verdict, rest, ws, state} = compare({method, path, body}, {slug, token}, state, 3)
              {{verdict, name, method, template, rest, ws}, state}
            end)

          Client.send_frame(client, {:close, 1000, ""})
          assert_receive {:core_terminate, _reason}, @recv_timeout
          rows
        end)
      end)

    by_verdict = Enum.frequencies_by(rows, &elem(&1, 0))

    if out = System.get_env("WS_EQUIV_OUT") do
      File.write!(out, Enum.map_join(rows, "\n", &line/1) <> "\n")
      File.write!(out <> ".summary", inspect(by_verdict, pretty: true, limit: :infinity) <> "\n")
    end

    permissive = for {:permissive, _, _, _, _, _} = row <- rows, do: line(row)
    unexplained = for {{:unexplained, _why}, _, _, _, _, _} = row <- rows, do: line(row)

    assert permissive == []
    assert unexplained == []

    # The comparison is of something: every kind of row occurs.
    assert by_verdict[:both_ok] > 500
    assert by_verdict[:both_refused] > 1_000
    assert by_verdict[:refused_before_dispatch] > 500
    assert length(rows) == length(@principals) * length(cases())
  end

  ## The cases

  defp cases do
    fixture =
      for %{"path" => path} <- @routes,
          template <- templates(path),
          do: template

    for(
      template <- Enum.uniq(fixture ++ @special),
      method <- @methods,
      do: {method, template, nil}
    ) ++
      for {template, body} <- @bodies, do: {"POST", template, body}
  end

  # The fixture instantiates `:slug` as `core_ssh` and as `self`.
  defp templates(path) do
    if "core_ssh" in String.split(path, "/"),
      do: for(slug <- @slugs, do: String.replace(path, "core_ssh", slug)),
      else: [path]
  end

  ## Both ways in

  # A handler runs only for a GET, and only where it does not stream.
  defp plug("GET", path, _body), do: if(streams?(path), do: GateOnly, else: Router)
  defp plug(_method, _path, nil), do: GateOnly
  defp plug(_method, _path, _body), do: Router

  defp streams?(path),
    do: String.ends_with?(path, "/follow") or path =~ ~r{/backups/[^/]+/download}

  defp rest(method, path, token, body) do
    verb = method |> String.downcase() |> String.to_existing_atom()

    conn =
      if body,
        do:
          verb
          |> conn(path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json"),
        else: conn(verb, path)

    conn = put_req_header(conn, "x-supervisor-token", token)

    # What the dispatcher itself answers, or sends past the router, it is
    # asked for in full: none of that reaches a handler.
    whole? =
      ExploitFilter.harmful_path?(conn.request_path) or
        ExploitFilter.harmful_query?(conn.query_string) or
        Dispatcher.family(conn.path_info) != :router or
        plug(method, conn.request_path, body) == Router

    try do
      conn =
        if whole?,
          do: Dispatcher.call(conn, Dispatcher.init([])),
          else: GateOnly.call(conn, [])

      {conn.status, to_string(conn.resp_body)}
    catch
      # `Plug.ErrorHandler` answers and then raises again.
      _kind, _reason ->
        receive do
          {ref, {status, _headers, body}} when is_reference(ref) -> {status, body}
        after
          0 -> {:crashed, ""}
        end
    end
  end

  defp ws(client, id, method, path, body) do
    # No timeout: a slow handler on a starved machine is answered with an
    # error after Core's ten seconds, which is a difference in time, not in
    # what the app may reach.
    call = %{
      "id" => id,
      "type" => "supervisor/api",
      "method" => String.downcase(method),
      "endpoint" => path,
      "timeout" => nil
    }

    frame = Jason.encode!(if body, do: Map.put(call, "data", body), else: call)

    # Asked of the bridge's own screening, so "refused before dispatch" is
    # what the bridge decided and not this test's idea of it.
    expected = WSBridge.screen(frame, {:addon, %{slug: "x", homeassistant_api: true}})

    client = Client.send_frame(client, {:text, frame})
    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    reply = Jason.decode!(raw)
    assert reply["id"] == id

    dispatched? =
      receive do
        :dispatched -> true
      after
        0 -> false
      end

    assert dispatched? == match?({:call, _id, _request}, expected)
    {reply, dispatched?, client}
  end

  ## The rule

  # A clock or a free-space reading can move between the two requests, so a
  # difference in data must show three times running to count.
  defp compare({method, path, body} = request, {slug, token} = caller, {client, id}, tries) do
    rest = rest(method, path, token, body)
    # Providing a service twice is an error, so each side starts without it.
    Vagus.App.withdraw_service(slug, "mqtt")
    {ws, dispatched?, client} = ws(client, id, method, path, body)
    Vagus.App.withdraw_service(slug, "mqtt")

    case verdict(rest, ws, dispatched?) do
      {:unexplained, :data_differs} when tries > 1 ->
        compare(request, caller, {client, id + 1}, tries - 1)

      verdict ->
        {verdict, rest, ws, {client, id + 1}}
    end
  end

  defp verdict({status, body}, ws, dispatched?) do
    rest = envelope(status, body)

    case {rest, ws, dispatched?} do
      {{:ok, data}, %{"success" => true, "result" => data}, true} ->
        :both_ok

      {{:ok, _data}, %{"success" => true}, true} ->
        {:unexplained, :data_differs}

      {_refused, %{"success" => true}, _dispatched?} ->
        :permissive

      {_any, %{"success" => false}, false} ->
        :refused_before_dispatch

      {{:ok, _data}, %{"success" => false}, true} ->
        {:unexplained, :http_ok_ws_refused}

      {{:error, status, message}, %{"success" => false, "error" => error}, true} ->
        if error == expected_error(status, message),
          do: :both_refused,
          else: {:unexplained, :error_mapping}
    end
  end

  defp envelope(200, body) do
    case Jason.decode(body) do
      {:ok, %{"result" => "ok"} = envelope} -> {:ok, Map.get(envelope, "data", %{})}
      {:ok, %{"result" => "error"} = envelope} -> {:error, 200, envelope["message"]}
      _not_an_envelope -> {:error, 200, nil}
    end
  end

  defp envelope(status, body) do
    case Jason.decode(body) do
      {:ok, %{"result" => "error", "message" => message}} -> {:error, status, message}
      _not_an_envelope -> {:error, status, nil}
    end
  end

  defp expected_error(_status, nil), do: %{"code" => "unknown_error", "message" => ""}

  defp expected_error(status, message) when status in [401, 403],
    do: %{"code" => "unauthorized", "message" => message}

  defp expected_error(_status, message), do: %{"code" => "unknown_error", "message" => message}

  defp line({verdict, name, method, template, {status, body}, ws}) do
    Enum.join(
      [
        inspect(verdict),
        name,
        method,
        template,
        status,
        body |> String.slice(0, 80) |> inspect(),
        ws |> Map.delete("id") |> Jason.encode!() |> String.slice(0, 120)
      ],
      "\t"
    )
  end
end
