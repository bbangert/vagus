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
  # Cap a single response body so a hostile/huge daemon stream can't exhaust a
  # 1GB device (mirrors the router's Plug.Parsers `length:` discipline).
  @max_body 16_777_216
  # Docker container name/id charset. A ref is interpolated into the request
  # path, so anything outside this (`/`, `?`, a leading `.`) could rewrite the
  # request against the root socket — reject at the boundary.
  @ref_re ~r/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/

  @typedoc "A decoded Engine-API response."
  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: term()
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

  @doc "POST `/containers/{id}/stop` (`opts[:timeout]` seconds). Already-stopped (304) is `:ok`."
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
    query = [stdout: true, stderr: true, tail: tail]

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

  @doc "GET `/containers/json` — running containers (`opts[:all]` includes stopped)."
  @spec list_containers(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_containers(opts \\ []) do
    query = [all: bool(Keyword.get(opts, :all, false))]
    get_json("/containers/json", Keyword.merge(opts, query: query))
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
  """
  @spec request(atom(), String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def request(method, path, opts \\ []) do
    socket = Keyword.get(opts, :socket, socket_path())
    full_path = path <> encode_query(Keyword.get(opts, :query, []))
    {headers, body} = prepare_body(Keyword.get(opts, :body), Keyword.get(opts, :headers, []))
    method = method |> to_string() |> String.upcase()

    case Mint.HTTP.connect(:http, {:local, socket}, 0, mode: :passive, hostname: "localhost") do
      {:ok, conn} ->
        # try/after so the socket is always closed — including when a *raise*
        # (not just an error tuple) escapes the request/recv path.
        try do
          with {:ok, conn, ref} <- Mint.HTTP.request(conn, method, full_path, headers, body || ""),
               {:ok, _conn, responses} <- recv_all(conn, ref) do
            {:ok, assemble(responses, ref)}
          else
            {:error, _conn, reason} -> {:error, reason}
            {:error, reason} -> {:error, reason}
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

  ## Internals

  # Reject a container ref that could break out of the request path.
  defp ensure_ref(id) when is_binary(id) do
    if Regex.match?(@ref_re, id), do: :ok, else: {:error, {:invalid_ref, id}}
  end

  defp ensure_ref(_id), do: {:error, {:invalid_ref, :not_a_string}}

  defp get_json(path, opts) do
    case request(:get, path, opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, message(body)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post_no_content(path, ok_statuses, opts) do
    case request(:post, path, Keyword.put_new(opts, :body, "")) do
      {:ok, %{status: s}} -> if s in ok_statuses, do: :ok, else: {:error, {:http, s}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Accumulate response batches newest-first (O(1) prepend, not O(n²) `++`),
  # enforcing a hard body ceiling so an unbounded daemon stream can't exhaust
  # memory. Flattened back into arrival order on `:done`.
  defp recv_all(conn, ref, acc \\ [], size \\ 0) do
    case Mint.HTTP.recv(conn, 0, @recv_timeout) do
      {:ok, conn, responses} ->
        size = size + data_size(responses)
        acc = [responses | acc]

        cond do
          size > @max_body ->
            {:error, conn, :response_too_large}

          Enum.any?(responses, &match?({:done, ^ref}, &1)) ->
            {:ok, conn, acc |> Enum.reverse() |> List.flatten()}

          true ->
            recv_all(conn, ref, acc, size)
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

  defp split_image(image) do
    case String.split(image, ":", parts: 2) do
      [repo, tag] -> {repo, tag}
      [repo] -> {repo, "latest"}
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
