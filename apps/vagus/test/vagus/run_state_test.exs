defmodule Vagus.RunStateTest do
  use ExUnit.Case, async: true

  import Bitwise
  import ExUnit.CaptureLog

  alias Vagus.RunState

  @moduletag :tmp_dir

  @registry %{
    by_token: %{
      "tok" => %{
        slug: "core_mosquitto",
        services_role: %{"mqtt" => "provide"},
        auth_api: true,
        discovery: ["mqtt"],
        hassio_api: true,
        hassio_role: "manager",
        homeassistant_api: false
      }
    },
    token_by_slug: %{"core_mosquitto" => "tok"}
  }

  @dns %{"core-mosquitto" => {172, 30, 33, 2}}

  test "round-trips the registry and dns shapes", %{tmp_dir: dir} do
    registry_path = Path.join(dir, "registry.term")
    dns_path = Path.join(dir, "dns.term")

    assert RunState.save(registry_path, @registry) == :ok
    assert RunState.save(dns_path, @dns) == :ok

    assert RunState.load(registry_path, :default) == @registry
    assert RunState.load(dns_path, :default) == @dns
  end

  # By path: `capture_log` also collects what concurrent tests log.
  test "a missing file yields the default without logging", %{tmp_dir: dir} do
    path = Path.join(dir, "gone.term")

    log = capture_log(fn -> assert RunState.load(path, :default) == :default end)

    refute log =~ path
  end

  test "an undecodable file yields the default and logs the path, not the contents", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "garbage.term")
    File.write!(path, "not a term")

    log = capture_log(fn -> assert RunState.load(path, :default) == :default end)

    assert log =~ path
    assert log =~ "undecodable"
    refute log =~ "not a term"
  end

  test "an unreadable file yields the default and logs the path and posix reason", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "adir.term")
    File.mkdir!(path)

    log = capture_log(fn -> assert RunState.load(path, :default) == :default end)

    assert log =~ path
    assert log =~ ":eisdir"
  end

  test "a failed save removes the older checkpoint rather than leaving it", %{tmp_dir: dir} do
    path = Path.join(dir, "registry.term")
    assert RunState.save(path, :v1) == :ok
    assert RunState.load(path, :default) == :v1

    File.mkdir!(path <> ".tmp")

    log = capture_log(fn -> assert RunState.save(path, :v2) == :ok end)

    refute File.exists?(path)
    assert RunState.load(path, :default) == :default
    assert log =~ path
    assert log =~ ":eisdir"
  end

  test "a failed save does not log the term", %{tmp_dir: dir} do
    path = Path.join(dir, "registry.term")
    File.mkdir!(path <> ".tmp")

    log = capture_log(fn -> RunState.save(path, %{secret: "hunter2"}) end)

    assert log =~ path
    refute log =~ "hunter2"
  end

  test "a failed save removes its tmp file", %{tmp_dir: dir} do
    path = Path.join(dir, "registry.term")
    # Renaming a file onto a non-empty directory fails after the tmp write succeeded.
    File.mkdir_p!(Path.join(path, "child"))

    capture_log(fn -> assert RunState.save(path, :v1) == :ok end)

    refute File.exists?(path <> ".tmp")
  end

  test "a saved file is mode 0600", %{tmp_dir: dir} do
    path = Path.join(dir, "registry.term")
    assert RunState.save(path, @registry) == :ok

    assert (File.stat!(path).mode &&& 0o777) == 0o600
  end

  test "a nil path is a no-op for save and load", %{tmp_dir: dir} do
    assert RunState.save(nil, @registry) == :ok

    assert File.ls!(dir) == []
    assert RunState.load(nil, :d) == :d
  end
end

defmodule Vagus.RunStateEnvTest do
  # Mutates the global :run_state_dir, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  import Bitwise
  import ExUnit.CaptureLog

  alias Vagus.RunState

  @moduletag :tmp_dir

  setup do
    old = Application.fetch_env(:vagus, :run_state_dir)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:vagus, :run_state_dir, value)
        :error -> Application.delete_env(:vagus, :run_state_dir)
      end
    end)
  end

  test "reset_dir empties the directory and leaves it 0700", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "run")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "registry.term"), "stale")
    Application.put_env(:vagus, :run_state_dir, dir)

    assert RunState.reset_dir() == :ok

    assert File.ls!(dir) == []
    assert (File.stat!(dir).mode &&& 0o777) == 0o700
    assert RunState.path(:registry) == Path.join(dir, "registry.term")
  end

  # A directory that could not be replaced may hold a checkpoint from an
  # earlier run, or one somebody else put there.
  test "a reset that fails turns checkpointing off", %{tmp_dir: tmp} do
    not_a_dir = Path.join(tmp, "file")
    File.write!(not_a_dir, "")
    dir = Path.join(not_a_dir, "run")
    Application.put_env(:vagus, :run_state_dir, dir)

    log = capture_log(fn -> assert RunState.reset_dir() == :ok end)

    assert log =~ "run state dir #{dir} reset failed"
    assert Application.get_env(:vagus, :run_state_dir) == nil
    assert RunState.path(:registry) == nil
  end

  test "reset_dir creates a missing directory", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "nested/run")
    Application.put_env(:vagus, :run_state_dir, dir)

    assert RunState.reset_dir() == :ok

    assert File.dir?(dir)
  end

  # Nothing else keeps a checkpoint from outliving the application run it
  # describes.
  test "starting the application replaces the run-state directory" do
    dir = Application.fetch_env!(:vagus, :run_state_dir)
    sentinel = Path.join(dir, "sentinel")
    File.mkdir_p!(dir)
    File.write!(sentinel, "")
    on_exit(fn -> {:ok, _apps} = Application.ensure_all_started(:vagus) end)

    capture_log(fn -> :ok = Application.stop(:vagus) end)
    assert {:ok, _apps} = Application.ensure_all_started(:vagus)

    refute File.exists?(sentinel)
    assert File.dir?(dir)
  end

  test "path is inside the configured directory", %{tmp_dir: tmp} do
    Application.put_env(:vagus, :run_state_dir, tmp)

    assert RunState.path(:registry) == Path.join(tmp, "registry.term")
    assert RunState.path(:dns) == Path.join(tmp, "dns.term")
  end

  test "an unset directory makes path nil and reset_dir a no-op" do
    Application.put_env(:vagus, :run_state_dir, nil)

    assert RunState.path(:registry) == nil
    log = capture_log(fn -> assert RunState.reset_dir() == :ok end)

    refute log =~ "run state"
  end
end
