defmodule Vagus.Runtime.Docker do
  @moduledoc """
  Docker Engine API client over the daemon's Unix socket (Mint HTTP/1) — the
  real Engine-API driver the `docs/contract-2026.7-m4-addendum.md` §A1 calls
  for, replacing `Vagus.Engine`'s spike-era CLI shelling.

  balena-engine is a moby fork speaking the same Engine API, so this same
  client drives both: on the host it talks to `/var/run/docker.sock` (regular
  Docker, for development + tests); on target to
  `/run/balena-engine.sock`. The socket path is
  `config :vagus, :docker_socket` (default `/var/run/docker.sock`), overridable
  per call via the `:socket` option.

  Transport: one short-lived Mint connection per request over the
  `{:local, socket}` address (Engine-API calls are add-on-lifecycle rate, not
  hot-path), driven synchronously in `:passive` mode. Streaming endpoints
  (`/logs`, `/stats` follow) need a held connection and are added with P5.

  All calls return `{:ok, term}` / `{:error, reason}` and never raise on a
  daemon-side or transport error.
  """

  @default_socket "/var/run/docker.sock"
  @recv_timeout 60_000
  # A pull is silent while the engine authenticates and resolves the manifest,
  # and again while it verifies and registers a large layer; how long those
  # silences last on a board is not measured.
  @pull_idle_timeout 300_000
  # One progress line is a few hundred bytes. This bounds what a stream with
  # no newline in it can make the reader hold.
  @max_pull_line 1_048_576
  @max_error_body 65_536
  # Cap a single response body so a hostile/huge daemon stream can't exhaust a
  # 1GB device (mirrors the router's Plug.Parsers `length:` discipline).
  @max_body 16_777_216
  # Docker container name/id charset. A ref is interpolated into the request
  # path, so anything outside this (`/`, `?`, a leading `.`) could rewrite the
  # request against the root socket — reject at the boundary.
  @ref_re ~r/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/

  # Docker image-reference allowlist (W1) — a real ref legitimately contains
  # `/` (repo namespace) and `:` (tag/registry port), so it can't reuse
  # `@ref_re`'s container-id charset; this instead allowlists the actual
  # docker-reference charset (`[a-zA-Z0-9._:@/-]`) rather than blocklisting
  # a handful of "dangerous" sequences, since a blocklist only ever covers
  # the sequences someone thought of. `..` is additionally rejected even
  # though the charset already permits `.`, since `a/../b`-style segments
  # could otherwise rewrite the request path; a leading `/` is rejected too
  # (belt-and-suspenders — the anchored `^[a-zA-Z0-9]` already excludes it).
  @image_ref_re ~r"^[a-zA-Z0-9][a-zA-Z0-9._:@/-]*$"

  @typedoc "A decoded Engine-API response."
  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: term()
        }

  @typedoc """
  What went wrong, whichever function reported it. See `failure/1`.

    * `{:unreachable, reason}`: nothing answered at the socket (`:enoent`,
      `:econnrefused`, `:eacces`). No request was sent.
    * `{:timeout, :recv | :idle | :total}`: the engine was silent for longer
      than the call allowed. The request was sent and may still take effect.
    * `{:status, status, message}`: the engine answered with that HTTP status;
      `message` is its own text, or `nil` where the call did not ask for it.
    * `{:stream, message}`: a pull answered 200 and then reported this.
    * `{:transport, reason}`: the connection broke after the request was sent.
    * `{:invalid, term}`: refused here, before any request.
    * `{:other, term}`: anything else, unchanged.
  """
  @type failure ::
          {:unreachable, term()}
          | {:timeout, :recv | :idle | :total}
          | {:status, pos_integer(), String.t() | nil}
          | {:stream, String.t()}
          | {:transport, term()}
          | {:invalid, term()}
          | {:other, term()}

  @typedoc "One container of a listing, as `summary/1` returns it."
  @type summary :: %{
          id: String.t(),
          names: [String.t()],
          image: String.t() | nil,
          state: String.t() | nil,
          status: String.t() | nil,
          labels: %{optional(String.t()) => String.t()}
        }

  ## Connectivity

  @doc "GET `/_ping` — `:ok` if the daemon answers 200, else `{:error, reason}`."
  @spec ping(keyword()) :: :ok | {:error, term()}
  def ping(opts \\ []) do
    case request(:get, "/_ping", opts) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "GET `/version` — the daemon's version map."
  @spec version(keyword()) :: {:ok, map()} | {:error, term()}
  def version(opts \\ []), do: get_json("/version", opts)

  @doc "GET `/info` — the daemon's info map."
  @spec info(keyword()) :: {:ok, map()} | {:error, term()}
  def info(opts \\ []), do: get_json("/info", opts)

  ## Images

  @doc """
  POST `/images/create?fromImage=&tag=` — pulls `image` (a `"repo:tag"` or
  `"repo"` string). Consumes the progress stream to completion; returns
  `{:error, {:pull_failed, detail}}` if the stream carries an `errorDetail`.

  `opts[:platform]` sets the `platform` query (e.g. `"linux/arm64"`).
  """
  @spec pull_image(String.t(), keyword()) :: :ok | {:error, term()}
  def pull_image(image, opts \\ []) when is_binary(image) do
    {repo, tag} = split_image(image)
    query = [fromImage: repo, tag: tag] ++ platform_query(opts)

    case request(:post, "/images/create", Keyword.merge(opts, query: query, body: "")) do
      {:ok, %{status: 200, body: body}} -> check_pull_stream(body)
      {:ok, %{status: status, body: body}} -> {:error, {:pull_failed, {status, body}}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `pull_image/2` without the buffering: each progress line is decoded and
  handed to `fun` with the accumulator as it arrives, and nothing of the
  stream is kept. A pull has no upper size, and its caller wants the progress
  while it happens.

  The engine answers 200 before it knows whether the pull will work and then
  reports a failure as a line of the stream; that line ends the call with
  `{:error, {:pull_failed, message}}`. A failure before the first line is an
  ordinary status: `{:error, {:pull_failed, {status, body}}}`.

  Options beyond `request/3`'s `:socket` and `pull_image/2`'s `:platform`:

    * `:idle_timeout`, the longest silence allowed, milliseconds (default
      five minutes). `{:error, {:pull_timeout, :idle}}`.
    * `:total_timeout`, for the whole call (default `:infinity`).
      `{:error, {:pull_timeout, :total}}`.

  The connection belongs to the calling process. Killing that process closes
  it, and the engine cancels a pull whose connection closes.
  """
  @spec pull_image_stream(String.t(), acc, (map(), acc -> acc), keyword()) ::
          {:ok, acc} | {:error, term()}
        when acc: var
  def pull_image_stream(image, acc, fun, opts \\ [])
      when is_binary(image) and is_function(fun, 2) do
    {repo, tag} = split_image(image)
    path = "/images/create" <> encode_query([fromImage: repo, tag: tag] ++ platform_query(opts))

    pull = %{
      status: nil,
      buffer: "",
      acc: acc,
      fun: fun,
      idle: Keyword.get(opts, :idle_timeout, @pull_idle_timeout),
      deadline: deadline(Keyword.get(opts, :total_timeout, :infinity))
    }

    case connect(opts) do
      {:ok, conn} ->
        try do
          case Mint.HTTP.request(conn, "POST", path, [], "") do
            {:ok, conn, ref} -> pull_recv(conn, ref, pull)
            {:error, _conn, reason} -> {:error, reason}
          end
        after
          Mint.HTTP.close(conn)
        end

      {:error, reason} ->
        {:error, {:connect, reason}}
    end
  end

  @doc "GET `/images/{name}/json`. A missing image is `{:error, {:http, 404, message}}`."
  @spec inspect_image(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_image(name, opts \\ []) do
    with :ok <- ensure_image_ref(name), do: get_json("/images/#{name}/json", opts)
  end

  @doc """
  DELETE `/images/{name}` (`name` a `"repo:tag"` or `"repo"` ref, as built by
  `Vagus.Addon.Manager.build_spec/2`). A missing image (404) is treated as
  `:ok` (already gone) — mirrors `remove_container/2`/`remove_network/2`.

  Unlike a container/network id, an image ref legitimately contains `/`
  (repo namespace) and `:` (tag), so it can't reuse `ensure_ref/1`'s
  container-id charset; `ensure_image_ref/1` instead allowlists the
  docker-reference charset (W1 — this used to be a 3-item blocklist, which
  only ever covers the sequences someone thought of).
  """
  @spec remove_image(String.t(), keyword()) :: :ok | {:error, term()}
  def remove_image(name, opts \\ []) do
    with :ok <- ensure_image_ref(name) do
      case request(:delete, "/images/#{name}", opts) do
        {:ok, %{status: s}} when s in [200, 404] ->
          :ok

        {:ok, %{status: status, body: body}} ->
          {:error, {:remove_image_failed, status, message(body)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  ## Containers

  @doc """
  POST `/containers/create[?name=]` with `config` (an Engine-API container
  config map). Returns `{:ok, id}`.
  """
  @spec create_container(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_container(config, opts \\ []) when is_map(config) do
    query = if name = opts[:name], do: [name: name], else: []

    case request(:post, "/containers/create", Keyword.merge(opts, query: query, body: config)) do
      {:ok, %{status: 201, body: %{"Id" => id}}} -> {:ok, id}
      {:ok, %{status: status, body: body}} -> {:error, {:create_failed, status, message(body)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "POST `/containers/{id}/start`. Idempotent: an already-started (304) is `:ok`."
  @spec start_container(String.t(), keyword()) :: :ok | {:error, term()}
  def start_container(id, opts \\ []) do
    with :ok <- ensure_ref(id),
         do: post_no_content("/containers/#{id}/start", [204, 304], opts)
  end

  @doc """
  POST `/containers/{id}/stop` (`opts[:timeout]` seconds). Already-stopped (304) is `:ok`.

  The engine answers only once the container has exited, so a caller whose
  `:timeout` approaches the receive timeout passes a longer `:recv_timeout`
  (see `request/3`). A call that gives up does not stop the stop.
  """
  @spec stop_container(String.t(), keyword()) :: :ok | {:error, term()}
  def stop_container(id, opts \\ []) do
    query = if t = opts[:timeout], do: [t: t], else: []

    with :ok <- ensure_ref(id),
         do:
           post_no_content("/containers/#{id}/stop", [204, 304], Keyword.put(opts, :query, query))
  end

  @doc "POST `/containers/{id}/restart` (`opts[:timeout]` seconds)."
  @spec restart_container(String.t(), keyword()) :: :ok | {:error, term()}
  def restart_container(id, opts \\ []) do
    query = if t = opts[:timeout], do: [t: t], else: []

    with :ok <- ensure_ref(id),
         do: post_no_content("/containers/#{id}/restart", [204], Keyword.put(opts, :query, query))
  end

  @doc """
  DELETE `/containers/{id}`. `opts[:force]` (default true) kills a running
  container; `opts[:volumes]` (default false) removes anonymous volumes.
  A missing container (404) is treated as `:ok` (already gone).
  """
  @spec remove_container(String.t(), keyword()) :: :ok | {:error, term()}
  def remove_container(id, opts \\ []) do
    query = [
      force: bool(Keyword.get(opts, :force, true)),
      v: bool(Keyword.get(opts, :volumes, false))
    ]

    with :ok <- ensure_ref(id) do
      case request(:delete, "/containers/#{id}", Keyword.merge(opts, query: query)) do
        {:ok, %{status: s}} when s in [204, 404] -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {:remove_failed, status, message(body)}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "GET `/containers/{id}/json` — the full inspect map."
  @spec inspect_container(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_container(id, opts \\ []) do
    with :ok <- ensure_ref(id), do: get_json("/containers/#{id}/json", opts)
  end

  @doc """
  GET `/containers/{id}/logs?stdout&stderr&tail=N` — the container's recent log
  output as the raw (multiplexed, when no TTY) stream body. `opts[:tail]`
  defaults to `100`. Non-following (one-shot); the follow stream is a later add.
  """
  @spec container_logs(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def container_logs(id, opts \\ []) do
    tail = Keyword.get(opts, :tail, 100)
    # `timestamps: true` makes the daemon prefix each line with RFC3339Nano —
    # the real per-line times the §A5 verbose format needs.
    timestamps = Keyword.get(opts, :timestamps, false)
    query = [stdout: true, stderr: true, tail: tail, timestamps: timestamps]

    with :ok <- ensure_ref(id) do
      case request(:get, "/containers/#{id}/logs", Keyword.merge(opts, query: query)) do
        {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
        {:ok, %{status: 200}} -> {:ok, ""}
        {:ok, %{status: status, body: body}} -> {:error, {:http, status, message(body)}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  GET `/containers/{id}/stats?stream=false` — a single resource-usage sample
  (with `precpu_stats` for the CPU delta). Raw Engine-API stats map.
  """
  @spec stats(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def stats(id, opts \\ []) do
    with :ok <- ensure_ref(id),
         do: get_json("/containers/#{id}/stats", Keyword.put(opts, :query, stream: false))
  end

  @doc """
  GET `/containers/json` — running containers (`opts[:all]` includes stopped),
  as the engine's own maps; `summary/1` projects one.

  `opts[:filters]` narrows the listing in the engine: `%{label: [...], name:
  [...]}`. Keys are ANDed and the values of one key ORed. A label is `"key"`
  or `"key=value"`. A name is a regular expression matched anywhere in the
  name, so a prefix is `"^app_"`.
  """
  @spec list_containers(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_containers(opts \\ []) do
    query = [all: bool(Keyword.get(opts, :all, false)), filters: filters(opts[:filters])]
    get_json("/containers/json", Keyword.merge(opts, query: query))
  end

  @doc "What a listing says about one container, enough to decide without inspecting it."
  @spec summary(map()) :: summary()
  def summary(%{"Id" => id} = container) do
    %{
      id: id,
      # The engine lists names as paths from its root.
      names: for(name <- container["Names"] || [], do: String.trim_leading(name, "/")),
      image: container["Image"],
      state: container["State"],
      status: container["Status"],
      labels: container["Labels"] || %{}
    }
  end

  @doc """
  Puts whatever a function of this module returned as `{:error, reason}`
  into one shape (`t:failure/0`), so a caller can tell an absent engine from
  a slow one from one that refused, without knowing which function it called.
  """
  @spec failure(term()) :: failure()
  def failure({:connect, %{reason: reason}}), do: {:unreachable, reason}
  def failure({:connect, reason}), do: {:unreachable, reason}
  def failure(%Mint.TransportError{reason: :timeout}), do: {:timeout, :recv}
  def failure({:pull_timeout, which}), do: {:timeout, which}
  def failure(%Mint.TransportError{reason: reason}), do: {:transport, reason}
  def failure(%Mint.HTTPError{reason: reason}), do: {:transport, reason}
  def failure({:http, status}) when is_integer(status), do: {:status, status, nil}
  def failure({:http, status, message}), do: {:status, status, message}
  def failure({:pull_failed, {status, body}}), do: {:status, status, message(body)}
  def failure({:pull_failed, message}) when is_binary(message), do: {:stream, message}
  def failure({:invalid_ref, _ref} = reason), do: {:invalid, reason}

  def failure({tag, status, message})
      when tag in [:create_failed, :remove_failed, :remove_image_failed] and is_integer(status),
      do: {:status, status, message}

  def failure(other), do: {:other, other}

  @doc """
  Runs `cmd` (via `/bin/sh -c`) inside container `id` and waits for it to
  exit — the §A4 `backup_pre`/`backup_post` hook for a **hot** add-on.
  `:ok` on exit code 0, `{:error, {:exec, code}}` on nonzero.

  **Deviation from the originally-specified approach**: the ticket describes
  starting the exec non-detached (`Detach: false`) and reading the
  hijacked/streamed `/exec/{id}/start` response body to completion through
  this module's `request/4`. Docker documents that endpoint as hijacking the
  HTTP connection to transport stdin/stdout/stderr directly — a duplex,
  protocol-upgraded stream that doesn't fit `request/4`'s buffered
  request-then-full-response model (built for ordinary Engine-API JSON
  calls, not an upgraded connection), without either blocking indefinitely
  on a malformed read or risking a wedged connection on a 1GB device.
  Instead this starts the exec `Detach: true` (fire-and-forget — the
  daemon still runs the command to completion, it just doesn't hold the
  HTTP connection open for output) and polls `GET /exec/{id}/json` for
  `Running: false` to read `ExitCode`. Consequence: `backup_pre`/
  `backup_post` output isn't captured anywhere (only the exit code is
  observed) — acceptable here since no current add-on config in scope
  (Mosquitto ships HOT with no pre/post at all) exercises this path; a
  future add-on that needs the command's stdout/stderr will need a real
  streaming client.
  """
  @spec exec(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def exec(id, cmd, opts \\ []) do
    with :ok <- ensure_ref(id),
         {:ok, exec_id} <- create_exec(id, cmd, opts),
         :ok <- start_exec_detached(exec_id, opts),
         {:ok, exit_code} <- await_exec(exec_id, opts) do
      if exit_code == 0, do: :ok, else: {:error, {:exec, exit_code}}
    end
  end

  @doc """
  `exec/3`'s sibling for a caller that needs the command's actual output,
  not just its exit code — `POST /core/check`'s config-check log (G3) is
  the first: a bare exit code can't distinguish "config invalid" from
  "container busy", and without the log a 400 response would carry no
  explanation, which is exactly the gap G3 flagged.

  Starts the exec `Detach: false` instead of `exec/3`'s `Detach: true` —
  the daemon holds the `/exec/{id}/start` response open and streams
  stdout/stderr into it until the process exits, at which point it closes
  the connection. `exec/3`'s moduledoc deviation note explains why a
  *duplex* hijack (stdin attached too) doesn't fit `request/4`'s buffered
  model; this exec never attaches stdin (`create_exec/3`'s body sets only
  `AttachStdout`/`AttachStderr`), so the daemon has nothing to read from
  the client — it is a one-way, close-delimited response, which
  `request/4`'s `recv_all/4` already handles the same way it does for
  `container_logs/2`. Still multiplexed (no `Tty` requested), so the
  returned `output` carries the same 8-byte frame headers
  `Vagus.Runtime.Logs.demux/1` strips — demuxing is the caller's job, the
  same division `container_logs/2` uses.

  Returns `{:ok, %{exit_code: integer(), output: binary()}}` for ANY exit
  code, including nonzero — a failing command is a legitimate result to
  report, not a client error; only a genuine Engine-API failure (create/
  start/inspect never completing) returns `{:error, reason}`.
  """
  @spec exec_capture(String.t(), String.t(), keyword()) ::
          {:ok, %{exit_code: integer(), output: binary()}} | {:error, term()}
  def exec_capture(id, cmd, opts \\ []) do
    with :ok <- ensure_ref(id),
         {:ok, exec_id} <- create_exec(id, cmd, opts),
         {:ok, output} <- start_exec_attached(exec_id, opts),
         {:ok, exit_code} <- await_exec(exec_id, opts) do
      {:ok, %{exit_code: exit_code, output: output}}
    end
  end

  ## Networks

  @doc "POST `/networks/create` with `config` (an Engine-API network config). Returns `{:ok, id}`."
  @spec create_network(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_network(config, opts \\ []) when is_map(config) do
    case request(:post, "/networks/create", Keyword.merge(opts, body: config)) do
      {:ok, %{status: 201, body: %{"Id" => id}}} ->
        {:ok, id}

      {:ok, %{status: 409}} ->
        {:error, :already_exists}

      {:ok, %{status: status, body: body}} ->
        {:error, {:create_network_failed, status, message(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "GET `/networks/{id}` — the network's inspect map."
  @spec inspect_network(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_network(id, opts \\ []) do
    with :ok <- ensure_ref(id), do: get_json("/networks/#{id}", opts)
  end

  @doc "DELETE `/networks/{id}`. A missing network (404) is `:ok`."
  @spec remove_network(String.t(), keyword()) :: :ok | {:error, term()}
  def remove_network(id, opts \\ []) do
    with :ok <- ensure_ref(id) do
      case request(:delete, "/networks/#{id}", opts) do
        {:ok, %{status: s}} when s in [204, 404] ->
          :ok

        {:ok, %{status: status, body: body}} ->
          {:error, {:remove_network_failed, status, message(body)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  ## Generic request

  @doc """
  Issues a single Engine-API request over the Unix socket.

  `opts`: `:socket`, `:query` (keyword/map → query string), `:body`
  (a map → JSON, or a raw string/`nil`), `:headers`. Returns `{:ok, response}`
  where `response.body` is JSON-decoded when the daemon says so, else the raw
  string.

  `:recv_timeout` is how long one receive may stay silent, in milliseconds
  (default `default_recv_timeout/0`); it is not a deadline for the call. On
  expiry the call returns `{:error, %Mint.TransportError{reason: :timeout}}`.
  Every function of this module that takes `opts` passes it on.

  `:detail` makes the calls that otherwise report a refusal as
  `{:error, {:http, status}}` (start, stop, restart) include the engine's
  message: `{:error, {:http, status, message}}`.
  """
  @spec request(atom(), String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def request(method, path, opts \\ []) do
    full_path = path <> encode_query(Keyword.get(opts, :query, []))
    {headers, body} = prepare_body(Keyword.get(opts, :body), Keyword.get(opts, :headers, []))
    method = method |> to_string() |> String.upcase()
    recv_timeout = Keyword.get(opts, :recv_timeout, default_recv_timeout())

    case connect(opts) do
      {:ok, conn} ->
        # try/after so the socket is always closed — including when a *raise*
        # (not just an error tuple) escapes the request/recv path.
        try do
          with {:ok, conn, ref} <- Mint.HTTP.request(conn, method, full_path, headers, body),
               {:ok, _conn, responses} <- recv_all(conn, ref, recv_timeout) do
            {:ok, assemble(responses, ref)}
          else
            {:error, _conn, reason} -> {:error, reason}
          end
        after
          Mint.HTTP.close(conn)
        end

      {:error, reason} ->
        {:error, {:connect, reason}}
    end
  end

  @doc "The resolved daemon socket path."
  @spec socket_path() :: String.t()
  def socket_path, do: Application.get_env(:vagus, :docker_socket, @default_socket)

  @doc """
  How long a receive may stay silent when a call names no `:recv_timeout`:
  60 s, or `config :vagus, :docker_recv_timeout`.
  """
  @spec default_recv_timeout() :: pos_integer()
  def default_recv_timeout, do: Application.get_env(:vagus, :docker_recv_timeout, @recv_timeout)

  ## Internals

  # Reject a container ref that could break out of the request path.
  defp ensure_ref(id) when is_binary(id) do
    if Regex.match?(@ref_re, id), do: :ok, else: {:error, {:invalid_ref, id}}
  end

  defp ensure_ref(_id), do: {:error, {:invalid_ref, :not_a_string}}

  ## `exec/3` internals — see the deviation note on `exec/3` itself.

  defp create_exec(id, cmd, opts) do
    body = %{"Cmd" => ["/bin/sh", "-c", cmd], "AttachStdout" => true, "AttachStderr" => true}

    case request(:post, "/containers/#{id}/exec", Keyword.merge(opts, body: body)) do
      {:ok, %{status: 201, body: %{"Id" => exec_id}}} ->
        {:ok, exec_id}

      {:ok, %{status: status, body: body}} ->
        {:error, {:exec_create_failed, status, message(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_exec_detached(exec_id, opts) do
    body = %{"Detach" => true}

    case request(:post, "/exec/#{exec_id}/start", Keyword.merge(opts, body: body)) do
      {:ok, %{status: s}} when s in [200, 204] ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:exec_start_failed, status, message(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `exec_capture/3`'s non-detached start — blocks until the daemon closes
  # the response (the process has exited), returning the raw captured
  # body. A no-output run's body decodes to `%{}` (`decode_body/2`'s empty
  # string clause), which `raw_output/1` normalizes back to `""`.
  defp start_exec_attached(exec_id, opts) do
    body = %{"Detach" => false}

    case request(:post, "/exec/#{exec_id}/start", Keyword.merge(opts, body: body)) do
      {:ok, %{status: s, body: raw}} when s in [200, 204] ->
        {:ok, raw_output(raw)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:exec_start_failed, status, message(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp raw_output(body) when is_binary(body), do: body
  defp raw_output(_empty_map), do: ""

  # ~30s cap (150 * 200ms) — long enough for a reasonable backup_pre/post
  # hook, bounded so a hung command can't wedge a backup job forever.
  @exec_poll_interval 200
  @exec_poll_max 150

  defp await_exec(exec_id, opts, attempt \\ 0) do
    case request(:get, "/exec/#{exec_id}/json", opts) do
      {:ok, %{status: 200, body: %{"Running" => false, "ExitCode" => code}}} ->
        {:ok, code}

      {:ok, %{status: 200}} when attempt < @exec_poll_max ->
        Process.sleep(@exec_poll_interval)
        await_exec(exec_id, opts, attempt + 1)

      {:ok, %{status: 200}} ->
        {:error, :exec_timeout}

      {:ok, %{status: status, body: body}} ->
        {:error, {:exec_inspect_failed, status, message(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An image ref is a path segment too, so it needs the same anti-traversal
  # discipline as `ensure_ref/1` — but its legitimate charset is much wider
  # (repo namespaces, registry `host:port` prefixes, tags), so this
  # allowlists the docker-reference charset instead of blocklisting specific
  # sequences (W1).
  defp ensure_image_ref(name) when is_binary(name) do
    if Regex.match?(@image_ref_re, name) and not String.contains?(name, "..") and
         not String.starts_with?(name, "/") do
      :ok
    else
      {:error, {:invalid_ref, name}}
    end
  end

  defp ensure_image_ref(_name), do: {:error, {:invalid_ref, :not_a_string}}

  defp get_json(path, opts) do
    case request(:get, path, opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, message(body)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post_no_content(path, ok_statuses, opts) do
    case request(:post, path, Keyword.put_new(opts, :body, "")) do
      {:ok, %{status: s, body: body}} ->
        cond do
          s in ok_statuses -> :ok
          opts[:detail] -> {:error, {:http, s, message(body)}}
          true -> {:error, {:http, s}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp connect(opts) do
    socket = Keyword.get(opts, :socket, socket_path())
    Mint.HTTP.connect(:http, {:local, socket}, 0, mode: :passive, hostname: "localhost")
  end

  defp filters(nil), do: nil

  defp filters(filters) do
    case Map.new(filters, fn {key, values} -> {to_string(key), List.wrap(values)} end) do
      empty when map_size(empty) == 0 -> nil
      map -> Jason.encode!(map)
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  # The receive timeout is the idle allowance, cut short by what is left of
  # the total; the second element says which of the two a timeout would mean.
  defp pull_wait(%{idle: idle, deadline: :infinity}), do: {idle, :idle}

  defp pull_wait(%{idle: idle, deadline: deadline}) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)
    if left < idle, do: {left, :total}, else: {idle, :idle}
  end

  defp pull_recv(conn, ref, pull) do
    {wait, which} = pull_wait(pull)

    case Mint.HTTP.recv(conn, 0, wait) do
      {:ok, conn, responses} ->
        case pull_responses(responses, ref, pull) do
          {:cont, pull} -> pull_recv(conn, ref, pull)
          {:halt, result} -> result
        end

      {:error, _conn, %Mint.TransportError{reason: :timeout}, _responses} ->
        {:error, {:pull_timeout, which}}

      {:error, _conn, reason, _responses} ->
        {:error, reason}
    end
  end

  defp pull_responses([], _ref, pull), do: {:cont, pull}

  defp pull_responses([response | rest], ref, pull) do
    case pull_response(response, ref, pull) do
      {:cont, pull} -> pull_responses(rest, ref, pull)
      {:halt, result} -> {:halt, result}
    end
  end

  defp pull_response({:status, ref, status}, ref, pull), do: {:cont, %{pull | status: status}}

  defp pull_response({:data, ref, chunk}, ref, %{status: 200} = pull) do
    {lines, rest} = split_lines(pull.buffer <> chunk)

    with {:cont, pull} <- pull_lines(lines, pull) do
      if byte_size(rest) > @max_pull_line,
        do: {:halt, {:error, {:pull_failed, "progress line over #{@max_pull_line} bytes"}}},
        else: {:cont, %{pull | buffer: rest}}
    end
  end

  # Not a progress stream but the body of a refusal, which is short; what is
  # kept of it is bounded all the same.
  defp pull_response({:data, ref, chunk}, ref, pull) do
    kept = binary_part(chunk, 0, min(byte_size(chunk), @max_error_body - byte_size(pull.buffer)))
    {:cont, %{pull | buffer: pull.buffer <> kept}}
  end

  defp pull_response({:done, ref}, ref, %{status: 200} = pull) do
    with {:cont, pull} <- pull_lines([pull.buffer], pull), do: {:halt, {:ok, pull.acc}}
  end

  defp pull_response({:done, ref}, ref, pull) do
    body =
      case Jason.decode(pull.buffer) do
        {:ok, decoded} -> decoded
        {:error, _reason} -> pull.buffer
      end

    {:halt, {:error, {:pull_failed, {pull.status, body}}}}
  end

  defp pull_response({:error, ref, reason}, ref, _pull), do: {:halt, {:error, reason}}
  defp pull_response(_other, _ref, pull), do: {:cont, pull}

  defp pull_lines([], pull), do: {:cont, pull}

  defp pull_lines([line | rest], pull) do
    case Jason.decode(line) do
      {:ok, %{"error" => message}} when is_binary(message) ->
        {:halt, {:error, {:pull_failed, message}}}

      {:ok, %{"errorDetail" => %{"message" => message}}} when is_binary(message) ->
        {:halt, {:error, {:pull_failed, message}}}

      {:ok, %{} = progress} ->
        pull_lines(rest, %{pull | acc: pull.fun.(progress, pull.acc)})

      _blank_or_not_json ->
        pull_lines(rest, pull)
    end
  end

  defp split_lines(buffer) do
    {lines, [rest]} = buffer |> String.split("\n") |> Enum.split(-1)
    {lines, rest}
  end

  # Accumulate response batches newest-first (O(1) prepend, not O(n²) `++`),
  # enforcing a hard body ceiling so an unbounded daemon stream can't exhaust
  # memory. Flattened back into arrival order on `:done`.
  defp recv_all(conn, ref, timeout, acc \\ [], size \\ 0) do
    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, responses} ->
        size = size + data_size(responses)
        acc = [responses | acc]

        cond do
          size > @max_body ->
            {:error, conn, :response_too_large}

          Enum.any?(responses, &match?({:done, ^ref}, &1)) ->
            {:ok, conn, acc |> Enum.reverse() |> List.flatten()}

          true ->
            recv_all(conn, ref, timeout, acc, size)
        end

      {:error, conn, reason, _responses} ->
        {:error, conn, reason}
    end
  end

  defp data_size(responses) do
    Enum.reduce(responses, 0, fn
      {:data, _ref, chunk}, acc -> acc + byte_size(chunk)
      _other, acc -> acc
    end)
  end

  defp assemble(responses, ref) do
    status =
      Enum.find_value(responses, fn
        {:status, ^ref, s} -> s
        _ -> nil
      end)

    headers =
      Enum.find_value(responses, [], fn
        {:headers, ^ref, h} -> h
        _ -> nil
      end)

    body =
      responses
      |> Enum.filter(&match?({:data, ^ref, _}, &1))
      |> Enum.map_join("", fn {:data, ^ref, chunk} -> chunk end)

    %{status: status, headers: headers, body: decode_body(body, headers)}
  end

  defp decode_body("", _headers), do: %{}

  defp decode_body(body, headers) do
    if json?(headers) do
      case Jason.decode(body) do
        {:ok, decoded} -> decoded
        {:error, _} -> body
      end
    else
      body
    end
  end

  defp json?(headers) do
    Enum.any?(headers, fn {k, v} ->
      String.downcase(k) == "content-type" and String.contains?(v, "application/json")
    end)
  end

  defp prepare_body(nil, headers), do: {headers, ""}
  defp prepare_body(body, headers) when is_binary(body), do: {headers, body}

  defp prepare_body(body, headers) when is_map(body) do
    {[{"content-type", "application/json"} | headers], Jason.encode!(body)}
  end

  defp encode_query([]), do: ""
  defp encode_query(query) when is_map(query), do: encode_query(Map.to_list(query))

  defp encode_query(query) do
    "?" <>
      (query
       |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
       |> Enum.map_join("&", fn {k, v} -> "#{k}=#{URI.encode_www_form(to_string(v))}" end))
  end

  # The tag is the part after the last ":" that follows the last "/", so a
  # registry `host:port` before the path isn't mistaken for a tag
  # (e.g. `ghcr.io:443/org/img:1.0` → repo `ghcr.io:443/org/img`, tag `1.0`).
  defp split_image(image) do
    last_segment = image |> String.split("/") |> List.last()

    case String.split(last_segment, ":", parts: 2) do
      [_name, tag] -> {String.replace_suffix(image, ":" <> tag, ""), tag}
      [_name] -> {image, "latest"}
    end
  end

  defp platform_query(opts), do: if(p = opts[:platform], do: [platform: p], else: [])

  defp check_pull_stream(body) do
    # /images/create streams newline-delimited JSON status objects; an
    # errorDetail anywhere means the pull failed even though the HTTP status
    # was 200.
    if String.contains?(body, "errorDetail") or String.contains?(body, "\"error\""),
      do: {:error, {:pull_failed, last_error_line(body)}},
      else: :ok
  end

  defp last_error_line(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode/1)
    |> Enum.find_value(body, fn
      {:ok, %{"error" => e}} -> e
      _ -> nil
    end)
  end

  defp message(body) when is_map(body), do: Map.get(body, "message", inspect(body))
  defp message(body), do: inspect(body)

  defp bool(true), do: "true"
  defp bool(false), do: "false"
  defp bool(other), do: to_string(other)
end
