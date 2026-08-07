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
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Vagus.Addon.{Config, State}
  alias Vagus.API.{AdminPanel, IngressProxy, Router, Token}
  alias Vagus.Ingress.Panels

  @proxy_opts IngressProxy.init([])
  @router_opts Router.init([])

  setup do
    start_supervised!({Vagus.Ingress, []})
    start_ssh_access()

    {:ok, session} = Vagus.Ingress.create_session()
    {:ok, token} = Vagus.Ingress.admin_token()

    %{session: session, token: token}
  end

  defp start_ssh_access do
    dir = Path.join(System.tmp_dir!(), "admin_panel_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    table = :"admin_panel_ssh_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Vagus.SSHAccess, table: table, dets_path: Path.join(dir, "ssh_access.dets")},
      id: make_ref()
    )

    on_exit(fn -> File.rm_rf!(dir) end)
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
      assert conn.resp_body =~ Vagus.SSHAccess.fingerprint()
      assert conn.resp_body =~ Vagus.SSHAccess.key_type()
      # The instructions must state the real target.exs posture.
      assert conn.resp_body =~ "chmod 600 vagus_key"
      assert conn.resp_body =~ "ssh -i vagus_key root@"
    end

    test "index.html is the same page", %{session: session, token: token} do
      conn = ingress_call("/ingress/#{token}/index.html", session: session)

      assert conn.status == 200
      assert conn.resp_body =~ Vagus.SSHAccess.fingerprint()
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
      refute conn.resp_body =~ Vagus.SSHAccess.fingerprint()
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
