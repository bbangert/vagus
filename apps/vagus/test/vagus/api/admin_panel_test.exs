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
  alias Vagus.DSP
  alias Vagus.Ingress.Panels

  @proxy_opts IngressProxy.init([])
  @router_opts Router.init([])

  @admin_user "01ab23cd45ef67890123456789abcdef"
  @boundary "vagus-panel-dsp-boundary"

  # ELF32 header size and the table entry sizes a Hexagon object uses.
  @ehsize 52
  @phentsize 32
  @shentsize 40
  @shnum 3

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
    conn = conn(Keyword.get(opts, :method, :get), path, Keyword.get(opts, :body))

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

    conn =
      case Keyword.get(opts, :content_type) do
        nil -> conn
        value -> put_req_header(conn, "content-type", value)
      end

    IngressProxy.call(conn, @proxy_opts)
  end

  defp supervisor_call(path) do
    :get
    |> conn(path)
    |> put_req_header("authorization", "Bearer #{Token.get()}")
    |> Router.call(@router_opts)
  end

  defp addon_call(path, token) do
    :get
    |> conn(path)
    |> put_req_header("x-supervisor-token", token)
    |> Router.call(@router_opts)
  end

  # Registers an add-on token the auth plug will resolve to `{:addon, _}`.
  defp addon_token(slug) do
    token = "tok-#{System.unique_integer([:positive])}"

    :ok =
      Vagus.Addon.Registry.register(token, %{
        slug: slug,
        services_role: %{},
        auth_api: true,
        discovery: [],
        hassio_api: true,
        hassio_role: "default"
      })

    on_exit(fn -> Vagus.Addon.Registry.unregister_slug(slug) end)
    token
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

    # That `ingress_url` is a bearer capability for the device's SSH private
    # key, so the reserved slug is supervisor-only — and it denies exactly the
    # way any other slug an add-on may not read does, leaking nothing by the
    # shape of the refusal.
    test "an add-on token is refused indistinguishably from a foreign slug", %{token: token} do
      addon = addon_token("nosy_addon")

      conn = addon_call("/addons/vagus/info", addon)
      foreign = addon_call("/addons/core_mosquitto/info", addon)

      assert conn.status == 403
      assert foreign.status == 403
      assert conn.resp_body == foreign.resp_body

      refute conn.resp_body =~ "ingress_url"
      refute conn.resp_body =~ token
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

  # The one route on this panel that writes. Its whole shape is the B1 rule:
  # `serve/2`'s admin check runs first, so the disk-spooling multipart parse
  # is only ever reached by an admin.
  describe "POST /ingress/<admin token>/dsp" do
    setup do
      dir = Path.join(System.tmp_dir!(), "vagus_panel_dsp_#{System.unique_integer([:positive])}")
      Application.put_env(:vagus, :dsp_root, dir)

      on_exit(fn ->
        Application.delete_env(:vagus, :dsp_root)
        File.rm_rf!(dir)
      end)

      %{dsp_dir: dir}
    end

    test "a valid skel is stored and the page reports it", %{session: session, token: token} do
      conn = upload(token, session, part("skel", "libQnnHtpV68Skel.so", skel("V68")))

      assert conn.status == 200
      assert ["text/html; charset=utf-8"] = get_resp_header(conn, "content-type")
      assert conn.resp_body =~ "Stored."
      assert conn.resp_body =~ "libQnnHtpV68Skel.so"
      assert conn.resp_body =~ "V68"
      assert conn.resp_body =~ "2.48.40"

      assert {:configured, %{filename: "libQnnHtpV68Skel.so", arch: "V68"}} = DSP.status()
      # The SSH section is on the same page and must survive the re-render.
      assert conn.resp_body =~ fingerprint()
    end

    test "the field name is irrelevant, as on the backup route", %{session: session, token: token} do
      conn = upload(token, session, part("whatever", "x.bin", skel("V73")))

      assert conn.status == 200
      assert {:configured, %{arch: "V73"}} = DSP.status()
    end

    test "a host library re-renders with a reason and stores nothing", %{
      session: session,
      token: token,
      dsp_dir: dir
    } do
      body = elf(class: 2, machine: 62) <> "libQnnHtpV68Skel.so"
      conn = upload(token, session, part("skel", "libQnnHtp.so", body))

      assert conn.status == 400
      assert ["text/html; charset=utf-8"] = get_resp_header(conn, "content-type")
      assert conn.resp_body =~ "aarch64 stub sits one directory away from the skeleton"
      # Still the page, not a bare 400 — the operator needs the form again.
      assert conn.resp_body =~ ~s(enctype="multipart/form-data")

      assert DSP.status() == :not_configured
      assert Path.wildcard(Path.join(dir, "*")) == []
    end

    # The discriminating case: the body is malformed multipart, so a handler
    # that parsed before authorizing would answer 400. A clean 403 is what
    # proves the parse never ran — and with it, that no non-admin can make
    # this device spool a file to disk.
    test "a non-admin is 403 before anything is parsed or written", %{
      session: session,
      token: token,
      dsp_dir: dir
    } do
      stub_admin({:ok, false})

      conn =
        ingress_call("/ingress/#{token}/dsp",
          method: :post,
          session: session,
          body: "not multipart at all",
          content_type: "multipart/form-data; boundary=#{@boundary}"
        )

      assert conn.status == 403
      assert conn.resp_body == "Forbidden: Home Assistant administrators only"
      assert DSP.status() == :not_configured
      refute File.exists?(dir)
    end

    test "a body with no file in it is refused cleanly", %{session: session, token: token} do
      field =
        "--#{@boundary}\r\n" <>
          ~s(content-disposition: form-data; name="note"\r\n\r\n) <>
          "hello\r\n--#{@boundary}--\r\n"

      conn = upload(token, session, field)

      assert conn.status == 400
      assert conn.resp_body =~ "No file was attached."
      assert DSP.status() == :not_configured
    end

    test "a malformed body is refused cleanly, not with a 500", %{session: session, token: token} do
      conn =
        ingress_call("/ingress/#{token}/dsp",
          method: :post,
          session: session,
          body: "not multipart at all",
          content_type: "multipart/form-data; boundary=#{@boundary}"
        )

      assert conn.status == 400
      assert conn.resp_body =~ "could not be read as a file submission"
    end

    # `Plug.Parsers.MULTIPART` re-raises this one instead of wrapping it, so
    # without its own rescue clause a client could turn any 400 on this panel
    # into a 500 just by sending non-UTF-8 bytes in a plain form field.
    test "a part with invalid UTF-8 is refused cleanly, not with a 500", %{
      session: session,
      token: token
    } do
      field =
        "--#{@boundary}\r\n" <>
          ~s(content-disposition: form-data; name="note"\r\n\r\n) <>
          <<0xFF, 0xFE, 0xFD>> <> "\r\n--#{@boundary}--\r\n"

      conn = upload(token, session, field)

      assert conn.status == 400
      assert conn.resp_body =~ "could not be read as a file submission"
      assert DSP.status() == :not_configured
    end

    # `Plug.Upload` resolves its spool roots once at application start into a
    # `:persistent_term`, so this is the only honest way to make
    # `random_file!/1` fail — a regular file as the tmp root makes its
    # `File.mkdir_p` return `:enotdir` for root as well, which permission
    # bits would not. No seam in the panel itself.
    test "an upload the device cannot spool is 507, not a 500 and not a 400", %{
      session: session,
      token: token
    } do
      {roots, suffix} = :persistent_term.get(Plug.Upload)

      blocker =
        Path.join(System.tmp_dir!(), "vagus_no_spool_#{System.unique_integer([:positive])}")

      File.write!(blocker, "")

      :persistent_term.put(Plug.Upload, {[blocker], suffix})

      on_exit(fn ->
        :persistent_term.put(Plug.Upload, {roots, suffix})
        File.rm_rf!(blocker)
      end)

      conn = upload(token, session, part("skel", "libQnnHtpV68Skel.so", skel("V68")))

      assert conn.status == 507
      assert conn.resp_body =~ "data partition is most likely"
      # The sentence must not send the operator back to the SDK tree.
      refute conn.resp_body =~ "aarch64 stub"
      assert DSP.status() == :not_configured
    end

    test "a non-multipart content type is refused cleanly", %{session: session, token: token} do
      conn =
        ingress_call("/ingress/#{token}/dsp",
          method: :post,
          session: session,
          body: skel("V68"),
          content_type: "application/octet-stream"
        )

      assert conn.status == 400
      assert conn.resp_body =~ "could not be read as a file submission"
    end

    # The parser cap bounds the whole body where `DSP.max_bytes/0` bounds the
    # file, so it sits a fixed framing allowance above it — a skel at the file
    # cap must still reach `store/1`, which owns the size rule and the sentence
    # that goes with it.
    test "the parser cap leaves room for multipart framing above the file cap" do
      headroom = AdminPanel.dsp_body_limit() - DSP.max_bytes()

      assert headroom > 0
      assert headroom <= 1024 * 1024
    end

    # The SDK archive an operator might submit instead of the extracted `.so`
    # dies in the parser rather than after being spooled whole. One body of
    # this size in the suite is enough; the file cap itself is `Vagus.DSPTest`'s
    # to pin.
    test "a body over the cap is refused and names the mistake", %{
      session: session,
      token: token
    } do
      oversize = String.duplicate("x", AdminPanel.dsp_body_limit() + 1024)
      conn = upload(token, session, part("skel", "qairt.zip", oversize))

      assert conn.status == 400
      assert conn.resp_body =~ "larger than #{div(DSP.max_bytes(), 1024 * 1024)} MB"
      assert conn.resp_body =~ "SDK archive you downloaded it in"
      assert DSP.status() == :not_configured
    end

    test "the panel renders on a target with no DSP at all", %{session: session, token: token} do
      Application.delete_env(:vagus, :dsp_root)

      conn = ingress_call("/ingress/#{token}/", session: session)

      assert conn.status == 200
      assert conn.resp_body =~ "no Hexagon DSP"
      refute conn.resp_body =~ "multipart/form-data"
    end

    test "the form posts back to the ingress-absolute /dsp path", %{
      session: session,
      token: token
    } do
      conn =
        ingress_call("/ingress/#{token}/",
          session: session,
          ingress_path: "/api/hassio_ingress/#{token}"
        )

      assert conn.resp_body =~ ~s(action="/api/hassio_ingress/#{token}/dsp")
    end
  end

  # The instructions are the deliverable: an operator has to find one file
  # inside a 2.4 GB SDK tree, and a path that does not exist in the download
  # would fail the feature at its only user-facing step.
  describe "the DSP section" do
    setup do
      dir = Path.join(System.tmp_dir!(), "vagus_dsp_ui_#{System.unique_integer([:positive])}")
      Application.put_env(:vagus, :dsp_root, dir)
      # Both Qualcomm boards set this beside :dsp_root; QCS6490 is Hexagon v68.
      Application.put_env(:vagus, :dsp_arch, "V68")

      on_exit(fn ->
        Application.delete_env(:vagus, :dsp_root)
        Application.delete_env(:vagus, :dsp_arch)
        File.rm_rf!(dir)
      end)

      :ok
    end

    test "not configured names the exact file and where it sits in the SDK", %{
      session: session,
      token: token
    } do
      conn = ingress_call("/ingress/#{token}/", session: session)

      assert conn.status == 200
      assert conn.resp_body =~ "lib/hexagon-v68/unsigned/libQnnHtpV68Skel.so"
      assert conn.resp_body =~ "Qualcomm AI Runtime (QAIRT) SDK"
      assert conn.resp_body =~ "Qualcomm account"
      assert conn.resp_body =~ ~s(enctype="multipart/form-data")
      assert conn.resp_body =~ fingerprint()
    end

    # The three ways to pick the wrong file, each of which an operator reaches
    # by looking in a plausible place.
    test "not configured warns off lib-safe, the aarch64 stub and the archive", %{
      session: session,
      token: token
    } do
      body = ingress_call("/ingress/#{token}/", session: session).resp_body

      assert body =~ "lib-safe/"
      assert body =~ "lib/aarch64-oe-linux-gcc11.2/libQnnHtpV68Stub.so"
      assert body =~ "2.4&nbsp;GB"
    end

    test "configured reports the stored file", %{session: session, token: token} do
      {:ok, info} = DSP.store(write_tmp(skel("V68")))

      conn = ingress_call("/ingress/#{token}/", session: session)

      assert conn.status == 200
      assert conn.resp_body =~ "libQnnHtpV68Skel.so"
      assert conn.resp_body =~ "V68"
      assert conn.resp_body =~ "2.48.40"
      assert conn.resp_body =~ "#{info.size} bytes"
      assert conn.resp_body =~ to_string(info.stored_at)
      refute conn.resp_body =~ "wrong DSP"
      assert conn.resp_body =~ fingerprint()
    end

    # Warn, never refuse — a V73 skel on a v68 DSP is the silent-CPU-fallback
    # failure this whole feature defends against, but `:dsp_arch` being wrong
    # for a board must not strand the operator.
    test "a skel for another Hexagon version warns and is still reported as stored", %{
      session: session,
      token: token
    } do
      {:ok, _info} = DSP.store(write_tmp(skel("V73")))

      conn = ingress_call("/ingress/#{token}/", session: session)

      assert conn.status == 200
      assert conn.resp_body =~ "wrong DSP"
      assert conn.resp_body =~ "falls back"
      assert conn.resp_body =~ "libQnnHtpV73Skel.so"
      assert conn.resp_body =~ "stored all the same"
      assert {:configured, %{arch: "V73"}} = DSP.status()
      assert conn.resp_body =~ fingerprint()
    end

    test "configured says the two version numbers cannot be compared", %{
      session: session,
      token: token
    } do
      {:ok, _info} = DSP.store(write_tmp(skel("V68")))

      body = ingress_call("/ingress/#{token}/", session: session).resp_body

      assert body =~ "cDSP firmware"
      assert body =~ "cannot be compared"
      assert body =~ "add-on author's contract"
    end

    # No cdsp remoteproc on a host or on `rpi3_64` — the row reads as unknown
    # rather than blanking or crashing the page that hands out the root key.
    test "an unreadable cDSP firmware version renders as unknown", %{
      session: session,
      token: token
    } do
      {:ok, _info} = DSP.store(write_tmp(skel("V68")))

      body = ingress_call("/ingress/#{token}/", session: session).resp_body

      assert body =~ ~s(<dt>cDSP firmware</dt><dd class="mono">unknown</dd>)
    end

    test "a skel carrying no AISW_VERSION reads as not detected", %{
      session: session,
      token: token
    } do
      body = elf() <> String.duplicate("\0", 64) <> "libQnnHtpV68Skel.so"
      {:ok, %{version: nil}} = DSP.store(write_tmp(body))

      page = ingress_call("/ingress/#{token}/", session: session)

      assert page.status == 200
      assert page.resp_body =~ ~s(<dt>Skeleton version</dt><dd class="mono">not detected</dd>)
      assert page.resp_body =~ "libQnnHtpV68Skel.so"
    end

    test "a target with no DSP gets neither instructions nor a form", %{
      session: session,
      token: token
    } do
      Application.delete_env(:vagus, :dsp_root)

      conn = ingress_call("/ingress/#{token}/", session: session)

      assert conn.status == 200
      assert conn.resp_body =~ "no Hexagon DSP"
      refute conn.resp_body =~ "multipart/form-data"
      refute conn.resp_body =~ "Qualcomm AI Runtime"
      refute conn.resp_body =~ "hexagon-v68"
      assert conn.resp_body =~ fingerprint()
    end
  end

  # The method gate is the outer guard. Narrowing it for one path must not
  # let it decay into `dispatch/2`'s 404 for anything else.
  describe "the narrowed method gate" do
    for method <- [:put, :delete, :patch] do
      test "#{method} on the upload path is still 405", %{session: session, token: token} do
        conn = ingress_call("/ingress/#{token}/dsp", method: unquote(method), session: session)
        assert conn.status == 405
      end
    end

    for path <- ["key", "", "index.html", "nope"] do
      test "POST to #{inspect(path)} is 405, not 404", %{session: session, token: token} do
        conn = ingress_call("/ingress/#{token}/#{unquote(path)}", method: :post, session: session)
        assert conn.status == 405
      end
    end

    # The UI lives on the index page; there is deliberately nothing to GET
    # here.
    test "GET on the upload path is 404", %{session: session, token: token} do
      conn = ingress_call("/ingress/#{token}/dsp", session: session)
      assert conn.status == 404
    end
  end

  # Panel-only and admin-gated by design: a `/dsp` route on the Supervisor API
  # would be a new mutating surface for `Vagus.API.Tiers` to grade, with no
  # caller that exists.
  describe "the Supervisor API has no DSP route" do
    for method <- [:get, :post] do
      test "#{method} /dsp is 404" do
        conn =
          unquote(method)
          |> conn("/dsp")
          |> put_req_header("authorization", "Bearer #{Token.get()}")
          |> Router.call(@router_opts)

        assert conn.status == 404
      end
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

  defp upload(token, session, body) do
    ingress_call("/ingress/#{token}/dsp",
      method: :post,
      session: session,
      body: body,
      content_type: "multipart/form-data; boundary=#{@boundary}"
    )
  end

  defp part(field, filename, contents) do
    "--#{@boundary}\r\n" <>
      ~s(content-disposition: form-data; name="#{field}"; filename="#{filename}"\r\n) <>
      "content-type: application/octet-stream\r\n\r\n" <>
      contents <> "\r\n--#{@boundary}--\r\n"
  end

  # Same synthesis as `Vagus.DSPTest` — the real skel cannot be redistributed,
  # so there is no fixture binary to point at. Complete 52-byte header plus the
  # tables it points at, since `store/1` rejects an object that describes more
  # of itself than it carries.
  defp elf(opts \\ []) do
    class = Keyword.get(opts, :class, 1)
    data = Keyword.get(opts, :data, 1)
    type = Keyword.get(opts, :type, 3)
    machine = Keyword.get(opts, :machine, 164)

    <<0x7F, "ELF", class, data, 1, 0::size(72), type::little-16, machine::little-16, 1::little-32,
      0::little-32, @ehsize::little-32, @ehsize + @phentsize::little-32, 0::little-32,
      @ehsize::little-16, @phentsize::little-16, 1::little-16, @shentsize::little-16,
      @shnum::little-16, 2::little-16>> <>
      :binary.copy(<<0>>, @phentsize + @shentsize * @shnum)
  end

  defp skel(arch) do
    elf() <>
      <<0::size(512)>> <>
      "AISW_VERSION: 2.48.40\0" <>
      "libQnnHtpV#{String.trim_leading(arch, "V")}Skel.so\0"
  end

  defp write_tmp(contents) do
    path = Path.join(System.tmp_dir!(), "vagus_dsp_ui_src_#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
