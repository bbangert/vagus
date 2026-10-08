defmodule Vagus.App.Controller.LiveTest do
  # Against a real engine: `mix test --only docker`.
  use ExUnit.Case, async: false

  import Vagus.Resource.Harness

  alias Vagus.App.{AuthIndex, Backend, Controller, Prepare}
  alias Vagus.App.Spec.Schema
  alias Vagus.Resource.{Store, TestClock}
  alias Vagus.Runtime.Docker
  alias Vagus.Test.AppManifests

  @moduletag :docker
  @moduletag :capture_log
  @moduletag timeout: 180_000

  @socket "/var/run/docker.sock"
  @base "alpine:3"

  defp docker!(args) do
    {out, 0} = System.cmd("docker", args, stderr_to_stdout: true)
    String.trim(out)
  end

  defp docker(args), do: System.cmd("docker", args, stderr_to_stdout: true)

  setup do
    # With the OS process: the counter starts over in every VM.
    n = "#{System.pid()}_#{System.unique_integer([:positive])}"
    slug = "live_#{n}"
    repository = "vagus-live-#{n}/sleeper"
    image = "#{repository}:1"
    # Every run's directory under one of the tests' own, which is all that
    # is ever mounted to clean up.
    root = "/tmp/vagus-live/#{n}"
    pulled? = match?({_out, 1}, docker(["image", "inspect", @base]))

    # Before anything is made, so that what a failing setup left goes too.
    on_exit(fn ->
      docker(["rm", "-f", "app_" <> slug, "vagus-live-#{n}-seed"])
      docker(["rmi", image])
      docker(["run", "--rm", "-v", "/tmp/vagus-live:/own", @base, "rm", "-rf", "/own/#{n}"])
      if pulled?, do: docker(["rmi", @base])
      File.rm_rf!(root)
    end)

    # An image whose own command keeps running: an app's container is made
    # with no command of its own. Its init passes a stop's signal on, so a
    # stop takes no part of the engine's ten seconds of grace.
    docker!(["create", "--name", "vagus-live-#{n}-seed", @base, "sleep", "86400"])
    docker!(["commit", "--change", ~s(CMD ["sleep", "86400"]), "vagus-live-#{n}-seed", image])
    docker!(["rm", "vagus-live-#{n}-seed"])

    # The engine may not share this file system: a bind's source has to be
    # there on its side, and only the engine can make it there.
    data = Path.join([root, "addons", "data", slug])
    docker!(["run", "--rm", "-v", "#{data}:/data", @base, "true"])

    config =
      AppManifests.parse!(%{
        "name" => "Live",
        "version" => "1",
        "slug" => slug,
        "image" => repository,
        "host_network" => true
      })

    %{n: n, slug: slug, image: image, root: root, config: config}
  end

  test "install, start, crash, stop and uninstall on a real engine", ctx do
    %{slug: slug, image: image} = ctx
    name = "app_" <> slug
    events = Module.concat(__MODULE__, "Events#{System.unique_integer([:positive])}")
    engine = [engine: [socket: @socket]]

    wiring =
      &Vagus.App.wiring(
        instance: &1,
        engine: [socket: @socket],
        facts: [data_root: ctx.root],
        boot_marker: Path.join(ctx.root, "booted"),
        context: %{api_ready: fn -> true end},
        observer: [events: {Vagus.Runtime.Events, events}, interval: :infinity]
      )

    sys =
      start_system(
        controllers: wiring.(nil)[:controllers],
        services: &wiring.(&1)[:services],
        observers: &wiring.(&1)[:observers]
      )

    start_supervised!({Vagus.Runtime.Events, name: events, socket: @socket})
    facts = Vagus.App.Facts.read(data_root: ctx.root)

    spec = Schema.from_manifest(ctx.config, facts, %{settings: %{watchdog: true}})
    {:ok, _app} = Store.create(:app, slug, spec, sys.i)
    app = await!(sys, :app, slug, &(&1.status[:state] == :stopped))
    assert Controller.wire_state(app) == :stopped
    assert Backend.Container.observe(name, engine) == {:ok, :absent}

    {:ok, _app} = Store.update_spec(:app, slug, %{run: true}, sys.i)
    app = await!(sys, :app, slug, :ready)
    assert Controller.wire_state(app) == :started

    assert {:ok, %{state: :running, id: first, env: env}} =
             Backend.Container.observe(name, engine)

    assert app.status.instance.id == first
    assert AuthIndex.lookup(env["SUPERVISOR_TOKEN"], sys.i) == {:ok, slug}
    assert env["SUPERVISOR_TOKEN"] =~ ~r/\A[A-Za-z0-9_-]{43}\z/
    assert File.read!(Prepare.options_path(slug, facts)) == "{}"

    # Killed from outside: the engine's event wakes the app, which counts
    # it and, its pause over, makes the container anew.
    docker!(["kill", name])
    app = await!(sys, :app, slug, &match?(%{reason: :backing_off}, &1.status.conditions.ready))
    assert app.status.restarts.attempts == 1
    settle(sys)
    TestClock.advance(sys.clock, 10_000)
    fire_timer(sys, Controller, slug)
    app = await!(sys, :app, slug, :ready)

    assert {:ok, %{state: :running, id: second, env: env}} =
             Backend.Container.observe(name, engine)

    assert second != first
    assert app.status.instance.id == second
    assert AuthIndex.lookup(env["SUPERVISOR_TOKEN"], sys.i) == {:ok, slug}

    {:ok, _app} = Store.update_spec(:app, slug, %{run: false}, sys.i)
    app = await!(sys, :app, slug, &(&1.status[:state] == :stopped))
    assert app.status.restarts.attempts == 0
    assert Backend.Container.observe(name, engine) == {:ok, :absent}
    assert AuthIndex.digest_of(slug, sys.i) == :error

    {:ok, _app} = Store.update_spec(:app, slug, %{run: true}, sys.i)
    await!(sys, :app, slug, :ready)
    {:ok, _app} = Store.delete(:app, slug, sys.i)
    await!(sys, :app, slug, :gone)
    assert Backend.Container.observe(name, engine) == {:ok, :absent}
    assert Backend.Container.image_present?(image, engine) == {:ok, false}
    assert AuthIndex.digest_of(slug, sys.i) == :error
    refute File.exists?(Prepare.data_dir(slug, facts))
    assert {:ok, containers} = Docker.list_containers(all: true, socket: @socket)
    refute Enum.any?(containers, &(("/" <> name) in &1["Names"]))
  end
end
