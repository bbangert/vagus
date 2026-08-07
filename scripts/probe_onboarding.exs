# Fresh-onboarding probe for a real Home Assistant Core container driven by
# the host dev-loop emulator (`scripts/dev-core.sh`). Run from the umbrella
# root against a Core whose /config volume is empty:
#
#     scripts/dev-core.sh reset
#     CORE_VERSION=2026.8.0 CORE_PORT=80 HOST_PORT=80 LEGACY_HOST_PORT=8123 \
#       scripts/dev-core.sh up
#     mix run --no-start scripts/probe_onboarding.exs
#
# It drives onboarding end to end over REST + the WebSocket API (the exact
# frontend calls, including the analytics step that was issue #11's repro) and
# asserts the port contract a supervised Core 2026.8 install has:
#
#   * Core binds `SUPERVISOR_DEFAULT_PORT` (80) on a fresh supervised install,
#     not the legacy 8123 — asserted over the Supervisor unix socket via
#     `GET /api/core/http_config`, the same endpoint (and implicit auth)
#     `Vagus.Core.HttpConfig` pulls on a device, so the assertion is about the
#     port Core BOUND rather than the host port it happens to be published on.
#   * While onboarding is pending, 8123 serves a method-preserving 307 to the
#     active port (Core's `_async_start_legacy_redirect`).
#   * Once the last onboarding step lands, that redirect listener is torn down
#     and 8123 stops answering entirely.
#
# Every check prints `ok`/`FAIL` with the observed evidence and the script
# exits non-zero if any failed, so it is usable as a one-shot gate.
#
# Environment (all optional):
#   CORE_BASE         base URL Core serves on            (http://localhost)
#   CORE_LEGACY_BASE  base URL of the legacy port        (http://localhost:8123)
#   CORE_PORT         port Core is expected to bind      (derived from CORE_BASE)
#   CORE_SOCKET       Core's Supervisor unix socket      (.dev/core-socket/core.sock)
#   SUPERVISOR_BASE   the emulator's API                 (http://localhost:8888)
#   SUPERVISOR_TOKEN  emulator bearer token              (read from .dev/supervisor_token)
#   PROBE_USERNAME / PROBE_PASSWORD / PROBE_NAME
#
# CORE_BASE is what the *probe* dials, i.e. the published host mapping; the
# port Core itself binds inside the container is `CORE_PORT`. They are the same
# number in the documented dev-loop invocation above, but keep them separable:
# publishing on a different host port is the fallback when the workstation's
# :80 is occupied, and the contract under test is Core's own bind.

{:ok, _} = Application.ensure_all_started(:req)

defmodule Probe do
  @moduledoc false

  # Core's own default: onboarding can take a while to answer the first time
  # (a fresh container installs the frontend's storage on boot).
  @boot_timeout_ms 180_000
  @poll_ms 2_000

  def start do
    :ets.new(:probe_results, [:named_table, :public, :duplicate_bag])
    :ok
  end

  def check(label, fun) do
    case safe(fun) do
      {:ok, evidence} ->
        record(:ok, label, evidence)
        IO.puts(IO.ANSI.green() <> "ok   " <> IO.ANSI.reset() <> label <> " — " <> evidence)
        :ok

      {:error, evidence} ->
        record(:error, label, evidence)
        IO.puts(IO.ANSI.red() <> "FAIL " <> IO.ANSI.reset() <> label <> " — " <> evidence)
        :error
    end
  end

  def info(label, evidence) do
    IO.puts(IO.ANSI.faint() <> "info " <> label <> " — " <> evidence <> IO.ANSI.reset())
  end

  defp safe(fun) do
    fun.()
  rescue
    error -> {:error, "raised " <> Exception.message(error)}
  catch
    kind, value -> {:error, "caught #{kind} #{inspect(value)}"}
  end

  defp record(status, label, evidence),
    do: :ets.insert(:probe_results, {status, label, evidence})

  def failures, do: :ets.lookup(:probe_results, :error)

  @doc "Polls `fun` until it returns `{:ok, _}`; the last error wins on timeout."
  def until(fun, timeout_ms \\ @boot_timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_until(fun, deadline)
  end

  defp do_until(fun, deadline) do
    case fun.() do
      {:ok, value} ->
        {:ok, value}

      {:error, reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, reason}
        else
          Process.sleep(@poll_ms)
          do_until(fun, deadline)
        end
    end
  end

  @doc """
  A GET that never follows redirects and never retries.

  Both matter here: the 307 stub IS the assertion, and once the stub is torn
  down the expected outcome is a connection error, which Req's default
  `retry: :safe_transient` would otherwise sit on for ~10s per attempt.
  """
  def raw_get(url, opts \\ []) do
    Req.get(url, [redirect: false, retry: false, receive_timeout: 15_000] ++ opts)
  end

  @doc """
  A GET over Core's Supervisor unix socket — no Bearer token, by design.

  Upstream treats every request arriving on that socket as the Supervisor
  user (`SUPERVISOR_CORE_API_SOCKET`), which is the same implicit-auth path
  `Vagus.Core.Transport` uses on a device. `hostname:` is not optional: a
  `{:local, _}` address carries none, and Mint needs one for the `host`
  header (`Transport.connect_opts/1` supplies the same "localhost").
  """
  def socket_get(socket_path, path) do
    connect_opts = [hostname: "localhost", protocols: [:http1]]

    with {:ok, conn} <- Mint.HTTP.connect(:http, {:local, socket_path}, 0, connect_opts),
         {:ok, conn, ref} <- Mint.HTTP.request(conn, "GET", path, [], nil),
         {:ok, status, body} <- socket_recv(conn, ref, nil, "") do
      {:ok, status, Jason.decode!(body)}
    else
      {:error, _conn, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp socket_recv(conn, ref, status, body) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            {status, body, done?} =
              Enum.reduce(responses, {status, body, false}, fn
                {:status, ^ref, value}, {_status, body, done?} -> {value, body, done?}
                {:data, ^ref, data}, {status, body, done?} -> {status, body <> data, done?}
                {:done, ^ref}, {status, body, _done?} -> {status, body, true}
                _other, acc -> acc
              end)

            if done?,
              do: {:ok, status, body},
              else: socket_recv(conn, ref, status, body)

          {:error, _conn, reason, _responses} ->
            {:error, reason}
        end
    after
      15_000 -> {:error, :timeout}
    end
  end
end

base = System.get_env("CORE_BASE", "http://localhost")
legacy_base = System.get_env("CORE_LEGACY_BASE", "http://localhost:8123")
supervisor_base = System.get_env("SUPERVISOR_BASE", "http://localhost:8888")

# The port Core is expected to have BOUND (in-container), which is what the
# emulator sees over the socket — not necessarily the port this probe dials.
expected_core_port =
  case System.get_env("CORE_PORT") do
    nil -> URI.parse(base).port
    value -> String.to_integer(value)
  end

core_socket =
  System.get_env("CORE_SOCKET") ||
    (
      path = Path.expand("../.dev/core-socket/core.sock", __DIR__)
      if File.exists?(path), do: path
    )

supervisor_token =
  System.get_env("SUPERVISOR_TOKEN") ||
    (
      path = Path.expand("../.dev/supervisor_token", __DIR__)
      if File.exists?(path), do: path |> File.read!() |> String.trim()
    )

client_id = base <> "/"
redirect_uri = client_id <> "?auth_callback=1"
username = System.get_env("PROBE_USERNAME", "probe")
password = System.get_env("PROBE_PASSWORD", "probe-pass-123")
name = System.get_env("PROBE_NAME", "Probe")

Probe.start()
Probe.info("target", "core #{base} (expects bind :#{expected_core_port}), legacy #{legacy_base}")

# ---------------------------------------------------------------------------
# 1. Core answers on the port it is supposed to have bound, un-onboarded.
# ---------------------------------------------------------------------------

steps =
  Probe.until(fn ->
    case Probe.raw_get(base <> "/api/onboarding") do
      {:ok, %{status: 200, body: body}} when is_list(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "status #{status}"}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end)

case steps do
  {:ok, body} ->
    Probe.check("Core serves onboarding on #{base}", fn ->
      pending = for %{"step" => step, "done" => false} <- body, do: step

      if pending == [] do
        {:error, "Core is already onboarded (#{inspect(body)}) — run dev-core.sh reset first"}
      else
        {:ok, "GET /api/onboarding 200, pending steps #{inspect(pending)}"}
      end
    end)

  {:error, reason} ->
    Probe.check("Core serves onboarding on #{base}", fn -> {:error, reason} end)
    IO.puts("\nCore never answered on #{base}; aborting.")
    System.halt(1)
end

# A fresh Core answers `/` with a 302 to the onboarding route (and 200 once
# onboarded), so any 2xx/3xx counts — as long as a redirect keeps us on the
# same port. That last part is the point of the check: it distinguishes the
# real frontend from the legacy stub's port-rewriting 307.
Probe.check("Core serves the frontend on #{base}", fn ->
  case Probe.raw_get(base <> "/") do
    {:ok, %{status: status} = response} when status >= 200 and status < 400 ->
      location = response |> Req.Response.get_header("location") |> List.first()
      port = if location, do: URI.parse(location).port

      if port in [nil, expected_core_port] do
        {:ok, "GET / #{status}#{if location, do: " -> " <> location, else: ""}"}
      else
        {:error, "GET / #{status} -> #{location} (port #{port} != #{expected_core_port})"}
      end

    {:ok, %{status: status}} ->
      {:error, "GET / #{status}"}

    {:error, error} ->
      {:error, Exception.message(error)}
  end
end)

# ---------------------------------------------------------------------------
# 2. The port Core reports over the Supervisor unix socket — the authority for
#    which port it actually bound, independent of the published host mapping.
# ---------------------------------------------------------------------------

if core_socket do
  Probe.check("Core reports port #{expected_core_port} over the Supervisor socket", fn ->
    case Probe.socket_get(core_socket, "/api/core/http_config") do
      {:ok, 200, %{"port" => ^expected_core_port} = body} ->
        {:ok, "GET /api/core/http_config (unix) 200 #{Jason.encode!(body)}"}

      {:ok, 200, %{"port" => port}} ->
        {:error, "Core reports port #{port}, expected #{expected_core_port}"}

      {:ok, status, body} ->
        {:error, "status #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end)
else
  Probe.info("Supervisor socket", "skipped — no CORE_SOCKET and no .dev/core-socket/core.sock")
end

# The same value as vagus itself serves it. Informational, NOT a check: the
# cache behind `/core/info` is `Vagus.Core.HttpConfig`, refreshed from
# `Vagus.Core.Lifecycle`'s health gate and its already-running branch — both
# driven by `Vagus.Core.Boot`/the container engine, which the host dev loop
# does not have (`:core_boot` is target-only). On host it therefore reports
# `HttpConfig.defaults/0` (8123) until something triggers a refresh; on a
# device it is the real assertion and must match the socket value above.
if supervisor_token do
  case Req.get(supervisor_base <> "/core/info", auth: {:bearer, supervisor_token}, retry: false) do
    {:ok, %{status: 200, body: %{"data" => %{"port" => port} = data}}} ->
      note =
        if port == expected_core_port,
          do: "matches Core's bound port",
          else: "HttpConfig cache not refreshed in this emulator (expected on host)"

      Probe.info("emulator GET /core/info", "port=#{port} ssl=#{inspect(data["ssl"])} — #{note}")

    {:ok, %{status: status}} ->
      Probe.info("emulator GET /core/info", "status #{status}")

    {:error, error} ->
      Probe.info(
        "emulator GET /core/info",
        Exception.message(error) <> " (emulator not running?)"
      )
  end
else
  Probe.info(
    "emulator GET /core/info",
    "skipped — no SUPERVISOR_TOKEN and no .dev/supervisor_token"
  )
end

# ---------------------------------------------------------------------------
# 3. The legacy-port stub, while onboarding is pending.
# ---------------------------------------------------------------------------

Probe.check("legacy #{legacy_base} redirects to the active port", fn ->
  case Probe.raw_get(legacy_base <> "/") do
    {:ok, %{status: 307} = response} ->
      location = response |> Req.Response.get_header("location") |> List.first()
      port = URI.parse(location || "").port

      if port == expected_core_port do
        {:ok, "GET / 307 -> #{location}"}
      else
        {:error, "307 -> #{inspect(location)} (port #{inspect(port)} != #{expected_core_port})"}
      end

    {:ok, %{status: status}} ->
      {:error, "expected 307, got #{status}"}

    {:error, error} ->
      {:error, Exception.message(error)}
  end
end)

Probe.check("the legacy redirect preserves the method", fn ->
  case Req.post(legacy_base <> "/api/onboarding/users",
         json: %{},
         redirect: false,
         retry: false
       ) do
    {:ok, %{status: 307} = response} ->
      location = response |> Req.Response.get_header("location") |> List.first()
      {:ok, "POST /api/onboarding/users 307 -> #{location}"}

    {:ok, %{status: status}} ->
      {:error, "expected 307 (HTTPTemporaryRedirect), got #{status}"}

    {:error, error} ->
      {:error, Exception.message(error)}
  end
end)

# ---------------------------------------------------------------------------
# 4. Drive onboarding to completion over the active port.
# ---------------------------------------------------------------------------

%{status: 200, body: %{"auth_code" => auth_code}} =
  Req.post!(base <> "/api/onboarding/users",
    json: %{
      client_id: client_id,
      name: name,
      username: username,
      password: password,
      language: "en"
    }
  )

Probe.check("onboarding step user", fn -> {:ok, "POST /api/onboarding/users 200"} end)

%{status: 200, body: %{"access_token" => token}} =
  Req.post!(base <> "/auth/token",
    form: [grant_type: "authorization_code", code: auth_code, client_id: client_id]
  )

Probe.check("token exchange on #{base}", fn -> {:ok, "POST /auth/token 200"} end)

auth = {:bearer, token}

Probe.check("onboarding step core_config", fn ->
  case Req.post(base <> "/api/onboarding/core_config", json: %{}, auth: auth, retry: false) do
    {:ok, %{status: 200}} -> {:ok, "POST /api/onboarding/core_config 200"}
    {:ok, %{status: status, body: body}} -> {:error, "status #{status}: #{inspect(body)}"}
    {:error, error} -> {:error, Exception.message(error)}
  end
end)

Probe.check("onboarding step analytics", fn ->
  case Req.post(base <> "/api/onboarding/analytics", json: %{}, auth: auth, retry: false) do
    {:ok, %{status: 200}} -> {:ok, "POST /api/onboarding/analytics 200"}
    {:ok, %{status: status, body: body}} -> {:error, "status #{status}: #{inspect(body)}"}
    {:error, error} -> {:error, Exception.message(error)}
  end
end)

# ---------------------------------------------------------------------------
# 5. The WebSocket API on the active port — the analytics-step commands the
#    frontend sends (issue #11's repro), plus the supervised-install
#    `supervisor/api` bridge into the emulator.
# ---------------------------------------------------------------------------

defmodule Probe.WS do
  @moduledoc false

  def connect(base) do
    uri = URI.parse(base)
    {:ok, conn} = Mint.HTTP.connect(:http, uri.host, uri.port || 80, protocols: [:http1])
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/api/websocket", [])
    {conn, resps} = stream_once(conn)

    status = find(resps, ref, :status)
    headers = find(resps, ref, :headers)
    {:ok, conn, ws} = Mint.WebSocket.new(conn, ref, status, headers)

    pending = for {:data, ^ref, data} <- resps, do: data
    {ws, frames} = decode_all(ws, pending)

    {conn, ws, ref, frames}
  end

  defp stream_once(conn) do
    receive do
      message ->
        {:ok, conn, resps} = Mint.WebSocket.stream(conn, message)
        {conn, resps}
    after
      15_000 -> raise "timeout waiting for websocket upgrade"
    end
  end

  defp find(resps, ref, tag) do
    Enum.find_value(resps, fn
      {^tag, ^ref, value} -> value
      _ -> nil
    end)
  end

  defp decode_all(ws, datas) do
    Enum.reduce(datas, {ws, []}, fn data, {ws, acc} ->
      {:ok, ws, frames} = Mint.WebSocket.decode(ws, data)
      {ws, acc ++ frames}
    end)
  end

  def send_json(conn, ws, ref, payload) do
    {:ok, ws, data} = Mint.WebSocket.encode(ws, {:text, Jason.encode!(payload)})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {conn, ws}
  end

  def recv_json(conn, ws, ref, carried \\ []) do
    case texts(carried) do
      [] ->
        {conn, resps} = stream_once(conn)
        datas = for {:data, ^ref, data} <- resps, do: data
        {ws, frames} = decode_all(ws, datas)
        recv_json(conn, ws, ref, frames)

      messages ->
        {conn, ws, messages}
    end
  end

  def texts(frames), do: for({:text, text} <- frames, do: Jason.decode!(text))

  def call(conn, ws, ref, id, payload) do
    {conn, ws} = send_json(conn, ws, ref, Map.put(payload, :id, id))
    await_result(conn, ws, ref, id)
  end

  defp await_result(conn, ws, ref, id) do
    {conn, ws, messages} = recv_json(conn, ws, ref)

    case Enum.find(messages, &(&1["id"] == id and &1["type"] == "result")) do
      nil -> await_result(conn, ws, ref, id)
      message -> {conn, ws, message}
    end
  end
end

{conn, ws, ref, hello} = Probe.WS.connect(base)

{conn, ws, hello} =
  if hello == [],
    do: Probe.WS.recv_json(conn, ws, ref),
    else: {conn, ws, Probe.WS.texts(hello)}

Probe.check("websocket handshake on #{base}", fn ->
  case hello do
    [%{"type" => "auth_required"} | _] -> {:ok, "auth_required received over /api/websocket"}
    other -> {:error, "unexpected first frame #{inspect(other)}"}
  end
end)

{conn, ws} = Probe.WS.send_json(conn, ws, ref, %{type: "auth", access_token: token})
{conn, ws, auth_response} = Probe.WS.recv_json(conn, ws, ref)

Probe.check("websocket auth", fn ->
  case auth_response do
    [%{"type" => "auth_ok"} | _] -> {:ok, "auth_ok"}
    other -> {:error, inspect(other)}
  end
end)

{conn, ws, analytics} =
  Probe.WS.call(conn, ws, ref, 1, %{type: "analytics/preferences", preferences: %{base: true}})

Probe.check("websocket analytics/preferences (issue #11 repro)", fn ->
  if analytics["success"],
    do: {:ok, Jason.encode!(analytics)},
    else: {:error, Jason.encode!(analytics)}
end)

{conn, ws, bridge} =
  Probe.WS.call(conn, ws, ref, 2, %{
    type: "supervisor/api",
    endpoint: "/supervisor/info",
    method: "get"
  })

Probe.check("websocket supervisor/api reaches the emulator", fn ->
  if bridge["success"] do
    {:ok, String.slice(Jason.encode!(bridge), 0, 200)}
  else
    {:error, Jason.encode!(bridge)}
  end
end)

_ = conn
_ = ws

# ---------------------------------------------------------------------------
# 6. The final step flips onboarding to done, which tears the stub down.
# ---------------------------------------------------------------------------

Probe.check("onboarding step integration", fn ->
  case Req.post(base <> "/api/onboarding/integration",
         json: %{client_id: client_id, redirect_uri: redirect_uri},
         auth: auth,
         retry: false
       ) do
    {:ok, %{status: 200}} -> {:ok, "POST /api/onboarding/integration 200"}
    {:ok, %{status: status, body: body}} -> {:error, "status #{status}: #{inspect(body)}"}
    {:error, error} -> {:error, Exception.message(error)}
  end
end)

Probe.check("onboarding completes", fn ->
  case Probe.raw_get(base <> "/api/onboarding") do
    {:ok, %{status: 200, body: body}} ->
      pending = for %{"step" => step, "done" => false} <- body, do: step

      if pending == [],
        do: {:ok, "all steps done: #{inspect(for(%{"step" => s} <- body, do: s))}"},
        else: {:error, "still pending #{inspect(pending)}"}

    {:ok, %{status: status}} ->
      {:error, "status #{status}"}

    {:error, error} ->
      {:error, Exception.message(error)}
  end
end)

Probe.check("the legacy port stops answering once onboarded", fn ->
  Probe.until(
    fn ->
      case Probe.raw_get(legacy_base <> "/") do
        {:ok, %{status: status}} -> {:error, "still answering with #{status}"}
        {:error, %Mint.TransportError{reason: reason}} -> {:ok, "connect failed: #{reason}"}
        {:error, error} -> {:ok, "connect failed: " <> Exception.message(error)}
      end
    end,
    60_000
  )
end)

Probe.check("Core still serves the API on #{base} after onboarding", fn ->
  case Req.get(base <> "/api/", auth: auth, retry: false) do
    {:ok, %{status: 200, body: body}} -> {:ok, inspect(body)}
    {:ok, %{status: status}} -> {:error, "status #{status}"}
    {:error, error} -> {:error, Exception.message(error)}
  end
end)

case Probe.failures() do
  [] ->
    IO.puts("\nall checks passed")

  failures ->
    IO.puts("\n#{length(failures)} check(s) FAILED:")
    for {_status, label, evidence} <- failures, do: IO.puts("  - #{label}: #{evidence}")
    System.halt(1)
end
