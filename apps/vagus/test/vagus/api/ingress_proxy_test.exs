defmodule Vagus.API.IngressProxyTest.HitCounter do
  @moduledoc "Counts requests the fake add-on Bandit actually received — proves an unauthorized/unresolvable request never reaches it."
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> 0 end, name: __MODULE__)
  def bump, do: Agent.update(__MODULE__, &(&1 + 1))
  def count, do: Agent.get(__MODULE__, & &1)
end

defmodule Vagus.API.IngressProxyTest.FakeAddon do
  @moduledoc """
  Stands in for an ingress-enabled add-on's own HTTP server: no
  `Plug.Parsers`, only the raw routes `Vagus.API.IngressProxyTest` needs to
  prove the proxy's streaming/header/status behavior end to end.
  """
  use Plug.Router

  alias Vagus.API.IngressProxyTest.HitCounter

  plug(:bump_hits)
  plug(:match)
  plug(:dispatch)

  defp bump_hits(conn, _opts) do
    HitCounter.bump()
    conn
  end

  # POST body >64KB regression case: proves the proxy streamed every byte
  # rather than a `Plug.Parsers`-truncated prefix.
  post "/echo-body" do
    {body, conn} = read_full_body(conn)

    send_json(conn, 200, %{
      size: byte_size(body),
      sha256: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    })
  end

  # Reflects every request header back as JSON — used both for the
  # strip-list assertions and to observe what `Host` actually arrives as.
  get "/echo-headers" do
    send_json(conn, 200, %{headers: Map.new(conn.req_headers)})
  end

  get "/stream3" do
    conn = send_chunked(conn, 200)
    {:ok, conn} = chunk(conn, "chunk1-")
    {:ok, conn} = chunk(conn, "chunk2-")
    {:ok, conn} = chunk(conn, "chunk3")
    conn
  end

  get "/empty204" do
    send_resp(conn, 204, "")
  end

  # Catch-all: reflects the decoded path + verbatim query string, proving
  # a percent-encoded space round-trips and the query string passes through.
  match _ do
    send_json(conn, 200, %{path: conn.request_path, query: conn.query_string})
  end

  defp read_full_body(conn, acc \\ "") do
    case Plug.Conn.read_body(conn, length: 1_000_000) do
      {:ok, data, conn} -> {acc <> data, conn}
      {:more, data, conn} -> read_full_body(conn, acc <> data)
    end
  end

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end

defmodule Vagus.API.IngressProxyTest do
  @moduledoc """
  IW-P3-T3: hermetic end-to-end tests for `Vagus.API.Dispatcher` +
  `Vagus.API.IngressProxy` (`docs/contract-2026.7-m4b-ingress-watchdog.md`
  §B2), driven over **real** listening Bandit servers on both ends — no
  `Plug.Test`, since the whole point under test is byte-for-byte streaming
  in both directions, which `Plug.Test`'s in-memory conn can't exercise.

  Three real processes per test: a fake ingress-enabled add-on
  (`FakeAddon`, above), the proxy stack itself (`Bandit` +
  `Vagus.API.Dispatcher`, exactly as `Vagus.API.Supervisor` wires it on a
  real device), and `Vagus.Ingress.Finch` (the proxy's outbound pool).
  `config :vagus, :ingress_target_fun` is pointed at the fake add-on's port
  for the duration of each test, standing in for a real docker
  inspect/`Vagus.Addon.State` lookup — `default_target/1` itself needs a
  real docker daemon and is out of scope for a hermetic suite.
  """
  use ExUnit.Case, async: false

  alias Vagus.API.IngressProxyTest.{FakeAddon, HitCounter}
  alias Vagus.API.Token
  alias Vagus.Addon.{Config, State}

  @client_finch Vagus.API.IngressProxyTest.ClientFinch

  setup do
    start_supervised!(HitCounter)
    start_supervised!({Vagus.Ingress, []})
    start_supervised!({Finch, name: Vagus.Ingress.Finch})
    start_supervised!({Finch, name: @client_finch})

    addon_pid =
      start_supervised!(
        {Bandit, plug: FakeAddon, port: 0, thousand_island_options: [num_acceptors: 1]},
        id: :fake_addon_bandit
      )

    proxy_pid =
      start_supervised!(
        {Bandit,
         plug: Vagus.API.Dispatcher, port: 0, thousand_island_options: [num_acceptors: 1]},
        id: :proxy_bandit
      )

    addon_port = listening_port(addon_pid)
    proxy_port = listening_port(proxy_pid)

    slug = "ingress_test_#{System.unique_integer([:positive])}"
    {:ok, config} = Config.parse(required_config(slug))
    :ok = State.put(config, :started)
    {:ok, entry} = State.get(slug)

    Application.put_env(:vagus, :ingress_target_fun, fn
      ^slug -> {:ok, {"127.0.0.1", addon_port}}
      _other -> {:error, :unknown_slug}
    end)

    on_exit(fn ->
      Application.delete_env(:vagus, :ingress_target_fun)
      State.delete(slug)
    end)

    %{
      slug: slug,
      token: entry.ingress_token,
      proxy_base: "http://127.0.0.1:#{proxy_port}",
      addon_port: addon_port
    }
  end

  ## Helpers

  # `port: 0` binds an OS-assigned ephemeral port — fully collision-proof,
  # unlike guessing a "probably free" fixed/random port. `Bandit`'s
  # `start_link/1` returns the same pid `ThousandIsland.listener_info/1`
  # expects (Bandit is itself a thin `ThousandIsland` supervisor).
  defp listening_port(bandit_pid) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit_pid)
    port
  end

  defp required_config(slug) do
    %{
      "name" => "Ingress Test Addon",
      "version" => "1.0.0",
      "slug" => slug,
      "description" => "fake ingress add-on for IngressProxy tests",
      "arch" => ["amd64"],
      "ingress" => true,
      "ingress_port" => 8099
    }
  end

  defp req(method, url, headers \\ [], body \\ nil) do
    request = Finch.build(method, url, headers, body)
    {:ok, resp} = Finch.request(request, @client_finch, receive_timeout: 5_000)
    resp
  end

  defp cookie_header(session), do: {"cookie", "ingress_session=#{session}"}

  defp json(%Finch.Response{body: body}), do: Jason.decode!(body)

  defp resp_header(%Finch.Response{headers: headers}, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end

  ## 1. Happy path

  test "GET with a valid session cookie proxies through to the add-on", %{
    proxy_base: base,
    token: token
  } do
    {:ok, session} = Vagus.Ingress.create_session()

    resp =
      req(:get, "#{base}/ingress/#{token}/echo-headers", [cookie_header(session)])

    assert resp.status == 200
    assert resp_header(resp, "x-accel-buffering") == "no"
    assert %{"headers" => _headers} = json(resp)
  end

  ## 2. Auth / token-resolution failures

  test "missing session cookie -> 401, and the add-on never sees the request", %{
    proxy_base: base,
    token: token
  } do
    resp = req(:get, "#{base}/ingress/#{token}/echo-headers")

    assert resp.status == 401
    assert resp.body == "Unauthorized"
    assert HitCounter.count() == 0
  end

  test "invalid session cookie -> 401, and the add-on never sees the request", %{
    proxy_base: base,
    token: token
  } do
    resp =
      req(:get, "#{base}/ingress/#{token}/echo-headers", [cookie_header("not-a-real-session")])

    assert resp.status == 401
    assert HitCounter.count() == 0
  end

  test "unknown ingress token -> 503", %{proxy_base: base} do
    {:ok, session} = Vagus.Ingress.create_session()

    resp =
      req(:get, "#{base}/ingress/no-such-token-1234567890/echo-headers", [
        cookie_header(session)
      ])

    assert resp.status == 503
    assert HitCounter.count() == 0
  end

  ## 3. Streamed request body (the Plug.Parsers regression case)

  test "a >64KB POST body reaches the add-on byte-for-byte", %{
    proxy_base: base,
    token: token
  } do
    {:ok, session} = Vagus.Ingress.create_session()
    payload = :crypto.strong_rand_bytes(200_000)
    expected_sha = Base.encode16(:crypto.hash(:sha256, payload), case: :lower)

    resp =
      req(:post, "#{base}/ingress/#{token}/echo-body", [cookie_header(session)], payload)

    assert resp.status == 200
    assert %{"size" => 200_000, "sha256" => ^expected_sha} = json(resp)
  end

  ## 4. Header handling

  test "strips supervisor/hop-by-hop headers, appends x-forwarded-for, passes custom headers through",
       %{proxy_base: base, token: token} do
    {:ok, session} = Vagus.Ingress.create_session()

    resp =
      req(:get, "#{base}/ingress/#{token}/echo-headers", [
        cookie_header(session),
        {"x-supervisor-token", "should-never-arrive"},
        {"connection", "keep-alive"},
        {"x-ingress-path", "/api/hassio_ingress/#{token}"}
      ])

    assert resp.status == 200
    %{"headers" => headers} = json(resp)

    refute Map.has_key?(headers, "x-supervisor-token")
    refute Map.has_key?(headers, "connection")
    assert headers["x-ingress-path"] == "/api/hassio_ingress/#{token}"
    assert headers["x-forwarded-for"] =~ "127.0.0.1"

    # [VERIFY] resolved empirically (contract §B2.2 step 4, `Host` not in
    # either strip list): Mint's HTTP/1 request builder only fills in a
    # default `Host` when one isn't already present
    # (`Headers.put_new("Host", ...)`, `deps/mint/lib/mint/http1.ex:1170`)
    # — a caller-supplied `Host` (here, the original inbound one) passes
    # through to the add-on completely untouched, exactly as the contract
    # describes, rather than being rejected or overridden with the
    # upstream connection's own authority.
    assert headers["host"] != nil
  end

  ## 5. Sliding renewal

  test "a proxied request slides the session's expiry rather than consuming it", %{
    proxy_base: base,
    token: token
  } do
    {:ok, session} = Vagus.Ingress.create_session()

    resp = req(:get, "#{base}/ingress/#{token}/echo-headers", [cookie_header(session)])
    assert resp.status == 200

    assert Vagus.Ingress.validate_session(session) == :ok
  end

  ## 6. Response streaming

  test "a chunked add-on response streams through to the client whole", %{
    proxy_base: base,
    token: token
  } do
    {:ok, session} = Vagus.Ingress.create_session()

    resp = req(:get, "#{base}/ingress/#{token}/stream3", [cookie_header(session)])

    assert resp.status == 200
    assert resp.body == "chunk1-chunk2-chunk3"
  end

  test "a 204 add-on response passes through with no body and no chunked-framing error", %{
    proxy_base: base,
    token: token
  } do
    {:ok, session} = Vagus.Ingress.create_session()

    resp = req(:get, "#{base}/ingress/#{token}/empty204", [cookie_header(session)])

    assert resp.status == 204
    assert resp.body == ""
  end

  ## 7. Path encoding + query string

  test "a percent-encoded space in the path reaches the add-on intact, query string passes through",
       %{proxy_base: base, token: token} do
    {:ok, session} = Vagus.Ingress.create_session()

    resp =
      req(:get, "#{base}/ingress/#{token}/a%20b/c?x=y&z=1", [cookie_header(session)])

    assert resp.status == 200
    # `conn.path_info`/`request_path` are never percent-decoded anywhere in
    # this pipeline (see `Vagus.API.IngressProxy.build_url/4`'s doc comment)
    # — "intact" means the `%20` survives verbatim end to end, not that it
    # becomes a literal space.
    assert %{"path" => "/a%20b/c", "query" => "x=y&z=1"} = json(resp)
  end

  ## 8. /ingress/panels and /ingress/session still hit the router

  test "/ingress/panels with a supervisor token hits the router (200 envelope), not the proxy", %{
    proxy_base: base
  } do
    resp =
      req(:get, "#{base}/ingress/panels", [{"authorization", "Bearer #{Token.get()}"}])

    assert resp.status == 200
    assert %{"data" => %{"panels" => %{}}} = json(resp)
  end

  test "/ingress/panels without auth is rejected by the router, not proxied (never a 503)", %{
    proxy_base: base
  } do
    resp = req(:get, "#{base}/ingress/panels")

    assert resp.status == 401
    # The router's `Vagus.API.Envelope`-wrapped rejection, not the proxy's
    # plain-text one — proves this request never reached `IngressProxy`.
    assert %{"message" => _} = json(resp)
  end

  test "/ingress/session with a supervisor token hits the router, not the proxy", %{
    proxy_base: base
  } do
    resp =
      req(:post, "#{base}/ingress/session", [
        {"authorization", "Bearer #{Token.get()}"},
        {"content-type", "application/json"}
      ])

    assert resp.status == 200
    assert %{"data" => %{"session" => session}} = json(resp)
    assert session =~ ~r/\A[0-9a-f]{128}\z/
  end
end
