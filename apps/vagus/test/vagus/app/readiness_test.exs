defmodule Vagus.App.ReadinessTest do
  use ExUnit.Case, async: true

  alias Vagus.App.Profile
  alias Vagus.App.Readiness
  alias Vagus.App.Spec.Schema
  alias Vagus.Resource.Stamp
  alias Vagus.Test.AppManifests

  defp t(ms), do: %Stamp{incarnation: 1, at: ms}

  describe "decide/3" do
    @container %{kind: :container, deadline_ms: :infinity}
    @http %{kind: {:http, "/manifest.json"}, deadline_ms: 600_000}
    @process %{kind: :process, deadline_ms: :infinity}

    for {name, readiness, instance, answered?, expected} <- [
          {"a container that runs, no healthcheck", @container, %{state: :running, health: :none},
           false, :ready},
          {"a container that runs and is healthy", @container,
           %{state: :running, health: :healthy}, false, :ready},
          {"a healthcheck still starting", @container, %{state: :running, health: :starting},
           false, {:waiting, :health_starting}},
          {"a healthcheck that failed", @container, %{state: :running, health: :unhealthy}, false,
           {:waiting, :unhealthy}},
          {"a container that is created", @container, %{state: :created, health: :none}, false,
           {:waiting, :not_running}},
          {"a container that is paused", @container, %{state: :paused, health: :healthy}, false,
           {:waiting, :not_running}},
          {"a container the engine is restarting", @container,
           %{state: :restarting, health: :none}, true, {:waiting, :not_running}},
          {"an app asked over HTTP that has not answered", @http,
           %{state: :running, health: :none}, false, {:waiting, :not_answering}},
          {"an app asked over HTTP that has answered", @http, %{state: :running, health: :none},
           true, :ready},
          {"an answer from an app that has stopped", @http, %{state: :exited, health: :none},
           true, {:waiting, :not_running}},
          {"a process that exists", @process, %{state: :running, health: :none}, false, :ready}
        ] do
      test name do
        assert Readiness.decide(
                 unquote(Macro.escape(readiness)),
                 unquote(Macro.escape(instance)),
                 unquote(answered?)
               ) == unquote(Macro.escape(expected))
      end
    end

    test "every profile's readiness is one this decides" do
      for profile <- [Profile.Container, Profile.Core, Profile.Native] do
        readiness = profile.readiness(%{})
        assert Readiness.decide(readiness, %{state: :running, health: :none}, true) == :ready
      end
    end
  end

  describe "past_deadline?/3" do
    test "never without a deadline, or before the instance was seen running" do
      refute Readiness.past_deadline?(@container, t(0), t(10_000_000))
      refute Readiness.past_deadline?(@http, nil, t(10_000_000))
    end

    test "from the deadline on, measured from when the instance was first seen running" do
      refute Readiness.past_deadline?(@http, t(1_000), t(600_999))
      assert Readiness.past_deadline?(@http, t(1_000), t(601_000))
    end

    test "an instant from another incarnation has no age: the deadline starts over" do
      refute Readiness.past_deadline?(@http, %Stamp{incarnation: 9, at: 0}, t(10_000_000))
    end
  end

  describe "the probe of a manifest's watchdog URL" do
    defp spec(manifest, fields \\ %{}) do
      facts = Vagus.App.Facts.read(data_root: "/nowhere")

      config =
        AppManifests.parse!(
          Map.merge(
            %{"name" => "n", "version" => "1", "slug" => "probed", "image" => "local/probed"},
            manifest
          )
        )

      {:ok, spec} = Schema.validate(Schema.from_manifest(config, facts, fields), facts)
      spec
    end

    defp host(_port), do: "10.0.0.9"

    test "a bridged app is asked at its own address, on the port the template names" do
      spec =
        spec(%{
          "watchdog" => "http://[HOST]:[PORT:8099]/health?x=1",
          "ports" => %{"8099/tcp" => 18_099}
        })

      assert Readiness.watchdog_target(spec, %{address: "172.30.33.7"}, &host/1) ==
               %{proto: "http", host: "172.30.33.7", port: 8099, path: "/health?x=1"}
    end

    test "an app on the host network is asked on the host, at the port published there" do
      spec =
        spec(%{
          "watchdog" => "tcp://[HOST]:[PORT:1883]",
          "host_network" => true,
          "ports" => %{"1883/tcp" => 11_883}
        })

      assert Readiness.watchdog_target(spec, %{address: nil}, &host/1) ==
               %{proto: "tcp", host: "10.0.0.9", port: 11_883, path: "/"}
    end

    test "the protocol can follow one of the app's options, the user's over the manifest's" do
      manifest = %{
        "watchdog" => "[PROTO:ssl]://[HOST]:[PORT:80]",
        "options" => %{"ssl" => false},
        "schema" => %{"ssl" => "bool"}
      }

      assert %{proto: "http"} =
               Readiness.watchdog_target(spec(manifest), %{address: "a"}, &host/1)

      assert %{proto: "https"} =
               Readiness.watchdog_target(
                 spec(manifest, %{options: %{"ssl" => true}}),
                 %{address: "a"},
                 &host/1
               )
    end

    test "nothing to aim at: no template, or an instance without an address" do
      assert Readiness.watchdog_target(spec(%{}), %{address: "a"}, &host/1) == nil

      assert Readiness.watchdog_target(
               spec(%{"watchdog" => "http://[HOST]:[PORT:80]/"}),
               %{address: nil},
               &host/1
             ) ==
               nil
    end

    test "is due two minutes after the app began to be watched or was last asked" do
      refute Readiness.probe_due?(%{misses: 0, at: nil}, t(999_999))
      refute Readiness.probe_due?(%{misses: 0, at: t(0)}, t(119_999))
      assert Readiness.probe_due?(%{misses: 0, at: t(0)}, t(120_000))
      assert Readiness.probe_due_in(%{misses: 0, at: t(0)}, t(100_000)) == 20_000
      assert Readiness.probe_due_in(%{misses: 0, at: t(0)}, t(500_000)) == 0
      assert Readiness.probe_due_in(%{misses: 0, at: nil}, t(0)) == Readiness.probe_interval_ms()
    end

    test "two misses in a row are unhealthy; an answer between them is not" do
      probe = %{misses: 0, at: t(0)}
      one = Readiness.strike(probe, :unhealthy, t(1))
      refute Readiness.unhealthy?(one)
      assert Readiness.unhealthy?(Readiness.strike(one, :unhealthy, t(2)))

      answered = Readiness.strike(one, :healthy, t(2))
      assert answered == %{misses: 0, at: t(2)}
      refute Readiness.unhealthy?(Readiness.strike(answered, :unhealthy, t(3)))
    end

    test "a probe that could not be aimed leaves the count and is not asked again at once" do
      assert Readiness.strike(%{misses: 1, at: t(0)}, :skipped, t(5)) == %{misses: 1, at: t(5)}
    end
  end

  describe "Vagus.App.Readiness.Http" do
    alias Vagus.App.Readiness.Http

    # Answers every connection with `response`, or holds it open in silence.
    defp serve(response) do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      test = self()
      pid = spawn_link(fn -> accept(listen, response, test) end)
      on_exit(fn -> Process.exit(pid, :kill) end)
      port
    end

    defp accept(listen, response, test) do
      with {:ok, socket} <- :gen_tcp.accept(listen) do
        if response, do: answer(socket, response, test)
        accept(listen, response, test)
      end
    end

    defp answer(socket, response, test) do
      {:ok, request} = :gen_tcp.recv(socket, 0)
      send(test, {:request, request})
      :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
    end

    defp target(port, proto \\ "http"),
      do: %{proto: proto, host: "127.0.0.1", port: port, path: "/manifest.json"}

    test "any status below 300 is an answer" do
      port = serve("HTTP/1.1 204 No Content\r\n\r\n")
      assert Http.probe(target(port), 2_000) == :ok
      assert_receive {:request, "GET /manifest.json HTTP/1.1" <> _}
    end

    test "any other status is none" do
      assert Http.probe(target(serve("HTTP/1.1 302 Found\r\nlocation: /\r\n\r\n")), 2_000) ==
               :error

      assert Http.probe(target(serve("HTTP/1.1 503 Busy\r\ncontent-length: 0\r\n\r\n")), 2_000) ==
               :error
    end

    test "an interim status is no answer: the final one that follows it is" do
      continue = "HTTP/1.1 100 Continue\r\n\r\n"
      hints = "HTTP/1.1 103 Early Hints\r\nlink: </style.css>; rel=preload\r\n\r\n"
      busy = "HTTP/1.1 503 Busy\r\ncontent-length: 0\r\n\r\n"
      fine = "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"

      assert Http.probe(target(serve(continue <> busy)), 2_000) == :error
      assert Http.probe(target(serve(hints <> fine)), 2_000) == :ok
      assert Http.probe(target(serve(continue <> hints <> busy)), 2_000) == :error
    end

    test "silence is none, within the time given" do
      port = serve(nil)
      started = System.monotonic_time(:millisecond)
      assert Http.probe(target(port), 150) == :error
      assert System.monotonic_time(:millisecond) - started < 2_000
    end

    # Writes `parts` one at a time, each when the test says so, and then
    # holds the connection open.
    defp serve_in_parts(parts) do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      test = self()

      pid =
        spawn_link(fn ->
          {:ok, socket} = :gen_tcp.accept(listen)
          {:ok, _request} = :gen_tcp.recv(socket, 0)

          for part <- parts do
            send(test, {:ready_to_write, self(), part})

            receive do
              :write -> :gen_tcp.send(socket, part)
            end
          end

          Process.sleep(:infinity)
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      port
    end

    test "a status line that comes in two reads is still an answer" do
      port = serve_in_parts(["HTTP/1.1 2", "04 No Content\r\n\r\n"])
      probing = Task.async(fn -> Http.probe(target(port), 5_000) end)

      # The second part is not written until the first has been sent, so
      # the probe has read a line that says nothing yet.
      assert_receive {:ready_to_write, server, "HTTP/1.1 2"}, 5_000
      send(server, :write)
      assert_receive {:ready_to_write, ^server, "04 No Content" <> _}, 5_000
      refute Task.yield(probing, 100)
      send(server, :write)
      assert Task.await(probing) == :ok
    end

    for {final, answer} <- [
          {"HTTP/1.1 503 Busy\r\ncontent-length: 0\r\n\r\n", :error},
          {"HTTP/1.1 204 No Content\r\n\r\n", :ok}
        ] do
      test "an interim status in one read and #{inspect(final)} in the next: #{answer}" do
        port = serve_in_parts(["HTTP/1.1 100 Continue\r\n\r\n", unquote(final)])
        probing = Task.async(fn -> Http.probe(target(port), 5_000) end)

        assert_receive {:ready_to_write, server, "HTTP/1.1 100" <> _}, 5_000
        send(server, :write)
        # Asked for only once the interim status has been sent: the probe
        # has read that one and goes on reading.
        assert_receive {:ready_to_write, ^server, unquote(final)}, 5_000
        refute Task.yield(probing, 100)
        send(server, :write)
        assert Task.await(probing) == unquote(answer)
      end
    end

    test "an interim status and then silence is none, within the time given" do
      port = serve_in_parts(["HTTP/1.1 100 Continue\r\n\r\n", "never written"])
      probing = Task.async(fn -> Http.probe(target(port), 300) end)
      assert_receive {:ready_to_write, server, "HTTP/1.1 100" <> _}, 5_000
      send(server, :write)
      assert Task.await(probing) == :error
    end

    test "an answer that stops in the middle is none, within the time given" do
      port = serve_in_parts(["HTTP/1.1 2", "never written"])
      started = System.monotonic_time(:millisecond)
      probing = Task.async(fn -> Http.probe(target(port), 300) end)
      assert_receive {:ready_to_write, server, "HTTP/1.1 2"}, 5_000
      send(server, :write)
      assert Task.await(probing) == :error
      assert System.monotonic_time(:millisecond) - started < 2_000
    end

    test "an app that answers over TLS with a certificate of its own making is answered for" do
      %{cert: cert, key: key} =
        :public_key.pkix_test_root_cert(~c"an app's own", key: {:rsa, 2048, 65_537})

      der = {:RSAPrivateKey, :public_key.der_encode(:RSAPrivateKey, key)}

      {:ok, listen} =
        :ssl.listen(0, cert: cert, key: der, active: false, mode: :binary, reuseaddr: true)

      {:ok, {_address, port}} = :ssl.sockname(listen)

      pid =
        spawn_link(fn ->
          {:ok, transport} = :ssl.transport_accept(listen)
          {:ok, socket} = :ssl.handshake(transport)
          {:ok, _request} = :ssl.recv(socket, 0)
          :ssl.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
          Process.sleep(:infinity)
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      assert Http.probe(target(port, "https"), 5_000) == :ok
      # The same port asked in the clear is no answer.
      assert Http.probe(target(port), 500) == :error
    end

    test "nothing listening is none, and so is a host that is none" do
      port = serve(nil)
      assert Http.probe(target(port + 0, "tcp"), 500) == :ok
      # A port that is held and not listened on refuses every connection,
      # and nobody else can take it meanwhile.
      {:ok, held} = :socket.open(:inet, :stream, :tcp)
      :ok = :socket.bind(held, %{family: :inet, addr: {127, 0, 0, 1}, port: 0})
      {:ok, %{port: free}} = :socket.sockname(held)
      on_exit(fn -> :socket.close(held) end)
      assert Http.probe(target(free), 500) == :error
      assert Http.probe(target(free, "tcp"), 500) == :error
      assert Http.probe(%{target(free) | host: "not a host"}, 500) == :error
      assert Http.probe(target(free, "gopher"), 500) == :error
    end
  end
end
