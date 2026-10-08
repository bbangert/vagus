defmodule Vagus.Test.FakeEngine.Model do
  @moduledoc """
  A container engine that keeps state: containers and images, served over a
  unix socket in the Engine API's shapes. Started by
  `Vagus.Test.FakeEngine.start_model/1`; every function here takes the
  handle that returns.

  What it models, because the code under test depends on it:

    * `GET /containers/json` with `all` and the `label` and `name` filters,
      a name pattern matched against the bare name, as moby does. `Status`
      is the engine's sentence, with a duration that differs in every
      listing and the health in brackets;
    * `GET /events` holds the response open and carries what happens from
      then on. Nothing is replayed;
    * `POST /containers/{name}/stop` answers only after `:stop_delay` ms,
      and the container stops, with its `die` and `stop` events, at the end
      of that time and not before;
    * a pull is a stream written from a script (`script_pull/3`), `200`
      before any line of it;
    * `crash/3` on a container with a restart policy is `die`, then `start`
      with a higher `RestartCount` and a new `StartedAt`.

  Time is a counter, so every event and start has a distinct, increasing
  stamp and a run is the same every time.

  Options: `:stop_delay` (default 0), `:notify`, a process
  told `{:fake_engine, :client_closed, path}` when a client closes a stream
  that had stalled, and `:on_request`, a function called here with each
  request as it arrives and the containers as they are then, before the
  request changes anything: what the engine saw, and in what order.
  """

  use GenServer

  alias Vagus.Test.FakeEngine

  @epoch 1_700_000_000_000_000_000

  ## For tests

  @doc "Adds an image, as if it had been pulled."
  def put_image(%{model: model}, image), do: GenServer.call(model, {:put_image, image})

  @doc """
  Adds a container. `attrs` may set `:image`, `:state` (the engine's word,
  default `"running"`), `:labels`, `:env` (a list), `:restart_policy`,
  `:health` (`{status, failing_streak}`), `:exit_code`, `:ip`, and
  `:fail_start` (the message a start is refused with).
  """
  def put_container(%{model: model}, name, attrs \\ []),
    do: GenServer.call(model, {:put_container, name, Map.new(attrs)})

  @doc "Takes a container away, with its `destroy` event, as something other than the code under test would."
  def delete_container(%{model: model}, name),
    do: GenServer.call(model, {:delete_container, name})

  @doc "The model's record of a container, or `nil`."
  def container(%{model: model}, name), do: GenServer.call(model, {:container, name})

  @doc """
  How a pull of `image` goes: `:ok` (two progress lines, then present),
  `{:lines, [map]}` (those lines, then present), `{:error, message}` (one
  progress line, then the error as a line), `:not_found` (a 404 and no
  stream), `{:stall, [map]}` (those lines, then silence), `{:steps, steps}`
  (exactly those `Vagus.Test.FakeEngine` stream steps).
  """
  def script_pull(%{model: model}, image, script),
    do: GenServer.call(model, {:script_pull, image, script})

  @doc "The container's process exits by itself with `exit_code`."
  def crash(%{model: model}, name, exit_code \\ 1),
    do: GenServer.call(model, {:crash, name, exit_code})

  def set_health(%{model: model}, name, status, failing_streak \\ 0),
    do: GenServer.call(model, {:set_health, name, status, failing_streak})

  @doc """
  Has every start of the container named `name` refused with `message`, as
  a 500, until it is called again with `nil`. The container need not exist
  yet.
  """
  def fail_start(%{model: model}, name, message),
    do: GenServer.call(model, {:fail_start, name, message})

  @doc "Emits a container event for any name, existing or not. Returns its `timeNano`."
  def emit(%{model: model}, action, name, attributes \\ %{}),
    do: GenServer.call(model, {:emit, action, name, attributes})

  @doc """
  Ends every open event stream, as an engine restart would: `:abort` breaks
  the connection, `:finish` ends the response properly, and `{:mid_line,
  action, name}` writes half of an event's line first.
  """
  def drop_event_streams(%{model: model}, how \\ :abort),
    do: GenServer.call(model, {:drop_event_streams, how})

  @doc "Returns once an event stream is open: what happens from then on is told to somebody."
  def await_event_stream(%{model: model}), do: GenServer.call(model, :await_event_stream)

  @doc "How many event streams are open."
  def event_streams(%{model: model}), do: GenServer.call(model, :event_streams)

  def set(%{model: model}, key, value) when key in [:stop_delay],
    do: GenServer.call(model, {:set, key, value})

  @doc """
  Has the next request of `method` whose path contains `part` wait, having
  arrived and changed nothing, until `release/1`. The caller is told
  `{:fake_engine, :held, entry}` when it has arrived.
  """
  def hold(%{model: model}, method, part),
    do: GenServer.call(model, {:hold, method, part, self()})

  @doc "Lets every held request go on, in the order they arrived."
  def release(%{model: model}), do: GenServer.call(model, :release)

  @doc """
  Has every request of `method` whose path contains `part` answered with
  `status` and `message` instead of being served, until called with `nil`.
  """
  def fail(%{model: model}, method, part, answer),
    do: GenServer.call(model, {:fail, method, part, answer})

  ## Server

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :socket)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        {:ifaddr, {:local, path}},
        active: false,
        packet: :raw,
        backlog: 128
      ])

    model = self()
    notify = opts[:notify]
    spawn_link(fn -> accept(listen, model, notify) end)

    {:ok,
     %{
       stop_delay: Keyword.get(opts, :stop_delay, 0),
       containers: %{},
       images: MapSet.new(),
       pulls: %{},
       fail_starts: %{},
       on_request: Keyword.get(opts, :on_request, fn _entry, _containers -> :ok end),
       holds: [],
       held: [],
       fails: %{},
       streams: [],
       stream_waiters: [],
       tick: 0,
       listings: 0,
       log: []
     }}
  end

  defp accept(listen, model, notify) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        pid = spawn_link(fn -> serve(model, notify) end)
        :ok = :gen_tcp.controlling_process(sock, pid)
        send(pid, {:socket, sock})
        accept(listen, model, notify)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(model, notify) do
    sock =
      receive do
        {:socket, sock} -> sock
      end

    with {:ok, method, path, query, body} <- FakeEngine.read_request(sock) do
      entry = %{method: method, path: path, query: query, body: body}

      # A request the test holds waits here for as long as the test likes.
      case GenServer.call(model, {:request, entry}, :infinity) do
        {:reply, status, body} ->
          FakeEngine.send_response(sock, status, body)

        {:hold, delay, then} ->
          Process.sleep(delay)
          {status, body} = GenServer.call(model, then, 10_000)
          FakeEngine.send_response(sock, status, body)

        {:stream, steps} ->
          FakeEngine.stream(sock, 200, steps, path, notify)

        :events ->
          FakeEngine.stream(sock, 200, [{:run, fn -> events(sock) end}], path, nil)
          # The response has ended and the connection has not: an engine
          # keeps it for the next request, and it is the client's to close.
          _ = :gen_tcp.recv(sock, 0)
      end
    end

    :gen_tcp.close(sock)
  end

  # Returns to end the response properly; exits to break it instead.
  defp events(sock) do
    receive do
      {:event, line} ->
        FakeEngine.chunk(sock, line)
        events(sock)

      {:drop, :finish} ->
        :ok

      {:drop, :abort} ->
        :gen_tcp.close(sock)
        exit(:normal)

      {:drop, {:partial, line}} ->
        FakeEngine.chunk(sock, binary_part(line, 0, div(byte_size(line), 2)))
        :gen_tcp.close(sock)
        exit(:normal)
    end
  end

  @impl true
  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.log), state}

  def handle_call({:put_image, image}, _from, state),
    do: {:reply, :ok, %{state | images: MapSet.put(state.images, image)}}

  def handle_call({:put_container, name, attrs}, _from, state) do
    {state, container} = new_container(state, name, attrs)
    {:reply, container.id, put(state, container)}
  end

  def handle_call({:delete_container, name}, _from, state) do
    {container, containers} = Map.pop!(state.containers, name)
    {:reply, :ok, event(%{state | containers: containers}, "destroy", container)}
  end

  def handle_call({:container, name}, _from, state),
    do: {:reply, find(state, name), state}

  def handle_call({:script_pull, image, script}, _from, state),
    do: {:reply, :ok, %{state | pulls: Map.put(state.pulls, image, script)}}

  def handle_call({:set, key, value}, _from, state), do: {:reply, :ok, Map.put(state, key, value)}

  def handle_call({:fail_start, name, message}, _from, state),
    do: {:reply, :ok, %{state | fail_starts: Map.put(state.fail_starts, name, message)}}

  def handle_call({:crash, name, exit_code}, _from, state) do
    container = Map.fetch!(state.containers, name)
    state = event(state, "die", container, %{"exitCode" => to_string(exit_code)})

    if container.restart_policy in ["always", "unless-stopped"] do
      {state, at} = started_at(state)

      container = %{
        container
        | restart_count: container.restart_count + 1,
          started_at: at,
          # The engine resets it at the start that follows.
          exit_code: 0,
          state: "running"
      }

      {:reply, :ok, state |> put(container) |> event("start", container)}
    else
      {:reply, :ok, put(state, %{container | state: "exited", exit_code: exit_code})}
    end
  end

  def handle_call({:set_health, name, status, streak}, _from, state) do
    container = %{Map.fetch!(state.containers, name) | health: {status, streak}}
    {:reply, :ok, state |> put(container) |> event("health_status: #{status}", container)}
  end

  def handle_call({:emit, action, name, attributes}, _from, state) do
    container = %{id: "id-#{name}", name: name, labels: %{}}
    state = event(state, action, container, attributes)
    {:reply, @epoch + state.tick * 1_000_000, state}
  end

  def handle_call({:drop_event_streams, how}, _from, state) do
    how =
      case how do
        {:mid_line, action, name} ->
          container = %{id: "id-#{name}", name: name, labels: %{}}
          {:partial, line(event_map(state.tick + 1, action, container, %{}))}

        other ->
          other
      end

    for pid <- state.streams, do: send(pid, {:drop, how})
    {:reply, :ok, %{state | streams: []}}
  end

  def handle_call(:event_streams, _from, state), do: {:reply, length(state.streams), state}

  def handle_call(:await_event_stream, from, state) do
    if state.streams == [],
      do: {:noreply, %{state | stream_waiters: [from | state.stream_waiters]}},
      else: {:reply, :ok, state}
  end

  def handle_call({:finish_stop, name}, _from, state) do
    case Map.fetch(state.containers, name) do
      {:ok, %{state: "running"} = container} ->
        container = %{container | state: "exited", exit_code: 143}

        state =
          state
          |> put(container)
          |> event("die", container, %{"exitCode" => "143"})
          |> event("stop", container)

        {:reply, {204, nil}, state}

      _gone_or_stopped ->
        {:reply, {304, nil}, state}
    end
  end

  def handle_call({:hold, method, part, tell}, _from, state),
    do: {:reply, :ok, %{state | holds: state.holds ++ [{method, part, tell}]}}

  def handle_call(:release, _from, state) do
    state =
      Enum.reduce(Enum.reverse(state.held), %{state | held: []}, fn {from, entry}, state ->
        {reply, state} = served(entry, elem(from, 0), state)
        GenServer.reply(from, reply)
        state
      end)

    {:reply, :ok, state}
  end

  def handle_call({:fail, method, part, answer}, _from, state) do
    fails =
      if answer,
        do: Map.put(state.fails, {method, part}, answer),
        else: Map.delete(state.fails, {method, part})

    {:reply, :ok, %{state | fails: fails}}
  end

  def handle_call({:request, entry}, {pid, _tag} = from, state) do
    state.on_request.(entry, state.containers)
    state = %{state | log: [entry | state.log]}

    case Enum.split_with(state.holds, fn {method, part, _tell} ->
           entry.method == method and entry.path =~ part
         end) do
      {[{_method, _part, tell} | more], others} ->
        send(tell, {:fake_engine, :held, entry})
        {:noreply, %{state | holds: more ++ others, held: [{from, entry} | state.held]}}

      {[], _holds} ->
        {reply, state} = served(entry, pid, state)
        {:reply, reply, state}
    end
  end

  defp served(entry, pid, state) do
    failing =
      Enum.find_value(state.fails, fn {{method, part}, answer} ->
        if entry.method == method and entry.path =~ part, do: answer
      end)

    {reply, state} =
      case failing do
        {status, message} -> {{status, %{"message" => message}}, state}
        nil -> route(entry.method, String.split(entry.path, "/", trim: true), entry, pid, state)
      end

    case reply do
      {status, body} when is_integer(status) -> {{:reply, status, body}, state}
      other -> {other, state}
    end
  end

  ## Routes

  defp route(:get, ["_ping"], _entry, _pid, state), do: {{200, "OK"}, state}

  defp route(:get, ["events"], _entry, pid, state) do
    for waiter <- state.stream_waiters, do: GenServer.reply(waiter, :ok)
    {:events, %{state | streams: [pid | state.streams], stream_waiters: []}}
  end

  defp route(:get, ["containers", "json"], entry, _pid, state) do
    all? = entry.query["all"] == "true"
    filters = Jason.decode!(entry.query["filters"] || "{}")

    listed =
      for {_name, container} <- Enum.sort(state.containers),
          all? or container.state == "running",
          listed?(container, filters),
          do: %{
            "Id" => container.id,
            "Names" => ["/" <> container.name],
            "Image" => container.image,
            "State" => container.state,
            "Status" => status_text(container, state.listings),
            "Labels" => container.labels
          }

    {{200, listed}, %{state | listings: state.listings + 1}}
  end

  defp route(:get, ["containers", ref, "json"], _entry, _pid, state) do
    case find(state, ref) do
      nil -> {no_container(ref), state}
      container -> {{200, inspect_json(container)}, state}
    end
  end

  defp route(:post, ["containers", "create"], entry, _pid, state) do
    name = entry.query["name"]
    config = entry.body

    cond do
      is_map_key(state.containers, name) ->
        {{409, %{"message" => "Conflict. The container name \"/#{name}\" is already in use"}},
         state}

      not MapSet.member?(state.images, config["Image"]) ->
        {{404, %{"message" => "No such image: #{config["Image"]}"}}, state}

      true ->
        attrs = %{
          image: config["Image"],
          state: "created",
          labels: config["Labels"] || %{},
          env: config["Env"] || [],
          restart_policy: get_in(config, ["HostConfig", "RestartPolicy", "Name"])
        }

        {state, container} = new_container(state, name, attrs)
        {{201, %{"Id" => container.id}}, state |> put(container) |> event("create", container)}
    end
  end

  defp route(:post, ["containers", ref, "start"], _entry, _pid, state) do
    case find(state, ref) do
      nil ->
        {no_container(ref), state}

      %{state: "running"} ->
        {{304, nil}, state}

      %{fail_start: message} when is_binary(message) ->
        {{500, %{"message" => message}}, state}

      %{name: name} when is_binary(:erlang.map_get(name, state.fail_starts)) ->
        {{500, %{"message" => state.fail_starts[name]}}, state}

      container ->
        {state, at} = started_at(state)
        container = %{container | state: "running", started_at: at, exit_code: 0}
        {{204, nil}, state |> put(container) |> event("start", container)}
    end
  end

  defp route(:post, ["containers", ref, "stop"], _entry, _pid, state) do
    case find(state, ref) do
      nil ->
        {no_container(ref), state}

      %{state: "running"} = container ->
        {{:hold, state.stop_delay, {:finish_stop, container.name}},
         event(state, "kill", container)}

      _stopped ->
        {{304, nil}, state}
    end
  end

  defp route(:delete, ["containers", ref], _entry, _pid, state) do
    case find(state, ref) do
      nil ->
        {no_container(ref), state}

      container ->
        state = %{state | containers: Map.delete(state.containers, container.name)}
        {{204, nil}, event(state, "destroy", container)}
    end
  end

  defp route(:get, ["images" | ref], _entry, _pid, state) do
    image = image(ref, "json")

    if MapSet.member?(state.images, image),
      do: {{200, %{"Id" => "sha256:" <> image, "RepoTags" => [image]}}, state},
      else: {{404, %{"message" => "No such image: #{image}"}}, state}
  end

  defp route(:delete, ["images" | ref], _entry, _pid, state) do
    image = Enum.join(ref, "/")

    cond do
      not MapSet.member?(state.images, image) ->
        {{404, %{"message" => "No such image: #{image}"}}, state}

      Enum.any?(state.containers, fn {_name, container} -> container.image == image end) ->
        {{409, %{"message" => "conflict: unable to remove repository reference \"#{image}\""}},
         state}

      true ->
        {{200, [%{"Untagged" => image}]}, %{state | images: MapSet.delete(state.images, image)}}
    end
  end

  defp route(:post, ["images", "create"], entry, _pid, state) do
    image = "#{entry.query["fromImage"]}:#{entry.query["tag"]}"
    model = self()
    # A call, so the image is there before the stream that announces it ends.
    pulled = {:run, fn -> GenServer.call(model, {:put_image, image}) end}
    start = %{"status" => "Pulling from #{entry.query["fromImage"]}", "id" => entry.query["tag"]}

    reply =
      case Map.get(state.pulls, image, :ok) do
        :ok ->
          {:stream,
           [
             {:line, start},
             {:line, downloading("layer1", 50, 100)},
             {:line, %{"status" => "Pull complete", "id" => "layer1"}},
             pulled
           ]}

        {:lines, lines} ->
          {:stream, Enum.map(lines, &{:line, &1}) ++ [pulled]}

        {:error, message} ->
          {:stream,
           [
             {:line, start},
             {:line, %{"errorDetail" => %{"message" => message}, "error" => message}}
           ]}

        :not_found ->
          {404, %{"message" => "pull access denied for #{entry.query["fromImage"]}"}}

        {:stall, lines} ->
          {:stream, Enum.map(lines, &{:line, &1}) ++ [:stall]}

        {:steps, steps} ->
          {:stream, steps}
      end

    {reply, state}
  end

  defp route(_method, _path, entry, _pid, state),
    do: {{500, %{"message" => "the model has no #{entry.method} #{entry.path}"}}, state}

  @doc "A `Downloading` progress line."
  def downloading(layer, current, total) do
    %{
      "status" => "Downloading",
      "id" => layer,
      "progressDetail" => %{"current" => current, "total" => total}
    }
  end

  ## State

  defp new_container(state, name, attrs) do
    tick = state.tick + 1
    state = %{state | tick: tick}
    state_word = Map.get(attrs, :state, "running")

    {state, at} =
      if state_word in ["created"], do: {state, "0001-01-01T00:00:00Z"}, else: started_at(state)

    container = %{
      id: "id#{tick}-#{name}",
      name: name,
      image: Map.get(attrs, :image, "image:1"),
      state: state_word,
      labels: Map.get(attrs, :labels, %{}),
      env: Map.get(attrs, :env, []),
      restart_policy: Map.get(attrs, :restart_policy),
      restart_count: Map.get(attrs, :restart_count, 0),
      health: Map.get(attrs, :health),
      exit_code: Map.get(attrs, :exit_code, 0),
      started_at: at,
      ip: Map.get(attrs, :ip, "172.30.33.#{tick}"),
      fail_start: Map.get(attrs, :fail_start)
    }

    {state, container}
  end

  defp put(state, container),
    do: %{state | containers: Map.put(state.containers, container.name, container)}

  defp find(state, ref) do
    Map.get(state.containers, ref) ||
      Enum.find_value(state.containers, fn {_name, container} ->
        if container.id == ref, do: container
      end)
  end

  defp started_at(state) do
    tick = state.tick + 1
    fraction = tick |> Integer.to_string() |> String.pad_leading(9, "0")
    {%{state | tick: tick}, "2026-01-01T00:00:00.#{fraction}Z"}
  end

  defp event(state, action, container, attributes \\ %{}) do
    tick = state.tick + 1
    line = line(event_map(tick, action, container, attributes))
    for pid <- state.streams, do: send(pid, {:event, line})
    %{state | tick: tick}
  end

  defp event_map(tick, action, container, attributes) do
    nano = @epoch + tick * 1_000_000

    %{
      "Type" => "container",
      "Action" => action,
      "Actor" => %{
        "ID" => container.id,
        "Attributes" =>
          container.labels |> Map.merge(attributes) |> Map.put("name", container.name)
      },
      "time" => div(nano, 1_000_000_000),
      "timeNano" => nano
    }
  end

  defp line(event), do: Jason.encode!(event) <> "\n"

  # As the engine words it: a sentence for people, not a state.
  # The durations grow with every listing, as they do with time.
  defp status_text(%{state: "running", health: {health, _streak}}, age),
    do: "Up #{age + 3} seconds (#{health_text(health)})"

  defp status_text(%{state: "running"}, age), do: "Up #{age + 3} seconds"
  defp status_text(%{state: "created"}, _age), do: "Created"
  defp status_text(%{state: "paused"}, age), do: "Up #{age + 3} seconds (Paused)"
  defp status_text(%{state: "removing"}, _age), do: "Removal In Progress"
  defp status_text(%{state: "dead"}, _age), do: "Dead"

  defp status_text(%{state: "restarting"} = container, age),
    do: "Restarting (#{container.exit_code}) #{age + 1} seconds ago"

  defp status_text(container, age), do: "Exited (#{container.exit_code}) #{age + 2} seconds ago"

  defp health_text("starting"), do: "health: starting"
  defp health_text(health), do: health

  # Label values are all required; name values are alternatives, each a
  # regular expression matched anywhere in the name.
  defp listed?(container, filters) do
    labels? =
      Enum.all?(filters["label"] || [], fn label ->
        case String.split(label, "=", parts: 2) do
          [key] -> is_map_key(container.labels, key)
          [key, value] -> Map.get(container.labels, key) == value
        end
      end)

    names = filters["name"] || []
    name = container.name
    labels? and (names == [] or Enum.any?(names, &Regex.match?(Regex.compile!(&1), name)))
  end

  # An image reference has slashes of its own.
  defp image(ref, suffix) do
    {^suffix, parts} = List.pop_at(ref, -1)
    Enum.join(parts, "/")
  end

  defp no_container(ref), do: {404, %{"message" => "No such container: #{ref}"}}

  defp inspect_json(container) do
    status = container.state

    state =
      %{
        "Status" => status,
        "Running" => status in ["running", "restarting", "paused"],
        "Paused" => status == "paused",
        "Restarting" => status == "restarting",
        "Dead" => status == "dead",
        "ExitCode" => container.exit_code,
        "StartedAt" => container.started_at
      }
      |> then(fn state ->
        case container.health do
          nil ->
            state

          {health, streak} ->
            Map.put(state, "Health", %{"Status" => health, "FailingStreak" => streak})
        end
      end)

    %{
      "Id" => container.id,
      "Name" => "/" <> container.name,
      "RestartCount" => container.restart_count,
      "Image" => "sha256:" <> container.image,
      "State" => state,
      "Config" => %{
        "Image" => container.image,
        "Env" => container.env,
        "Labels" => container.labels
      },
      "HostConfig" => %{"RestartPolicy" => %{"Name" => container.restart_policy || ""}},
      "NetworkSettings" => %{
        "Networks" => %{
          "hassio" => %{"IPAddress" => if(status == "running", do: container.ip, else: "")}
        }
      }
    }
  end
end
