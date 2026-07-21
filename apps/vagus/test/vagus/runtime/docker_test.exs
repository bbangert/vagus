defmodule Vagus.Runtime.DockerTest do
  use ExUnit.Case, async: false

  alias Vagus.Runtime.Docker

  describe "transport errors (hermetic — no daemon)" do
    @bad_socket "/tmp/vagus-nonexistent-#{System.unique_integer([:positive])}.sock"

    test "request against a missing socket returns a connect error, never raises" do
      assert {:error, {:connect, _reason}} = Docker.request(:get, "/version", socket: @bad_socket)
    end

    test "ping against a missing socket returns an error" do
      assert {:error, _} = Docker.ping(socket: @bad_socket)
    end

    test "socket_path/0 falls back to the host default" do
      assert Docker.socket_path() == "/var/run/docker.sock"
    end
  end

  describe "container ref validation (hermetic — rejects before any connect)" do
    @malicious ["../images/create?fromImage=evil", "a/b", "a?b", "?x", "/x", "..", ""]

    test "path-op refs outside the Docker charset are rejected, no daemon touched" do
      for ref <- @malicious do
        assert {:error, {:invalid_ref, ^ref}} = Docker.start_container(ref)
        assert {:error, {:invalid_ref, ^ref}} = Docker.stop_container(ref)
        assert {:error, {:invalid_ref, ^ref}} = Docker.restart_container(ref)
        assert {:error, {:invalid_ref, ^ref}} = Docker.remove_container(ref)
        assert {:error, {:invalid_ref, ^ref}} = Docker.inspect_container(ref)
      end
    end

    test "a non-string ref is rejected" do
      assert {:error, {:invalid_ref, :not_a_string}} = Docker.start_container(nil)
    end

    test "legitimate names/ids pass validation (fail later at connect, not at the ref check)" do
      # valid ref → not an :invalid_ref error; with no daemon it fails at connect.
      assert {:error, {:connect, _}} =
               Docker.start_container("addon_core_mosquitto",
                 socket: "/tmp/nope-#{System.unique_integer([:positive])}.sock"
               )
    end
  end

  describe "image ref validation (hermetic — rejects before any connect, W1)" do
    @malicious_images [
      "../images/create?fromImage=evil",
      "a/../../etc",
      "..",
      "/etc/passwd",
      "repo:tag?x",
      "repo#frag",
      "repo tag with space",
      ""
    ]

    test "path-op image refs outside the docker-reference charset are rejected" do
      for ref <- @malicious_images do
        assert {:error, {:invalid_ref, ^ref}} = Docker.remove_image(ref)
      end
    end

    test "a non-string image ref is rejected" do
      assert {:error, {:invalid_ref, :not_a_string}} = Docker.remove_image(nil)
    end

    test "legitimate image refs (namespaces, tags, registry host:port) pass validation" do
      for ref <- [
            "alpine",
            "alpine:3",
            "homeassistant/amd64-addon-mosquitto:7.1.0",
            "ghcr.io:443/org/img:1.0",
            "library/ubuntu@sha256:abc123"
          ] do
        assert {:error, {:connect, _}} =
                 Docker.remove_image(ref,
                   socket: "/tmp/nope-#{System.unique_integer([:positive])}.sock"
                 )
      end
    end
  end

  describe "against a live daemon" do
    @describetag :docker

    @image "alpine:3"

    test "ping / version / info" do
      assert :ok = Docker.ping()
      assert {:ok, %{"ApiVersion" => api}} = Docker.version()
      assert is_binary(api)
      assert {:ok, %{"OperatingSystem" => _}} = Docker.info()
    end

    test "pull → create → start → inspect → stop → remove lifecycle" do
      name = "vagus-rt-test-#{System.unique_integer([:positive])}"
      on_exit(fn -> Docker.remove_container(name, force: true) end)

      assert :ok = Docker.pull_image(@image)

      config = %{"Image" => @image, "Cmd" => ["sleep", "30"], "HostConfig" => %{}}
      assert {:ok, id} = Docker.create_container(config, name: name)
      assert is_binary(id)

      assert :ok = Docker.start_container(name)
      assert {:ok, %{"State" => %{"Running" => true}}} = Docker.inspect_container(name)

      # start is idempotent (already-running → :ok)
      assert :ok = Docker.start_container(name)

      assert {:ok, containers} = Docker.list_containers(all: true)
      assert Enum.any?(containers, fn c -> "/#{name}" in (c["Names"] || []) end)

      assert :ok = Docker.stop_container(name, timeout: 1)
      assert {:ok, %{"State" => %{"Running" => false}}} = Docker.inspect_container(name)

      assert :ok = Docker.remove_container(name)
      assert {:error, {:http, 404, _}} = Docker.inspect_container(name)
    end

    test "pull of a nonexistent image reports a stream error, not :ok" do
      assert {:error, {:pull_failed, _}} =
               Docker.pull_image(
                 "vagus-does-not-exist-#{System.unique_integer([:positive])}:nope"
               )
    end

    test "remove of a missing container is idempotent :ok" do
      assert :ok =
               Docker.remove_container("vagus-rt-missing-#{System.unique_integer([:positive])}")
    end
  end
end
