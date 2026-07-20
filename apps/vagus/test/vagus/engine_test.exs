defmodule Vagus.EngineTest do
  use ExUnit.Case, async: true

  alias Vagus.Engine

  describe "build_args/1" do
    test ":info addresses the daemon socket" do
      assert Engine.build_args(:info) == ["--host", Engine.socket(), "info"]
    end

    test ":ps lists all containers" do
      assert Engine.build_args(:ps) == ["--host", Engine.socket(), "ps", "-a"]
    end

    test "{:pull, image} pulls the given reference" do
      image = "ghcr.io/home-assistant/raspberrypi3-64-homeassistant:stable"

      assert Engine.build_args({:pull, image}) ==
               ["--host", Engine.socket(), "pull", image]
    end

    test "{:run, args} splices run args in verbatim after the run subcommand" do
      run_args = ["-d", "--name", "homeassistant", "--network=host", "some/image"]

      assert Engine.build_args({:run, run_args}) ==
               ["--host", Engine.socket(), "run" | run_args]
    end
  end

  test "socket/0 is the unix socket the daemon's --host flag binds" do
    assert Engine.socket() == "unix:///run/balena-engine.sock"
  end

  describe "shell-out wrappers when the balena-engine binary is missing" do
    # On :host (this test env has no balena-engine on PATH) System.cmd/3
    # would otherwise raise ErlangError (:enoent) straight through every
    # public wrapper. Confirms the rescue in the shared exec helper keeps
    # the same {output, exit_status} shape instead.
    test "info/0 returns the not-found tuple instead of raising" do
      assert Engine.info() == {"balena-engine binary not found", 127}
    end

    test "ps/0 returns the not-found tuple instead of raising" do
      assert Engine.ps() == {"balena-engine binary not found", 127}
    end
  end
end
