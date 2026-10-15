defmodule Vagus.Runtime.Podman.CmdTest do
  use ExUnit.Case, async: true

  alias Vagus.Runtime.Podman.Cmd
  alias Vagus.Test.FakePodman

  defp script(body) do
    dir = Path.join(System.tmp_dir!(), "podman-cmd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    bin = Path.join(dir, "podman")
    File.write!(bin, "#!/bin/sh\n" <> body)
    File.chmod!(bin, 0o755)
    {bin, dir}
  end

  # A zombie has exited: only reaping removes it from /proc.
  defp alive?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> not (stat |> String.split(") ", parts: 2) |> List.last() =~ ~r/^Z/)
      {:error, _} -> false
    end
  end

  # The script's own marker that its TERM handling is set up.
  defp await_file(path) do
    Enum.find_value(1..1_000, fn _ ->
      case File.read(path) do
        {:ok, content} when content != "" -> String.trim(content)
        _ -> Process.sleep(10) && nil
      end
    end) || flunk("#{path} never appeared")
  end

  # Writes its pid once its TERM trap is in place, then loops until killed.
  defp trapping_script(trap) do
    script("""
    d="$(dirname "$0")"
    trap '#{trap}' TERM
    echo $$ > "$d/pid.tmp" && mv "$d/pid.tmp" "$d/pid"
    while :; do sleep 0.1; done
    """)
  end

  test "global flags come first, then the args as given" do
    fake = FakePodman.start([{"ps *", [{0, "[]"}]}])
    assert {:ok, "[]"} = Cmd.run(["ps", "--all"], timeout_ms: 5_000, podman_bin: fake.bin)
    assert [["--log-level=error", "--transient-store", "ps", "--all"]] = FakePodman.calls(fake)
  end

  test "a non-zero exit carries the merged output" do
    fake = FakePodman.start([{"start *", [{125, "Error: no such container\n"}]}])

    assert Cmd.run(["start", "--", "x"], timeout_ms: 5_000, podman_bin: fake.bin) ==
             {:exit, 125, "Error: no such container\n"}
  end

  test "a missing binary is :unavailable" do
    assert Cmd.run(["info"], timeout_ms: 1_000, podman_bin: "/nonexistent/podman") ==
             {:error, :unavailable}
  end

  test "an argument holding a NUL byte is refused before spawning" do
    assert Cmd.run(["start", "a\0b"], timeout_ms: 1_000, podman_bin: "/bin/true") ==
             {:error, :invalid_argument}
  end

  # The deadline must outlast the script's start on a starved runner; the
  # marker proves it did. `run` returns only once muontrap, and so podman,
  # has exited.
  describe "the deadline" do
    @tag timeout: 60_000
    test "SIGTERMs a podman that is still running, and returns once it is dead" do
      {bin, dir} = trapping_script(~s(echo term > "$d/term"; exit 0))
      task = Task.async(fn -> Cmd.run([], timeout_ms: 5_000, podman_bin: bin) end)
      pid = await_file(Path.join(dir, "pid"))

      assert Task.await(task, 30_000) == {:error, :timeout}
      assert File.read!(Path.join(dir, "term")) == "term\n"
      refute alive?(pid), "podman #{pid} outlived run/2"
    end

    @tag timeout: 60_000
    test "SIGKILLs one that survives SIGTERM, and returns once it is dead" do
      {bin, dir} = trapping_script(~s(echo term >> "$d/term"))
      task = Task.async(fn -> Cmd.run([], timeout_ms: 5_000, podman_bin: bin) end)
      pid = await_file(Path.join(dir, "pid"))

      assert Task.await(task, 30_000) == {:error, :timeout}
      assert File.read!(Path.join(dir, "term")) =~ "term"
      refute alive?(pid), "podman #{pid} outlived run/2"
    end
  end

  # A caller that resumes after its deadline, with podman's output and exit
  # status already queued, is still past its deadline.
  test "output queued past the deadline does not outrun it" do
    {bin, dir} =
      script("""
      d="$(dirname "$0")"
      : > "$d/started"
      sleep 0.3
      printf done
      : > "$d/printed"
      """)

    caller = spawn_run(bin, timeout_ms: 500)
    await_file_exists(Path.join(dir, "started"))
    :erlang.suspend_process(caller)
    await_file_exists(Path.join(dir, "printed"))
    Process.sleep(700)
    :erlang.resume_process(caller)

    assert_receive {:result, {:error, :timeout}}, 10_000
  end

  defp spawn_run(bin, opts) do
    test = self()
    spawn(fn -> send(test, {:result, Cmd.run([], [podman_bin: bin] ++ opts)}) end)
  end

  defp await_file_exists(path) do
    Enum.find(1..1_000, fn _ -> File.exists?(path) or (Process.sleep(10) && false) end) ||
      flunk("#{path} never appeared")
  end

  # Discarded stdout must not even reach the caller's mailbox: a suspended
  # caller would otherwise hold all 50 MB of it.
  @tag timeout: 60_000
  test "discarded stdout never reaches the caller; stderr and the exit code do" do
    {bin, dir} =
      script("""
      d="$(dirname "$0")"
      : > "$d/started"
      head -c 50000000 /dev/zero
      echo err >&2
      : > "$d/written"
      exit 3
      """)

    caller =
      spawn_run(bin, timeout_ms: 30_000, cap: 65_536, truncate: true, discard_stdout: true)

    await_file_exists(Path.join(dir, "started"))
    :erlang.suspend_process(caller)
    await_file_exists(Path.join(dir, "written"))
    # Time for any output still in flight to land in the mailbox.
    Process.sleep(200)

    [message_queue_len: queued, memory: memory] =
      Process.info(caller, [:message_queue_len, :memory])

    :erlang.resume_process(caller)

    assert queued < 10
    assert memory < 1_048_576
    assert_receive {:result, {:exit, 3, "err\n"}}, 10_000
  end

  describe "the output cap" do
    setup do
      {bin, _dir} = script("printf '%5000s' '' | tr ' ' x\n")
      %{bin: bin}
    end

    test "past the cap the call fails", %{bin: bin} do
      assert Cmd.run([], timeout_ms: 5_000, podman_bin: bin, cap: 100) ==
               {:error, :output_too_large}

      assert {:ok, out} = Cmd.run([], timeout_ms: 5_000, podman_bin: bin)
      assert byte_size(out) == 5_000
    end

    test "with truncate: true it keeps the head", %{bin: bin} do
      assert Cmd.run([], timeout_ms: 5_000, podman_bin: bin, cap: 100, truncate: true) ==
               {:ok, String.duplicate("x", 100)}
    end
  end

  test "the call's env reaches podman's environment, a secret never its argv" do
    fake = FakePodman.start([{"create *", [{0, "c0ffee\n"}]}], log_env: ["SECRET_X", "PLAIN"])

    {:ok, _} =
      Cmd.run(["create", "--env", "SECRET_X", "--", "img"],
        timeout_ms: 5_000,
        podman_bin: fake.bin,
        env: [{"SECRET_X", "s3cret"}, {"PLAIN", "p"}]
      )

    assert [["SECRET_X=s3cret", "PLAIN=p"]] = FakePodman.envs(fake)
    refute fake |> FakePodman.calls() |> List.flatten() |> Enum.any?(&(&1 =~ "s3cret"))
  end

  # MuonTrap.cmd/3's output acks kill a caller with :epipe now and then;
  # under this load it lost about 1 call in 20.
  @tag timeout: 120_000
  test "many quick calls at once never kill their callers" do
    fake = FakePodman.start([{"start *", [{125, "Error: no such container\n"}]}])

    reasons =
      1..640
      |> Task.async_stream(
        fn _ ->
          {_pid, ref} =
            spawn_monitor(fn ->
              {:exit, 125, _} =
                Cmd.run(["start", "--", "x"], timeout_ms: 30_000, podman_bin: fake.bin)
            end)

          receive do
            {:DOWN, ^ref, :process, _, reason} -> reason
          end
        end,
        max_concurrency: 64,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, reason} -> reason end)

    assert Enum.frequencies(reasons) == %{normal: 640}
  end

  describe "decode/1" do
    test "decodes JSON" do
      assert Cmd.decode(~s([{"Id":"a"}])) == {:ok, [%{"Id" => "a"}]}
    end

    test "skips a stray line before the document" do
      assert Cmd.decode(~s(time="x" level=warning msg="y"\n[{"Id":"a"}]\n)) ==
               {:ok, [%{"Id" => "a"}]}
    end

    test "garbage is :bad_json" do
      assert Cmd.decode("nope") == {:error, :bad_json}
    end
  end
end
