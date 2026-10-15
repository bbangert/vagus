defmodule Vagus.Runtime.Podman.ErrorTest do
  # Classifies what a real podman 6.1.4 printed, not texts written for the
  # test: each case names a recorded command in cli_results.txt.
  use ExUnit.Case, async: true

  alias Vagus.Runtime.Podman.Error

  @fixture Path.expand("../../../fixtures/podman/cli_results.txt", __DIR__)
  @external_resource @fixture

  @recorded @fixture
            |> File.read!()
            |> String.split(~r/^\$ podman /m, trim: true)
            |> Map.new(fn entry ->
              [cmd, "[exit " <> rest] = String.split(entry, "\n", parts: 2)
              [code, output] = String.split(rest, "]\n", parts: 2)
              {cmd, {String.to_integer(code), output}}
            end)

  defp classify(verb, cmd) do
    {status, output} = Map.fetch!(@recorded, cmd)
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

  test "lock texts are :busy" do
    for text <- [
          "Error: database is locked",
          "Error: timed out waiting for lock",
          "Error: acquiring lock 3: timeout"
        ] do
      assert Error.classify(:inspect, 125, text) == {:error, :busy}
    end
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
