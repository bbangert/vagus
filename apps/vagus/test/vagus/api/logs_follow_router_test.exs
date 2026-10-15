defmodule Vagus.API.LogsFollowRouterTest do
  @moduledoc """
  `/logs/follow` routes — chunked headers, engine-backed streaming against
  `Engine.Fake`, client-death teardown, and the native-broker branch.
  async: false — mutates :vagus app env (the global Fake engine,
  follow_idle_ms, core_container) and registers the native broker's global
  process names.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  import Vagus.AppFixtures

  alias Vagus.Mqtt.Broker
  alias Vagus.Runtime.Engine.Fake

  @opts Vagus.API.Router.init([])

  defp sup(conn), do: put_req_header(conn, "authorization", "Bearer #{Vagus.API.Token.get()}")

  setup do
    # Short idle window so streams without an eof end deterministically
    # instead of holding for the production 15 min. 600ms (not lower): the
    # idle-terminated tests are a POSITIVE race — subscribe/backfill/live
    # delivery must all complete before the window fires — and this repo's
    # CI has punished tight windows before.
    Application.put_env(:vagus, :follow_idle_ms, 600)
    on_exit(fn -> Application.delete_env(:vagus, :follow_idle_ms) end)
    :ok
  end

  # Core's container on a global Fake engine: the router takes no per-call
  # engine opts.
  defp with_core(attrs) do
    fake = Fake.start_global()
    old_core = Application.get_env(:vagus, :core_container)
    Application.put_env(:vagus, :core_container, "homeassistant")

    on_exit(fn ->
      if old_core,
        do: Application.put_env(:vagus, :core_container, old_core),
        else: Application.delete_env(:vagus, :core_container)
    end)

    Fake.put_container(fake, "homeassistant", attrs)
    fake
  end

  # The engine's streamer is linked to the request process that started it.
  defp streamer_of(request) do
    wait_until(fn -> linked(request) != nil end)
    linked(request)
  end

  defp linked(pid) do
    case Process.info(pid, :links) do
      {:links, links} -> Enum.find(links, &(is_pid(&1) and &1 != self()))
      nil -> nil
    end
  end

  # -- engine-backed follow ---------------------------------------------------

  test "core follow: chunked 200 + headers + streamed lines until the engine ends it" do
    with_core(logs: "one\ntwo\n")

    conn = conn(:get, "/core/logs/follow?lines=7") |> sup() |> Vagus.API.Router.call(@opts)
    assert conn.status == 200
    assert get_resp_header(conn, "x-first-cursor") == ["0"]
    assert get_resp_header(conn, "x-accel-buffering") == ["no"]
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
    assert conn.resp_body == "one\ntwo\n"
  end

  test "no configured core container: honest empty chunked stream that closes" do
    conn = conn(:get, "/core/logs/follow") |> sup() |> Vagus.API.Router.call(@opts)
    assert conn.status == 200
    assert get_resp_header(conn, "x-first-cursor") == ["0"]
    assert conn.resp_body == ""
  end

  test "client death mid-stream tears down the engine's streamer" do
    with_core(logs: "before-death\n", follow_open: true)

    {:ok, request} =
      Task.start(fn ->
        conn(:get, "/core/logs/follow") |> sup() |> Vagus.API.Router.call(@opts)
      end)

    ref = request |> streamer_of() |> Process.monitor()
    Process.exit(request, :kill)
    assert_receive {:DOWN, ^ref, :process, _streamer, _reason}, 3_000
  end

  test "an add-on may not follow another add-on's logs" do
    {:ok, config} =
      Vagus.Addon.Config.parse(%{
        "name" => "Test App",
        "version" => "1",
        "slug" => "intruder",
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "x/y"
      })

    token = register_app_token(config)

    conn =
      conn(:get, "/addons/core_mosquitto/logs/follow")
      |> put_req_header("x-supervisor-token", token)
      |> Vagus.API.Router.call(@opts)

    assert conn.status == 403
  end

  # -- native-broker follow ---------------------------------------------------

  test "native add-on follow: backfill then live broker lines, unsubscribed after" do
    # Fake a running native broker: Native.running?/1 is a whereis on the
    # broker subtree name; the logs buffer is <name>.Logs.
    broker_name = Module.concat(Broker, "addon_core_mqtt")
    dummy = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(dummy, broker_name)
    on_exit(fn -> if Process.alive?(dummy), do: Process.exit(dummy, :kill) end)

    logs = start_supervised!({Broker.Logs, name: Module.concat(broker_name, "Logs")})
    GenServer.cast(logs, {:append, "old-line"})

    task =
      Task.async(fn ->
        conn(:get, "/addons/core_mqtt/logs/follow") |> sup() |> Vagus.API.Router.call(@opts)
      end)

    # Wait until the request process has subscribed, then append a live line.
    wait_until(fn -> map_size(:sys.get_state(logs).subscribers) == 1 end)
    GenServer.cast(logs, {:append, "live-line"})

    conn = Task.await(task, 5_000)
    assert conn.status == 200
    assert conn.resp_body == "old-line\nlive-line\n"
    # Idle teardown unsubscribed the (now finished) request process.
    assert :sys.get_state(logs).subscribers == %{}
  end

  # -- §A5 contract surface on follow routes (P3) -----------------------------

  test "follow rejects unsupported Accept with 400 before streaming" do
    conn =
      conn(:get, "/core/logs/follow")
      |> sup()
      |> put_req_header("accept", "application/json")
      |> Vagus.API.Router.call(@opts)

    assert conn.status == 400
  end

  test "lines floor + verbose: the engine gets tail 100 + timestamps; lines get the §A5 prefix" do
    fake = with_core(logs: "started\n")

    conn =
      conn(:get, "/core/logs/follow?lines=1&verbose") |> sup() |> Vagus.API.Router.call(@opts)

    assert {:follow_logs, opts} = List.keyfind(Fake.call_opts(fake), :follow_logs, 0)
    assert opts[:tail] == 100
    assert opts[:timestamps] == true

    {:ok, host} = :inet.gethostname()
    assert conn.resp_body == "2026-10-14 21:00:00.000 #{host} homeassistant: started\n"
  end

  test "boots/0/follow streams the current source; other offsets stream empty" do
    fake = with_core(logs: "current-boot\n")

    # Non-zero offset: no journal history — empty stream, no engine call.
    conn = conn(:get, "/core/logs/boots/-1/follow") |> sup() |> Vagus.API.Router.call(@opts)
    assert conn.status == 200
    assert conn.resp_body == ""
    assert Fake.calls(fake) == []

    # Offset 0 = current boot = the live source.
    conn = conn(:get, "/core/logs/boots/0/follow") |> sup() |> Vagus.API.Router.call(@opts)
    assert conn.resp_body == "current-boot\n"
  end

  test "the idle timeout tears down the engine's streamer" do
    with_core(logs: "only-line\n", follow_open: true)

    task =
      Task.async(fn ->
        conn(:get, "/core/logs/follow") |> sup() |> Vagus.API.Router.call(@opts)
      end)

    # Then silence: the 600ms idle window must fire and stop the streamer.
    ref = task.pid |> streamer_of() |> Process.monitor()
    conn = Task.await(task, 5_000)
    assert conn.status == 200
    assert conn.resp_body == "only-line\n"
    assert_receive {:DOWN, ^ref, :process, _streamer, _reason}, 1_000
  end

  # The request process outlives its stream (it answers, then waits): the
  # teardown must stop the streamer and leave the request process alone.
  test "the idle teardown stops the streamer without taking the request process with it" do
    with_core(logs: "only-line\n", follow_open: true)
    test = self()

    request =
      spawn(fn ->
        conn = conn(:get, "/core/logs/follow") |> sup() |> Vagus.API.Router.call(@opts)
        send(test, {:conn, conn})

        receive do
          :done -> :ok
        end
      end)

    request_ref = Process.monitor(request)
    streamer_ref = request |> streamer_of() |> Process.monitor()

    assert_receive {:conn, %{resp_body: "only-line\n"}}, 5_000
    assert_receive {:DOWN, ^streamer_ref, :process, _streamer, _reason}, 1_000
    refute_receive {:DOWN, ^request_ref, :process, _request, _reason}, 300
    send(request, :done)
  end

  test "verbose reassembles a line split across two engine chunks" do
    # One log line, split mid-word across two {:log_chunk, _} messages; the
    # router's line buffer must reassemble before applying the verbose prefix.
    with_core(logs: ["2026-07-23T01:02:03Z hel", "lo\n"])

    conn = conn(:get, "/core/logs/follow?verbose") |> sup() |> Vagus.API.Router.call(@opts)

    {:ok, host} = :inet.gethostname()
    assert conn.resp_body == "2026-07-23 01:02:03.000 #{host} homeassistant: hello\n"
  end

  test "native follow with ?verbose prefixes host + ident (no source stamps)" do
    broker_name = Module.concat(Broker, "addon_core_mqtt")
    dummy = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(dummy, broker_name)
    on_exit(fn -> if Process.alive?(dummy), do: Process.exit(dummy, :kill) end)

    logs = start_supervised!({Broker.Logs, name: Module.concat(broker_name, "Logs")})
    GenServer.cast(logs, {:append, "CONNECT c1"})

    conn =
      conn(:get, "/addons/core_mqtt/logs/follow?verbose")
      |> sup()
      |> Vagus.API.Router.call(@opts)

    {:ok, host} = :inet.gethostname()
    assert conn.resp_body == "#{host} addon_core_mqtt: CONNECT c1\n"
  end

  defp wait_until(fun, timeout_ms \\ 2_000) do
    do_wait_until(fun, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition never became true")

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end
end
