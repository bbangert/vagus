defmodule Vagus.Runtime.Engine.Podman.EventSourceTest do
  # async: false — the end-to-end test registers in the global App.Directory.
  use ExUnit.Case, async: false

  alias Vagus.Runtime.Engine.Event
  alias Vagus.Runtime.Engine.Podman.EventSource
  alias Vagus.Runtime.Events

  @fixture Path.expand("../../../fixtures/podman/events.log", __DIR__)
  @recorded @fixture |> File.read!() |> String.split("\n", trim: true)

  setup do
    path = Path.join(System.tmp_dir!(), "podman-events-#{System.unique_integer([:positive])}.log")
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  # The test drives the ticks itself; the armed timer is too slow to fire.
  defp connect(path) do
    {:ok, notices, src} =
      EventSource.connect(EventSource.init(events_log: path, events_poll_ms: 60_000))

    {notices, src}
  end

  defp tick(src) do
    {:ok, notices, src} = EventSource.handle_info({EventSource, :tick, src.ref}, src)
    {notices, src}
  end

  defp append(path, data), do: File.write!(path, data, [:append])

  defp line(status, name, extra \\ %{}) do
    Jason.encode!(
      Map.merge(
        %{
          "ID" => "c1",
          "Name" => name,
          "Status" => status,
          "Time" => "2026-10-15T17:42:51.911683317Z",
          "Type" => "container",
          "Attributes" => %{"supervisor_managed" => ""}
        },
        extra
      )
    ) <> "\n"
  end

  test "connect starts at the end of the file and asks for a resync", %{path: path} do
    File.write!(path, Enum.join(@recorded, "\n") <> "\n")
    {notices, src} = connect(path)
    assert notices == [:answered, :ready]
    assert tick(src) |> elem(0) == []
  end

  test "appended lines arrive across ticks, a line split across appends whole", %{path: path} do
    File.write!(path, "")
    {[:answered, :ready], src} = connect(path)

    whole = line("start", "addon_a")
    split = line("died", "addon_b", %{"ContainerExitCode" => 3})
    {head, rest} = String.split_at(split, 40)

    append(path, whole <> head)
    {notices, src} = tick(src)
    assert [%Event{action: :start, name: "addon_a"}] = notices

    append(path, rest)
    {notices, src} = tick(src)
    assert [%Event{action: :die, name: "addon_b", exit_code: 3}] = notices
    assert tick(src) |> elem(0) == []
  end

  test "a file that does not exist yet is read from its first byte", %{path: path} do
    {[:answered, :ready], src} = connect(path)
    File.write!(path, line("start", "addon_a"))
    assert [%Event{action: :start}] = tick(src) |> elem(0)
  end

  test "a 300-byte line arrives intact", %{path: path} do
    File.write!(path, "")
    {_, src} = connect(path)

    long =
      line("start", "addon_a", %{
        "Attributes" => %{"supervisor_managed" => "", "pad" => String.duplicate("x", 200)}
      })

    assert byte_size(long) > 300

    {head, rest} = String.split_at(long, 280)
    append(path, head)
    {[], src} = tick(src)
    append(path, rest)
    assert [%Event{action: :start, name: "addon_a", managed: true}] = tick(src) |> elem(0)
  end

  describe "rotation" do
    test "a file replaced by a new one (new inode) is read from its start", %{path: path} do
      File.write!(path, line("start", "addon_old"))
      {_, src} = connect(path)

      # podman rotates by writing a truncated copy and renaming it over the log.
      tmp = path <> ".tmp"
      File.write!(tmp, line("died", "addon_new", %{"ContainerExitCode" => 1}))
      File.rename!(tmp, path)

      assert [%Event{action: :die, name: "addon_new"}] = tick(src) |> elem(0)
    end

    test "a file truncated below the offset is read from its start", %{path: path} do
      File.write!(path, String.duplicate(line("start", "addon_old"), 5))
      {_, src} = connect(path)
      File.write!(path, line("died", "addon_new", %{"ContainerExitCode" => 1}))
      assert [%Event{action: :die, name: "addon_new"}] = tick(src) |> elem(0)
    end
  end

  test "close cancels both timers and drops the file", %{path: path} do
    File.write!(path, "")

    {:ok, _, src} =
      EventSource.connect(EventSource.init(events_log: path, events_poll_ms: 50, resync_ms: 50))

    timers = [src.timer, src.resync_timer]
    src = EventSource.close(src)
    assert Enum.map(timers, &Process.read_timer/1) == [false, false]
    assert %{fd: nil, timer: nil, resync_timer: nil, ref: nil} = src
    refute_receive {EventSource, _, _}, 150
    assert EventSource.handle_info({EventSource, :tick, make_ref()}, src) == :unknown
  end

  test "every resync_ms it reports :ready again", %{path: path} do
    {:ok, [:answered, :ready], src} =
      EventSource.connect(
        EventSource.init(events_log: path, events_poll_ms: 60_000, resync_ms: 30)
      )

    ref = src.ref
    assert_receive {EventSource, :resync, ^ref} = msg, 500
    assert {:ok, [:ready], src} = EventSource.handle_info(msg, src)
    assert_receive {EventSource, :resync, ^ref}, 500
    EventSource.close(src)
  end

  test "a die whose line never reached the file is repaired by the periodic resync" do
    slug = "podman_missed_#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(Vagus.App.Directory, {:slug, slug}, nil)
    path = Path.join(System.tmp_dir!(), "podman-missed-#{System.unique_integer([:positive])}.log")
    File.write!(path, "")
    on_exit(fn -> File.rm(path) end)

    fake = Vagus.Runtime.Engine.Fake.start()
    Vagus.Runtime.Engine.Fake.put_container(fake, "addon_" <> slug, id: "c1")
    engine = [engine: Vagus.Runtime.Engine.Fake, fake: fake]

    start_supervised!(
      {Events,
       name: :"podman_missed_#{slug}",
       source: EventSource,
       list: fn -> Vagus.Runtime.Engine.list([all: true, name_prefix: "addon_"] ++ engine) end,
       engine_opts: [events_log: path, events_poll_ms: 20, resync_ms: 300]}
    )

    # The connect's own resync reports it running.
    assert_receive {:engine_event, %Event{action: :start, name: "addon_" <> ^slug}}, 2_000

    # It dies, and podman's line for it is lost.
    Vagus.Runtime.Engine.Fake.put_container(fake, "addon_" <> slug,
      id: "c1",
      state: :exited,
      exit_code: 9
    )

    assert_receive {:engine_event, %Event{action: :die, name: "addon_" <> ^slug, exit_code: 9}},
                   2_000
  end

  describe "normalisation of the recorded lines" do
    defp normalised, do: Enum.map(@recorded, &(&1 |> Jason.decode!() |> EventSource.normalize()))

    test "every status, the exit code, health, labels and time" do
      events = normalised()

      assert %Event{
               action: :create,
               name: "fx_running",
               id: "0592abe301c4b28c3f12696daf119c49fc87d7e39d5046fb217350aca63baf0a",
               managed: true,
               time_ns: 1_792_086_171_634_353_085
             } = hd(events)

      assert %Event{action: :die, name: "fx_exited", exit_code: 3, managed: false} =
               Enum.find(events, &(&1.action == :die))

      assert %Event{action: :health, health: :healthy, name: "fx_health"} =
               Enum.find(events, &(&1.action == :health))

      assert Enum.any?(events, &match?(%Event{action: :start, name: "fx_running"}, &1))
      # `init` and `cleanup` have no Docker counterpart.
      assert Enum.count(events, &(&1.action == :other)) == 6
    end

    test "remove is :destroy" do
      assert %Event{action: :destroy} =
               "remove" |> line("addon_a") |> Jason.decode!() |> EventSource.normalize()
    end
  end

  test "Events over this source sends an app process its container's death" do
    slug = "podman_events_#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(Vagus.App.Directory, {:slug, slug}, nil)

    path =
      Path.join(System.tmp_dir!(), "podman-events-e2e-#{System.unique_integer([:positive])}.log")

    File.write!(path, Enum.join(@recorded, "\n") <> "\n")
    on_exit(fn -> File.rm(path) end)

    events =
      start_supervised!(
        {Events,
         name: :"podman_events_#{slug}",
         source: EventSource,
         resync: false,
         engine_opts: [events_log: path, events_poll_ms: 20]}
      )

    # Connected once its state is readable: connect runs in handle_continue.
    _ = :sys.get_state(events)
    append(path, line("died", "addon_" <> slug, %{"ContainerExitCode" => 42}))

    assert_receive {:engine_event, %Event{action: :die, name: "addon_" <> ^slug, exit_code: 42}},
                   2_000

    # The history before connect was not replayed.
    refute_received {:engine_event, %Event{name: "fx_" <> _}}
  end
end
