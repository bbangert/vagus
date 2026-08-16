defmodule Vagus.API.AdminPanel do
  @moduledoc """
  The **synthetic** `vagus` ingress panel — an admin page in the Home
  Assistant sidebar that is backed by no add-on container at all.

  It shows the device's SSH access key (`Vagus.SSHAccess`) fingerprint plus
  usage instructions, and serves the matching private key as a download.

  ## How Core sees it

  Three Core-facing surfaces, all pointed here:

    * `GET /ingress/panels` (`Vagus.Ingress.Panels.list/1`) advertises
      `panel_entry/0` under the `vagus` slug. That response is parsed by
      `aiohasupervisor`'s strict `IngressPanel` model, so all four of
      `title`/`icon`/`admin`/`enable` must be present — a missing key breaks
      panel registration for *every* add-on, not just this one.
    * `GET /addons/vagus/info` (`Vagus.API.Router`) returns `info/0`. Core's
      frontend panel component (`ha-panel-app`) builds its iframe `src`
      solely from `ingress_url`, refuses to render on a falsy `version`, and
      offers to start the add-on unless `state` is `"startup"`/`"started"`.
      This call travels Core's *untyped* WS proxy, so the minimal payload
      here is safe.
    * `GET /ingress/<token>/…` (`Vagus.API.IngressProxy`) is served by
      `serve/2` instead of being reverse-proxied to a container.

  The synthetic slug deliberately does **not** appear in `GET /addons`:
  that response IS strictly modelled (`InstalledAddon` →
  `InstalledAddonComplete`, ~60 required fields), and a synthetic entry
  there would break the whole add-on coordinator.

  ## Security posture

  Every route here hands out (or describes) a credential granting a root
  shell, so `serve/2` gates on Core **administrator** status before it
  dispatches anything — by construction, not per route. That ordering is
  what makes `POST /dsp` (the operator's `Vagus.DSP` skel upload, the one
  route here that writes) safe to accept: the multipart parse that spools a
  file to disk sits behind the admin check, not beside it.

  Two independent gates stack:

    * `Vagus.API.IngressProxy`'s `check_session/1` — a valid
      `ingress_session` cookie, or 401. Unchanged for this panel.
    * this module's own admin check — 403 for anything else.

  The second gate is necessary because the first proves nothing about
  privilege: Core's `/ingress/session` is in its `WS_NO_ADMIN_ENDPOINTS`
  set, so **non-admin users legitimately mint ingress sessions**. Nor does
  the proxied request itself carry any identity — Core adds only
  `X-Hass-Source`/`X-Ingress-Path`/`X-Forwarded-*`. The caller is therefore
  identified solely by mapping the cookie back to the `user_id` Core sent
  when the session was created (`Vagus.Ingress.session_user/2`).

  Admin status resolves through `Vagus.Core.Users.admin?/2` (swappable via
  `config :vagus, :core_users`), which reads Core's WS `config/auth/list` —
  the only surface that answers this; Core has no REST equivalent — and
  derives the verdict exactly as Core itself does
  (`homeassistant/auth/models.py`):

      is_owner or (is_active and "system-admin" in group_ids)

  Verdicts are cached for 30 seconds there, so a panel reload doesn't
  hammer Core.

  **Fail closed.** Access is granted on `{:ok, true}` and nothing else:
  a missing cookie, an unknown/expired session, a session with no recorded
  user (Core sent none, or it predates this being recorded), `{:ok, false}`,
  and every `{:error, _}` — including Core being unreachable — are all 403.

  This is a deliberate deviation from the real Supervisor, which does not
  enforce admin on ingress at all (it only forwards `X-Remote-User-*`
  headers to the add-on and lets the add-on decide). Upstream has no
  Supervisor-owned panel handing out the host's root key, so it has nothing
  to protect here; Vagus does.
  """

  import Plug.Conn

  require Logger

  alias Vagus.{DSP, SSHAccess}

  @slug "vagus"
  @title "Vagus"
  @icon "mdi:key-chain"

  @doc "The reserved slug of the synthetic panel."
  @spec slug() :: String.t()
  def slug, do: @slug

  @doc """
  The `GET /ingress/panels` entry for this panel — exactly the four
  string keys `aiohasupervisor`'s `IngressPanel` model requires.
  """
  @spec panel_entry() :: %{String.t() => String.t() | boolean()}
  def panel_entry do
    %{"title" => @title, "icon" => @icon, "admin" => true, "enable" => true}
  end

  @doc """
  The `GET /addons/vagus/info` payload the frontend's `ha-panel-app` needs:
  a truthy `version`, a `state` it won't offer to "start", and the
  `ingress_url` it builds the iframe `src` from.

  The trailing slash on `ingress_url` is load-bearing — relative links
  inside the iframe resolve against it.

  `ingress_url` is `nil` when `Vagus.Ingress` isn't running (e.g.
  `:ingress_enabled false`); the frontend then reports "no ingress" rather
  than rendering a broken iframe.
  """
  @spec info() :: %{String.t() => term()}
  def info do
    %{
      "slug" => @slug,
      "name" => @title,
      "version" => version(),
      "state" => "started",
      "ingress_url" => ingress_url()
    }
  end

  @doc """
  Serves the panel itself. `rest` is `conn.path_info` with the leading
  `["ingress", token]` already stripped, exactly as
  `Vagus.API.IngressProxy` splits it — so the panel root
  (`GET /ingress/<token>/`) arrives as `[]`.

  The caller has already validated the `ingress_session` cookie (401 on
  failure). This function additionally requires the session's Core user to
  be an administrator, ahead of *any* dispatch — see the moduledoc's
  "Security posture" — and answers 403 if not.
  """
  @spec serve(Plug.Conn.t(), [String.t()]) :: Plug.Conn.t()
  def serve(conn, rest) do
    case authorize(conn) do
      :ok -> serve_authorized(conn, rest)
      {:denied, reason, user_id} -> deny(conn, reason, user_id)
    end
  end

  defp serve_authorized(%Plug.Conn{method: method} = conn, rest)
       when method in ["GET", "HEAD"] do
    dispatch(conn, rest)
  end

  # The panel's "only ever reads" guarantee is narrowed here, not dropped:
  # exactly one path accepts exactly one method. The method gate stays the
  # outer guard so a POST anywhere else is still 405 rather than falling
  # through to `dispatch/2`'s 404, and `serve/2` still runs `authorize/1`
  # ahead of every clause in this group — nothing about the upload is
  # reachable, or even parsed, without admin.
  defp serve_authorized(%Plug.Conn{method: "POST"} = conn, ["dsp"]), do: handle_dsp_upload(conn)

  defp serve_authorized(conn, _rest), do: send_plain(conn, 405, "Method Not Allowed")

  ## Authorization (see the moduledoc's "Security posture")

  # `Vagus.API.IngressProxy.call/2` already ran `fetch_cookies/1` before
  # dispatching here, but this is the gate on the device's root key — it
  # calls it again rather than trusting an upstream plug to have done so.
  # `fetch_cookies/1` is idempotent (`%Plug.Conn{cookies: %Unfetched{}}` is
  # the only state it acts on), so the repeat costs nothing.
  defp authorize(conn) do
    case fetch_cookies(conn).cookies["ingress_session"] do
      session when is_binary(session) -> authorize_session(session)
      _missing -> {:denied, :no_session_cookie, nil}
    end
  end

  defp authorize_session(session) do
    case session_user(session) do
      {:ok, user_id} when is_binary(user_id) -> authorize_user(user_id)
      {:ok, nil} -> {:denied, :session_has_no_user, nil}
      :error -> {:denied, :unknown_session, nil}
    end
  end

  defp authorize_user(user_id) do
    case users_mod().admin?(user_id) do
      {:ok, true} -> :ok
      {:ok, false} -> {:denied, :not_admin, user_id}
      {:error, reason} -> {:denied, {:unresolved, reason}, user_id}
      other -> {:denied, {:unresolved, {:unexpected_result, other}}, user_id}
    end
  end

  # `Vagus.Ingress` is gated by `:ingress_enabled`, so — like `SSHAccess`
  # above — a call to a dead name exits and would take the connection down.
  # An absent session store can answer for no session, which is a denial.
  defp session_user(session) do
    Vagus.Ingress.session_user(session)
  catch
    :exit, _reason -> :error
  end

  defp users_mod, do: Application.get_env(:vagus, :core_users, Vagus.Core.Users)

  # The body deliberately carries no fingerprint, no key material and no
  # hint about which condition failed; the reason and user id go to the log
  # instead, where an operator diagnosing "why can't I see my key" can find
  # them.
  #
  # The request path is deliberately NOT logged: it embeds the per-boot
  # ingress token, a bearer capability for this panel, and RingLogger
  # persists what is written here. Same for the query string and headers.
  defp deny(conn, reason, user_id) do
    Logger.warning(
      "vagus admin panel: denied #{conn.method} " <>
        "(reason=#{inspect(reason)} user_id=#{inspect(user_id)})"
    )

    send_plain(conn, 403, "Forbidden: Home Assistant administrators only")
  end

  ## Dispatch

  defp dispatch(conn, []), do: send_page(conn)
  defp dispatch(conn, [""]), do: send_page(conn)
  defp dispatch(conn, ["index.html"]), do: send_page(conn)
  defp dispatch(conn, ["key"]), do: send_key(conn)
  defp dispatch(conn, _other), do: send_plain(conn, 404, "Not Found")

  ## DSP skel upload

  # `Plug.Parsers.init/1` only normalizes options into an opaque tuple, so
  # computing it once at compile time is safe. The cap is `Vagus.DSP`'s own,
  # not a second number beside it: the parser must refuse what `store/1`
  # would refuse anyway, and the two drifting apart would spool a file to
  # disk only to reject it.
  @dsp_parser_opts Plug.Parsers.init(
                     parsers: [{:multipart, length: DSP.max_bytes()}],
                     pass: []
                   )

  # Multipart is parsed HERE (B1), not upstream: `Vagus.API.Dispatcher` sends
  # the ingress leg nowhere near the router's `Plug.Parsers`, and
  # `IngressProxy.route/3` hands this module an unread body. So the
  # disk-spooling parse happens only after `serve/2`'s admin check has passed
  # — a non-admin POST costs a 403 and nothing else.
  #
  # No CSRF token: the URL an attacker would have to target embeds the
  # per-boot ingress token, which is already the bearer capability for this
  # whole panel.
  #
  # Any field name is accepted (the first `%Plug.Upload{}` in the parsed
  # params), matching `handle_backup_upload/1`'s tolerance in
  # `Vagus.API.Router`.
  defp handle_dsp_upload(conn) do
    case parse_multipart(conn) do
      {:ok, conn} ->
        case first_upload(conn.body_params) do
          {:ok, %Plug.Upload{path: path}} -> store_skel(conn, path)
          :error -> refuse(conn, :no_file)
        end

      {:error, conn, reason} ->
        refuse(conn, reason)
    end
  end

  # `store/1` returns the info it just wrote, so the page renders from that
  # rather than asking `status/0` to re-read the file it has already read.
  defp store_skel(conn, path) do
    case DSP.store(path) do
      {:ok, info} -> send_page(conn, 200, :stored, {:configured, info})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  defp refuse(conn, reason),
    do: send_page(conn, status_for(reason), {:error, reason}, dsp_status())

  # 400 says the operator's file was wrong. These two say the device could
  # not take it — a full or read-only data partition, fixed by freeing space
  # rather than by choosing a different `.so` — so they get the status that
  # means that instead of blaming the upload.
  defp status_for(:spool_failed), do: 507
  defp status_for({:store_failed, _posix}), do: 507
  defp status_for(_reason), do: 400

  # `pass: []` means a non-multipart content-type raises
  # `UnsupportedMediaTypeError` rather than passing through unparsed, and a
  # malformed body raises `ParseError`.
  #
  # Everything else `Plug.Parsers.MULTIPART` can raise it deliberately
  # *re-raises* instead of wrapping in `ParseError`, so the rescue list must
  # name each one — and there is no `Plug.ErrorHandler` anywhere on the
  # ingress leg (unlike the router, which catches these for the backup
  # upload), so anything that escapes is a Bandit 500 on the page that hands
  # out the device's root SSH key:
  #
  #   * `RequestTooLargeError` — the cap above firing.
  #   * `BadEncodingError` — a non-file part whose bytes are not UTF-8, i.e.
  #     client-triggerable at will.
  #   * `UploadError` — `Plug.Upload.random_file!/1` could not spool. NOT the
  #     missing `PLUG_TMPDIR` case (`generate_tmp_dir/0` creates it); on this
  #     device it means a full or read-only data partition, which is the one
  #     failure here that is not the operator's file being wrong.
  defp parse_multipart(conn) do
    {:ok, Plug.Parsers.call(conn, @dsp_parser_opts)}
  rescue
    e in Plug.Parsers.RequestTooLargeError ->
      Logger.debug("vagus admin panel: DSP upload over cap: #{Exception.message(e)}")
      {:error, conn, :too_large}

    e in Plug.UploadError ->
      Logger.warning(
        "vagus admin panel: DSP upload could not be spooled: #{Exception.message(e)}"
      )

      {:error, conn, :spool_failed}

    e in [
      Plug.Parsers.ParseError,
      Plug.Parsers.UnsupportedMediaTypeError,
      Plug.Parsers.BadEncodingError
    ] ->
      Logger.debug("vagus admin panel: DSP upload parse failed: #{Exception.message(e)}")
      {:error, conn, :unparsable}
  end

  defp first_upload(params) do
    case Enum.find_value(params, fn {_key, value} -> match?(%Plug.Upload{}, value) and value end) do
      %Plug.Upload{} = upload -> {:ok, upload}
      _none -> :error
    end
  end

  # `Vagus.DSP.status/0` reads the stored skel whole to rescan its embedded
  # version — both markers sit megabytes into a 10 MB file, so no bounded
  # read is possible. That is fine for a page a human loads by hand; nothing
  # that polls may call it.
  defp dsp_status, do: DSP.status()

  ## Responses

  defp send_page(conn), do: send_page(conn, 200, nil, dsp_status())

  # every interpolated value goes through esc/1 (Plug.HTML.html_escape)
  # sobelow_skip ["XSS.SendResp"]
  defp send_page(conn, status, notice, dsp) do
    case ssh_facts() do
      {:ok, key_type, fingerprint} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("text/html")
        |> send_resp(status, page_html(key_type, fingerprint, conn, notice, dsp))

      :unavailable ->
        send_plain(conn, 503, "SSH access key unavailable")
    end
  end

  # a PEM download (application/x-pem-file, attachment), never HTML
  # sobelow_skip ["XSS.SendResp"]
  defp send_key(conn) do
    case safely(&SSHAccess.private_key/0) do
      {:ok, pem} ->
        conn
        # `Content-Disposition` and `Cache-Control` survive Core's ingress
        # proxy verbatim (it only regenerates the framing/content-type
        # headers), so the browser really does get a download.
        |> put_resp_header("content-type", "application/x-pem-file")
        |> put_resp_header("content-disposition", ~s(attachment; filename="vagus_ssh_key"))
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, pem)

      :unavailable ->
        send_plain(conn, 503, "SSH access key unavailable")
    end
  end

  defp send_plain(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end

  ## Data

  defp version do
    case Application.spec(:vagus, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  defp ingress_url do
    case Vagus.Ingress.admin_token() do
      {:ok, token} -> "/api/hassio_ingress/#{token}/"
      {:error, :unavailable} -> nil
    end
  end

  # `Vagus.SSHAccess` is gated by `:ssh_access_enabled` and does its keygen
  # in `handle_continue/2`, so it can legitimately be absent (host unit
  # tests) — a `GenServer.call/2` to a dead name exits, which would take the
  # whole connection down instead of answering.
  defp ssh_facts do
    with {:ok, fingerprint} <- safely(&SSHAccess.fingerprint/0) do
      {:ok, SSHAccess.key_type(), fingerprint}
    end
  end

  # Two distinct "no key" conditions collapse to the same 503: a dead/absent
  # server (exit), and a live one running degraded — `Vagus.SSHAccess`
  # answers `{:error, :unavailable}` when its store could not be proven mode
  # 0600, so it holds no keypair at all.
  defp safely(fun) do
    case fun.() do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> :unavailable
    end
  catch
    :exit, _reason -> :unavailable
  end

  # Core sends `X-Ingress-Path: /api/hassio_ingress/<token>` on every
  # proxied request; an absolute href built from it keeps working no matter
  # how the browser resolved the current URL. The relative fallback covers a
  # direct (non-Core) hit on the ingress path — and for the upload form it is
  # also what makes the POST land back on `/dsp` rather than one level up,
  # since the browser is already sitting on the panel root.
  defp href(conn, path) do
    case get_req_header(conn, "x-ingress-path") do
      [prefix | _rest] when is_binary(prefix) and prefix != "" -> prefix <> "/" <> path
      _absent -> path
    end
  end

  ## Markup — fully self-contained (no external CSS/JS/fonts): this renders
  ## inside an HA iframe, which inherits none of HA's own theme, hence the
  ## explicit light/dark handling.

  defp page_html(key_type, fingerprint, conn, notice, dsp) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Vagus SSH access</title>
    <style>
    :root {
      color-scheme: light dark;
      --bg: #f5f6f8; --fg: #1c1c1e; --muted: #5a6068;
      --card: #ffffff; --border: #d9dce1; --code-bg: #eef0f3;
      --accent: #0b74c4; --accent-fg: #ffffff;
      --warn-bg: #fdf3e3; --warn-border: #e0a95c; --warn-fg: #6b4a0c;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #16181c; --fg: #e6e8eb; --muted: #9aa2ad;
        --card: #1f2228; --border: #343943; --code-bg: #12141a;
        --accent: #4aa3e8; --accent-fg: #0b1016;
        --warn-bg: #33270f; --warn-border: #8a6a22; --warn-fg: #f0d9a6;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; padding: 24px 16px; background: var(--bg); color: var(--fg);
      font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
      line-height: 1.5;
    }
    main { max-width: 46rem; margin: 0 auto; }
    h1 { font-size: 1.5rem; margin: 0 0 .25rem; }
    h2 { font-size: 1.05rem; margin: 0 0 .5rem; }
    h3 { font-size: .95rem; margin: 1.4rem 0 .5rem; }
    p.lede { margin: 0 0 1.5rem; color: var(--muted); }
    p.note { color: var(--muted); font-size: .92rem; }
    section {
      background: var(--card); border: 1px solid var(--border);
      border-radius: 10px; padding: 16px 18px; margin-bottom: 16px;
    }
    dl { margin: 0; display: grid; grid-template-columns: auto 1fr; gap: .35rem .9rem; }
    dt { color: var(--muted); }
    dd { margin: 0; }
    code, pre, dd.mono {
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: .9rem;
    }
    pre {
      background: var(--code-bg); border: 1px solid var(--border);
      border-radius: 8px; padding: 12px; margin: 0;
      overflow-x: auto; white-space: pre;
    }
    ol, ul { margin: 0; padding-left: 1.25rem; }
    ol li, ul li { margin-bottom: .75rem; }
    ol li:last-child, ul li:last-child { margin-bottom: 0; }
    code { background: var(--code-bg); border-radius: 4px; padding: .05rem .3rem; }
    pre code { background: none; padding: 0; }
    a.download {
      display: inline-block; background: var(--accent); color: var(--accent-fg);
      text-decoration: none; font-weight: 600;
      padding: .7rem 1.2rem; border-radius: 8px;
    }
    a.download:hover { filter: brightness(1.08); }
    .warn {
      background: var(--warn-bg); border: 1px solid var(--warn-border);
      color: var(--warn-fg); border-radius: 8px; padding: 12px 14px;
      margin-top: 14px;
    }
    .warn strong { font-weight: 700; }
    </style>
    </head>
    <body>
    <main>
      <h1>SSH access</h1>
      <p class="lede">
        This device generated its own SSH keypair on first boot and authorized
        the public half for logins. Download the private half below to get a
        shell on the device.
      </p>

      <section>
        <h2>Device key</h2>
        <dl>
          <dt>Type</dt><dd class="mono">#{esc(key_type)}</dd>
          <dt>Fingerprint</dt><dd class="mono">#{esc(fingerprint)}</dd>
        </dl>
      </section>

      <section>
        <h2>Download</h2>
        <p>Save the private key, then restrict its permissions — OpenSSH
           refuses to use a world-readable key file.</p>
        <p><a class="download" href="#{esc(href(conn, "key"))}" download="vagus_ssh_key">Download private key</a></p>
        <div class="warn">
          <strong>This key grants a root shell on this device.</strong>
          Treat it as a credential: store it somewhere safe and never share it.
        </div>
      </section>

      <section>
        <h2>Connecting</h2>
        <ol>
          <li>
            Restrict the key file's permissions:
            <pre>chmod 600 vagus_key</pre>
          </li>
          <li>
            Connect:
            <pre>ssh -i vagus_key root@&lt;device&gt;.local</pre>
          </li>
        </ol>
        <p>The device's SSH daemon is configured for public-key authentication
           only, so the username is ignored — any name works, and there is no
           password to enter. You land in an IEx prompt.</p>
      </section>

      #{dsp_section(conn, notice, dsp)}
    </main>
    </body>
    </html>
    """
  end

  defp dsp_section(conn, notice, dsp) do
    """
    <section>
      <h2>DSP acceleration</h2>
      #{notice_html(notice)}
      #{dsp_state_html(dsp)}
      #{dsp_form_html(conn, dsp)}
    </section>
    """
  end

  defp dsp_state_html(:unsupported),
    do: "<p>This device has no Hexagon DSP, so there is nothing to configure here.</p>"

  # The operator has to find one file inside a 2.4 GB SDK tree, so this names
  # the path, the two neighbours that look like it, and the archive they must
  # not upload. A path that does not exist in the download fails the whole
  # feature at its only user-facing step.
  defp dsp_state_html(:not_configured) do
    """
    <p>Add-ons that run models on this device's Hexagon DSP need Qualcomm's QNN
       skeleton library. Qualcomm does not permit redistributing it, so it is
       not in the Vagus image and no add-on may ship it either — you supply it
       once, here. It is kept on the data partition and survives updates.</p>
    <p><strong>No skeleton library is stored yet.</strong> An add-on that asks
       for DSP access will fail to start until one is.</p>

    <h3>Getting the file</h3>
    <ol>
      <li>On your own computer, download the
          <strong>Qualcomm AI Runtime (QAIRT) SDK</strong> from Qualcomm's
          developer site. It needs a Qualcomm account, which is why this device
          cannot fetch it for you.</li>
      <li>Extract the archive there. The download is about 2.4&nbsp;GB.</li>
      <li>Inside the extracted SDK, take exactly this file:
          <pre>#{esc(skel_path())}</pre>
          It is around 10&nbsp;MB.</li>
      <li>Upload that one file with the form below.</li>
    </ol>

    <h3>Three ways to pick the wrong file</h3>
    <ul>
      <li><strong><code>lib-safe/</code> is a different tree.</strong> The SDK
          ships <code>lib-safe/</code> beside <code>lib/</code>, and that one
          carries only v73 and v81 — so the <code>hexagon-v*</code> directory
          you are looking for may simply not be in it, which reads as the file
          not existing. Take it from <code>lib/</code>, which carries all
          seven.</li>
      <li><strong><code>Stub</code> is not <code>Skel</code>.</strong>
          <code>lib/aarch64-oe-linux-gcc11.2/libQnnHtp#{esc(expected_arch())}Stub.so</code>
          is one word away in a directory listing and is a different file: the
          host-side stub for this device's own CPU, not the Hexagon skeleton.
          The name you want ends in <code>Skel.so</code>.</li>
      <li><strong>The SDK archive is not the file.</strong> Upload the
          extracted <code>.so</code>, never the 2.4&nbsp;GB download it came
          in — this device will refuse it.</li>
    </ul>
    <p>The <code>lib/</code> tree holds seven near-identical
       <code>hexagon-v*/unsigned/</code> directories, one per Hexagon version.
       This device needs <strong>#{esc(expected_arch())}</strong>; a skeleton
       from any of the others will not load.</p>
    """
  end

  defp dsp_state_html({:configured, info}) do
    """
    #{arch_warning_html(info)}
    <dl>
      <dt>File</dt><dd class="mono">#{esc(info.filename)}</dd>
      <dt>Architecture</dt><dd class="mono">#{esc(info.arch)}</dd>
      <dt>Skeleton version</dt><dd class="mono">#{esc(info.version || "not detected")}</dd>
      <dt>cDSP firmware</dt><dd class="mono">#{esc(DSP.cdsp_version() || "unknown")}</dd>
      <dt>Size</dt><dd class="mono">#{esc(info.size)} bytes</dd>
      <dt>Stored</dt><dd class="mono">#{esc(info.stored_at)}</dd>
    </dl>
    <p class="note">Those two version numbers are <strong>different numbering
       schemes and cannot be compared</strong> — neither says anything about
       the other, and this device does not check them against each other. What
       has to match is this skeleton against the QAIRT SDK the add-on's own QNN
       libraries were built from. That is the add-on author's contract; Vagus
       cannot see inside an add-on image to verify it.</p>
    """
  end

  # A skeleton for another Hexagon version does not load, and QNN then falls
  # back to the CPU reporting nothing — so the upload is the only place this
  # is ever visible. It warns and keeps the file: `:dsp_arch` being wrong for
  # a board must not be able to lock the operator out of storing anything.
  defp arch_warning_html(%{arch: arch}) do
    case DSP.expected_arch() do
      nil -> ""
      ^arch -> ""
      expected -> arch_mismatch_html(arch, expected)
    end
  end

  defp arch_mismatch_html(stored, expected) do
    """
    <div class="warn">
      <strong>This skeleton library is for the wrong DSP.</strong>
      It is #{esc(stored)}; this device's DSP is #{esc(expected)}. A skeleton
      built for another Hexagon version does not load, and QNN then falls back
      to the CPU <strong>without reporting an error</strong> — the add-on still
      runs, just far slower. Upload <code>#{esc(skel_path())}</code> instead.
      The file described below is stored all the same, and is still what a DSP
      add-on will be given.
    </div>
    """
  end

  defp dsp_form_html(_conn, :unsupported), do: ""

  defp dsp_form_html(conn, {:configured, _info}) do
    upload_form(
      conn,
      "Replace it",
      "<p>Uploading another file replaces the one above — this device keeps " <>
        "exactly one skeleton library.</p>"
    )
  end

  defp dsp_form_html(conn, _not_configured), do: upload_form(conn, "Upload it", "")

  defp upload_form(conn, heading, lede) do
    """
    <h3>#{esc(heading)}</h3>
    #{lede}
    <form method="post" action="#{esc(href(conn, "dsp"))}" enctype="multipart/form-data">
      <p><input type="file" name="skel" accept=".so"></p>
      <p><button type="submit">Upload skeleton library</button></p>
    </form>
    """
  end

  # Named from `:dsp_arch` so the copy tracks the board rather than hardcoding
  # a version that rots when a v73 board arrives. The placeholder is the same
  # one the refusal sentences use, for the misconfigured case where a board
  # declares a store but not an architecture.
  defp expected_arch, do: DSP.expected_arch() || "V<NN>"

  defp skel_path do
    arch = expected_arch()
    "lib/hexagon-#{String.downcase(arch)}/unsigned/libQnnHtp#{arch}Skel.so"
  end

  defp notice_html(nil), do: ""
  defp notice_html(:stored), do: "<p><strong>Stored.</strong></p>"

  defp notice_html({:error, reason}),
    do: ~s(<div class="warn">#{esc(reason_sentence(reason))}</div>)

  # The operator is a human who just picked one file out of a 2.4 GB SDK
  # tree, so every reason names the mistake rather than restating the atom —
  # telling them which file to pick is the entire point of this surface.
  defp reason_sentence(:unsupported),
    do: "This device has no DSP, so there is nothing to store a skeleton library for."

  defp reason_sentence(:too_large) do
    "That file is larger than #{div(DSP.max_bytes(), 1024 * 1024)} MB. " <>
      "Upload the extracted libQnnHtpV<NN>Skel.so — a few megabytes — not the " <>
      "SDK archive you downloaded it in."
  end

  defp reason_sentence(:not_hexagon) do
    "That is a library for this device's own CPU, not for the DSP. The aarch64 " <>
      "stub sits one directory away from the skeleton; the file you want is the " <>
      "libQnnHtpV<NN>Skel.so under the SDK's hexagon-v<NN>/unsigned directory."
  end

  defp reason_sentence(:not_elf),
    do: "That is not a shared library at all. Upload the extracted libQnnHtpV<NN>Skel.so."

  defp reason_sentence(:truncated),
    do: "That file is too short to be a library — the upload or the extraction was cut off."

  defp reason_sentence(:not_32bit),
    do: "That claims to be a Hexagon object but is 64-bit, so it is not a DSP skeleton."

  defp reason_sentence(:not_little_endian),
    do: "That claims to be a Hexagon object but is big-endian, so it is not a DSP skeleton."

  defp reason_sentence(:not_shared_object),
    do: "That is a Hexagon object but not a shared library — the skeleton is a .so."

  defp reason_sentence(:no_skel_marker),
    do: "That is a Hexagon library, but not a QNN skeleton — it names no libQnnHtpV<NN>Skel.so."

  defp reason_sentence(:ambiguous_skel_marker),
    do: "That file names more than one skeleton library, so it cannot say which one it is."

  defp reason_sentence(:no_file),
    do: "No file was attached. Choose the libQnnHtpV<NN>Skel.so and submit again."

  defp reason_sentence(:unparsable),
    do: "That upload could not be read as a file submission. Try again from the form above."

  defp reason_sentence({:unreadable, posix}),
    do: "The uploaded file could not be read (#{posix})."

  # Nothing is wrong with the file, and saying otherwise would send the
  # operator back to the SDK tree to hunt for a different one.
  defp reason_sentence(:spool_failed) do
    "The device could not save the upload — its data partition is most likely " <>
      "full or read-only. Free some space and submit the same file again."
  end

  defp reason_sentence({:store_failed, posix}),
    do: "The device could not write the skeleton library to its own storage (#{posix})."

  # Defence in depth: every value interpolated above is device-generated
  # (fingerprint, key type, Core's own header) or one of the fixed sentences
  # below, never user input.
  defp esc(value), do: value |> to_string() |> Plug.HTML.html_escape()
end
