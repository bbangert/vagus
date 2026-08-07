defmodule Vagus.Core.Transport do
  @moduledoc """
  The one place that answers "how do I reach Core right now" — the
  Supervisor↔Core unix socket when it exists, TCP `:core_base_url`
  otherwise.

  Real HAOS runs every Supervisor→Core call (HTTP *and* WebSocket) over
  `SUPERVISOR_CORE_API_SOCKET` (`Vagus.Core.Container.socket_path/0`,
  bind-mounted into both mount namespaces by `Vagus.Core.Container`'s spec).
  Core treats every request arriving on that socket as the **Supervisor
  user**: no `Authorization` header is expected on HTTP, and the WS API
  skips its `auth_required`/`auth` handshake entirely — the connection is
  authenticated from its first frame. `implicit_auth?/1` is what every
  client branches on, so that rule lives here once instead of in five
  modules.

  ## Presence is re-decided per request / per connection, never cached

  `current/1` resolves the transport by asking the filesystem whether the
  socket file exists (`File.exists?/1` — one `stat` per resolution, noise
  next to the HTTP round trip that follows). Nothing memoizes the answer:
  Core creates the socket when it starts, so a socket that is absent at
  Vagus boot appears minutes later, and a Core recreate (`Vagus.Core.
  Lifecycle`) can take it away and put it back. Callers therefore resolve

    * per request for the HTTP clients (`Vagus.Core.Client`,
      `Vagus.Core.Health`, `Vagus.API.CoreProxy`), and
    * per connection attempt for the WS clients
      (`Vagus.Core.EventPusher`, `Vagus.API.CoreProxy.WSBridge.Upstream`),
      both of which already re-dial on loss — so a late-appearing socket is
      picked up by the next reconnect rather than needing its own watcher.

  A resolved `t()` is then threaded through one request/connection so the
  URL, the credential decision and the connect arguments can never disagree
  with each other (a socket vanishing mid-request can't produce a
  socket-shaped URL dialed over TCP).

  ## Configuration

  `config :vagus, :core_socket_path` overrides the socket path;
  unset means `Vagus.Core.Container.socket_path/0` (the device path).
  Explicitly `nil` means "there is never a socket here" — what
  `config/test.exs` sets so the suite is deterministic regardless of what
  happens to exist under `/run` on the machine running it.
  `config :vagus, :core_base_url` is the TCP fallback, unchanged.
  """

  alias Vagus.Core.Container

  @typedoc """
  A resolved transport: the unix socket path, or the TCP base URL to prefix
  request paths with.
  """
  @type t :: {:socket, String.t()} | {:tcp, String.t()}

  # Any authority works for a `unix_socket:` request — Finch/Mint dial the
  # socket and use this only to fill in the `host` header.
  @socket_origin "http://localhost"
  @socket_hostname "localhost"

  @default_base_url "http://localhost:8123"

  @doc """
  Resolves the transport to use for one request or one connection attempt.

  Options:

    * `:base_url` - TCP base URL to fall back to, defaults to
      `config :vagus, :core_base_url`. Callers holding their own configured
      base (e.g. `Vagus.Core.Client`'s `:core_base_url` start option) pass
      it so a socket-less run keeps dialing exactly what they were told to.
    * `:socket` - socket path to test for, defaults to `socket_path/0`.
  """
  @spec current(keyword()) :: t()
  def current(opts \\ []) do
    case Keyword.get(opts, :socket, socket_path()) do
      path when is_binary(path) ->
        if File.exists?(path),
          do: {:socket, path},
          else: {:tcp, Keyword.get(opts, :base_url, base_url())}

      _no_socket_configured ->
        {:tcp, Keyword.get(opts, :base_url, base_url())}
    end
  end

  @doc "The configured socket path (whether or not anything is listening on it), or `nil`."
  @spec socket_path() :: String.t() | nil
  def socket_path do
    Application.get_env(:vagus, :core_socket_path, Container.socket_path())
  end

  @doc "The socket path if the socket exists right now, `nil` otherwise."
  @spec socket() :: String.t() | nil
  def socket do
    case current() do
      {:socket, path} -> path
      {:tcp, _base_url} -> nil
    end
  end

  @doc "The TCP fallback base URL (`config :vagus, :core_base_url`)."
  @spec base_url() :: String.t()
  def base_url, do: Application.get_env(:vagus, :core_base_url, @default_base_url)

  @doc """
  Whether requests on `transport` authenticate implicitly as the Supervisor
  user — `true` on the socket (no bearer token, no WS auth handshake),
  `false` on TCP (today's token flow, unchanged).
  """
  @spec implicit_auth?(t()) :: boolean()
  def implicit_auth?({:socket, _path}), do: true
  def implicit_auth?({:tcp, _base_url}), do: false

  @doc """
  Builds a `Finch.Request` for `path` (an absolute path, query string
  included) on `transport`.
  """
  @spec build(
          t(),
          Finch.Request.method(),
          String.t(),
          Finch.Request.headers(),
          Finch.Request.body()
        ) ::
          Finch.Request.t()
  def build(transport, method, path, headers \\ [], body \\ nil)

  def build({:socket, socket}, method, path, headers, body) do
    Finch.build(method, @socket_origin <> path, headers, body, unix_socket: socket)
  end

  def build({:tcp, base_url}, method, path, headers, body) do
    Finch.build(method, base_url <> path, headers, body)
  end

  @doc """
  `Mint.HTTP.connect/4`'s first three arguments for `transport` — the unix
  socket is an ordinary Mint address (`{:local, path}` on port 0).
  """
  @spec connect_args(t()) :: {Mint.Types.scheme(), Mint.Types.address(), :inet.port_number()}
  def connect_args({:socket, socket}), do: {:http, {:local, socket}, 0}

  def connect_args({:tcp, base_url}) do
    uri = URI.parse(base_url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    {scheme, uri.host, uri.port}
  end

  @doc """
  `Mint.HTTP.connect/4` options that depend on the transport — a
  `{:local, _}` address carries no hostname of its own, so one has to be
  supplied for the `host` header and (on TLS, which never applies here) SNI.
  """
  @spec connect_opts(t()) :: keyword()
  def connect_opts({:socket, _socket}), do: [hostname: @socket_hostname]
  def connect_opts({:tcp, _base_url}), do: []

  @doc "The `Mint.WebSocket.upgrade/5` scheme matching `connect_args/1`'s."
  @spec ws_scheme(t()) :: :ws | :wss
  def ws_scheme(transport) do
    case connect_args(transport) do
      {:https, _address, _port} -> :wss
      {:http, _address, _port} -> :ws
    end
  end
end
