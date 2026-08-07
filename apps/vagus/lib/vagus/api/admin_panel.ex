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
  dispatches anything — by construction, not per route.

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

  alias Vagus.SSHAccess

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
  defp deny(conn, reason, user_id) do
    Logger.warning(
      "vagus admin panel: denied #{conn.method} #{conn.request_path} " <>
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

  ## Responses

  # every interpolated value goes through esc/1 (Plug.HTML.html_escape)
  # sobelow_skip ["XSS.SendResp"]
  defp send_page(conn) do
    case ssh_facts() do
      {:ok, key_type, fingerprint} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("text/html")
        |> send_resp(200, page_html(key_type, fingerprint, key_href(conn)))

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

  defp safely(fun) do
    {:ok, fun.()}
  catch
    :exit, _reason -> :unavailable
  end

  # Core sends `X-Ingress-Path: /api/hassio_ingress/<token>` on every
  # proxied request; an absolute href built from it keeps working no matter
  # how the browser resolved the current URL. The relative fallback covers a
  # direct (non-Core) hit on the ingress path.
  defp key_href(conn) do
    case get_req_header(conn, "x-ingress-path") do
      [path | _rest] when is_binary(path) and path != "" -> path <> "/key"
      _absent -> "key"
    end
  end

  ## Markup — fully self-contained (no external CSS/JS/fonts): this renders
  ## inside an HA iframe, which inherits none of HA's own theme, hence the
  ## explicit light/dark handling.

  defp page_html(key_type, fingerprint, key_href) do
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
    p.lede { margin: 0 0 1.5rem; color: var(--muted); }
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
    ol { margin: 0; padding-left: 1.25rem; }
    ol li { margin-bottom: .75rem; }
    ol li:last-child { margin-bottom: 0; }
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
        <p><a class="download" href="#{esc(key_href)}" download="vagus_ssh_key">Download private key</a></p>
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
    </main>
    </body>
    </html>
    """
  end

  # Defence in depth: every value interpolated above is device-generated
  # (fingerprint, key type, Core's own header), never user input.
  defp esc(value), do: value |> to_string() |> Plug.HTML.html_escape()
end
