defmodule Vagus.Runtime.Podman.ErrorTest do
  # Classifies what a real podman 6.1.4 printed: each case names a recorded
  # command in cli_results.txt. The lock, signal, detail and rm/rmi status-1
  # cases are synthetic; podman never printed them for us.
  use ExUnit.Case, async: true

  alias Vagus.Runtime.Podman.Error
  alias Vagus.Test.PodmanRecorded

  defp classify(verb, cmd) do
    {status, output} = PodmanRecorded.fetch!(cmd)
    Error.classify(verb, status, output)
  end

  test "an absent container is :not_found for every verb" do
    for {verb, cmd} <- [
          inspect: "container inspect ghost",
          start: "start ghost",
          stop: "stop ghost",
          restart: "restart ghost",
          logs: "logs ghost",
          stats: "stats --no-stream --no-reset --format '{{json .ContainerStats}}' ghost",
          exec: "exec ghost true",
          healthcheck: "healthcheck run ghost",
          remove: "rm ghost",
          exists: "container exists ghost"
        ] do
      assert {verb, classify(verb, cmd)} == {verb, {:error, :not_found}}
    end
  end

  test "a name in use is :conflict" do
    assert classify(
             :create,
             "create --name fx_running --pull=never docker.io/library/alpine:3.20 true"
           ) ==
             {:error, :conflict}
  end

  test "create from an absent image or onto an absent network" do
    assert classify(:create, "create --name fx_nope --pull=never docker.io/library/nope:1 true") ==
             {:error, {:failed, :create, :image_not_found}}

    assert classify(
             :create,
             "create --name fx_nonet --pull=never --network nonet docker.io/library/alpine:3.20 true"
           ) == {:error, {:failed, :create, :network_not_found}}
  end

  test "rmi: 2 is :in_use, 1 is :not_found" do
    assert classify(:remove_image, "rmi docker.io/library/alpine:3.20") == {:error, :in_use}
    assert classify(:remove_image, "rmi docker.io/library/nope:1") == {:error, :not_found}

    assert classify(:remove_image, "rmi --ignore -- docker.io/library/alpine:3.20") ==
             {:error, :in_use}
  end

  test "the exists verb's silent 1 is :not_found" do
    assert {1, _blank} = PodmanRecorded.fetch!("container exists -- ghost")
    assert classify(:exists, "container exists -- ghost") == {:error, :not_found}
  end

  # podman sets 1 for any error whose text mentions "no such container" (rm)
  # or for a missing image or layer (rmi); the absent target itself already
  # exits 0 under the --ignore Vagus always passes.
  test "status 1 from rm or rmi is :not_found only when the text says so" do
    for cmd <- ["rm --ignore -- ghost", "rm --force --ignore --time 0 -- ghost"],
        do: assert({0, _} = PodmanRecorded.fetch!(cmd))

    assert {0, _} = PodmanRecorded.fetch!("rmi --ignore -- docker.io/library/nope:1")

    assert Error.classify(:remove, 1, "Error: no such container") == {:error, :not_found}
    assert Error.classify(:remove_image, 1, "Error: x:1: image not known") == {:error, :not_found}

    assert {:error, {:failed, :remove, "Error: removing storage: permission denied"}} =
             Error.classify(:remove, 1, "Error: removing storage: permission denied\n")

    assert {:error, {:failed, :remove_image, "Error: 08bc4e53: layer not known"}} =
             Error.classify(:remove_image, 1, "Error: 08bc4e53: layer not known\n")

    assert {:error, {:failed, :remove_image, ""}} = Error.classify(:remove_image, 1, "")
  end

  test "rm: dependents and a running container without force are the verb's failure" do
    assert {:error, {:failed, :remove, detail}} =
             classify(:remove, "rm --force --ignore --time 0 -- fx_parent")

    assert detail =~ "has dependent containers"

    for cmd <- ["rm --ignore -- fx_running", "rm --ignore -- fx_paused"] do
      assert {:error, {:failed, :remove, detail}} = classify(:remove, cmd)
      assert detail =~ "container state improper"
    end
  end

  test "an existing network is :ok for ensure_network" do
    cmd =
      "network create --disable-dns --interface-name hassio --subnet 172.30.32.0/23 " <>
        "--gateway 172.30.32.1 --ip-range 172.30.33.0-172.30.33.255 --driver bridge hassio"

    assert classify(:ensure_network, cmd) == :ok
  end

  test "container state improper is the verb's own failure" do
    assert {:error, {:failed, :remove, detail}} = classify(:remove, "rm fx_running")
    assert detail =~ "container state improper"

    assert {:error, {:failed, :stop, _}} = classify(:stop, "stop -t 0 fx_paused")
    assert {:error, {:failed, :exec, _}} = classify(:exec, "exec fx_stopped true")
  end

  test "no healthcheck is a plain failure here; the adapter reads it" do
    assert {:error, {:failed, :healthcheck, detail}} =
             classify(:healthcheck, "healthcheck run fx_running")

    assert detail =~ "has no defined healthcheck"
  end

  test "SQLite's lock text is :busy; a mere mention of a lock is not" do
    assert Error.classify(:inspect, 125, "Error: database is locked") == {:error, :busy}

    for text <- ["Error: clock skew: timeout", "Error: block device lock timeout"] do
      assert {:error, {:failed, :inspect, _}} = Error.classify(:inspect, 125, text)
    end
  end

  test "a name in use is :conflict only for create" do
    text = "Error: that name is already in use"
    assert Error.classify(:create, 125, text) == {:error, :conflict}
    assert {:error, {:failed, :start, _}} = Error.classify(:start, 125, text)
  end

  test "the detail is cut at a codepoint boundary" do
    # 601 bytes of 3-byte codepoints: the last 512 start mid-codepoint.
    output = "a" <> String.duplicate("€", 200)
    assert {:error, {:failed, :start, detail}} = Error.classify(:start, 125, output)
    assert String.valid?(detail)
    assert byte_size(detail) <= 512 and byte_size(detail) >= 510
  end

  test "podman killed by a signal is :unavailable, but an exec's status is the command's" do
    assert Error.classify(:inspect, 137, "") == {:error, :unavailable}
    assert Error.classify(:exec, 137, "") == {:error, {:failed, :exec, ""}}
  end

  test "anything else is {:failed, verb, tail of output}" do
    long = String.duplicate("a", 600) <> " Error: boom\n"
    assert {:error, {:failed, :start, detail}} = Error.classify(:start, 125, long)
    assert byte_size(detail) == 512
    assert String.ends_with?(detail, "Error: boom")
  end
end
