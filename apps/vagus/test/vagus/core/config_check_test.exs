defmodule Vagus.Core.ConfigCheckTest do
  @moduledoc """
  Hermetic, FakeEngine-driven tests for `POST /core/check`'s real
  implementation (audit G3) — same fake-unix-socket-daemon pattern
  `Vagus.Core.LifecycleTest` uses, since `ConfigCheck.check/1` drives the
  same `Vagus.Runtime.Docker` client.
  """
  use ExUnit.Case, async: false

  alias Vagus.Core.{ConfigCheck, Container}
  alias Vagus.Test.FakeEngine

  defp framed(payload, stream \\ 1), do: <<stream, 0, 0, 0, byte_size(payload)::32>> <> payload

  defp inspect_body(running), do: %{"State" => %{"Running" => running}}

  defp start_engine(responses) do
    engine = FakeEngine.start(responses)
    on_exit(fn -> FakeEngine.stop(engine) end)
    engine
  end

  describe "Core not running" do
    test "no container at all (404 inspect) -> {:not_running, message}" do
      engine = start_engine([{404, %{"message" => "No such container: homeassistant"}}])

      assert {:not_running, message} = ConfigCheck.check(docker: [socket: engine.socket])
      assert message =~ "not running"

      assert [%{method: :get, path: "/containers/homeassistant/json"}] =
               FakeEngine.requests(engine)
    end

    test "container exists but stopped -> {:not_running, message}, no exec attempted" do
      engine = start_engine([{200, inspect_body(false)}])

      assert {:not_running, message} = ConfigCheck.check(docker: [socket: engine.socket])
      assert message =~ "not running"
      assert [%{method: :get}] = FakeEngine.requests(engine)
    end

    test "a genuine inspect failure surfaces as {:error, reason}" do
      engine = start_engine([{500, %{"message" => "daemon exploded"}}])

      assert {:error, {:http, 500, _message}} = ConfigCheck.check(docker: [socket: engine.socket])
    end
  end

  describe "Core running — check_config exec" do
    test "exit 0, clean log -> :valid" do
      output = framed("Testing configuration at /config\nSuccess!\n")

      engine =
        start_engine([
          {200, inspect_body(true)},
          {201, %{"Id" => "exec-1"}},
          {200, output},
          {200, %{"Running" => false, "ExitCode" => 0}}
        ])

      assert :valid = ConfigCheck.check(docker: [socket: engine.socket])

      requests = FakeEngine.requests(engine)
      assert Enum.map(requests, & &1.method) == [:get, :post, :post, :get]
      assert Enum.at(requests, 1).path == "/containers/#{Container.name()}/exec"

      assert Enum.at(requests, 1).body["Cmd"] == [
               "/bin/sh",
               "-c",
               "python3 -m homeassistant -c /config --script check_config"
             ]
    end

    test "nonzero exit -> {:invalid, log}, log is the demuxed+ANSI-stripped output" do
      colored = "\e[31mFailed config\e[0m\nsome.yaml: invalid key 'foo'\n"
      output = framed(colored, 2)

      engine =
        start_engine([
          {200, inspect_body(true)},
          {201, %{"Id" => "exec-2"}},
          {200, output},
          {200, %{"Running" => false, "ExitCode" => 1}}
        ])

      assert {:invalid, log} = ConfigCheck.check(docker: [socket: engine.socket])
      assert log == "Failed config\nsome.yaml: invalid key 'foo'\n"
      refute log =~ "\e["
    end

    test "exit 0 but the log carries the yaml-error marker -> {:invalid, log} (two-way fix)" do
      output = framed("homeassistant.util.yaml.loader: while parsing a block mapping\n")

      engine =
        start_engine([
          {200, inspect_body(true)},
          {201, %{"Id" => "exec-3"}},
          {200, output},
          # Upstream's own check occasionally exits 0 even when the parser
          # logged a yaml error — the log match is what actually decides.
          {200, %{"Running" => false, "ExitCode" => 0}}
        ])

      assert {:invalid, log} = ConfigCheck.check(docker: [socket: engine.socket])
      assert log =~ "homeassistant.util.yaml"
    end

    test "an exec failure (e.g. create_exec 500) surfaces as {:error, reason}" do
      engine =
        start_engine([
          {200, inspect_body(true)},
          {500, %{"message" => "no such container"}}
        ])

      assert {:error, {:exec_create_failed, 500, _message}} =
               ConfigCheck.check(docker: [socket: engine.socket])
    end
  end
end
