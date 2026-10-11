defmodule Vagus.API.CoreProxy.WSDispatch do
  @moduledoc """
  Core's `supervisor/api` WebSocket command, answered here as the calling app.

  Core answers this command by calling the Supervisor API with its own
  token, so relayed from an app it would hand that app Core's privilege
  (`Vagus.Core.Reserved`). It is never relayed. The request it names is put
  to `Vagus.API.Router` carrying the app's own token instead, so what grants
  it is the gate that grants the same request over HTTP. This module can
  refuse a request and grants none: `CoreProxyWSEquivalenceTest` sends the
  fixture's routes both ways and finds no call answered that HTTP refused.
  A handler that only acts was not run there, only graded.

  The token is asked for again at every call, because a socket outlives
  what its app was granted at the handshake. It must be the token the socket
  was opened with, by hash: a restart or a reinstall mints a new one, and a
  socket opened with the old one is refused, as that token is over HTTP.

  This is a second way into the router, past `Vagus.API.Dispatcher`, so
  `read/1` refuses what the dispatcher would have filtered or sent
  elsewhere, and what cannot be answered with one result.

  Against Core (`hassio/websocket_api.py`, 2026.10.1): a 401 or 403 is
  `unauthorized` here, not `unknown_error`; a frame outside the schema is
  refused as a reserved command, not as `invalid_format`; and the methods
  are the three the router serves, not any string.
  """

  require Logger

  alias Vagus.API.{Auth, Authz, Dispatcher, ExploitFilter, Router, SourceGuard, Tiers}
  alias Vagus.App
  alias Vagus.App.Policy

  @keys ~w(id type endpoint method data params timeout)
  @methods ~w(GET POST DELETE)

  # Bandit refuses a request line over 10 000 bytes.
  @max_target_bytes 8_000

  # Core's default, in its unit: seconds.
  @default_timeout_ms 10_000

  # Core's `null` means no limit. The bridge keeps an entry per call, so
  # there is one, at the figure of Bandit's read timeout. That timeout bounds
  # reads from the client, not how long an HTTP caller waits for a handler.
  @max_timeout_ms 900_000

  @authz_ctx %{leg: :core_api, decoded_segments: nil}

  @router_opts Router.init([])

  @typedoc "`body` is `data` encoded again, key order and repeats included."
  @type request :: %{
          method: String.t(),
          path: String.t(),
          segments: [String.t()],
          query: String.t(),
          body: binary(),
          timeout_ms: non_neg_integer()
        }

  @typedoc "What a socket was opened with: `Vagus.App.Policy.hash/1` of its token."
  @type credential :: binary()

  @type outcome ::
          {:response, status :: pos_integer(), body :: binary()}
          | :no_response
          | :unauthorized

  @doc """
  The request a `supervisor/api` frame asks for.

  `:malformed` is a frame Core's schema would not accept, a repeated key
  among them: Core reads the last of a repeated key and `Jason` the first.
  `:reserved` names one of Core's reserved views, and `:too_large` carries
  more `data` than the router reads. `:unsupported` is everything else this
  module does not dispatch.

  Runs in the bridge, so the sizes are bounded before anything is encoded:
  a frame may be megabytes. The source address is not among the checks: it
  is the socket's peer, which the dispatcher admitted at the upgrade.
  """
  @spec read(Jason.OrderedObject.t()) ::
          {:ok, pos_integer(), request()}
          | {:error, pos_integer(), :reserved | :unsupported | :too_large}
          | :malformed
  def read(%Jason.OrderedObject{values: values}) do
    with {:ok, frame} <- fields(values),
         {:ok, id} <- id(frame),
         {:ok, endpoint} <- binary(frame, "endpoint"),
         {:ok, method} <- binary(frame, "method"),
         {:ok, data} <- object(frame, "data"),
         {:ok, params} <- object(frame, "params"),
         {:ok, query} <- query(params),
         {:ok, timeout_ms} <- timeout_ms(frame) do
      method = String.upcase(method, :ascii)

      with {:ok, segments} <- target(method, endpoint, query),
           {:ok, body} <- body(data) do
        {:ok, id,
         %{
           method: method,
           path: endpoint,
           segments: segments,
           query: query,
           body: body,
           timeout_ms: timeout_ms
         }}
      else
        {:error, why} -> {:error, id, why}
      end
    else
      :error -> :malformed
    end
  end

  defp body(nil), do: {:ok, ""}

  # Past the first check the encoding is a few hundred kilobytes at the very
  # most: six bytes out for one in at worst.
  defp body(data) do
    limit = Router.body_limit()

    with true <- at_least(data, 0, limit) <= limit,
         body = Jason.encode!(data),
         true <- byte_size(body) <= limit do
      {:ok, body}
    else
      false -> {:error, :too_large}
    end
  end

  # No more than the encoded size of `term`, and never less than one per
  # element, so it stops within `limit` elements of starting.
  defp at_least(_term, sum, limit) when sum > limit, do: sum

  defp at_least(%Jason.OrderedObject{values: values}, sum, limit),
    do: at_least_all(values, sum + 2, limit)

  defp at_least(list, sum, limit) when is_list(list), do: at_least_all(list, sum + 2, limit)
  defp at_least({key, value}, sum, limit), do: at_least(value, sum + byte_size(key) + 3, limit)
  defp at_least(string, sum, _limit) when is_binary(string), do: sum + byte_size(string) + 2

  # Two decimal digits to the byte is under what any integer takes, and
  # asking its size does not write it out.
  defp at_least(integer, sum, _limit) when is_integer(integer),
    do: sum + max(1, 2 * (:erlang.external_size(integer) - 7))

  # `1.0` is the shortest a float is written.
  defp at_least(float, sum, _limit) when is_float(float), do: sum + 3
  defp at_least(_scalar, sum, _limit), do: sum + 1

  defp at_least_all(_elements, sum, limit) when sum > limit, do: sum
  defp at_least_all([], sum, _limit), do: sum

  defp at_least_all([element | rest], sum, limit),
    do: at_least_all(rest, at_least(element, sum, limit), limit)

  defp fields(values) do
    keys = Enum.map(values, &elem(&1, 0))

    if Enum.all?(keys, &(&1 in @keys)) and Enum.uniq(keys) == keys,
      do: {:ok, Map.new(values)},
      else: :error
  end

  # Core's own rule for a command's id.
  defp id(%{"id" => id}) when is_integer(id) and id > 0, do: {:ok, id}
  defp id(_frame), do: :error

  defp binary(frame, key) do
    case frame do
      %{^key => value} when is_binary(value) -> {:ok, value}
      _absent_or_not_a_string -> :error
    end
  end

  defp object(frame, key) do
    case Map.fetch(frame, key) do
      :error -> {:ok, nil}
      {:ok, %Jason.OrderedObject{} = object} -> {:ok, object}
      {:ok, _not_an_object} -> :error
    end
  end

  defp query(nil), do: {:ok, ""}

  # Encoding never shortens, so a query too long as written is not encoded.
  defp query(%Jason.OrderedObject{values: values}) do
    cond do
      not Enum.all?(values, fn {_key, value} -> is_binary(value) or is_number(value) end) ->
        :error

      written(values, 0) > @max_target_bytes ->
        {:ok, :too_long}

      true ->
        {:ok, URI.encode_query(values)}
    end
  end

  defp written(_pairs, sum) when sum > @max_target_bytes, do: sum
  defp written([], sum), do: sum

  defp written([{key, value} | rest], sum) do
    value = if is_binary(value), do: byte_size(value), else: 1
    written(rest, sum + byte_size(key) + value)
  end

  defp timeout_ms(frame) do
    case Map.fetch(frame, "timeout") do
      :error -> {:ok, @default_timeout_ms}
      {:ok, nil} -> {:ok, @max_timeout_ms}
      {:ok, seconds} when is_number(seconds) -> {:ok, clamp(seconds)}
      {:ok, _not_a_number} -> :error
    end
  end

  defp clamp(seconds) when seconds <= 0, do: 0
  defp clamp(seconds) when seconds >= div(@max_timeout_ms, 1000), do: @max_timeout_ms
  defp clamp(seconds), do: round(seconds * 1000)

  defp target(_method, _endpoint, :too_long), do: {:error, :unsupported}

  defp target(method, endpoint, query) do
    with true <- method in @methods,
         true <- byte_size(endpoint) + byte_size(query) <= @max_target_bytes,
         {:ok, segments} <- segments(endpoint),
         false <- ExploitFilter.harmful_path?(endpoint),
         false <- ExploitFilter.harmful_query?(query) do
      cond do
        Tiers.blacklisted?(segments) -> {:error, :reserved}
        Dispatcher.family(segments) != :router -> {:error, :unsupported}
        unanswerable?(segments) -> {:error, :unsupported}
        true -> {:ok, segments}
      end
    else
      _refused -> {:error, :unsupported}
    end
  end

  defp segments("/"), do: {:ok, []}

  defp segments("/" <> rest) do
    segments = String.split(rest, "/")
    if Enum.all?(segments, &plain?/1), do: {:ok, segments}, else: :error
  end

  defp segments(_relative), do: :error

  defp plain?(segment) when segment in ["", ".", ".."], do: false
  defp plain?(segment), do: plain_bytes?(segment)

  defp plain_bytes?(<<>>), do: true

  defp plain_bytes?(<<byte, rest::binary>>)
       when byte > 0x20 and byte < 0x7F and byte not in [?%, ??, ?#, ?\\],
       do: plain_bytes?(rest)

  defp plain_bytes?(_other), do: false

  @assets ~w(icon logo changelog documentation)

  # Method-blind, so a route added beside one of these under another method
  # is refused too.
  defp unanswerable?(segments) do
    case Enum.reverse(segments) do
      ["follow", "logs" | _family] -> true
      ["follow", _boot, "boots", "logs" | _family] -> true
      _other -> file?(segments)
    end
  end

  defp file?(["backups", "new", "upload"]), do: true
  defp file?(["backups", _slug, "download"]), do: true
  defp file?(["addons", _slug, kind]), do: kind in @assets
  defp file?(["store", "addons", _slug, kind]), do: kind in @assets
  defp file?(_segments), do: false

  @doc """
  Runs `request` as the app `slug`, if the app still holds the token whose
  hash is `credential`. Call it from a task: it blocks for as long as the
  route's handler does, and the response is sent to the calling process.

  `router` is `Vagus.API.Router` everywhere but in a test that must not run
  a handler.
  """
  @spec run(String.t(), credential(), request(), (Plug.Conn.t() -> term())) :: outcome()
  def run(slug, credential, request, router \\ &router/1) do
    # This process binds the token only inside this `try`, having received
    # it in the app process's reply. A raise with it in scope is caught here
    # and never becomes a crash report, which prints arguments.
    attempt =
      try do
        with {:ok, token} <- App.token(slug),
             true <- Plug.Crypto.secure_compare(Policy.hash(token), credential),
             {:addon, %{slug: ^slug}} = app <- Auth.principal(token),
             {:intercept, :supervisor_api} <- still_admitted(app) do
          router.(conn(request, token))
          :called
        else
          _gone_rotated_or_no_longer_granted -> :refused
        end
      catch
        kind, reason -> {:crashed, crash(kind, reason, __STACKTRACE__)}
      end

    outcome(attempt)
  end

  defp router(conn), do: Router.call(conn, @router_opts)

  defp outcome(:refused) do
    count_refusal()
    :unauthorized
  end

  # `Plug.ErrorHandler` sends the error envelope and then raises again, so a
  # handler that raised has still answered. What it raised is logged only
  # when that answer is a server error: the router raises to refuse, too.
  defp outcome(attempt) do
    receive do
      {__MODULE__.Adapter, status, body} ->
        with {:crashed, crash} when status >= 500 <- attempt, do: log_crash(crash)
        {:response, status, body}
    after
      0 ->
        with {:crashed, crash} <- attempt, do: log_crash(crash)
        :no_response
    end
  end

  @refusal_label "authz/core_ws+caller"

  # Counted as the bridge counts its own refusals: an open socket can repeat
  # the call at will.
  defp count_refusal do
    if SourceGuard.enabled?() do
      SourceGuard.record_filtered(:authz, @refusal_label)
    else
      Logger.warning("Vagus.API.CoreProxy.WSDispatch: refused a call (#{@refusal_label})")
    end
  end

  # The command itself, put to the evaluator again: the bridge asked as the
  # app the handshake saw.
  defp still_admitted(app),
    do: Authz.authorize(app, {:ws, :core_api, "supervisor/api", %{}}, @authz_ctx)

  @doc false
  @spec conn(request(), String.t()) :: Plug.Conn.t()
  def conn(request, token) do
    %Plug.Conn{
      adapter: {__MODULE__.Adapter, %{owner: self(), body: request.body}},
      host: "supervisor",
      method: request.method,
      owner: self(),
      path_info: request.segments,
      port: 80,
      remote_ip: {127, 0, 0, 1},
      query_string: request.query,
      # Always JSON, with or without a body: a request without the type
      # skips `Plug.Parsers`, and with it the body limit.
      req_headers: [{"content-type", "application/json"}, {"x-supervisor-token", token}],
      request_path: request.path,
      scheme: :http
    }
  end

  # The router wraps what a handler raised, together with the conn.
  defp crash(:error, %Plug.Conn.WrapperError{kind: kind, reason: reason, stack: stack}, _outer),
    do: crash(kind, reason, stack)

  defp crash(kind, reason, stacktrace), do: what(kind, reason, stacktrace) <> where(stacktrace)

  # Neither the message nor the arguments: both can carry the request.
  defp log_crash(crash),
    do: Logger.error("Vagus.API.CoreProxy.WSDispatch: a supervisor/api call #{crash}")

  defp what(:error, reason, stacktrace),
    do: "raised #{inspect(Exception.normalize(:error, reason, stacktrace).__struct__)}"

  defp what(:exit, _reason, _stacktrace), do: "exited"
  defp what(:throw, _value, _stacktrace), do: "threw"

  defp where([{module, function, args, location} | _rest]) do
    arity = if is_list(args), do: length(args), else: args
    " in #{Exception.format_mfa(module, function, arity)}#{line(location)}"
  end

  defp where(_no_frames), do: ""

  defp line(location) do
    case Keyword.fetch(location, :line) do
      {:ok, line} -> ", line #{line}"
      :error -> ""
    end
  end

  @unauthorized "Supervisor-only commands are not available through this proxy"

  @doc """
  Core's result message for `outcome`, encoded. Only a 200 carrying an `ok`
  envelope is a success, as in `HassIO.send_command`.
  """
  @spec result(term(), outcome() | :reserved | :unsupported | :too_large | :busy | :timeout) ::
          binary()
  def result(id, {:response, 200, body}) do
    case Jason.decode(body) do
      {:ok, %{"result" => "ok"} = envelope} -> success(id, Map.get(envelope, "data", %{}))
      {:ok, envelope} -> error(id, "unknown_error", message(envelope))
      {:error, _not_json} -> error(id, "unknown_error", "")
    end
  end

  def result(id, {:response, status, body}) do
    code = if status in [401, 403], do: "unauthorized", else: "unknown_error"

    case Jason.decode(body) do
      {:ok, %{"result" => "error"} = envelope} -> error(id, code, message(envelope))
      _not_an_error_envelope -> error(id, "unknown_error", "")
    end
  end

  def result(id, refused) when refused in [:unauthorized, :reserved],
    do: error(id, "unauthorized", @unauthorized)

  def result(id, :busy), do: error(id, "unknown_error", "Too many requests in flight")

  # The router's own answer to a body over its limit.
  def result(id, :too_large), do: error(id, "unknown_error", "request body too large")

  # Core's own failures to reach the Supervisor carry no message.
  def result(id, failed) when failed in [:no_response, :unsupported, :timeout],
    do: error(id, "unknown_error", "")

  defp message(%{"message" => message}) when is_binary(message), do: message
  defp message(_envelope), do: ""

  defp success(id, data),
    do: Jason.encode!(%{"id" => id, "type" => "result", "success" => true, "result" => data})

  defp error(id, code, message) do
    Jason.encode!(%{
      "id" => id,
      "type" => "result",
      "success" => false,
      "error" => %{"code" => code, "message" => message}
    })
  end
end

defmodule Vagus.API.CoreProxy.WSDispatch.Adapter do
  @moduledoc """
  The `Plug.Conn` adapter behind a `supervisor/api` request: a body to read
  and one response to hand back to the process that made the request.

  It cannot stream. A route that sends chunks or a file would otherwise run
  in a task with nobody reading, so those raise, and the caller is told the
  call failed.
  """

  @behaviour Plug.Conn.Adapter

  @impl Plug.Conn.Adapter
  def send_resp(%{owner: owner} = payload, status, _headers, body) do
    send(owner, {__MODULE__, status, IO.iodata_to_binary(body)})
    {:ok, nil, payload}
  end

  @impl Plug.Conn.Adapter
  def read_req_body(%{body: body} = payload, opts) do
    length = Keyword.get(opts, :length, 8_000_000)

    case body do
      <<data::binary-size(^length), rest::binary>> when rest != "" ->
        {:more, data, %{payload | body: rest}}

      data ->
        {:ok, data, %{payload | body: ""}}
    end
  end

  @impl Plug.Conn.Adapter
  def send_chunked(_payload, _status, _headers), do: raise(ArgumentError, "cannot stream")

  @impl Plug.Conn.Adapter
  def chunk(_payload, _body), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def send_file(_payload, _status, _headers, _path, _offset, _length),
    do: raise(ArgumentError, "cannot send a file")

  @impl Plug.Conn.Adapter
  def inform(_payload, _status, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def upgrade(_payload, _protocol, _opts), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def get_peer_data(_payload), do: %{address: {127, 0, 0, 1}, port: 0, ssl_cert: nil}

  @impl Plug.Conn.Adapter
  def get_http_protocol(_payload), do: :"HTTP/1.1"
end
