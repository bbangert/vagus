defmodule Vagus.Runtime.DockerTest do
  use ExUnit.Case, async: false

  alias Vagus.Runtime.{Docker, Logs}
  alias Vagus.Test.FakeEngine
  alias Vagus.Test.FakeEngine.Model

  # An 8-byte-framed multiplex record (`Vagus.Runtime.Logs.demux/1`'s
  # counterpart) — `stream` 1 = stdout, 2 = stderr, matching what a
  # no-`Tty` exec (`AttachStdout`/`AttachStderr`, no `Tty` key) actually
  # produces.
  defp framed(payload, stream \\ 1), do: <<stream, 0, 0, 0, byte_size(payload)::32>> <> payload

  describe "transport errors (hermetic — no daemon)" do
    @bad_socket "/tmp/vagus-nonexistent-#{System.unique_integer([:positive])}.sock"

    test "request against a missing socket returns a connect error, never raises" do
      assert {:error, {:connect, _reason}} = Docker.request(:get, "/version", socket: @bad_socket)
    end

    test "ping against a missing socket returns an error" do
      assert {:error, _} = Docker.ping(socket: @bad_socket)
    end

    test "socket_path/0 falls back to the host default" do
      assert Docker.socket_path() == "/var/run/docker.sock"
    end
  end

  describe "container ref validation (hermetic — rejects before any connect)" do
    @malicious ["../images/create?fromImage=evil", "a/b", "a?b", "?x", "/x", "..", ""]

    test "path-op refs outside the Docker charset are rejected, no daemon touched" do
      for ref <- @malicious do
        assert {:error, {:invalid_ref, ^ref}} = Docker.start_container(ref)
        assert {:error, {:invalid_ref, ^ref}} = Docker.stop_container(ref)
        assert {:error, {:invalid_ref, ^ref}} = Docker.restart_container(ref)
        assert {:error, {:invalid_ref, ^ref}} = Docker.remove_container(ref)
        assert {:error, {:invalid_ref, ^ref}} = Docker.inspect_container(ref)
      end
    end

    test "a non-string ref is rejected" do
      assert {:error, {:invalid_ref, :not_a_string}} = Docker.start_container(nil)
    end

    test "legitimate names/ids pass validation (fail later at connect, not at the ref check)" do
      # valid ref → not an :invalid_ref error; with no daemon it fails at connect.
      assert {:error, {:connect, _}} =
               Docker.start_container("addon_core_mosquitto",
                 socket: "/tmp/nope-#{System.unique_integer([:positive])}.sock"
               )
    end
  end

  describe "image ref validation (hermetic — rejects before any connect, W1)" do
    @malicious_images [
      "../images/create?fromImage=evil",
      "a/../../etc",
      "..",
      "/etc/passwd",
      "repo:tag?x",
      "repo#frag",
      "repo tag with space",
      ""
    ]

    test "path-op image refs outside the docker-reference charset are rejected" do
      for ref <- @malicious_images do
        assert {:error, {:invalid_ref, ^ref}} = Docker.remove_image(ref)
      end
    end

    test "a non-string image ref is rejected" do
      assert {:error, {:invalid_ref, :not_a_string}} = Docker.remove_image(nil)
    end

    test "legitimate image refs (namespaces, tags, registry host:port) pass validation" do
      for ref <- [
            "alpine",
            "alpine:3",
            "homeassistant/amd64-addon-mosquitto:7.1.0",
            "ghcr.io:443/org/img:1.0",
            "library/ubuntu@sha256:abc123"
          ] do
        assert {:error, {:connect, _}} =
                 Docker.remove_image(ref,
                   socket: "/tmp/nope-#{System.unique_integer([:positive])}.sock"
                 )
      end
    end
  end

  describe "exec_capture/3 (hermetic — FakeEngine, audit G3)" do
    test "captures the still-framed output alongside a zero exit code" do
      output = framed("config valid\n")

      engine =
        FakeEngine.start([
          {201, %{"Id" => "exec-1"}},
          {200, output},
          {200, %{"Running" => false, "ExitCode" => 0}}
        ])

      on_exit(fn -> FakeEngine.stop(engine) end)

      assert {:ok, %{exit_code: 0, output: raw}} =
               Docker.exec_capture("homeassistant", "echo hi", socket: engine.socket)

      assert raw == output
      assert Logs.demux(raw) == "config valid\n"

      requests = FakeEngine.requests(engine)
      assert Enum.map(requests, & &1.method) == [:post, :post, :get]
      assert Enum.at(requests, 0).path == "/containers/homeassistant/exec"
      assert Enum.at(requests, 0).body["Cmd"] == ["/bin/sh", "-c", "echo hi"]
      assert Enum.at(requests, 1).path == "/exec/exec-1/start"
      assert Enum.at(requests, 1).body == %{"Detach" => false}
    end

    test "a nonzero exit code is still {:ok, ...} — a failing command is a result, not a client error" do
      output = framed("boom\n", 2)

      engine =
        FakeEngine.start([
          {201, %{"Id" => "exec-2"}},
          {200, output},
          {200, %{"Running" => false, "ExitCode" => 1}}
        ])

      on_exit(fn -> FakeEngine.stop(engine) end)

      assert {:ok, %{exit_code: 1, output: raw}} =
               Docker.exec_capture("homeassistant", "false", socket: engine.socket)

      assert raw == output
    end

    test "no output at all normalizes to an empty binary, not a bare map" do
      engine =
        FakeEngine.start([
          {201, %{"Id" => "exec-3"}},
          {200, nil},
          {200, %{"Running" => false, "ExitCode" => 0}}
        ])

      on_exit(fn -> FakeEngine.stop(engine) end)

      assert {:ok, %{exit_code: 0, output: ""}} =
               Docker.exec_capture("homeassistant", "true", socket: engine.socket)
    end

    test "a create failure never reaches start/inspect" do
      engine = FakeEngine.start([{500, %{"message" => "no such container"}}])
      on_exit(fn -> FakeEngine.stop(engine) end)

      assert {:error, {:exec_create_failed, 500, _message}} =
               Docker.exec_capture("homeassistant", "echo hi", socket: engine.socket)

      assert length(FakeEngine.requests(engine)) == 1
    end
  end

  describe "receive timeout (hermetic — FakeEngine)" do
    setup do
      previous = Application.fetch_env(:vagus, :docker_recv_timeout)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:vagus, :docker_recv_timeout, value)
          :error -> Application.delete_env(:vagus, :docker_recv_timeout)
        end
      end)

      :ok
    end

    # An engine that holds its answer to a stop for longer than the default
    # receive timeout, which is cut to 50 ms so that "longer" is 400 ms.
    defp slow_stop do
      Application.put_env(:vagus, :docker_recv_timeout, 50)
      engine = FakeEngine.start([{204, nil, delay: 400}])
      on_exit(fn -> FakeEngine.stop(engine) end)
      engine
    end

    test "the default is 60 s when nothing configures it" do
      Application.delete_env(:vagus, :docker_recv_timeout)
      assert Docker.default_recv_timeout() == 60_000
    end

    test "a stop the engine holds past the default receive timeout fails as a timeout" do
      engine = slow_stop()

      assert {:error, %Mint.TransportError{reason: :timeout}} =
               Docker.stop_container("core", socket: engine.socket, timeout: 300)
    end

    test "the same stop succeeds with a receive timeout of its own" do
      engine = slow_stop()

      assert :ok =
               Docker.stop_container("core",
                 socket: engine.socket,
                 timeout: 300,
                 recv_timeout: 5_000
               )

      assert [%{method: :post, path: "/containers/core/stop", query: %{"t" => "300"}}] =
               FakeEngine.requests(engine)
    end
  end

  describe "pull_image_stream/4 (hermetic — FakeEngine)" do
    defp scripted(responses, opts \\ []) do
      engine = FakeEngine.start(responses, opts)
      on_exit(fn -> FakeEngine.stop(engine) end)
      engine
    end

    defp collect(engine, opts \\ []) do
      Docker.pull_image_stream(
        "repo/img:1",
        [],
        &[&1 | &2],
        [socket: engine.socket] ++ opts
      )
    end

    defp status(text), do: %{"status" => text}

    test "hands every progress line to the function, in order, and returns its accumulator" do
      lines = [status("Pulling from repo/img"), Model.downloading("l1", 1, 2), status("Digest")]
      engine = scripted([{:stream, 200, Enum.map(lines, &{:line, &1})}])

      assert {:ok, seen} = collect(engine)
      assert Enum.reverse(seen) == lines

      assert [%{path: "/images/create", query: %{"fromImage" => "repo/img", "tag" => "1"}}] =
               FakeEngine.requests(engine)
    end

    test "a line split across two chunks is one line" do
      line = Jason.encode!(status("Extracting")) <> "\n"
      {head, tail} = String.split_at(line, 9)
      engine = scripted([{:stream, 200, [{:chunk, head}, {:chunk, tail}]}])

      assert {:ok, [%{"status" => "Extracting"}]} = collect(engine)
    end

    test "an error line after the 200 fails the pull with the engine's message" do
      engine =
        scripted([
          {:stream, 200,
           [
             {:line, status("Pulling from repo/img")},
             {:line,
              %{
                "errorDetail" => %{"message" => "manifest unknown"},
                "error" => "manifest unknown"
              }},
             {:line, status("never read")}
           ]}
        ])

      assert {:error, {:pull_failed, "manifest unknown"}} = collect(engine)
    end

    test "an error line with no errorDetail fails the pull too" do
      engine = scripted([{:stream, 200, [{:line, %{"error" => "toomanyrequests"}}]}])

      assert {:error, {:pull_failed, "toomanyrequests"}} = collect(engine)
    end

    test "an errorDetail with no error key fails the pull too" do
      engine =
        scripted([{:stream, 200, [{:line, %{"errorDetail" => %{"message" => "no space left"}}}]}])

      assert {:error, {:pull_failed, "no space left"}} = collect(engine)
    end

    test "a refusal before the stream is the status and the engine's body" do
      engine = scripted([{404, %{"message" => "pull access denied"}}])

      assert {:error, {:pull_failed, {404, %{"message" => "pull access denied"}}}} =
               collect(engine)
    end

    test "silence longer than the idle timeout ends the pull" do
      # Nothing after the headers, so nothing has to arrive inside the 50 ms.
      engine = scripted([{:stream, 200, [:stall]}])

      assert {:error, {:pull_timeout, :idle}} =
               collect(engine, idle_timeout: 50, total_timeout: 60_000)
    end

    test "what came before the silence was handed over" do
      test = self()
      engine = scripted([{:stream, 200, [{:line, status("first")}, :stall]}])

      assert {:error, {:pull_timeout, :idle}} =
               Docker.pull_image_stream(
                 "repo/img:1",
                 nil,
                 fn line, nil -> send(test, {:line, line}) && nil end,
                 socket: engine.socket,
                 idle_timeout: 1_000
               )

      assert_received {:line, %{"status" => "first"}}
    end

    test "with both timeouts set, a silent stream ends by whichever is shorter" do
      engine = scripted([{:stream, 200, [:stall]}, {:stream, 200, [:stall]}])

      assert {:error, {:pull_timeout, :idle}} =
               collect(engine, idle_timeout: 50, total_timeout: 60_000)

      assert {:error, {:pull_timeout, :total}} =
               collect(engine, idle_timeout: 60_000, total_timeout: 50)
    end

    test "a stream that never falls silent still ends at the total timeout" do
      steps = Enum.flat_map(1..100, &[{:line, status("#{&1}")}, {:wait, 20}])
      engine = scripted([{:stream, 200, steps}])

      assert {:error, {:pull_timeout, :total}} =
               collect(engine, idle_timeout: 10_000, total_timeout: 100)
    end

    test "a reader slower than the stream, with lines always waiting, ends at the total too" do
      # The engine is done in a moment; the function takes 40 ms a line, so
      # every receive after the first finds data and none of them waits.
      steps = Enum.flat_map(1..40, &[{:line, status("#{&1}")}, {:wait, 2}])
      engine = scripted([{:stream, 200, steps}])
      test = self()

      slow = fn _line, count ->
        Process.sleep(40)
        send(test, {:read, count + 1})
        count + 1
      end

      assert {:error, {:pull_timeout, :total}} =
               Docker.pull_image_stream("repo/img:1", 0, slow,
                 socket: engine.socket,
                 total_timeout: 200
               )

      refute_received {:read, 40}
    end

    test "the total is asked about between the lines of one read, not only between reads" do
      # One write, and so one read or two: forty lines, forty milliseconds
      # each for the function.
      body = Enum.map_join(1..40, &(Jason.encode!(status("#{&1}")) <> "\n"))
      engine = scripted([{:stream, 200, [{:chunk, body}, :stall]}])

      slow = fn _line, count ->
        Process.sleep(40)
        count + 1
      end

      test = self()
      counted = fn line, count -> slow.(line, count) |> tap(&send(test, {:read, &1})) end

      assert {:error, {:pull_timeout, :total}} =
               Docker.pull_image_stream("repo/img:1", 0, counted,
                 socket: engine.socket,
                 total_timeout: 200
               )

      # The function ran for the lines before the total, and one at most
      # that began before it; not for the rest.
      assert_received {:read, 1}
      refute_received {:read, 10}
    end

    test "a last line the stream ends without terminating is still read" do
      engine = scripted([{:stream, 200, [{:chunk, Jason.encode!(status("last"))}]}])
      assert {:ok, [%{"status" => "last"}]} = collect(engine)
    end

    test "an error in a last line the stream ends without terminating fails the pull" do
      engine =
        scripted([
          {:stream, 200, [{:line, status("first")}, {:chunk, ~s({"error":"no space left"})}]}
        ])

      assert {:error, {:pull_failed, "no space left"}} = collect(engine)
    end

    test "a stream that breaks off is the transport's failure" do
      engine = scripted([{:stream, 200, [{:line, status("first")}, :abort]}])

      assert {:error, reason} = collect(engine)
      assert Docker.failure(reason) == {:transport, :closed}
    end

    test "an error line that arrives with the break is the pull's failure, not the break" do
      # One write: a whole chunk holding the error, then bytes that are no
      # chunk. The reader gets the data and the framing error together.
      chunk = ~s({"error":"layer verification failed"}\n)
      raw = Integer.to_string(byte_size(chunk), 16) <> "\r\n" <> chunk <> "\r\n" <> "ZZ\r\n"
      engine = scripted([{:stream, 200, [{:line, status("first")}, {:wait, 50}, {:raw, raw}]}])

      assert {:error, {:pull_failed, "layer verification failed"}} = collect(engine)
    end

    test "lines ending in CR LF are lines" do
      body = Enum.map_join(["a", "b"], &(Jason.encode!(status(&1)) <> "\r\n"))
      engine = scripted([{:stream, 200, [{:chunk, body}]}])

      assert {:ok, [%{"status" => "b"}, %{"status" => "a"}]} = collect(engine)
    end

    test "a read may end between CR and LF, in a chunk's size, or inside a character" do
      a = Jason.encode!(status("a"))
      accented = Jason.encode!(status("é"))
      [before, rest] = :binary.split(accented, <<0xA9>>)
      b = Jason.encode!(status("b")) <> String.duplicate(" ", 300) <> "\n"

      <<size_digit, framed_rest::binary>> =
        Integer.to_string(byte_size(b), 16) <> "\r\n" <> b <> "\r\n"

      engine =
        scripted([
          {:stream, 200,
           [
             {:chunk, a <> "\r"},
             {:wait, 20},
             {:chunk, "\n" <> before},
             {:wait, 20},
             {:chunk, <<0xA9>> <> rest <> "\n"},
             {:wait, 20},
             {:raw, <<size_digit>>},
             {:wait, 20},
             {:raw, framed_rest}
           ]}
        ])

      assert {:ok, seen} = collect(engine)
      assert Enum.reverse(seen) == [status("a"), status("é"), status("b")]
    end

    test "a refusal that is not JSON keeps its text" do
      engine = scripted([{500, "something broke\n"}])

      assert {:error, {:pull_failed, {500, "something broke\n"}} = reason} = collect(engine)

      assert Docker.failure({:pull_failed, {500, "something broke"}}) ==
               {:status, 500, "something broke"}

      assert {:status, 500, "something broke\n"} = Docker.failure(reason)
    end

    test "of a refusal's body no more than 64 kB is kept" do
      engine = scripted([{500, String.duplicate("x", 200_000)}])

      assert {:error, {:pull_failed, {500, kept}}} = collect(engine)
      assert byte_size(kept) == 65_536
    end

    for {reference, repo, tag} <- [
          {"img", "img", "latest"},
          {"repo/img:1.2", "repo/img", "1.2"},
          {"host:5000/img", "host:5000/img", "latest"},
          {"host:5000/org/img:1", "host:5000/org/img", "1"},
          {"img@sha256:abc", "img", "sha256:abc"},
          {"repo/img:1@sha256:abc", "repo/img", "sha256:abc"},
          {"host:5000/img@sha256:abc", "host:5000/img", "sha256:abc"}
        ] do
      test "#{reference} is pulled as #{repo} at #{tag}, streamed or buffered" do
        lines = [{:line, status("one")}, {:line, status("two")}]
        engine = scripted([{:stream, 200, lines}, {:stream, 200, lines}])

        assert {:ok, [_two, _one]} =
                 Docker.pull_image_stream(unquote(reference), [], &[&1 | &2],
                   socket: engine.socket
                 )

        assert :ok = Docker.pull_image(unquote(reference), socket: engine.socket)

        assert [%{"fromImage" => unquote(repo), "tag" => unquote(tag)} = query, query] =
                 for(request <- FakeEngine.requests(engine), do: request.query)
      end
    end

    test "killing the caller closes the connection" do
      test = self()
      engine = scripted([{:stream, 200, [{:line, status("first")}, :stall]}], notify: self())

      pulling = fn _line, nil -> send(test, :pulling) && nil end

      {caller, monitor} =
        spawn_monitor(fn ->
          Docker.pull_image_stream("repo/img:1", nil, pulling, socket: engine.socket)
        end)

      assert_receive :pulling, 2_000
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 2_000

      assert_receive {:fake_engine, :client_closed, "/images/create"}, 2_000
    end

    test "a stream larger than a buffered response may be is read through, none of it kept" do
      line = status(String.duplicate("x", 500_000))
      stream = {:stream, 200, List.duplicate({:line, line}, 36)}
      engine = scripted([stream, stream])

      # Binaries this process still holds once it has collected its garbage:
      # what the reader keeps of the stream, whatever it means to.
      held = fn ->
        :erlang.garbage_collect()
        {:binary, binaries} = Process.info(self(), :binary)
        binaries |> Enum.map(&elem(&1, 1)) |> Enum.sum()
      end

      base = held.()

      count = fn %{"status" => text}, {lines, bytes, most} ->
        {lines + 1, bytes + byte_size(text), max(most, held.() - base)}
      end

      assert {:ok, {36, 18_000_000, most}} =
               Docker.pull_image_stream("repo/img:1", {0, 0, 0}, count, socket: engine.socket)

      # A few lines' worth at the worst, with 36 gone by.
      assert most < 4_000_000

      # The same stream through the call that buffers it.
      assert {:error, :response_too_large} =
               Docker.pull_image("repo/img:1", socket: engine.socket)
    end

    # A progress line of exactly `bytes` bytes, its newline not counted.
    defp line_of(bytes) do
      empty = byte_size(Jason.encode!(status("")))
      Jason.encode!(status(String.duplicate("x", bytes - empty)))
    end

    test "a line that ends is refused over a megabyte like one that does not, before it is decoded" do
      engine =
        scripted([
          {:stream, 200, [{:line, status("first")}, {:chunk, line_of(1_048_577) <> "\n"}]}
        ])

      test = self()

      assert {:error, {:pull_failed, "progress line over 1048576 bytes"}} =
               Docker.pull_image_stream(
                 "repo/img:1",
                 nil,
                 fn line, nil -> send(test, {:line, line}) && nil end,
                 socket: engine.socket
               )

      assert_received {:line, %{"status" => "first"}}
      refute_received {:line, _the_long_one}
    end

    test "a line of exactly a megabyte is read, ended or left unended by the stream's end" do
      line = line_of(1_048_576)
      engine = scripted([{:stream, 200, [{:chunk, line <> "\n" <> line}]}])

      assert {:ok, [%{"status" => "x" <> _}, %{"status" => "x" <> _}]} = collect(engine)
    end

    test "a line with no end is refused once it passes a megabyte, while the stream goes on" do
      # The engine stays silent afterwards: the refusal cannot be waiting
      # for the stream to end, and a reader that only kept on buffering
      # would end in the idle timeout instead.
      engine = scripted([{:stream, 200, [{:chunk, String.duplicate("x", 1_100_000)}, :stall]}])

      assert {:error, {:pull_failed, "progress line over 1048576 bytes"}} =
               collect(engine, idle_timeout: 1_000)
    end
  end

  describe "listing, images and failure shapes (hermetic — FakeEngine model)" do
    setup do
      engine = FakeEngine.start_model()
      on_exit(fn -> FakeEngine.stop(engine) end)

      managed = %{"supervisor_managed" => ""}
      Model.put_container(engine, "app_a", labels: managed, image: "repo/a:1")

      Model.put_container(engine, "addon_b",
        labels: Map.put(managed, "tier", "x"),
        state: "exited"
      )

      Model.put_container(engine, "homeassistant", state: "exited")
      Model.put_container(engine, "bystander")

      %{engine: engine, opts: [socket: engine.socket]}
    end

    defp names(containers),
      do: containers |> Enum.flat_map(&Docker.summary(&1).names) |> Enum.sort()

    test "without all, only running containers are listed", %{opts: opts} do
      assert {:ok, listed} = Docker.list_containers(opts)
      assert names(listed) == ["app_a", "bystander"]
    end

    test "all: true lists stopped containers as well", %{opts: opts} do
      assert {:ok, listed} = Docker.list_containers([all: true] ++ opts)
      assert names(listed) == ["addon_b", "app_a", "bystander", "homeassistant"]
    end

    test "a label filter keeps the containers carrying the label", %{opts: opts} do
      filters = %{label: ["supervisor_managed"]}
      assert {:ok, listed} = Docker.list_containers([all: true, filters: filters] ++ opts)
      assert names(listed) == ["addon_b", "app_a"]
    end

    test "a label filter with a value asks for that value", %{opts: opts} do
      assert {:ok, listed} =
               Docker.list_containers([all: true, filters: %{label: ["tier=x"]}] ++ opts)

      assert names(listed) == ["addon_b"]
    end

    test "name filters are alternatives, each matched as an expression", %{opts: opts} do
      filters = %{name: ["^app_", "^homeassistant$"]}
      assert {:ok, listed} = Docker.list_containers([all: true, filters: filters] ++ opts)
      assert names(listed) == ["app_a", "homeassistant"]
    end

    test "filters travel as one JSON map in the query", %{engine: engine, opts: opts} do
      {:ok, _} =
        Docker.list_containers([all: true, filters: %{label: ["l"], name: ["n"]}] ++ opts)

      assert [%{path: "/containers/json", query: %{"all" => "true", "filters" => filters}}] =
               FakeEngine.requests(engine)

      assert Jason.decode!(filters) == %{"label" => ["l"], "name" => ["n"]}
    end

    test "no filters, no filters parameter", %{engine: engine, opts: opts} do
      {:ok, _} = Docker.list_containers(opts)
      assert [%{query: query}] = FakeEngine.requests(engine)
      refute is_map_key(query, "filters")
    end

    test "summary/1 is the listing's id, names, image, state, status and labels", %{opts: opts} do
      {:ok, listed} = Docker.list_containers([filters: %{name: ["^app_a$"]}] ++ opts)

      assert [
               %{
                 id: "id" <> _,
                 names: ["app_a"],
                 image: "repo/a:1",
                 state: "running",
                 status: "Up " <> _,
                 labels: %{"supervisor_managed" => ""}
               }
             ] = Enum.map(listed, &Docker.summary/1)
    end

    test "inspect_image/2 finds a present image and reports an absent one as 404", %{
      engine: engine,
      opts: opts
    } do
      Model.put_image(engine, "ghcr.io/org/img:1")

      assert {:ok, %{"RepoTags" => ["ghcr.io/org/img:1"]}} =
               Docker.inspect_image("ghcr.io/org/img:1", opts)

      assert {:error, {:http, 404, "No such image: ghcr.io/org/none:1"}} =
               Docker.inspect_image("ghcr.io/org/none:1", opts)

      assert {:error, {:invalid_ref, "../x"}} = Docker.inspect_image("../x", opts)
    end

    test "failure/1: no socket is unreachable" do
      assert {:error, reason} = Docker.inspect_container("x", socket: FakeEngine.socket_path())
      assert Docker.failure(reason) == {:unreachable, :enoent}
    end

    test "failure/1: a socket nobody listens on is unreachable" do
      path = FakeEngine.socket_path()
      {:ok, listen} = :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, path}}])
      :ok = :gen_tcp.close(listen)
      on_exit(fn -> File.rm(path) end)

      assert {:error, reason} = Docker.inspect_container("x", socket: path)
      assert Docker.failure(reason) == {:unreachable, :econnrefused}
    end

    test "failure/1: an engine that stays silent is a timeout" do
      engine = FakeEngine.start([{200, %{}, delay: 400}])
      on_exit(fn -> FakeEngine.stop(engine) end)

      assert {:error, reason} =
               Docker.inspect_container("x", socket: engine.socket, recv_timeout: 30)

      assert Docker.failure(reason) == {:timeout, :recv}
    end

    test "failure/1: a missing container is the 404 with the engine's message", %{opts: opts} do
      assert {:error, reason} = Docker.inspect_container("nobody", opts)
      assert Docker.failure(reason) == {:status, 404, "No such container: nobody"}
    end

    test "failure/1: a name in use is the 409 with the engine's message", %{
      engine: engine,
      opts: opts
    } do
      Model.put_image(engine, "repo/a:1")

      assert {:error, reason} =
               Docker.create_container(%{"Image" => "repo/a:1"}, [name: "app_a"] ++ opts)

      assert {:status, 409, "Conflict. The container name" <> _} = Docker.failure(reason)
    end

    test "start reports a refusal as before, and with the message when asked for detail", %{
      engine: engine,
      opts: opts
    } do
      message = "driver failed programming external connectivity: port is already allocated"
      Model.put_container(engine, "app_p", state: "created", fail_start: message)

      assert {:error, {:http, 500}} = Docker.start_container("app_p", opts)
      assert Docker.failure({:http, 500}) == {:status, 500, nil}

      assert {:error, {:http, 500, ^message} = reason} =
               Docker.start_container("app_p", [detail: true] ++ opts)

      assert Docker.failure(reason) == {:status, 500, message}
    end

    test "failure/1: the other shapes this module returns" do
      assert Docker.failure({:pull_failed, "manifest unknown"}) == {:stream, "manifest unknown"}

      assert Docker.failure({:pull_failed, {404, %{"message" => "denied"}}}) ==
               {:status, 404, "denied"}

      assert Docker.failure({:pull_timeout, :idle}) == {:timeout, :idle}
      assert Docker.failure({:remove_failed, 409, "in progress"}) == {:status, 409, "in progress"}
      assert Docker.failure(%Mint.TransportError{reason: :closed}) == {:transport, :closed}

      assert Docker.failure(%Mint.HTTPError{reason: :invalid_chunk_size}) ==
               {:transport, :invalid_chunk_size}

      assert Docker.failure({:connect, :enoent}) == {:unreachable, :enoent}
      assert Docker.failure({:invalid_ref, "a/b"}) == {:invalid, {:invalid_ref, "a/b"}}
      assert Docker.failure(:response_too_large) == {:other, :response_too_large}
    end
  end

  describe "against a live daemon" do
    @describetag :docker

    @image "alpine:3"

    test "ping / version / info" do
      assert :ok = Docker.ping()
      assert {:ok, %{"ApiVersion" => api}} = Docker.version()
      assert is_binary(api)
      assert {:ok, %{"OperatingSystem" => _}} = Docker.info()
    end

    test "pull → create → start → inspect → stop → remove lifecycle" do
      name = "vagus-rt-test-#{System.unique_integer([:positive])}"
      on_exit(fn -> Docker.remove_container(name, force: true) end)

      assert :ok = Docker.pull_image(@image)

      config = %{"Image" => @image, "Cmd" => ["sleep", "30"], "HostConfig" => %{}}
      assert {:ok, id} = Docker.create_container(config, name: name)
      assert is_binary(id)

      assert :ok = Docker.start_container(name)
      assert {:ok, %{"State" => %{"Running" => true}}} = Docker.inspect_container(name)

      # start is idempotent (already-running → :ok)
      assert :ok = Docker.start_container(name)

      assert {:ok, containers} = Docker.list_containers(all: true)
      assert Enum.any?(containers, fn c -> "/#{name}" in (c["Names"] || []) end)

      assert :ok = Docker.stop_container(name, timeout: 1)
      assert {:ok, %{"State" => %{"Running" => false}}} = Docker.inspect_container(name)

      assert :ok = Docker.remove_container(name)
      assert {:error, {:http, 404, _}} = Docker.inspect_container(name)
    end

    test "pull of a nonexistent image reports a stream error, not :ok" do
      assert {:error, {:pull_failed, _}} =
               Docker.pull_image(
                 "vagus-does-not-exist-#{System.unique_integer([:positive])}:nope"
               )
    end

    test "remove of a missing container is idempotent :ok" do
      assert :ok =
               Docker.remove_container("vagus-rt-missing-#{System.unique_integer([:positive])}")
    end
  end
end
