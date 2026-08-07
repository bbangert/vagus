defmodule Vagus.API.AdminPanelTest do
  @moduledoc """
  `Vagus.API.AdminPanel` — the synthetic `vagus` ingress panel.

  The panel leg needs no Finch/Bandit: `Vagus.API.IngressProxy.call/2` is a
  plain Plug and the synthetic slug never reaches the reverse-proxy path, so
  a `Plug.Test` conn exercises the real end-to-end route (session cookie →
  token resolution → page/key) in-process.

  `async: false` throughout: both `Vagus.Ingress` and `Vagus.SSHAccess` are
  started here under their **default** global names, because that is how
  `AdminPanel`/`IngressProxy` reach them in production (no injectable
  `server` arg on those call sites). `config/test.exs` disables the
  app-started instances of both, so there is nothing to clash with.

  Core admin resolution is stubbed through the `:core_users` module seam.
  `AdminPanel.serve/2` runs synchronously in the test process (it's a plain
  Plug call), so the stub can take its answer from — and record its calls
  in — the process dictionary, exactly like `auth_router_test.exs`'s
  `StubCore`.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Vagus.Addon.{Config, State}
  alias Vagus.API.{AdminPanel, IngressProxy, Router, Token}
  alias Vagus.Ingress.Panels

  @proxy_opts IngressProxy.init([])
  @router_opts Router.init([])

  @admin_user "01ab23cd45ef67890123456789abcdef"

  defmodule StubUsers do
    @moduledoc false
    def admin?(user_id) do
      Process.put(:admin_checked, [user_id | Process.get(:admin_checked, [])])
      Process.get(:admin_result, {:ok, true})
    end
  end

  setup context do
    start_supervised!({Vagus.Ingress, []})

    # `@tag :degraded_ssh` starts `Vagus.SSHAccess` with a store it can never
    # prove is mode 0600, so it holds no keypair at all.
    ssh_opts =
      if context[:degraded_ssh],
        do: [chmod_fun: fn _path, _mode -> {:error, :eperm} end],
        else: []

    start_ssh_access(ssh_opts)

    Application.put_env(:vagus, :core_users, StubUsers)
    on_exit(fn -> Application.delete_env(:vagus, :core_users) end)

    {:ok, session} = Vagus.Ingress.create_session(Vagus.Ingress, user_id: @admin_user)
    {:ok, token} = Vagus.Ingress.admin_token()

    %{session: session, token: token}
  end

  # What the stub will answer for the rest of this test.
  defp stub_admin(result), do: Process.put(:admin_result, result)

  defp admin_checks, do: Enum.reverse(Process.get(:admin_checked, []))

  defp start_ssh_access(opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "admin_panel_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    table = :"admin_panel_ssh_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Vagus.SSHAccess, [table: table, dets_path: Path.join(dir, "ssh_access.dets")] ++ opts},
      id: make_ref()
    )

    on_exit(fn -> File.rm_rf!(dir) end)
  end

  defp fingerprint do
    {:ok, fingerprint} = Vagus.SSHAccess.fingerprint()
    fingerprint
  end

  # Drives the real dispatch path `Vagus.API.Dispatcher` uses for
  # `["ingress", token | rest]`.
  defp ingress_call(path, opts \\ []) do
    conn = conn(Keyword.get(opts, :method, :get), path)

    conn =
      case Keyword.get(opts, :session) do
        nil -> conn
        session -> put_req_cookie(conn, "ingress_session", session)
      end

    conn =
      case Keyword.get(opts, :ingress_path) do
        nil -> conn
        value -> put_req_header(conn, "x-ingress-path", value)
      end

    IngressProxy.call(conn, @proxy_opts)
  end

  defp supervisor_call(path) do
    :get
    |> conn(path)
    |> put_req_header("authorization", "Bearer #{Token.get()}")
    |> Router.call(@router_opts)
  end

  defp data(conn), do: Jason.decode!(conn.resp_body)["data"]

  describe "Vagus.Ingress.Panels.list/1" do
    test "advertises the synthetic panel with the four keys aiohasupervisor requires" do
      entry = Panels.list()["vagus"]

      assert Map.keys(entry) |> Enum.sort() == ["admin", "enable", "icon", "title"]
      assert entry["admin"] == true
      assert entry["enable"] == true
      assert is_binary(entry["title"]) and entry["title"] != ""
      assert is_binary(entry["icon"]) and entry["icon"] != ""
    end

    test "still lists real ingress add-ons alongside it" do
      state = start_state()
      slug = "panel_addon_#{System.unique_integer([:positive])}"
      :ok = State.put(ingress_config(slug), :started, server: state)

      panels = Panels.list(state)

      assert Map.has_key?(panels, slug)
      assert Map.has_key?(panels, "vagus")
    end
  end

  describe "GET /ingress/<admin token>/" do
    test "renders the page with the device key fingerprint", %{session: session, token: token} do
      conn = ingress_call("/ingress/#{token}/", session: session)

      assert conn.status == 200
      assert ["text/html; charset=utf-8"] = get_resp_header(conn, "content-type")
      assert conn.resp_body =~ fingerprint()
      assert conn.resp_body =~ Vagus.SSHAccess.key_type()
      # The instructions must state the real target.exs posture.
      assert conn.resp_body =~ "chmod 600 vagus_key"
      assert conn.resp_body =~ "ssh -i vagus_key root@"
    end

    test "index.html is the same page", %{session: session, token: token} do
      conn = ingress_call("/ingress/#{token}/index.html", session: session)

      assert conn.status == 200
      assert conn.resp_body =~ fingerprint()
    end

    test "builds the download href from Core's X-Ingress-Path header", %{
      session: session,
      token: token
    } do
      conn =
        ingress_call("/ingress/#{token}/",
          session: session,
          ingress_path: "/api/hassio_ingress/#{token}"
        )

      assert conn.resp_body =~ ~s(href="/api/hassio_ingress/#{token}/key")
    end

    test "falls back to a relative href without the header", %{session: session, token: token} do
      conn = ingress_call("/ingress/#{token}/", session: session)
      assert conn.resp_body =~ ~s(href="key")
    end
  end

  describe "GET /ingress/<admin token>/key" do
    test "serves the private key as an attachment", %{session: session, token: token} do
      conn = ingress_call("/ingress/#{token}/key", session: session)

      assert conn.status == 200
      assert String.starts_with?(conn.resp_body, "-----BEGIN OPENSSH PRIVATE KEY-----")
      assert get_resp_header(conn, "content-type") == ["application/x-pem-file"]

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="vagus_ssh_key")
             ]

      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  describe "authorization" do
    test "no ingress_session cookie is 401 for the page", %{token: token} do
      conn = ingress_call("/ingress/#{token}/")

      assert conn.status == 401
      refute conn.resp_body =~ "PRIVATE KEY"
      refute conn.resp_body =~ fingerprint()
    end

    test "no ingress_session cookie is 401 for the key download", %{token: token} do
      conn = ingress_call("/ingress/#{token}/key")

      assert conn.status == 401
      refute conn.resp_body =~ "PRIVATE KEY"
    end

    test "an invalid ingress_session cookie is 401 for the key download", %{token: token} do
      conn = ingress_call("/ingress/#{token}/key", session: "not-a-real-session")

      assert conn.status == 401
      refute conn.resp_body =~ "PRIVATE KEY"
    end
  end

  # Core's `/ingress/session` is in its own `WS_NO_ADMIN_ENDPOINTS` set, so a
  # non-admin HA user mints a perfectly valid session by design — the cookie
  # gate above proves authentication, never privilege. Everything below is
  # the second gate: the session's recorded Core `user_id` resolved through
  # the `:core_users` seam, fail-closed.
  describe "admin enforcement" do
    test "an admin sees the page and may download the key", %{session: session, token: token} do
      stub_admin({:ok, true})

      page = ingress_call("/ingress/#{token}/", session: session)
      assert page.status == 200
      assert page.resp_body =~ fingerprint()

      key = ingress_call("/ingress/#{token}/key", session: session)
      assert key.status == 200
      assert String.starts_with?(key.resp_body, "-----BEGIN OPENSSH PRIVATE KEY-----")
      assert get_resp_header(key, "content-type") == ["application/x-pem-file"]

      assert get_resp_header(key, "content-disposition") == [
               ~s(attachment; filename="vagus_ssh_key")
             ]

      assert admin_checks() == [@admin_user, @admin_user]
    end

    test "a non-admin is 403 on the page, with no fingerprint in the body", %{
      session: session,
      token: token
    } do
      stub_admin({:ok, false})

      conn = ingress_call("/ingress/#{token}/", session: session)

      assert conn.status == 403
      refute conn.resp_body =~ fingerprint()
      assert admin_checks() == [@admin_user]
    end

    test "a non-admin is 403 on the key download, with no key material", %{
      session: session,
      token: token
    } do
      stub_admin({:ok, false})

      conn = ingress_call("/ingress/#{token}/key", session: session)

      assert conn.status == 403
      refute conn.resp_body =~ "BEGIN OPENSSH PRIVATE KEY"
      refute conn.resp_body =~ "PRIVATE KEY"
      assert get_resp_header(conn, "content-disposition") == []
    end

    # A session minted before this enforcement existed, or one Core created
    # without a `user_id`. Nobody to ask Core about — deny without asking.
    test "a session carrying no user id is 403 and never reaches Core", %{token: token} do
      {:ok, anonymous} = Vagus.Ingress.create_session()

      page = ingress_call("/ingress/#{token}/", session: anonymous)
      key = ingress_call("/ingress/#{token}/key", session: anonymous)

      assert page.status == 403
      assert key.status == 403
      refute key.resp_body =~ "PRIVATE KEY"
      assert admin_checks() == []
    end

    for reason <- [:not_connected, :timeout, :disconnected, :not_started] do
      test "resolution failing with #{inspect(reason)} is 403, not access", %{
        session: session,
        token: token
      } do
        stub_admin({:error, unquote(reason)})

        page = ingress_call("/ingress/#{token}/", session: session)
        key = ingress_call("/ingress/#{token}/key", session: session)

        assert page.status == 403
        assert key.status == 403
        refute page.resp_body =~ fingerprint()
        refute key.resp_body =~ "PRIVATE KEY"
      end
    end

    test "an unknown sub-path under a non-admin session is still 403, not 404", %{
      session: session,
      token: token
    } do
      stub_admin({:ok, false})

      conn = ingress_call("/ingress/#{token}/nope", session: session)
      assert conn.status == 403
    end

    # The gate sits above the method check, so even a 405-shaped request from
    # a non-admin is refused on privilege first — nothing about the panel's
    # surface is observable without admin.
    test "a non-GET method from a non-admin is 403, not 405", %{session: session, token: token} do
      stub_admin({:ok, false})

      conn = ingress_call("/ingress/#{token}/key", session: session, method: :post)
      assert conn.status == 403
    end

    # The 401 gate must not be swallowed by the new 403 one: no cookie is
    # still "not authenticated", answered by `IngressProxy` before this
    # module is ever reached.
    test "no session is still 401, and Core is never consulted", %{token: token} do
      conn = ingress_call("/ingress/#{token}/key")

      assert conn.status == 401
      assert admin_checks() == []
    end

    # An ordinary add-on's ingress traffic must be untouched by any of this.
    # The stub says "not an admin" and the target resolver refuses: a 502
    # (not a 403) proves the request went down the add-on proxy leg, and the
    # untouched call log proves Core was never asked about the user.
    test "an add-on ingress request applies no admin check", %{session: session} do
      stub_admin({:ok, false})

      slug = "addon_regression_#{System.unique_integer([:positive])}"
      :ok = State.put(ingress_config(slug), :started)
      on_exit(fn -> State.delete(slug) end)

      {:ok, %{ingress_token: addon_token}} = State.get(slug)

      Application.put_env(:vagus, :ingress_target_fun, fn _slug -> {:error, :no_target} end)
      on_exit(fn -> Application.delete_env(:vagus, :ingress_target_fun) end)

      conn = ingress_call("/ingress/#{addon_token}/", session: session)

      assert conn.status == 502
      assert admin_checks() == []
    end
  end

  # The denial log is written to RingLogger, which persists it — so anyone
  # who can read the logs could otherwise replay the per-boot ingress token
  # the request path embeds.
  describe "denial logging" do
    test "never records the ingress token", %{session: session, token: token} do
      stub_admin({:ok, false})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          ingress_call("/ingress/#{token}/key", session: session)
        end)

      assert log =~ "vagus admin panel: denied"
      assert log =~ "not_admin"
      assert log =~ @admin_user
      refute log =~ token
    end
  end

  # The store could not be proven mode 0600, so `Vagus.SSHAccess` refused to
  # generate a key. An admin must see the existing "unavailable" 503, not a
  # 500 from a crash on the missing keypair.
  describe "degraded Vagus.SSHAccess" do
    @tag :degraded_ssh
    test "the page is 503", %{session: session, token: token} do
      stub_admin({:ok, true})

      conn = ingress_call("/ingress/#{token}/", session: session)

      assert conn.status == 503
      assert conn.resp_body == "SSH access key unavailable"
    end

    @tag :degraded_ssh
    test "the key download is 503 and carries no key material", %{session: session, token: token} do
      stub_admin({:ok, true})

      conn = ingress_call("/ingress/#{token}/key", session: session)

      assert conn.status == 503
      refute conn.resp_body =~ "PRIVATE KEY"
      assert get_resp_header(conn, "content-disposition") == []
    end

    @tag :degraded_ssh
    test "a non-admin is still 403, not 503", %{session: session, token: token} do
      stub_admin({:ok, false})

      conn = ingress_call("/ingress/#{token}/key", session: session)
      assert conn.status == 403
    end
  end

  describe "unknown sub-paths" do
    test "404 under the admin token", %{session: session, token: token} do
      conn = ingress_call("/ingress/#{token}/nope", session: session)

      assert conn.status == 404
      refute conn.resp_body =~ "PRIVATE KEY"
    end

    test "a non-GET method is 405", %{session: session, token: token} do
      conn = ingress_call("/ingress/#{token}/key", session: session, method: :post)
      assert conn.status == 405
    end
  end

  describe "GET /addons/vagus/info" do
    test "returns the payload ha-panel-app needs" do
      conn = supervisor_call("/addons/vagus/info")
      assert conn.status == 200

      info = data(conn)
      assert info["slug"] == "vagus"
      assert info["state"] == "started"
      assert is_binary(info["name"]) and info["name"] != ""
      assert is_binary(info["version"]) and info["version"] != ""
      assert info["ingress_url"] =~ ~r"^/api/hassio_ingress/[^/]+/$"
    end

    test "the advertised ingress_url carries the admin token", %{token: token} do
      info = data(supervisor_call("/addons/vagus/info"))
      assert info["ingress_url"] == "/api/hassio_ingress/#{token}/"
    end
  end

  describe "GET /addons regression" do
    test "the synthetic slug is absent from the strictly-modelled add-on list" do
      slugs = Enum.map(data(supervisor_call("/addons"))["addons"], & &1["slug"])
      refute "vagus" in slugs
    end
  end

  describe "Vagus.Ingress.resolve_token/2" do
    test "the admin token resolves to the synthetic slug", %{token: token} do
      assert {:ok, "vagus"} = Vagus.Ingress.resolve_token(token)
      assert AdminPanel.slug() == "vagus"
    end

    test "a real add-on's token still resolves to its own slug" do
      slug = "resolve_addon_#{System.unique_integer([:positive])}"
      :ok = State.put(ingress_config(slug), :started)
      on_exit(fn -> State.delete(slug) end)

      {:ok, %{ingress_token: addon_token}} = State.get(slug)

      assert {:ok, ^slug} = Vagus.Ingress.resolve_token(addon_token)
    end
  end

  ## Fixtures

  defp start_state do
    start_supervised!({State, name: nil, persist_path: nil}, id: make_ref())
  end

  defp ingress_config(slug) do
    {:ok, config} =
      Config.parse(%{
        "name" => "Admin Panel Test Addon",
        "version" => "1.0.0",
        "slug" => slug,
        "description" => "fixture",
        "arch" => ["aarch64"],
        "ingress" => true,
        "ingress_port" => 8099
      })

    config
  end
end
