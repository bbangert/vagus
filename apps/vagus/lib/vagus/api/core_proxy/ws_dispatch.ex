defmodule Vagus.API.CoreProxy.WSDispatch do
  @moduledoc """
  Core's `supervisor/api` WebSocket command, answered here as the calling app.

  On Home Assistant OS the frontend sends this command to Core, and Core
  calls the Supervisor API with its own token. Relayed from an app it would
  hand that app Core's privilege (`Vagus.Core.Reserved`), so the frame never
  leaves Vagus: `read/1` turns it into a request, `run/3` puts that request
  to `Vagus.API.Router` carrying the app's own token, and `result/2` words
  the answer as Core words its own (`hassio/websocket_api.py`,
  `websocket_supervisor_api`, Core 2026.10.1). The app gets what the same
  request over HTTP would have got it, or less.

  ## The caller is looked up again for every call

  A socket outlives what its app was granted at the handshake. `run/3` takes
  only the slug, asks the app's process for the token its container holds
  now, and has `Vagus.API.Auth` resolve that token like any other. An app
  that is stopped or gone has no token, and one reinstalled without
  `homeassistant_api` is refused the command itself.

  This module puts the token in the request and nowhere else. `run/3` runs
  in a task, so the bridge never holds it, and whatever the router raises is
  caught here and logged without its message or arguments: both can carry
  the request.

  ## What `Vagus.API.Dispatcher` would have done

  This is a second way into the router, past the dispatcher, so `read/1`
  refuses what the dispatcher would not have routed there:

    * an endpoint that is not plain path segments. No percent-escape, query,
      fragment, dot segment or empty segment is accepted, so an endpoint has
      one spelling and it is the one every later check reads. Core refuses
      what its URL library would rewrite (`HassIO.send_command`,
      `raw_path != command`); this is stricter;
    * an endpoint and query longer than a request line may be;
    * what `Vagus.API.ExploitFilter` blocks, in the endpoint or the query;
    * the Core proxy's and the ingress proxy's paths, by
      `Vagus.API.Dispatcher.family/1`;
    * the routes that stream, take an upload or answer with a file: none
      has a result to return, and a stream would hold the task open.

  The source address is not checked again: it is the socket's peer, which
  the dispatcher admitted at the upgrade and which cannot change. The body
  limit is the router's own, because the request carries a real JSON body
  for `Plug.Parsers` to read.

  ## Differences from Core

  Core answers every Supervisor refusal as `unknown_error`. A 401 or 403
  from the router is `unauthorized` here, the code this proxy already gives
  a refused command. A frame that does not fit the command's schema is
  refused like any other reserved command rather than as `invalid_format`,
  and the schema here is narrower: no number where Core's coerces one to a
  string, and no boolean as a timeout.
  Core passes any method string to its HTTP client; only the three the
  router serves are dispatched.
  """

  require Logger

  alias Vagus.API.{Auth, Authz, Dispatcher, ExploitFilter, Router, SourceGuard, Tiers}
  alias Vagus.App

  @keys ~w(id type endpoint method data params timeout)
  @methods ~w(GET POST DELETE)

  # Bandit refuses a request line over 10 000 bytes.
  @max_target_bytes 8_000

  # Core's default, in its unit: seconds.
  @default_timeout_ms 10_000

  # Core's `null` means no limit. The bridge keeps an entry per call, so
  # there is one: Bandit's read timeout, the longest an HTTP caller waits.
  @max_timeout_ms 900_000

  @authz_ctx %{leg: :core_api, decoded_segments: nil}

  @typedoc "`data` is still as decoded, key order and repeats included."
  @type request :: %{
          method: String.t(),
          path: String.t(),
          segments: [String.t()],
          query: String.t(),
          data: Jason.OrderedObject.t() | nil,
          timeout_ms: non_neg_integer()
        }

  @type outcome ::
          {:response, status :: pos_integer(), body :: binary()}
          | :no_response
          | :unauthorized

  @doc """
  The request a `supervisor/api` frame asks for.

  `:malformed` is a frame Core's schema would not accept, a repeated key
  among them: Core reads the last of a repeated key and `Jason` the first.
  `:reserved` names one of Core's reserved views. `:unsupported` is
  everything else this module does not dispatch.
  """
  @spec read(Jason.OrderedObject.t()) ::
          {:ok, pos_integer(), request()}
          | {:error, pos_integer(), :reserved | :unsupported}
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

      case target(method, endpoint, query) do
        {:ok, segments} ->
          {:ok, id,
           %{
             method: method,
             path: endpoint,
             segments: segments,
             query: query,
             data: data,
             timeout_ms: timeout_ms
           }}

        {:error, why} ->
          {:error, id, why}
      end
    else
      :error -> :malformed
    end
  end

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

  defp query(%Jason.OrderedObject{values: values}) do
    if Enum.all?(values, fn {_key, value} -> is_binary(value) or is_number(value) end),
      do: {:ok, URI.encode_query(values)},
      else: :error
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
  Runs `request` as the app `slug` is now. Call it from a task: it blocks
  for as long as the route's handler does, and the response is sent to the
  calling process.

  `plug` is `Vagus.API.Router` everywhere but in a test that must not run a
  handler.
  """
  @spec run(String.t(), request(), module()) :: outcome()
  def run(slug, request, plug \\ Router) when is_binary(slug) do
    with {:ok, token} <- App.token(slug),
         {:addon, %{slug: ^slug}} = app <- Auth.principal(token),
         {:intercept, :supervisor_api} <- still_admitted(app) do
      call(plug, conn(request, token))
    else
      _gone_or_no_longer_granted ->
        count_refusal()
        :unauthorized
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
    body = if request.data, do: Jason.encode!(request.data), else: ""

    %Plug.Conn{
      adapter: {__MODULE__.Adapter, %{owner: self(), body: body}},
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

  # `Plug.ErrorHandler` sends the error envelope and then raises again, so a
  # handler that raised has still answered. What it raised is logged only
  # when that answer is a server error: an oversized body raises too.
  defp call(plug, conn) do
    crash =
      try do
        plug.call(conn, plug.init([]))
        nil
      catch
        kind, reason -> crash(kind, reason, __STACKTRACE__)
      end

    receive do
      {__MODULE__.Adapter, status, body} ->
        if crash && status >= 500, do: log_crash(crash)
        {:response, status, body}
    after
      0 ->
        if crash, do: log_crash(crash)
        :no_response
    end
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
  @spec result(term(), outcome() | :reserved | :unsupported | :busy | :timeout) :: binary()
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
