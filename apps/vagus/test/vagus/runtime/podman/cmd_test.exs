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

  defp alive?(pid), do: File.exists?("/proc/#{pid}")

  defp await_pid(dir) do
    path = Path.join(dir, "pid")

    Enum.find_value(1..100, fn _ ->
      case File.read(path) do
        {:ok, pid} when pid != "" -> String.trim(pid)
        _ -> Process.sleep(20) && nil
      end
    end)
  end

  defp await_dead(pid, ms) do
    Enum.any?(1..div(ms, 50), fn _ -> not alive?(pid) or (Process.sleep(50) && false) end)
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

  describe "the deadline" do
    test "SIGTERMs a podman that is still running" do
      {bin, dir} = script("echo $$ > \"$(dirname $0)/pid\"\nexec sleep 30\n")
      assert Cmd.run([], timeout_ms: 300, podman_bin: bin) == {:error, :timeout}
      pid = await_pid(dir)
      assert await_dead(pid, 1_500), "podman #{pid} survived the deadline"
    end

    @tag timeout: 20_000
    test "SIGKILLs one that ignores SIGTERM, 3 s later" do
      {bin, dir} =
        script("trap '' TERM\necho $$ > \"$(dirname $0)/pid\"\nwhile :; do sleep 0.1; done\n")

      assert Cmd.run([], timeout_ms: 300, podman_bin: bin) == {:error, :timeout}
      pid = await_pid(dir)
      Process.sleep(1_500)
      assert alive?(pid), "the TERM-trapping podman died before its SIGKILL was due"
      assert await_dead(pid, 4_000), "podman #{pid} survived SIGKILL"
    end
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
